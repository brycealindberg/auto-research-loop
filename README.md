# Auto Research Loop

A Claude Code plugin combining [Karpathy's autoresearch](https://github.com/karpathy/autoresearch) methodology with Ralph Loop infrastructure into a unified autonomous iteration engine.

**Go to sleep. Wake up to results.**

## What It Does

You give it a goal and a way to measure progress. It loops autonomously — making one change per iteration, verifying the result, keeping improvements, reverting regressions — until the metric hits your target or you stop it.

Each iteration gets a **fresh context window** (via `run-loop.sh`), so it can run 100+ iterations overnight without hitting context limits. Memory persists via scratchpad, git history, and results TSV — not conversation.

Two modes:

| | Metric Mode | Task Mode |
|---|---|---|
| **For** | Optimizing a number | Completing a task |
| **Decision** | Metric improved? Keep commit. Worse? `git revert` | Accumulate work toward completion |
| **Exit** | Max iterations or manual stop | Completion promise met + gates pass |
| **Example** | "Get test coverage to 90%" | "Build auth system with JWT" |

## Install

### From marketplace (recommended)

```bash
/plugin marketplace add brycealindberg/auto-research-loop
/plugin install auto-research-loop@auto-research-loop
```

Then restart Claude Code. You'll get `/auto-research-loop` and `/auto-research-loop-plan` slash commands.

### Test locally (for development)

```bash
git clone https://github.com/brycealindberg/auto-research-loop.git
claude --plugin-dir ./auto-research-loop
```

No restart needed — the plugin loads for that session. Use `/reload-plugins` to pick up changes.

## Usage

### Two ways to run

**Interactive (short runs, watch it work):**
```bash
/auto-research-loop "Increase test coverage to 90%" \
  --metric coverage --direction higher \
  --verify "pytest --cov=src | grep TOTAL | awk '{print \$4}'" \
  --max-iterations 10
```
Uses the stop hook — same session, context accumulates. Good for 5-15 iterations.

**Overnight (100+ iterations, fresh context each time):**
```bash
# Step 1: Set up (creates state file, branch, baseline)
/auto-research-loop "Increase test coverage to 90%" \
  --metric coverage --direction higher \
  --verify "pytest --cov=src | grep TOTAL | awk '{print \$4}'" \
  --max-iterations 100

# Step 2: Run the bash loop (fresh claude -p per iteration)
bash scripts/run-loop.sh
```

`run-loop.sh` spawns a new `claude -p` process per iteration — clean context every time, like Karpathy's autoresearch. Memory persists via files, not conversation.

### Planning wizard

```bash
/auto-research-loop-plan
```

Interactive 7-phase wizard that helps you pick the right metric, verify command, scope, and direction. Dry-runs the verify command to make sure it works. Outputs a ready-to-paste `/auto-research-loop` command.

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
- **Read-only protection**: `--read-only "tests/conftest.py"` locks evaluation files so the agent can't game the metric.
- **Circuit breaker**: Auto-stops after N consecutive stalled iterations (no commits + identical diff).
- **Task mode never reverts**: `git reset --hard` only runs in metric mode. Task mode just accumulates commits.
- **30-minute iteration timeout**: `run-loop.sh` kills hung iterations automatically.
- **Backpressure gates**: Test/lint/typecheck must pass before task completion is accepted.

## How It Works

```
LOOP (fresh context each iteration):
  0. Read scratchpad (persistent memory across iterations)
  1. Review state + git log + results/plan
  2. Ideate: fix crashes > exploit wins > explore > simplify > radical
  3. Modify: ONE focused change
  4. Commit: git commit BEFORE verification
  5. Verify: run metric command or gate commands
  6. Decide:
     Metric mode: IMPROVED -> keep. WORSE -> git reset --hard HEAD~1
     Task mode: gates pass + promise true -> exit
  7. Log results
  8. Update scratchpad
  9. Repeat (NEVER STOP)
```

### Infrastructure Created

| File | Purpose |
|------|---------|
| `.claude/auto-research-loop.local.md` | State file (delete to stop the loop) |
| `.claude/auto-research-loop-scratchpad.md` | Persistent memory across iterations |
| `.claude/auto-research-loop-log.jsonl` | Structured iteration logs (15 fields + cost estimates) |
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

# Overnight ML experiment (use run-loop.sh for fresh context)
/auto-research-loop "Improve LOCO-CV AUC above 0.75" \
  --metric loco_auc --direction higher \
  --verify "python train.py --quick 2>&1 | grep LOCO | awk '{print \$3}'" \
  --scope "train.py" --read-only "evaluate.py" \
  --timeout 600 --branch loco-experiments --max-iterations 100
# Then: bash scripts/run-loop.sh
```

## Architecture

Built from two proven systems:

**From [Karpathy's autoresearch](https://github.com/karpathy/autoresearch):**
- Fresh context per iteration (via `run-loop.sh` bash launcher)
- Metric-driven keep/discard via git
- Results TSV as experiment journal
- Simplicity pressure ("0.5% improvement + 20 lines ugly = discard")
- Read-only file protection (can't game the metric)
- Experiment branch isolation

**From Ralph Loop:**
- Stop hook that mechanically blocks exit and re-feeds the prompt
- Persistent scratchpad for cross-iteration memory (with mtime enforcement)
- Implementation plan with task tracking + stall/empty/done warnings
- Backpressure gates (test/lint/typecheck with 60s timeout)
- Circuit breaker (stall detection via diff hash + commit tracking)
- Structured JSONL logging with cost estimates
- Completion promise with anti-circumvention language

## File Structure

```
auto-research-loop/
  .claude-plugin/
    plugin.json                              # Plugin manifest
    marketplace.json                         # Self-hosted marketplace config
  commands/
    auto-research-loop.md                    # /auto-research-loop slash command
    auto-research-loop-plan.md               # /auto-research-loop-plan wizard
  hooks/
    hooks.json                               # Auto-registers stop hook
    stop-hook.sh                             # Same-session loop mechanism
  scripts/
    setup-auto-research-loop.sh              # Creates infrastructure + state file
    run-loop.sh                              # Overnight launcher (fresh context per iteration)
  skills/
    auto-research-loop/
      SKILL.md                               # Skill entry point
      references/
        autonomous-loop-protocol.md          # Full 9-phase loop protocol
        core-principles.md                   # 7 autoresearch principles
        results-logging.md                   # TSV format spec
        plan-workflow.md                     # Planning wizard protocol
```

## Stopping the Loop

Four ways:
1. **Delete the state file**: `rm .claude/auto-research-loop.local.md`
2. **Max iterations**: Set `--max-iterations N`
3. **Completion promise**: Task mode exits when promise is TRUE + gates pass
4. **Circuit breaker**: Triggers automatically after N consecutive stalls

## License

MIT
