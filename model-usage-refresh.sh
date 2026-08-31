#!/usr/bin/env bash
# Refresh the per-model weekly usage cache that statusline.sh renders.
#
# WHY THIS EXISTS: the StatuslineUpdate payload's rate_limits object is built from
# exactly three sources — five_hour, seven_day, and (gateway sessions only)
# spend_limit. The per-model weekly buckets that /usage shows as
# "Current week (Fable)" never reach the hook. They come from the endpoint /usage
# itself calls: GET /api/oauth/usage, whose `limits[]` array carries one
# kind=="weekly_scoped" entry per model bucket, each with scope.model.display_name
# and a 0-100 `percent`.
#
# Run OUT OF BAND, never in the render path: statusline.sh spawns this detached
# when the cache goes stale, so a render never blocks on the network.
#
# Requires: jq, curl
#
# Env:
#   STATUSLINE_MODEL_USAGE_CACHE    cache file (default ~/.claude-statusline/model-usage.json)
#   STATUSLINE_MODEL_USAGE_FIXTURE  read this file instead of calling the API (tests, debugging)
#   STATUSLINE_MODEL_USAGE_URL      endpoint override (default the production oauth usage endpoint)
#   STATUSLINE_MODEL_USAGE_TIMEOUT  curl timeout in seconds (default 10)
#   STATUSLINE_MODEL_USAGE_FIXTURE_STATUS       HTTP status to simulate with a fixture (default 200)
#   STATUSLINE_MODEL_USAGE_FIXTURE_RETRY_AFTER  retry-after seconds to simulate with a fixture
#
# THE ENDPOINT IS RATE LIMITED PER ACCOUNT, on an hours-scale window, and Claude
# Code's own /usage polling spends the same budget. A 429 carrying
# `retry-after: 3387` is a normal outcome, not a malfunction (measured 2026-08-31:
# the first call this script ever made was already throttled). So a 429 is recorded
# rather than retried: the absolute epoch the server named goes in the cache, and
# the statusline refuses to spawn again before it.

set -uo pipefail

CACHE="${STATUSLINE_MODEL_USAGE_CACHE:-$HOME/.claude-statusline/model-usage.json}"
URL="${STATUSLINE_MODEL_USAGE_URL:-https://api.anthropic.com/api/oauth/usage}"
TIMEOUT="${STATUSLINE_MODEL_USAGE_TIMEOUT:-10}"
CACHE_DIR=$(dirname "$CACHE")
LOG="$CACHE_DIR/model-usage.log"
LOCK="$CACHE.lock"
LOCK_STALE_SECS=120
LOG_MAX_BYTES=65536

mkdir -p "$CACHE_DIR" 2>/dev/null || true

now=$(date +%s)

# Errors go to a file because this process runs detached: its stderr has nowhere
# to land. Truncated rather than rotated — the log is a debugging aid, not a record.
log() {
	local size
	size=$(wc -c < "$LOG" 2>/dev/null | tr -d ' ') || size=0
	[ "${size:-0}" -gt "$LOG_MAX_BYTES" ] && : > "$LOG"
	printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG" 2>/dev/null || true
}

# Write the cache atomically. The tmp path carries the pid because concurrent
# sessions each run their own refresher: a shared tmp name lets the loser's
# rename die after the winner's rename consumes the file.
write_cache() {
	local body=$1 tmp="$CACHE.tmp.$$"
	printf '%s\n' "$body" > "$tmp" 2>/dev/null || { log "cache write failed: $tmp"; return 1; }
	mv -f "$tmp" "$CACHE" 2>/dev/null || { log "cache rename failed: $tmp -> $CACHE"; rm -f "$tmp"; return 1; }
}

# Record the attempt without touching the data. The three timestamps answer three
# different questions: `ts` is how old the numbers are, so the statusline hides a
# stale field on it; `checked_at` is when we last tried, so respawn backs off on it;
# `retry_after` is the absolute epoch the server told us to come back, so the spawn
# refuses outright before it. Keeping the previous buckets means one failed call
# degrades the display by age instead of blanking it.
#
# $1 = retry deadline as an absolute epoch, or 0 when the server named none.
record_failed_attempt() {
	local retry_at=${1:-0} prev_ts=0 prev_models='[]'
	if [ -f "$CACHE" ]; then
		prev_ts=$(jq -r '.ts // 0' "$CACHE" 2>/dev/null) || prev_ts=0
		prev_models=$(jq -c '.models // []' "$CACHE" 2>/dev/null) || prev_models='[]'
	fi
	case "$prev_ts" in ''|*[!0-9]*) prev_ts=0 ;; esac
	case "$retry_at" in ''|*[!0-9]*) retry_at=0 ;; esac
	write_cache "$(printf '{"ts":%s,"checked_at":%s,"retry_after":%s,"models":%s}' \
		"$prev_ts" "$now" "$retry_at" "$prev_models")"
}

# One refresher at a time per cache. mkdir is the atomic test-and-set; a lock older
# than LOCK_STALE_SECS is assumed abandoned (the holder died mid-run).
acquire_lock() {
	if mkdir "$LOCK" 2>/dev/null; then return 0; fi
	local age
	age=$(( now - $(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || echo "$now") ))
	if [ "$age" -gt "$LOCK_STALE_SECS" ]; then
		log "removing stale lock (${age}s old)"
		rmdir "$LOCK" 2>/dev/null || true
		mkdir "$LOCK" 2>/dev/null && return 0
	fi
	return 1
}

# The OAuth access token, from the credentials file if present, else the macOS
# keychain entry Claude Code stores it under.
read_token() {
	local f="$HOME/.claude/.credentials.json" raw=""
	if [ -f "$f" ]; then
		raw=$(jq -r '.claudeAiOauth.accessToken // empty' "$f" 2>/dev/null) || raw=""
		if [ -n "$raw" ]; then printf '%s' "$raw"; return 0; fi
	fi
	if command -v security >/dev/null 2>&1; then
		raw=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || raw=""
		if [ -n "$raw" ]; then
			raw=$(printf '%s' "$raw" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null) || raw=""
			if [ -n "$raw" ]; then printf '%s' "$raw"; return 0; fi
		fi
	fi
	return 1
}

if ! acquire_lock; then
	log "another refresher holds the lock; skipping"
	exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# Fetch the usage body: a saved fixture when one is named, else the live endpoint.
# Both paths produce the same three values, so the status handling below has one
# code path rather than a live branch the tests cannot reach.
body=""
http_code=200
retry_secs=0

if [ -n "${STATUSLINE_MODEL_USAGE_FIXTURE:-}" ]; then
	if [ ! -f "$STATUSLINE_MODEL_USAGE_FIXTURE" ]; then
		log "fixture not found: $STATUSLINE_MODEL_USAGE_FIXTURE"
		record_failed_attempt 0
		exit 1
	fi
	body=$(cat "$STATUSLINE_MODEL_USAGE_FIXTURE")
	http_code=${STATUSLINE_MODEL_USAGE_FIXTURE_STATUS:-200}
	retry_secs=${STATUSLINE_MODEL_USAGE_FIXTURE_RETRY_AFTER:-0}
else
	token=$(read_token) || {
		log "no OAuth access token in ~/.claude/.credentials.json or the keychain"
		record_failed_attempt 0
		exit 1
	}
	body_file="$CACHE.body.$$"
	hdr_file="$CACHE.hdr.$$"
	http_code=$(curl -sS --max-time "$TIMEOUT" \
		-o "$body_file" -D "$hdr_file" -w '%{http_code}' \
		-H "Authorization: Bearer $token" \
		-H "Content-Type: application/json" \
		"$URL" 2>>"$LOG") || {
		log "fetch failed: curl could not complete a request to $URL"
		rm -f "$body_file" "$hdr_file"
		record_failed_attempt 0
		exit 1
	}
	body=$(cat "$body_file" 2>/dev/null)
	# retry-after is seconds here, not a date, on every response measured so far.
	retry_secs=$(awk 'BEGIN{IGNORECASE=1} /^retry-after:/ {gsub(/[^0-9]/, "", $2); print $2; exit}' \
		"$hdr_file" 2>/dev/null)
	rm -f "$body_file" "$hdr_file"
fi

case "$http_code" in ''|*[!0-9]*) http_code=0 ;; esac
case "$retry_secs" in ''|*[!0-9]*) retry_secs=0 ;; esac
retry_at=0
[ "$retry_secs" -gt 0 ] && retry_at=$((now + retry_secs))

# A non-200 never reaches the parse. An error body can be perfectly good JSON, and
# parsing it would write an empty bucket list over a healthy cache.
if [ "$http_code" -ne 200 ]; then
	if [ "$retry_at" -gt 0 ]; then
		log "HTTP $http_code; server asked for ${retry_secs}s, not retrying before $retry_at"
	else
		log "HTTP $http_code with no retry-after; keeping previous data"
	fi
	record_failed_attempt "$retry_at"
	exit 1
fi

# A usage body is an object carrying at least one known window key. Anything else
# is an in-band error page or an auth failure, and must not overwrite good data
# with an empty bucket list — jq errors instead, routing to the failure path.
#
# `percent` is floored the way /usage floors it, so the statusline shows the same
# integer the dialog does.
parsed=$(printf '%s' "$body" | jq -c --argjson now "$now" '
	def known: [ "five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet",
	             "seven_day_oauth_apps", "extra_usage", "limits" ];
	if type != "object" then error("not an object")
	elif (keys - known) == keys then error("no usage window keys")
	else . end
	| { ts: $now, checked_at: $now, retry_after: 0,
	    models: [ .limits[]?
	      | select(.kind == "weekly_scoped")
	      | select(.scope.model.display_name != null)
	      | { name: .scope.model.display_name,
	          pct: ((.percent // 0) | if type == "number" then floor else 0 end),
	          resets_at: (.resets_at // null) } ] }' 2>>"$LOG") || parsed=""

if [ -z "$parsed" ]; then
	log "a 200 response was not a usage body; keeping previous data"
	record_failed_attempt 0
	exit 1
fi

write_cache "$parsed" || exit 1
exit 0
