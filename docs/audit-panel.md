# Audit Panel — the seven-agent review team

A reusable definition of the independent audit team used twice so far (2026-05-30 initial, 2026-05-31 delta re-audit). Each agent is spawned in parallel via the Agent tool with a self-contained brief, reads the repo read-only, and returns a <600-word report ending in a **PASS / WATCH / FAIL** verdict. The orchestrator synthesizes the seven reports and turns findings into fix bundles.

**Why this doc exists:** the prompts were originally passed inline and lived only in the chat transcript. This captures them so the panel is a repeatable instrument, not a one-off.

## How to run it

1. Spawn all seven in a single message (parallel) via the Agent tool, `subagent_type: general-purpose`, `run_in_background: true`.
2. Each prompt = role + "what's landed since your last pass" (the delta) + "your task" (numbered deliverables) + "end with PASS/WATCH/FAIL".
3. Collect verdicts into a table; convert findings into tasks/bundles; cite commits.
4. The **delta framing** is what makes re-audits cheap — tell each agent what changed since last time and ask what's closed / still open / newly surfaced.

## Shared prompt skeleton

```
You are the **<ROLE>** agent doing a delta re-audit of the Schindler 2.0 FPGA
project at /home/justin/Dropbox/_PROJECTS/Schindler-2.0. You previously flagged
<prior focus>. Goal now: report what's closed vs still open, plus what's new.

Branch under audit: iter5-1080p-clean (effective trunk).

What's landed since your last pass:
  <bulleted delta — commits, docs, memory entries, rule changes>

Your task: produce a concise re-audit under 600 words covering:
  1. Issues from your prior pass now closed (cite commit where known).
  2. Issues still open or only partially addressed.
  3. New issues introduced/surfaced by recent work.
  4. The 2-3 highest-priority items to queue next.

Read <relevant paths>. Don't modify anything.
End with a clear PASS / WATCH / FAIL verdict on <domain> health.
```

## The seven agents

### 1. HDL Audit
**Focus:** RTL correctness, CDC, timing/WNS, BD slot allocation, dead code.
**Reads:** `hdl/`, `constraints/zybo_z7_20_phase_b.xdc`, `tcl/build_phase_b.tcl`, `tcl/create_bd.tcl`, `docs/wiki/`, memory entries cited in commits.
**Signature findings:** chronic WNS=-3.5 ns (missing `/inst/` in XDC false-paths); `axi_gpio_7` slot collision blocking iter14 backport; stale `phase_b_top.v`; dead `scaler_coeffs_*` kept by synth-keep.

### 2. Documentation Cohesion
**Focus:** doc/code drift, stale refs, broken cross-links, version mismatches.
**Reads:** `docs/`, `docs/wiki/`, all `control-plane/*/README.md`, memory `MEMORY.md` + sample entries.
**Signature findings:** catalog v0.1.0→v0.2.0 incomplete propagation; production-substrate commit hash disagreeing across 5 docs; stale manifest header timestamp; `[[memory-link]]` + wiki internal-link resolution sweep.

### 3. Test Methodology
**Focus:** pre-bench sim coverage, mock-able CI, regression gates, the MS2109/coin-flip/provenance rules.
**Reads:** `tests/`, `control-plane/schindlerd/*.py`, `sim/`, `python/scaler_kernel_compare.py`, methodology memory entries.
**Signature findings:** V0a shipped with zero automated tests; no mock UART (FakeSerial was the fix); fragile TelemetryParser regexes; no `make sim` gate; no catalog schema validator.

### 4. Git Hygiene
**Focus:** branch sprawl, tags, commit provenance, branch model.
**Reads:** `git log --oneline --all`, `git branch -a`, `git tag --list 'archive/*'`, `docs/wiki/BRANCHES.md`, manifest "Branch model" section.
**Signature findings:** soft consolidation verified (5 archive tags, default flip); sibling drift accruing (mackin/phase-e1 commits behind); duplicate-subject backport commits; commit-message quality sample.

### 5. PM Trajectory
**Focus:** v1 ship target, scope creep, external dependencies, bench-vs-engineering bottleneck.
**Reads:** `docs/build-manifest.md`, `docs/control-plane-architecture.md`, `docs/format-support-matrix.md`, `docs/matrix-scope-cut-v1.md`, `docs/wiki/START-HERE.md`, roadmap memory.
**Signature findings:** v1 scope cut accepted but no ship date; Method-D-only decision implicit (made explicit in `v1-critical-path.md`); V0a sequel (V0b/V0c) scope-creep WATCH; Phase G chip the only external blocker.

### 6. Risk Audit
**Focus:** numbered risk register — close/open/new, with severity.
**Reads:** manifest, format matrix, recent commits, session-established rules.
**Signature findings:** #4 (matrix bench debt) + #10 (WNS) closed; HDMI 1080p60-OUT escalated (silicon-blocked); N1 V0a auth release-gate; N2 catalog filename↔schema_version mismatch; branch-drift risk.

### 7. Wiki Editor
**Focus:** wiki staleness vs codebase, missing pages, cross-link gaps.
**Reads:** all `docs/wiki/*.md`, `docs/control-plane-architecture.md`, `control-plane/*/README.md`, sample memory.
**Signature findings:** wiki lagged the entire V0a tier (0 of 19 pages referenced control-plane); 7 new pages owed (authored in the follow-up); BRANCHES.md citing a tip hash not in `git log`.

## Synthesis pattern

After collection:
- Roll verdicts into a table (agent | verdict | top concern).
- Look for **cross-agent agreement** — when ≥2 agents flag the same thing it jumps priority (e.g. Risk + Doc Cohesion both caught the catalog version mismatch).
- Convert findings to tasks; group into bundles; each bundle = one commit with the verdict-delta in the message.
- A WATCH closes only when there's a landed artifact (commit/test/doc), not an intention.

## Run history

- **2026-05-30** — initial 7-agent panel. Produced the wiki structure, scope-cut, WNS root-cause, branch-consolidation plan. Findings: doc cohesion PARTIAL, test methodology ⚠️, ~40 h verification debt.
- **2026-05-31** — delta re-audit after the V0a build + 6-item burn-down. 6 WATCH / 1 PASS initially; absorbed into 5 fix bundles → ended 6 PASS / 1 WATCH (HDL, on the Mackin-TB gap).
