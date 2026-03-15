---
name: auto-research-loop
description: "Use when user wants autonomous iteration on any task — improving metrics, completing features, running experiments, optimizing code, or working unattended. Make sure to use this skill whenever someone mentions autoresearch, autonomous loops, iterating until done, running overnight, keep improving, hill-climbing, or any measurable improvement goal, even if they don't explicitly ask for a 'loop'."
---

# Auto Research Loop — Autonomous Iteration Engine

Combines [Karpathy's autoresearch](https://github.com/karpathy/autoresearch) with Ralph Loop infrastructure. Modify, Verify, Keep/Discard, Repeat.

## Invocation

**`/auto-research-loop [PROMPT] [FLAGS]`** — Run the loop:

```!
"$HOME/.claude/skills/auto-research-loop/scripts/setup-auto-research-loop.sh" $ARGUMENTS
```

Then follow the injected instructions. The stop hook auto-installs and intercepts exit to re-feed the prompt.

**`/auto-research-loop:plan`** — Interactive planning wizard:

Don't run the setup script. Instead, read `references/plan-workflow.md` and walk the user through 7 phases to build a validated configuration:
1. Capture goal
2. Analyze codebase context
3. Define scope (which files to modify)
4. Define metric (must be mechanical — a command that outputs a number)
5. Define direction (higher or lower is better)
6. Define verify command (dry-run it to confirm it works)
7. Confirm and launch — output a ready-to-paste `/auto-research-loop` command

Use this wizard when the user says "help me set up", "plan a run", "what should my metric be", or invokes `:plan`.

## Two Modes

| | Metric Mode | Task Mode |
|---|---|---|
| **When** | `--metric` + `--verify` provided | No metric provided |
| **Decision** | Metric improved? Keep. Worse? `git revert` | Accumulate toward completion |
| **Exit** | Max iterations or manual | Completion promise or max iterations |
| **Journal** | `autoresearch-results.tsv` | `IMPLEMENTATION_PLAN.md` |

## The Loop

```
LOOP:
  0. Scratchpad: READ .claude/auto-research-loop-scratchpad.md
  1. Review: State + git log + results/plan
  2. Ideate: Fix crashes > exploit wins > explore > simplify > radical
  3. Modify: ONE focused change
  4. Commit: git commit BEFORE verification
  5. Verify: Metric command (metric) or gate commands (task)
  6. Decide:
     Metric: IMPROVED -> keep. WORSE -> git reset --hard HEAD~1
     Task: Gates pass + promise true -> exit. Else -> continue
  7. Log: Results TSV (metric) or update plan (task)
  8. Scratchpad: UPDATE before exit
  9. Repeat
```

Read `references/autonomous-loop-protocol.md` for full protocol.

## Critical Rules

1. **NEVER STOP** — loop until interrupted, max iterations, or promise met
2. **One change per iteration** — atomic, attributable
3. **Mechanical verification only** — no subjective judgment
4. **Simplicity wins** — equal results + less code = KEEP
5. **Git is memory** — commit before verify, revert on failure
6. **Scratchpad is mandatory** — read at start, update before exit

## Domain Adaptation

| Domain | Metric | Direction | Verify | Scope |
|---|---|---|---|---|
| Test coverage | % | higher | `pytest --cov \| grep TOTAL` | `src/**/*.py` |
| Bundle size | KB | lower | `npm run build \| grep size` | `src/**/*.ts` |
| ML training | val_bpb | lower | `uv run train.py \| grep val_bpb` | `train.py` |
| Performance | ms | lower | `npm run bench \| grep p95` | target files |

## References

- `references/autonomous-loop-protocol.md` — Full loop protocol with both modes
- `references/core-principles.md` — 7 autoresearch principles
- `references/results-logging.md` — TSV format
- `references/plan-workflow.md` — `/auto-research-loop:plan` wizard

To manually stop: `rm .claude/auto-research-loop.local.md`
