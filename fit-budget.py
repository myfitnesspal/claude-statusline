#!/usr/bin/env python3
"""Fit the account's 5h and 7d usage-window caps in $ and tokens from statusline history.

Data source: ~/.claude-statusline/usage-history.jsonl — one JSON object per statusline
render, from EVERY session (tagged with session_id). Because every concurrent session
logs here, we reconstruct ACCOUNT-WIDE cost at any instant as the sum of each session's
latest cost_usd — which removes the multi-session contamination that makes a single
session's Delta-cost a floor.

Method (per context/throttle-budget-methodology.md): within one usage window the meter %
rises ~monotonically with account cost; least-squares slope of account_cost vs meter%
gives cost-per-percent; x100 = the window cap in $. Tokens via the measured anchor
($142 <-> 12.1M all-uncached tokens => ~85,200 uncached tokens/$; refine as logs allow).

The 7d cap is wide until a LARGE clean 7d span accumulates (one window only moves 7d
~5-6 integer points; +-1 rounding on that is +-15-20%). Re-run this as days accrue;
the reported +- shrinks with the span. Usage on claude.ai / non-Code clients is NOT
captured here (no statusline) and remains an unmodeled floor on the account total.
"""
import json, glob, os, math, sys

HISTORY = os.path.expanduser("~/.claude-statusline/usage-history.jsonl")
TOKENS_PER_USD = 12.1e6 / 142.0     # measured anchor; all-uncached tokens per dollar

def load():
    rows = []
    for line in open(HISTORY, encoding="utf-8", errors="replace") if os.path.exists(HISTORY) else []:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
            d["ts"] = int(d["ts"])
            d["cost_usd"] = float(d["cost_usd"])
            d["session_id"] = str(d.get("session_id", "?"))
        except (ValueError, KeyError, TypeError):
            continue
        # 5h/7d pct may be null right after a plan/limit gap
        for k in ("five_hour_pct", "seven_day_pct"):
            try:
                d[k] = int(d[k])
            except (ValueError, TypeError):
                d[k] = None
        rows.append(d)
    rows.sort(key=lambda r: r["ts"])
    return rows

def account_series(rows):
    """(ts, account_cost, 5h%, 7d%, 5h_reset, 7d_reset) with account_cost summed across sessions."""
    latest = {}
    out = []
    for r in rows:
        latest[r["session_id"]] = r["cost_usd"]
        out.append((r["ts"], sum(latest.values()),
                    r["five_hour_pct"], r["seven_day_pct"],
                    r.get("five_hour_reset"), r.get("seven_day_reset")))
    return out

def lsq(xs, ys):
    """slope, slope_stderr for y = a + b*x."""
    n = len(xs)
    if n < 2:
        return None, None
    mx = sum(xs) / n
    my = sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx == 0:
        return None, None
    b = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx
    if n < 3:
        return b, None
    a = my - b * mx
    resid = sum((y - (a + b * x)) ** 2 for x, y in zip(xs, ys))
    se = math.sqrt((resid / (n - 2)) / sxx)
    return b, se

def fit_window(series, pct_idx, reset_idx, label):
    # group points by the window's reset epoch (one group = one window)
    groups = {}
    for p in series:
        reset = p[reset_idx]
        pct = p[pct_idx]
        if reset in (None, "", "null") or pct is None:
            continue
        groups.setdefault(reset, []).append((pct, p[1]))  # (meter%, account_cost)
    best = None
    for reset, pts in groups.items():
        pcts = [p[0] for p in pts]
        span = max(pcts) - min(pcts)
        if span < 2 or len(pts) < 2:
            continue
        b, se = lsq(pcts, [p[1] for p in pts])
        if b is None or b <= 0:
            continue
        cand = {"reset": reset, "n": len(pts), "span": span,
                "cap_usd": b * 100, "se_usd": (se * 100 if se else None)}
        # prefer the window with the largest span (tightest estimate)
        if best is None or span > best["span"]:
            best = cand
    print(f"== {label} window cap ==")
    if best is None:
        print("  not enough clean span yet (need a window with >=2 pts spanning >=2%). Keep accumulating.")
        return
    cap = best["cap_usd"]
    tok = cap * TOKENS_PER_USD
    ci = f" +-${best['se_usd']:.0f}" if best["se_usd"] is not None else " (need >=3 pts for a CI)"
    print(f"  cap ~ ${cap:,.0f}/window{ci}   (~{tok/1e6:.0f}M all-uncached tokens)")
    print(f"  basis: {best['n']} pts over a {best['span']}% span in one window"
          + ("" if best["span"] >= 15 else "  <- span still small; widen it to tighten"))

def main():
    rows = load()
    print(f"history: {len(rows)} snapshots"
          + (f" across {len({r['session_id'] for r in rows})} session(s)" if rows else "")
          + f"  ({HISTORY})")
    if not rows:
        print("no data yet — the patched statusline appends here each render. Re-run after some usage.")
        print(f"prior (methodology.md): 5h ~ $142 / ~12M tok ; 7d ~ $1.4K / ~120M tok (wide).")
        return
    series = account_series(rows)
    fit_window(series, 2, 4, "5h")
    fit_window(series, 3, 5, "7d")
    print("\nnote: account cost = sum of every logged session's latest cost (multi-session-safe).")
    print("      claude.ai / non-Code usage is NOT logged here -> the account total is a mild floor.")

if __name__ == "__main__":
    main()
