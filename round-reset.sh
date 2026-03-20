#!/usr/bin/env bash
# Called by UserPromptSubmit hook to mark the start of a new round.
# The statusline reads this to calculate per-round deltas.
echo "reset" > /tmp/claude-statusline-newround
