---
description: "Interactive wizard to build a validated auto-research-loop configuration"
argument-hint: "[GOAL]"
---

# Auto Research Loop — Planning Wizard

Do NOT run the setup script. Instead, walk the user through 7 phases to build a validated configuration.

Read `${CLAUDE_PLUGIN_ROOT}/references/plan-workflow.md` for the full wizard protocol.

## Quick Summary

1. **Capture Goal** — Ask what the user wants to improve (or accept inline text)
2. **Analyze Context** — Scan codebase for tooling, test runners, build scripts
3. **Define Scope** — Suggest file globs, validate they resolve to real files
4. **Define Metric** — Suggest mechanical metrics, validate they output a number
5. **Define Direction** — Higher or lower is better
6. **Define Verify** — Construct the shell command, dry-run it, confirm it works
7. **Confirm & Launch** — Present complete config, offer to launch immediately

## Critical Gates

- Metric MUST be mechanical (outputs a parseable number, not subjective)
- Verify command MUST pass a dry run on the current codebase before accepting
- Scope MUST resolve to at least 1 file

## Output

A ready-to-paste `/auto-research-loop` command with all flags configured:

```
/auto-research-loop "Goal here" \
  --metric name --direction higher \
  --verify "command here" \
  --scope "glob" --branch experiment-name \
  --max-iterations 30
```
