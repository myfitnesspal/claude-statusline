#!/usr/bin/env bash
# Called by UserPromptSubmit hook to mark the start of a new round.
# The statusline reads this to calculate per-round deltas.
session_id=$(cat | jq -r '.session_id // "default"')
echo "reset" > "/tmp/claude-statusline-newround-${session_id}"
