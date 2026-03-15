---
description: "Start autonomous research loop — metric-driven keep/discard or task completion"
argument-hint: "PROMPT [--metric NAME --verify CMD] [--completion-promise TEXT] [--max-iterations N] [--test-cmd CMD] [--branch NAME]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-auto-research-loop.sh:*)"]
hide-from-slash-command-tool: "true"
---

# Auto Research Loop

Execute the setup script to initialize the loop:

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-auto-research-loop.sh" $ARGUMENTS
```

Then follow the injected instructions in the state file. The stop hook intercepts exit and re-feeds the prompt for the next iteration.

## Two Modes

**Metric mode** (when `--metric` + `--verify` provided): Each iteration makes ONE change, commits, then the stop hook runs the verify command, compares to best metric, and keeps the commit or reverts via `git reset --hard HEAD~1`. Auto-creates an experiment branch for safety.

**Task mode** (no metric): Scratchpad + implementation plan + completion promise. Changes accumulate. Exit when promise is genuinely TRUE and all gates pass.

## Critical Rules

1. **NEVER STOP** — loop until interrupted, max iterations, or promise met
2. **One change per iteration** — atomic, attributable
3. **Mechanical verification only** — no subjective judgment
4. **Simplicity wins** — equal results + less code = KEEP
5. **Git is memory** — commit before verify, revert on failure
6. **Scratchpad is mandatory** — read at start, update before exit
