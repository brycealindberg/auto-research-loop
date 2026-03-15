# Auto Research Loop

A Claude Code skill that combines [Karpathy's autoresearch](https://github.com/karpathy/autoresearch) methodology with Ralph Loop infrastructure into a unified autonomous iteration engine.

**Go to sleep. Wake up to results.**

## What It Does

You give it a goal and a way to measure progress. It loops autonomously — making one change per iteration, verifying the result, keeping improvements, reverting regressions — until the metric hits your target or you stop it.

Two modes:

| | Metric Mode | Task Mode |
|---|---|---|
| **For** | Optimizing a number | Completing a task |
| **Decision** | Metric improved? Keep commit. Worse? `git revert` | Accumulate work toward completion |
| **Exit** | Max iterations or manual stop | Completion promise met |
| **Example** | "Get test coverage to 90%" | "Build auth system with JWT" |

## Install

Copy to your Claude Code skills directory:

```bash
cp -r auto-research-loop ~/.claude/skills/auto-research-loop
chmod +x ~/.claude/skills/auto-research-loop/scripts/*.sh
```

## Usage

### Metric Mode — Improve a number

```bash
/auto-research-loop "Increase test coverage to 90%" \
  --metric coverage --direction higher \
  --verify "pytest --cov=src | grep TOTAL | awk '{print \$4}'" \
  --scope "tests/**/*.py" \
  --max-iterations 30
```

The skill automatically:
- Creates an isolated `autoresearch/arl-*` branch (safe by default)
- Captures the baseline metric
- Installs a stop hook that re-feeds the prompt after each iteration
- Runs the verify command, compares to best, keeps or `git reset --hard HEAD~1`
- Logs every experiment to `autoresearch-results.tsv`

### Task Mode — Complete a task

```bash
/auto-research-loop "Build REST API with CRUD endpoints and tests" \
  --completion-promise "All tests pass and API responds correctly" \
  --test-cmd "npm test" \
  --max-iterations 25
```

The agent breaks the task into subtasks, works through them one per iteration, and exits when the promise is genuinely true and all gates pass.

## Flags

### Metric Mode
| Flag | Description | Default |
|------|-------------|---------|
| `--metric <name>` | Metric name (e.g., "coverage") | Required |
| `--direction <higher\|lower>` | Is higher or lower better? | `higher` |
| `--verify <command>` | Shell command that outputs the metric value | Required |
| `--scope <glob>` | Files the agent can modify | All files |
| `--read-only <glob>` | Files the agent must NOT modify (protects evaluation logic) | None |
| `--timeout <seconds>` | Verify command timeout | `300` |
| `--branch <name>` | Experiment branch name | Auto-generated |

### Task Mode
| Flag | Description | Default |
|------|-------------|---------|
| `--completion-promise <text>` | Statement that must be TRUE to exit | None (loops forever) |

### Shared
| Flag | Description | Default |
|------|-------------|---------|
| `--max-iterations <n>` | Maximum iterations | Unlimited |
| `--test-cmd <command>` | Test gate (must pass before completion) | None |
| `--lint-cmd <command>` | Lint gate | None |
| `--typecheck-cmd <command>` | Type-check gate | None |
| `--max-failures <n>` | Circuit breaker threshold | `5` |

## Safety

- **Auto-branch in metric mode**: Forgetting `--branch` auto-creates `autoresearch/arl-<timestamp>`. Your main branch is never touched by `git reset`.
- **Read-only protection**: `--read-only "tests/conftest.py"` tells the agent the evaluation logic is locked. Improves the code, not the measurement.
- **Circuit breaker**: Auto-stops after N consecutive stalled iterations (no commits + identical diff).
- **Task mode never reverts**: `git reset --hard` only runs in metric mode. Task mode just accumulates commits.

## How It Works

```
LOOP:
  0. Read scratchpad (persistent memory across iterations)
  1. Review state + git log + results/plan
  2. Ideate: fix crashes > exploit wins > explore > simplify > radical
  3. Modify: ONE focused change
  4. Commit: git commit BEFORE verification
  5. Verify: run metric command or gate commands
  6. Decide:
     Metric mode: IMPROVED → keep. WORSE → git reset --hard HEAD~1
     Task mode: gates pass + promise true → exit
  7. Log results
  8. Update scratchpad
  9. Repeat (NEVER STOP)
```

### Infrastructure Created

| File | Purpose |
|------|---------|
| `.claude/auto-research-loop.local.md` | State file (delete to stop the loop) |
| `.claude/auto-research-loop-scratchpad.md` | Persistent memory across iterations |
| `.claude/auto-research-loop-log.jsonl` | Structured iteration logs with timing + cost estimates |
| `.claude/settings.local.json` | Stop hook configuration (auto-installed) |
| `IMPLEMENTATION_PLAN.md` | Task tracking with subtasks |
| `autoresearch-results.tsv` | Metric mode experiment journal (keep/discard/crash) |

## Examples

```bash
# Reduce bundle size
/auto-research-loop "Get First Load JS under 200KB" \
  --metric bundle_kb --direction lower \
  --verify "npm run build 2>&1 | grep 'First Load JS' | grep -oE '[0-9]+'" \
  --scope "src/**/*.{ts,tsx}" --timeout 120

# Improve Lighthouse score
/auto-research-loop "Hit 95+ Lighthouse performance" \
  --metric lighthouse --direction higher \
  --verify "npx lighthouse http://localhost:3000 --quiet --output json | jq '.categories.performance.score * 100'"

# Fix a complex bug
/auto-research-loop "Fix race condition in payment queue" \
  --completion-promise "Concurrent payment test passes with 0 duplicates" \
  --test-cmd "pytest tests/payments/ -x" --max-iterations 15

# Refactor with safety net
/auto-research-loop "Simplify auth module" \
  --metric loc --direction lower \
  --verify "npm test && wc -l src/auth/**/*.ts | tail -1 | awk '{print \$1}'" \
  --read-only "tests/**" --test-cmd "npm test"

# Overnight ML experiment
/auto-research-loop "Improve LOCO-CV AUC above 0.75" \
  --metric loco_auc --direction higher \
  --verify "python train.py --quick 2>&1 | grep LOCO | awk '{print \$3}'" \
  --scope "train.py" --read-only "evaluate.py" \
  --timeout 600 --branch loco-experiments
```

## Architecture

Built from two proven systems:

**From [Karpathy's autoresearch](https://github.com/karpathy/autoresearch):**
- Metric-driven keep/discard via git
- Results TSV as experiment journal
- Simplicity pressure ("0.5% improvement + 20 lines ugly = discard")
- Read-only file protection
- Experiment branch isolation

**From Ralph Loop:**
- Stop hook that mechanically blocks exit and re-feeds the prompt
- Persistent scratchpad for cross-iteration memory
- Implementation plan with task tracking
- Backpressure gates (test/lint/typecheck)
- Circuit breaker (stall detection)
- Structured JSONL logging with cost estimates

## File Structure

```
auto-research-loop/
  SKILL.md                                    # Entry point (447 words)
  scripts/
    setup-auto-research-loop.sh              # Creates infrastructure + installs hook
    stop-hook.sh                              # Loop mechanism (intercepts exit)
  references/
    autonomous-loop-protocol.md              # Full 9-phase loop protocol
    core-principles.md                       # 7 autoresearch principles
    results-logging.md                       # TSV format spec
    plan-workflow.md                         # /auto-research-loop:plan wizard
```

## Stopping the Loop

Three ways:
1. **Delete the state file**: `rm .claude/auto-research-loop.local.md`
2. **Max iterations**: Set `--max-iterations N`
3. **Circuit breaker**: Triggers automatically after N consecutive stalls

## License

MIT
