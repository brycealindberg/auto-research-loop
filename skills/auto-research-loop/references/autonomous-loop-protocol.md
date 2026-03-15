# Autonomous Loop Protocol

Full protocol for the auto-research-loop. Covers both metric mode and task mode.

## Phase 0: Scratchpad Read

At the START of every iteration, read `.claude/auto-research-loop-scratchpad.md`. This contains notes from previous iterations — what worked, what failed, what to try next. Then snapshot its modification time so the stop hook can verify you updated it.

## Phase 1: Review

Build situational awareness before making changes:

1. Read current state of in-scope files
2. **Metric mode:** Read last 10-20 entries from `autoresearch-results.tsv` + `git log --oneline -20`
3. **Task mode:** Read `IMPLEMENTATION_PLAN.md` + `git log --oneline -20`
4. Identify: what worked, what failed, what's untried

After rollbacks, state may differ from what you expect. Never assume — always verify.

## Phase 2: Ideate

Pick the NEXT change. Priority order:

1. **Fix crashes/failures** from previous iteration
2. **Exploit successes** — try variants in the same direction
3. **Explore new approaches** — something the log shows hasn't been attempted
4. **Combine near-misses** — two changes that individually didn't help might work together
5. **Simplify** — remove code while maintaining metric
6. **Radical experiments** — when incremental changes stall

Don't repeat discarded changes. Don't make multiple unrelated changes at once. Don't chase marginal gains with ugly complexity.

## Phase 3: Modify

Make ONE focused change to in-scope files. Write the description BEFORE making the change.

## Phase 4: Commit

```bash
git add <changed-files>
git commit -m "experiment: <one-sentence description>"
```

Commit BEFORE verification so rollback is clean via `git reset --hard HEAD~1`.

## Phase 5: Verify

**Metric mode:** The stop hook automatically runs the verify command and compares to best metric. You don't need to run it yourself — just commit and let the hook handle it.

**Task mode:** Run backpressure gate commands (test/lint/typecheck) yourself before declaring completion. Check if your completion promise can be truthfully stated.

Timeout: 2x normal time = kill and treat as crash.

## Phase 6: Decide

**Metric mode** (handled by stop hook):
- Metric improved → KEEP (commit stays, best_metric updated)
- Metric same/worse → DISCARD (`git reset --hard HEAD~1`)
- Verify crashed → CRASH (revert, try different approach)
- Simplicity override: barely improved but adds complexity → discard. Unchanged but simpler → keep.

**Task mode:**
- Gates pass + promise true → EXIT LOOP
- Gates pass + work remains → continue, update plan
- Gates fail → fix in next iteration

## Phase 7: Log

**Metric mode:** Stop hook appends to `autoresearch-results.tsv` automatically.

**Task mode:** Update `IMPLEMENTATION_PLAN.md` — mark completed tasks `[x]`, add discovered work.

Both modes log to `.claude/auto-research-loop-log.jsonl`.

## Phase 8: Scratchpad Write

UPDATE `.claude/auto-research-loop-scratchpad.md` with:
- Current Understanding
- Decisions Made
- Approaches Tried (table with metric deltas)
- Blockers Found
- Files Modified
- Next Steps

The stop hook checks if you updated it and warns if you didn't.

## Phase 9: Repeat

**NEVER STOP. NEVER ASK "should I continue?"** Loop until max iterations, completion promise met, or circuit breaker triggers. Print brief status every ~5 iterations.

## When Stuck (>5 consecutive discards)

1. Re-read ALL in-scope files from scratch
2. Re-read the original goal
3. Review entire results log for patterns
4. Combine 2-3 previously successful changes
5. Try the OPPOSITE of what hasn't been working
6. Try a radical architectural change

## Crash Recovery

- Syntax error → fix immediately, don't count as iteration
- Runtime error → attempt fix (max 3 tries), then move on
- Resource exhaustion → revert, try smaller variant
- Hang → kill after timeout, revert, avoid that approach

## Backpressure Gates

Quality gates (`--test-cmd`, `--lint-cmd`, `--typecheck-cmd`) must pass before completion is accepted in task mode. Each has 60-second timeout. In metric mode, gates are informational only.

Run gate commands yourself before declaring completion to avoid wasted iterations.

## Circuit Breaker

Monitors git activity each iteration:
- **Progress** = at least one commit OR different working-tree diff
- **Stall** = no commits AND identical diff to previous iteration
- N consecutive stalls → auto-stop

Commit early and often. If stuck after 2 attempts, change approach fundamentally.
