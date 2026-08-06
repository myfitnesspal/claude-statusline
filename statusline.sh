#!/usr/bin/env bash
# Claude Code Status Line
# [model] | [context] | [rate limits] | [cost]
#
# Context total colored by absolute token thresholds (retrieval quality):
#   green < 120K, yellow 120-250K, orange 250-400K, red >= 400K
#
# Requires: jq
# Requires: UserPromptSubmit hook running round-reset.sh

input=$(cat)
# Extract all fields in a single jq call (one per line)
_i=0 _f=()
while IFS= read -r _line; do _f[$((_i++))]=$_line; done < <(echo "$input" | jq -r '
	(.context_window.current_usage) as $u |
	(.session_id // "default"),
	(.model.display_name // ""),
	(.workspace.current_dir // .cwd // ""),
	(.workspace.project_dir // ""),
	(.agent.name // ""),
	(.worktree.name // ""),
	(.rate_limits.five_hour.used_percentage // "" | if type == "number" then floor else . end),
	(.rate_limits.five_hour.resets_at // ""),
	(.rate_limits.seven_day.used_percentage // "" | if type == "number" then floor else . end),
	(.rate_limits.seven_day.resets_at // ""),
	(.cost.total_cost_usd // 0),
	(($u.input_tokens // 0) + ($u.cache_creation_input_tokens // 0) + ($u.cache_read_input_tokens // 0)),
	(.context_window.context_window_size // 0),
	(.cost.total_api_duration_ms // 0),
	(.exceeds_200k_tokens // false)
')
session_id=${_f[0]}  model=${_f[1]}  cwd=${_f[2]}  project_dir=${_f[3]}
agent_name=${_f[4]}  worktree_name=${_f[5]}
limit_5h=${_f[6]}  limit_5h_reset=${_f[7]}  limit_7d=${_f[8]}  limit_7d_reset=${_f[9]}
cost=${_f[10]}  ctx_tokens=${_f[11]}  ctx_max=${_f[12]}  api_ms=${_f[13]}
exceeds_200k=${_f[14]}
STATE_FILE="/tmp/claude-statusline-${session_id}"
NEWROUND_FILE="/tmp/claude-statusline-newround-${session_id}"

# Auto-compact threshold: the token count that triggers compaction.
# CLAUDE_AUTOCOMPACT_PCT_OVERRIDE is Claude Code's OWN variable (do NOT namespace it):
# reading the same var Claude Code uses keeps the bar in sync with the real override.
# If set (e.g. 85), use it as the threshold percentage. Otherwise approximate:
# contextWindow - STATUSLINE_COMPACT_OVERHEAD (default 33000).
if [ -n "${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-}" ]; then
	compact_threshold=$((ctx_max * CLAUDE_AUTOCOMPACT_PCT_OVERRIDE / 100))
else
	compact_overhead=${STATUSLINE_COMPACT_OVERHEAD:-33000}
	compact_threshold=$((ctx_max - compact_overhead))
fi
[ "$compact_threshold" -le 0 ] && compact_threshold=1


# Colors
GREEN='\033[32m'
YELLOW='\033[33m'
ORANGE='\033[38;5;208m'
RED='\033[31m'
COLD='\033[38;5;33m'   # under-pace (cool blue, legible on light and dark)
NORMAL='\033[38;5;245m'
RESET='\033[0m'

# Bar widths, in cells. Two bars use them: the context usage bar and the 7d
# pace meter. Independent knobs (env-overridable) so either can be tuned
# alone; set them equal for a matched look.
STATUSLINE_CTX_BAR_WIDTH="${STATUSLINE_CTX_BAR_WIDTH:-8}"
STATUSLINE_PACE_BAR_WIDTH="${STATUSLINE_PACE_BAR_WIDTH:-8}"
# 7d pace meter tuning. STATUSLINE_PACE_TOL is the on-pace dead-band as a percent of urgency
# (0-100): urgency below it reads empty/on-pace. STATUSLINE_PACE_GAMMA shapes the response above
# the band — 1 = linear, 1.5 (default) / 2 / 3 keep the low end flatter and calmer,
# ramping up only as correcting gets urgent.
STATUSLINE_PACE_TOL="${STATUSLINE_PACE_TOL:-10}"
STATUSLINE_PACE_GAMMA="${STATUSLINE_PACE_GAMMA:-1.5}"

# Build a bar string: `filled` solid cells (█) out of `width`, the rest empty (░).
bar_of() {
	local filled=$1 width=$2 out="" i=0
	while [ "$i" -lt "$width" ]; do
		if [ "$i" -lt "$filled" ]; then out="${out}█"; else out="${out}░"; fi
		i=$((i + 1))
	done
	printf '%s' "$out"
}

# Integer square root (Newton's method).
_isqrt() {
	local n=$1 x y
	[ "$n" -lt 2 ] && { printf '%s' "$n"; return; }
	x=$n; y=$(( (x + 1) / 2 ))
	while [ "$y" -lt "$x" ]; do x=$y; y=$(( (x + n / x) / 2 )); done
	printf '%s' "$x"
}

# Apply STATUSLINE_PACE_GAMMA to a permille value (0-1000). Presets: 1 linear, 1.5 (default,
# flatter low end via x^1.5 = x*sqrt(x)), 2 (x^2), 3 (x^3). Unknown -> linear.
pace_shape() {
	local x=$1 s
	case "$STATUSLINE_PACE_GAMMA" in
		1|1.0) printf '%s' "$x" ;;
		1.5)   s=$(_isqrt $(( x * 1000 ))); printf '%s' "$(( x * s / 1000 ))" ;;
		2|2.0) printf '%s' "$(( x * x / 1000 ))" ;;
		3|3.0) printf '%s' "$(( x * x / 1000 * x / 1000 ))" ;;
		*)     printf '%s' "$x" ;;
	esac
}

# Human-friendly token formatting (1234 -> 1.2k, 200000 -> 200k, 1000000 -> 1M)
fmt_tokens() {
	local n=$1
	if [ "$n" -ge 1000000 ]; then
		local major=$((n / 1000000)) minor=$(( (n % 1000000) / 100000 ))
		if [ "$minor" -eq 0 ]; then printf '%sM' "$major"
		else printf '%s.%sM' "$major" "$minor"; fi
	elif [ "$n" -ge 1000 ]; then
		local major=$((n / 1000)) minor=$(( (n % 1000) / 100 ))
		if [ "$minor" -eq 0 ] || [ "$major" -ge 100 ]; then printf '%sk' "$major"
		else printf '%s.%sk' "$major" "$minor"; fi
	else
		printf '%s' "$n"
	fi
}

# State format v6: version|round_start_cost. Only the per-round cost baseline is
# persisted now. round_start_cost is field 2 of every prior format, so all legacy
# state files (v2-v5) still yield it on read; their extra fields are ignored.
round_start_cost=$cost
if [ -f "$STATE_FILE" ]; then
	IFS='|' read -r _ver _rsc _rest < "$STATE_FILE"
	case "$_ver" in
		6|5|4|3|2) round_start_cost=$_rsc ;;
	esac
fi
now=$(date +%s)

# New round = a fresh human turn (UserPromptSubmit hook): reset the round cost baseline.
if [ -f "$NEWROUND_FILE" ]; then
	round_start_cost=$cost
	rm -f "$NEWROUND_FILE"
fi

# Save state
echo "6|${round_start_cost}" > "$STATE_FILE"

# Usage snapshot for programmatic reads (agent self-throttling). Authoritative rate-limit
# fields come straight from Claude Code's statusline input; persisted here each render so a
# Bash poll can read live 5h/7d usage % + reset times. Written to a stable, session-scoped path.
# Also APPENDED (tagged with session_id) to a persistent history so account-wide cost can be
# reconstructed across concurrent sessions = Sum of each session's latest cost -> a
# contamination-free budget fit (see fit-budget.py). cost_usd is PER-SESSION; the % are account-wide.
usage_json=$(printf '{"five_hour_pct":%s,"five_hour_reset":"%s","seven_day_pct":%s,"seven_day_reset":"%s","cost_usd":%s,"ctx_tokens":%s,"ts":%s,"session_id":"%s"}' \
	"${limit_5h:-null}" "${limit_5h_reset}" "${limit_7d:-null}" "${limit_7d_reset}" "${cost:-0}" "${ctx_tokens:-0}" "${now}" "${session_id}")
printf '%s\n' "$usage_json" > "/tmp/claude-usage-${session_id}.json" 2>/dev/null
printf '%s\n' "$usage_json" >> "$HOME/.claude-statusline/usage-history.jsonl" 2>/dev/null

# Color for total context: absolute token thresholds (retrieval quality), plus the
# long-context pricing cliff. Orange normally marks retrieval degradation (>=250K),
# but Claude Code's exceeds_200k_tokens flag (premium long-context pricing kicks in
# above 200K on 1M-context models) starts orange earlier, at the cliff, and it runs
# through to the red retrieval catastrophe (>=400K). The flag can't be true on a
# 200K-window session (context can't exceed the window), so those are unaffected.
usable_cap=$((compact_threshold < 400000 ? compact_threshold : 400000))
compact_pct=$((ctx_tokens * 100 / usable_cap))
if [ "$ctx_tokens" -ge 400000 ]; then
	ctx_color="$RED"
elif [ "$exceeds_200k" = "true" ] || [ "$ctx_tokens" -ge 250000 ]; then
	ctx_color="$ORANGE"
elif [ "$ctx_tokens" -ge 120000 ]; then
	ctx_color="$YELLOW"
else
	ctx_color="$GREEN"
fi

# Context usage bar: fill = ctx_tokens / usable_cap, so a full bar is the
# min(compact_threshold, 400000) ceiling. Fill inherits ctx_color (absolute token
# thresholds). Overflow marker: a ▶ arrowhead fused to the bar (adds one cell,
# reading as the bar continuing off-scale), shown only in the red retrieval zone
# (>= 400K) and strictly past the ceiling. On a small window the ceiling is the
# compact threshold (< 400K, unreachable-red), so the bar just pegs full with no
# marker — auto-compact self-heals, so it needs no alarm glyph.
ctx_filled=$(( (compact_pct * STATUSLINE_CTX_BAR_WIDTH + 50) / 100 ))
[ "$ctx_filled" -gt "$STATUSLINE_CTX_BAR_WIDTH" ] && ctx_filled=$STATUSLINE_CTX_BAR_WIDTH
ctx_bar=$(bar_of "$ctx_filled" "$STATUSLINE_CTX_BAR_WIDTH")
if [ "$ctx_tokens" -ge 400000 ] && [ "$ctx_tokens" -gt "$usable_cap" ]; then
	ctx_bar="${ctx_bar}▶"
fi

# Format duration from seconds (e.g. 3661 -> "1h1m", 90 -> "1m", 86400 -> "1d")
fmt_duration() {
	local secs=$1
	if [ "$secs" -le 0 ]; then
		printf '<1m'
		return
	fi
	local days=$((secs / 86400))
	local hours=$(( (secs % 86400) / 3600 ))
	local mins=$(( (secs % 3600) / 60 ))
	if [ "$days" -gt 0 ]; then
		printf '%dd%dh' "$days" "$hours"
	elif [ "$hours" -gt 0 ]; then
		printf '%dh%dm' "$hours" "$mins"
	else
		printf '%dm' "$mins"
	fi
}

# Format rate limits with color coding and time remaining
fmt_limit() {
	local pct=$1
	local reset_ts=$2
	if [ -z "$pct" ]; then
		return
	fi
	local color="$NORMAL"
	if [ "$pct" -ge 80 ]; then
		color="$RED"
	elif [ "$pct" -ge 50 ]; then
		color="$YELLOW"
	fi
	local label=""
	if [ -n "$reset_ts" ]; then
		local now
		now=$(date +%s)
		local remaining=$((reset_ts - now))
		label=$(fmt_duration "$remaining")
	else
		label="?"
	fi
	printf '%b%s %s%%%b' "$color" "$label" "$pct" "$NORMAL"
}

# Auth/plan mode letter, shown after the model. K = ANTHROPIC_API_KEY in env
# (pay-per-token API billing). Otherwise the letter reflects the OAuth account's
# organizationType: M = Max, P = Pro, T = Team, E = Enterprise. A = any other
# non-empty org type (unknown/fallback). Hidden when logged out with no key.
# The env var wins because Claude Code prefers an approved ANTHROPIC_API_KEY
# over the stored OAuth login.
# STATUSLINE_JSON_PATH overrides the credential file location (tests).
auth_letter=""
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
	auth_letter="K"
else
	claude_json="${STATUSLINE_JSON_PATH:-$HOME/.claude.json}"
	if [ -f "$claude_json" ]; then
		org_type=$(jq -r 'if .oauthAccount then (.oauthAccount.organizationType // "unknown") else "" end' "$claude_json" 2>/dev/null)
		case "$org_type" in
			claude_max) auth_letter="M" ;;
			claude_pro) auth_letter="P" ;;
			claude_team) auth_letter="T" ;;
			claude_enterprise) auth_letter="E" ;;
			"") auth_letter="" ;;
			*) auth_letter="A" ;;
		esac
	fi
fi

# Day name (mon/tue/.../sun, case/prefix-insensitive) -> 1..7 (Mon=1), 0 if invalid.
_pace_dow() {
	case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in
		mon*) echo 1 ;; tue*) echo 2 ;; wed*) echo 3 ;; thu*) echo 4 ;;
		fri*) echo 5 ;; sat*) echo 6 ;; sun*) echo 7 ;; *) echo 0 ;;
	esac
}

# Effective pace horizon: the latest work-active instant at or before the reset, per
# STATUSLINE_PACE_WORK ("<days> <start>-<end>" local 24h, e.g. "Mon-Fri 09-18"; days a range
# like Mon-Fri or a comma list like Mon,Wed,Fri; hours HH or HH:MM). Echoes that
# epoch; echoes nothing and returns 1 if STATUSLINE_PACE_WORK is unset or malformed. $1 = now
# epoch, $2 = reset epoch. Wall-clock components are derived from the epoch plus the
# current `date +%z` offset — pure arithmetic, portable, DST-approximate (offset
# sampled once). If the reset falls inside work hours the horizon IS the reset (you
# work right up to it); if it falls in off-hours the horizon is the preceding
# work-end, so the meter later hides once that work-end is behind you.
pace_horizon() {
	local now=$1 reset=$2 spec days_spec hours_spec start_spec end_spec
	spec="${STATUSLINE_PACE_WORK:-}"
	[ -z "$spec" ] && return 1
	days_spec="${spec%% *}"
	hours_spec="${spec#* }"; hours_spec="${hours_spec// /}"
	[ "$hours_spec" = "$spec" ] && return 1        # no space between days and hours
	case "$hours_spec" in *-*) : ;; *) return 1 ;; esac
	start_spec="${hours_spec%%-*}"; end_spec="${hours_spec##*-}"
	local sh sm eh em start_secs end_secs
	case "$start_spec" in *:*) sh="${start_spec%%:*}"; sm="${start_spec##*:}" ;; *) sh="$start_spec"; sm=0 ;; esac
	case "$end_spec"   in *:*) eh="${end_spec%%:*}";   em="${end_spec##*:}"   ;; *) eh="$end_spec";   em=0 ;; esac
	case "${sh}${sm}${eh}${em}" in ''|*[!0-9]*) return 1 ;; esac
	start_secs=$(( 10#$sh * 3600 + 10#$sm * 60 ))
	end_secs=$(( 10#$eh * 3600 + 10#$em * 60 ))
	{ [ "$start_secs" -ge "$end_secs" ] || [ "$end_secs" -gt 86400 ]; } && return 1

	# Build a work-day membership string " d d ... " from a range or comma list.
	local work_dows=" " a b n part IFS
	case "$days_spec" in
		*-*)
			a=$(_pace_dow "${days_spec%%-*}"); b=$(_pace_dow "${days_spec##*-}")
			{ [ "$a" = 0 ] || [ "$b" = 0 ]; } && return 1
			n=$a
			while : ; do work_dows="${work_dows}${n} "; [ "$n" = "$b" ] && break; n=$(( n % 7 + 1 )); done ;;
		*,*)
			IFS=,
			for part in $days_spec; do
				n=$(_pace_dow "$part"); [ "$n" = 0 ] && return 1
				work_dows="${work_dows}${n} "
			done ;;
		*)
			a=$(_pace_dow "$days_spec"); [ "$a" = 0 ] && return 1
			work_dows="${work_dows}${a} " ;;
	esac

	# tz offset (seconds) from date +%z (+HHMM / -HHMM), applied to reach local time.
	local z sign zh zm off
	z=$(date +%z); sign="${z%"${z#?}"}"; zh="${z:1:2}"; zm="${z:3:2}"
	off=$(( 10#$zh * 3600 + 10#$zm * 60 )); [ "$sign" = "-" ] && off=$(( -off ))

	# Local components of the reset.
	local rl rdow rsecs rmid
	rl=$(( reset + off ))
	rdow=$(( (rl / 86400 + 3) % 7 + 1 ))
	rsecs=$(( rl - (rl / 86400) * 86400 ))
	rmid=$(( reset - rsecs ))                        # epoch of the reset's local midnight

	# Reset itself inside work hours -> you work up to it -> horizon = reset.
	case "$work_dows" in *" $rdow "*)
		if [ "$rsecs" -ge "$start_secs" ] && [ "$rsecs" -lt "$end_secs" ]; then
			printf '%s' "$reset"; return 0
		fi ;;
	esac

	# Otherwise the latest work-end at or before the reset.
	local k dm dow cand
	k=0
	while [ "$k" -le 7 ]; do
		dm=$(( rmid - k * 86400 ))
		dow=$(( ((dm + off) / 86400 + 3) % 7 + 1 ))
		cand=$(( dm + end_secs ))
		case "$work_dows" in *" $dow "*)
			[ "$cand" -le "$reset" ] && { printf '%s' "$cand"; return 0; } ;;
		esac
		k=$(( k + 1 ))
	done
	return 1
}

# 7d pace meter, appended to the 7d limit — a bidirectional gas-pedal gauge around
# the cruise rate that would land you at exactly 100% used at the horizon. It shows
# how far your foot is from cruise, WEIGHTED BY HOW LITTLE TIME IS LEFT to move it:
#   wall = seconds until you'd hit 100% at your current average rate
#   r    = time-to-horizon / wall        (r=1 on pace; >1 too hot; <1 too cold)
# HOT (r > 1, pressing harder than cruise -> you'd wall before the horizon) fills from
# the LEFT and escalates yellow -> orange -> red. COLD (r < 1, pressing softer -> you'd
# reach the horizon with budget unused, lost at reset) fills from the RIGHT in blue and
# never escalates (a milder, cliff-free cost). The fill is URGENCY = how little slack
# is left, so it stays calm early (plenty of time to correct) and rises as the horizon
# nears — a steady off-pace burn is near-empty most of the week, filling only when
# scaling back (hot) or flooring it (cold) is actually urgent. STATUSLINE_PACE_TOL is the on-pace
# dead-band; STATUSLINE_PACE_GAMMA shapes how flat the calm end stays. No overflow marker (a full
# hot bar already means back off hard). Hidden the first ~8h.
#
# The horizon is the reset by default. Set STATUSLINE_PACE_WORK ("<days> <start>-<end>" local,
# e.g. "Mon-Fri 09-18") to judge pace against your work schedule instead: the burn
# rate is still measured over the real elapsed window, but "do I run dry in time?" is
# asked against the last work-active instant at or before the reset (see pace_horizon).
# Unlike a fixed weekday deadline this stays correct when the reset drifts mid-week —
# a reset during work hours simply yields the reset itself. Once that work moment is
# behind you (coasting to the reset), the meter hides. STATUSLINE_PACE_HORIZON_TS is an
# absolute-epoch override of the computed horizon (advanced / tests).
fmt_pace() {
	local pct=$1
	local reset_ts=$2
	[ -z "$pct" ] && return
	[ -z "$reset_ts" ] && return
	[ "$pct" -le 0 ] && return
	local now window remaining_reset elapsed horizon h remaining wall hot u tolp e cells w color
	now=$(date +%s)
	window=604800
	remaining_reset=$((reset_ts - now))
	[ "$remaining_reset" -le 0 ] && return
	[ "$remaining_reset" -gt "$window" ] && remaining_reset=$window
	elapsed=$((window - remaining_reset))
	[ "$elapsed" -lt $((window / 20)) ] && return   # <~8.4h in: not enough to extrapolate

	# Effective horizon: the work-schedule horizon if set, else the reset; capped at
	# the reset. A horizon at or before now means the last work moment is behind you
	# (coasting to the reset) -> hide.
	horizon=$reset_ts
	if [ -n "${STATUSLINE_PACE_HORIZON_TS:-}" ]; then
		horizon=$STATUSLINE_PACE_HORIZON_TS
	elif [ -n "${STATUSLINE_PACE_WORK:-}" ]; then
		h=$(pace_horizon "$now" "$reset_ts") && [ -n "$h" ] && horizon=$h
	fi
	[ "$horizon" -gt "$reset_ts" ] && horizon=$reset_ts
	remaining=$((horizon - now))
	[ "$remaining" -le 0 ] && return

	# Gas-pedal urgency (permille). wall = time to hit 100% at the current rate; the
	# side is hot when you'd hit it before the horizon, cold when after. Urgency is the
	# fraction of the near-horizon slack you've used up, so it climbs toward the horizon.
	w=$STATUSLINE_PACE_BAR_WIDTH
	wall=$(( (100 - pct) * elapsed / pct ))
	if [ "$remaining" -gt "$wall" ]; then
		hot=1; u=$(( (remaining - wall) * 1000 / remaining ))
	else
		hot=0; u=$(( (wall - remaining) * 1000 / wall ))
	fi

	# Dead-band, then gamma-shape the remainder into bar cells.
	tolp=$(( STATUSLINE_PACE_TOL * 10 ))
	if [ "$u" -le "$tolp" ]; then
		cells=0
	else
		e=$(( (u - tolp) * 1000 / (1000 - tolp) ))
		e=$(pace_shape "$e")
		cells=$(( (e * w + 500) / 1000 )); [ "$cells" -gt "$w" ] && cells=$w
	fi

	if [ "$cells" -eq 0 ]; then
		# On pace (within tolerance): neutral, empty.
		printf ' %b%b' "${NORMAL}$(bar_of 0 "$w")" "$NORMAL"
	elif [ "$hot" -eq 1 ]; then
		# Too hot: fills from the left, yellow -> orange -> red by magnitude.
		color="$YELLOW"; [ "$cells" -ge 3 ] && color="$ORANGE"; [ "$cells" -ge 6 ] && color="$RED"
		printf ' %b%b' "${color}$(bar_of "$cells" "$cells")${NORMAL}$(bar_of 0 $(( w - cells )))" "$NORMAL"
	else
		# Too cold: fills from the right, blue (never escalates).
		printf ' %b%b' "${NORMAL}$(bar_of 0 $(( w - cells )))${COLD}$(bar_of "$cells" "$cells")" "$NORMAL"
	fi
}

# Shorten model name, append context size (e.g. "Opus 4.6 (1M context)" -> "O4.6·1M")
short_model="${model%% (*}"
short_model="${short_model/Opus /O}"
short_model="${short_model/Sonnet /S}"
short_model="${short_model/Haiku /H}"
short_model="${short_model} $(fmt_tokens "$ctx_max")"

# Show dir/agent/worktree only when context differs from project root
location=""
[ -n "$agent_name" ] && location="${agent_name}"
[ -n "$worktree_name" ] && location="${location:+${location} }${worktree_name}"
[ "$cwd" != "$project_dir" ] && [ -z "$worktree_name" ] && location="${cwd##*/}"

# Subagent governance status (optional, no-op if not installed)
sa_status=""
if [ -f "$HOME/src/claude-config/hooks/subagent-status.sh" ]; then
	sa_state_file="/tmp/claude-subagent-state-${session_id}"
	if [ -f "$sa_state_file" ]; then
		if grep -q "^disabled$" "$sa_state_file" 2>/dev/null; then
			sa_status="${NORMAL}[sa:off]"
		else
			sa_status="${GREEN}[sa:on]"
		fi
	elif [ -f "$HOME/src/claude-config/subagents-disabled" ]; then
		sa_status="${NORMAL}[sa:off]"
	else
		sa_status="${GREEN}[sa:on]"
	fi
fi

parts="${NORMAL}${short_model}"
[ -n "$auth_letter" ] && parts="${parts} ${auth_letter}"
[ -n "$location" ] && parts="${parts} ${location}"
[ -n "$sa_status" ] && parts="${parts} ${sa_status}${NORMAL}"
parts="${parts} |"
parts="${parts} ${ctx_color}$(fmt_tokens "$ctx_tokens") ${ctx_bar}${NORMAL}"
api_secs=$((api_ms / 1000))
round_cost=$(awk "BEGIN {printf \"%.2f\", $cost - $round_start_cost}")
cost_fmt=$(printf '%s +$%s $%.2f' "$(fmt_duration "$api_secs")" "$round_cost" "$cost")
limit_parts=""
if [ -n "$limit_5h" ]; then
	limit_parts="$(fmt_limit "$limit_5h" "$limit_5h_reset")"
	[ -n "$limit_7d" ] && limit_parts="${limit_parts} · $(fmt_limit "$limit_7d" "$limit_7d_reset")$(fmt_pace "$limit_7d" "$limit_7d_reset")"
	parts="${parts} | ${limit_parts}"
fi
parts="${parts} | ${cost_fmt}${RESET}"
printf '%b' "$parts"
