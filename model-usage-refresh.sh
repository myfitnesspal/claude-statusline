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

# Record the attempt without touching the data. `ts` is how old the numbers are,
# `checked_at` is when we last tried: the statusline hides a stale field on `ts`
# and backs off respawning on `checked_at`. Keeping the previous buckets means one
# failed call degrades the display by age instead of blanking it.
record_failed_attempt() {
	local prev_ts=0 prev_models='[]'
	if [ -f "$CACHE" ]; then
		prev_ts=$(jq -r '.ts // 0' "$CACHE" 2>/dev/null) || prev_ts=0
		prev_models=$(jq -c '.models // []' "$CACHE" 2>/dev/null) || prev_models='[]'
	fi
	case "$prev_ts" in ''|*[!0-9]*) prev_ts=0 ;; esac
	write_cache "$(printf '{"ts":%s,"checked_at":%s,"models":%s}' "$prev_ts" "$now" "$prev_models")"
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
body=""
if [ -n "${STATUSLINE_MODEL_USAGE_FIXTURE:-}" ]; then
	if [ -f "$STATUSLINE_MODEL_USAGE_FIXTURE" ]; then
		body=$(cat "$STATUSLINE_MODEL_USAGE_FIXTURE")
	else
		log "fixture not found: $STATUSLINE_MODEL_USAGE_FIXTURE"
		record_failed_attempt
		exit 1
	fi
else
	token=$(read_token) || {
		log "no OAuth access token in ~/.claude/.credentials.json or the keychain"
		record_failed_attempt
		exit 1
	}
	body=$(curl -sS --max-time "$TIMEOUT" \
		-H "Authorization: Bearer $token" \
		-H "Content-Type: application/json" \
		"$URL" 2>>"$LOG") || {
		log "fetch failed: curl exited $? for $URL"
		record_failed_attempt
		exit 1
	}
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
	| { ts: $now, checked_at: $now,
	    models: [ .limits[]?
	      | select(.kind == "weekly_scoped")
	      | select(.scope.model.display_name != null)
	      | { name: .scope.model.display_name,
	          pct: ((.percent // 0) | if type == "number" then floor else 0 end),
	          resets_at: (.resets_at // null) } ] }' 2>>"$LOG") || parsed=""

if [ -z "$parsed" ]; then
	log "response was not a usage body; keeping previous data"
	record_failed_attempt
	exit 1
fi

write_cache "$parsed" || exit 1
exit 0
