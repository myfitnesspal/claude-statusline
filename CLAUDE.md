# claude-statusline

Custom statusline for Claude Code, displayed via the `StatuslineUpdate` hook.

## Auto-compact threshold

The context percentage shown in the statusline is relative to the auto-compact trigger, not the raw context window size.

Claude Code's auto-compact threshold is computed in the binary as:

```
threshold = contextWindow - min(maxOutputTokens, 20000) - 13000
```

This was found by running `strings` on the Claude Code binary and tracing the minified JS:
- `IeH(model, autoCompactWindow)` computes the threshold
- `yU(model, autoCompactWindow)` computes the effective window (`contextWindow - outputReserve`)
- `PYH(tokens, model, autoCompactWindow)` checks if tokens exceed the threshold
- Constants: `jn1=20000` (output reserve cap), `T_8=13000` (buffer before threshold)
- The env var `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` can override the percentage in Claude Code itself

We approximate the overhead as 33000 (configurable via `COMPACT_OVERHEAD` env var).

To re-derive if values change, search the binary:
```sh
strings $(which claude) | grep 'autocompact:.*threshold'
strings $(which claude) | grep -oE 'function IeH.{0,300}'
```