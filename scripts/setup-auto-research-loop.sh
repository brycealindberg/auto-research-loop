#!/bin/bash
# Auto Research Loop — Setup Script
# Creates state file, scratchpad, plan, results log, JSONL log.
# Auto-installs stop hook into .claude/settings.local.json.

set -euo pipefail

PROMPT_PARTS=()
MAX_ITERATIONS=0
COMPLETION_PROMISE="null"
TEST_CMD=""
LINT_CMD=""
TYPECHECK_CMD=""
MAX_FAILURES=5
METRIC_NAME=""
METRIC_DIRECTION=""
VERIFY_CMD=""
SCOPE=""
READ_ONLY=""
BRANCH=""
VERIFY_TIMEOUT=300
# Use plugin root if available, fall back to skills dir
if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
  STOP_HOOK_PATH="${CLAUDE_PLUGIN_ROOT}/hooks/stop-hook.sh"
else
  STOP_HOOK_PATH="$HOME/.claude/skills/auto-research-loop/scripts/stop-hook.sh"
fi

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      cat << 'EOF'
Auto Research Loop — Autonomous iteration engine

USAGE: /auto-research-loop [PROMPT...] [OPTIONS]

METRIC MODE (autoresearch-style):
  --metric '<name>'          Metric name (e.g., "coverage", "val_bpb")
  --direction <higher|lower> Higher or lower is better (default: higher)
  --verify '<command>'       Shell command that outputs the metric value
  --scope '<glob>'           In-scope files (e.g., "src/**/*.ts")
  --read-only '<glob>'       Files agent must NOT modify (e.g., "tests/conftest.py")
  --timeout <seconds>        Verify command timeout (default: 300)
  --branch '<name>'          Create experiment branch autoresearch/<name>

TASK MODE (ralph-style):
  --completion-promise '<text>'  Promise that must be TRUE to exit

SHARED:
  --max-iterations <n>       Max iterations (default: unlimited)
  --test-cmd '<cmd>'          Test gate
  --lint-cmd '<cmd>'          Lint gate
  --typecheck-cmd '<cmd>'     Type-check gate
  --max-failures <n>          Circuit breaker threshold (default: 5)

EXAMPLES:
  # Metric: improve test coverage
  /auto-research-loop "Increase coverage" --metric coverage --direction higher \
    --verify "pytest --cov | grep TOTAL | awk '{print \$4}'" --max-iterations 30

  # Task: build a feature
  /auto-research-loop "Build REST API" --completion-promise "All tests pass" \
    --test-cmd "npm test" --max-iterations 20
EOF
      exit 0 ;;
    --max-iterations) [[ -z "${2:-}" || ! "$2" =~ ^[0-9]+$ ]] && { echo "Error: --max-iterations needs integer" >&2; exit 1; }; MAX_ITERATIONS="$2"; shift 2 ;;
    --completion-promise) [[ -z "${2:-}" ]] && { echo "Error: --completion-promise needs text" >&2; exit 1; }; COMPLETION_PROMISE="$2"; shift 2 ;;
    --test-cmd) [[ -z "${2:-}" ]] && { echo "Error: --test-cmd needs command" >&2; exit 1; }; TEST_CMD="$2"; shift 2 ;;
    --lint-cmd) [[ -z "${2:-}" ]] && { echo "Error: --lint-cmd needs command" >&2; exit 1; }; LINT_CMD="$2"; shift 2 ;;
    --typecheck-cmd) [[ -z "${2:-}" ]] && { echo "Error: --typecheck-cmd needs command" >&2; exit 1; }; TYPECHECK_CMD="$2"; shift 2 ;;
    --max-failures) [[ -z "${2:-}" || ! "$2" =~ ^[1-9][0-9]*$ ]] && { echo "Error: --max-failures needs positive int" >&2; exit 1; }; MAX_FAILURES="$2"; shift 2 ;;
    --metric) [[ -z "${2:-}" ]] && { echo "Error: --metric needs name" >&2; exit 1; }; METRIC_NAME="$2"; shift 2 ;;
    --direction) [[ -z "${2:-}" ]] && { echo "Error: --direction needs higher/lower" >&2; exit 1; }; [[ "$2" == "higher" || "$2" == "lower" ]] || { echo "Error: --direction must be higher or lower" >&2; exit 1; }; METRIC_DIRECTION="$2"; shift 2 ;;
    --verify) [[ -z "${2:-}" ]] && { echo "Error: --verify needs command" >&2; exit 1; }; VERIFY_CMD="$2"; shift 2 ;;
    --scope) [[ -z "${2:-}" ]] && { echo "Error: --scope needs glob" >&2; exit 1; }; SCOPE="$2"; shift 2 ;;
    --read-only) [[ -z "${2:-}" ]] && { echo "Error: --read-only needs glob/path" >&2; exit 1; }; READ_ONLY="$2"; shift 2 ;;
    --branch) [[ -z "${2:-}" ]] && { echo "Error: --branch needs name" >&2; exit 1; }; BRANCH="$2"; shift 2 ;;
    --timeout) [[ -z "${2:-}" || ! "$2" =~ ^[0-9]+$ ]] && { echo "Error: --timeout needs integer seconds" >&2; exit 1; }; VERIFY_TIMEOUT="$2"; shift 2 ;;
    *) PROMPT_PARTS+=("$1"); shift ;;
  esac
done

PROMPT="${PROMPT_PARTS[*]}"
[[ -z "$PROMPT" ]] && { echo "Error: No prompt. Run --help for usage." >&2; exit 1; }

# Warn on orphan flags
[[ -n "$METRIC_NAME" && -z "$VERIFY_CMD" ]] && echo "Warning: --metric without --verify. Using task mode." >&2
[[ -z "$METRIC_NAME" && -n "$VERIFY_CMD" ]] && echo "Warning: --verify without --metric. Using task mode." >&2

# Auto-detect mode
MODE="task"
if [[ -n "$METRIC_NAME" && -n "$VERIFY_CMD" ]]; then
  MODE="metric"
  [[ -z "$METRIC_DIRECTION" ]] && METRIC_DIRECTION="higher"
fi

# --- Safety: auto-create branch in metric mode ---
if [[ "$MODE" == "metric" && -z "$BRANCH" ]]; then
  if git rev-parse --git-dir >/dev/null 2>&1; then
    BRANCH="arl-$(date '+%Y%m%d-%H%M%S')"
    echo "[auto-research-loop] Metric mode: auto-creating branch autoresearch/${BRANCH} for safety" >&2
    echo "  (discarded experiments run git reset --hard HEAD~1 — isolating to a branch protects your work)" >&2
  fi
fi

# --- Fix G: Create experiment branch ---
if [[ -n "$BRANCH" ]]; then
  if git rev-parse --git-dir >/dev/null 2>&1; then
    BRANCH_NAME="autoresearch/${BRANCH}"
    if git show-ref --verify --quiet "refs/heads/${BRANCH_NAME}" 2>/dev/null; then
      echo "[auto-research-loop] Branch ${BRANCH_NAME} exists, switching to it"
      git checkout "$BRANCH_NAME"
    else
      git checkout -b "$BRANCH_NAME"
      echo "[auto-research-loop] Created branch ${BRANCH_NAME}"
    fi
  else
    echo "[auto-research-loop] Warning: not a git repo, --branch ignored" >&2
  fi
fi

# --- Create infrastructure ---
mkdir -p .claude

# Build prompt additions before heredoc
PROMPT_ADDITIONS='
--- SCRATCHPAD INSTRUCTIONS (Ralph Loop) ---

A persistent scratchpad exists at .claude/auto-research-loop-scratchpad.md that carries your working memory across loop iterations. Follow these rules EVERY iteration:

1. READ FIRST: At the very start of this iteration, read .claude/auto-research-loop-scratchpad.md. It contains notes from your previous iterations -- what you tried, what worked, what failed, and what to do next. Do not skip this step.

2. SNAPSHOT MTIME: After reading the scratchpad, run this command to record its modification time (used to detect if you updated it):
   if [[ "$(uname)" == "Darwin" ]]; then stat -f "%m" .claude/auto-research-loop-scratchpad.md > .claude/.auto-research-loop-scratchpad-mtime; else stat -c "%Y" .claude/auto-research-loop-scratchpad.md > .claude/.auto-research-loop-scratchpad-mtime; fi

3. UPDATE BEFORE EXIT: Before you finish your work, update .claude/auto-research-loop-scratchpad.md with:
   - What you now understand about the task (Current Understanding)
   - Any decisions you made and why (Decisions Made)
   - What you tried and whether it worked (Approaches Tried)
   - Any blockers or errors you hit (Blockers Found)
   - Which files you created, modified, or deleted (Files Modified)
   - Specific next steps for the next iteration (Next Steps)

4. KEEP IT CONCISE: Bullet points, not prose. The scratchpad is injected into the system message -- keep it scannable.

5. DO NOT DELETE the scratchpad or remove previous entries. Append and update. Mark resolved blockers with [RESOLVED].

--- IMPLEMENTATION PLAN PROTOCOL ---

You MUST follow these rules for IMPLEMENTATION_PLAN.md in every iteration:

1. READ THE PLAN FIRST. Before doing any work, read IMPLEMENTATION_PLAN.md.

2. FIRST ITERATION -- POPULATE THE PLAN. If the Tasks section has no real tasks (only the default placeholder), your FIRST action must be:
   - Analyze the task prompt thoroughly.
   - Break it into discrete, actionable subtasks. Each task should be completable in a single iteration.
   - Write them using: - [ ] Task description (priority: high/medium/low)
   - Order by priority. Do NOT start implementation until the plan is written.

3. PICK THE NEXT TASK. Select the highest-priority unchecked task (- [ ]). Work on ONLY that task this iteration.

4. MARK COMPLETION. When you finish a task, change - [ ] to - [x] and move it to the Completed section with a note.

5. DISCOVER AND ADD. If you find new work during implementation, add it as a new task with appropriate priority. Do NOT silently do extra work without tracking it.

6. UPDATE NOTES. Record implementation decisions, API quirks, edge cases, or gotchas in the Notes section.

7. SAVE BEFORE EXIT. Always write updates to IMPLEMENTATION_PLAN.md before your iteration ends.

--- LOOP PROTOCOL ---
'

if [[ "$MODE" == "metric" ]]; then
  PROMPT_ADDITIONS+='
You are in METRIC MODE. Each iteration:
1. Read scratchpad + autoresearch-results.tsv + git log --oneline -20
2. Pick ONE focused change (fix crashes > exploit wins > explore > simplify > radical)
3. Make the change to in-scope files ONLY
4. git add + git commit -m "experiment: <description>" BEFORE verification
5. The stop hook automatically runs the verify command, compares to best metric, and keeps (commit stays) or discards (git reset --hard HEAD~1)
6. You will see the result (KEEP/DISCARD/CRASH) in the next iteration system message
7. Update scratchpad before exiting

NEVER STOP. NEVER ASK "should I continue?" One change per iteration. Mechanical verification only.

SIMPLICITY: A 0.5% improvement that adds 20 lines of ugly complexity? Probably not worth it. A 0.5% improvement from DELETING code? Definitely keep. Equal metric + simpler code = KEEP.

When stuck (>5 consecutive discards): re-read ALL in-scope files from scratch, review entire results log for patterns, combine 2-3 previously successful changes, try the OPPOSITE of what has not been working, try a radical architectural change.
'

if [[ -n "$READ_ONLY" ]]; then
  PROMPT_ADDITIONS+="
--- READ-ONLY FILES (DO NOT MODIFY) ---

These files are LOCKED. They contain the evaluation logic or test infrastructure. Modifying them would game the metric rather than genuinely improving. Do NOT edit, rename, or delete:
  ${READ_ONLY}

If you need to change how something is measured, ask the human. Improve the CODE, not the MEASUREMENT.
"
fi
else
  PROMPT_ADDITIONS+='
You are in TASK MODE. Each iteration:
1. Read scratchpad + IMPLEMENTATION_PLAN.md
2. First iteration: break task into subtasks in the plan (do NOT start coding until plan is written)
3. Pick the highest-priority unchecked task (- [ ]). Work on ONLY that task.
4. Complete it, mark [x] in plan, move to Completed section
5. If you discover new work, add it as a new task -- do NOT do untracked work
6. Commit your work (small atomic commits)
7. Update scratchpad before exiting

NEVER STOP. NEVER ASK "should I continue?" One task per iteration. Commit early and often.
'
fi

if [[ -n "$TEST_CMD" || -n "$LINT_CMD" || -n "$TYPECHECK_CMD" ]]; then
  PROMPT_ADDITIONS+='
--- BACKPRESSURE GATES ---

Quality gates are active. The loop will NOT accept your completion until every gate passes. If a gate fails, your completion is rejected and you must fix the issues.

Active gates:
'
  [[ -n "$TEST_CMD" ]] && PROMPT_ADDITIONS+="  test: ${TEST_CMD}
"
  [[ -n "$LINT_CMD" ]] && PROMPT_ADDITIONS+="  lint: ${LINT_CMD}
"
  [[ -n "$TYPECHECK_CMD" ]] && PROMPT_ADDITIONS+="  typecheck: ${TYPECHECK_CMD}
"
  PROMPT_ADDITIONS+='
Rules:
1. Run the gate commands YOURSELF before declaring completion. This avoids wasting an iteration on a rejection you could have caught.
2. Fix ALL failures -- the loop runs ALL gates and reports ALL errors at once.
3. Do not skip or bypass gates. They exist to enforce quality.
4. Timeouts count as failures. Each gate has a 60-second timeout. If your code causes a command to hang, that is a gate failure.
'
fi

PROMPT_ADDITIONS+="
--- CIRCUIT BREAKER (auto-stop on stall) ---

A circuit breaker is active. If you fail to make meaningful progress for ${MAX_FAILURES} consecutive iterations, the loop automatically stops.

What counts as progress:
- Making at least one git commit during the iteration
- Producing a different set of working-tree changes than the previous iteration

What triggers a failure:
- No commits AND the git diff is identical to the previous iteration

Rules to avoid tripping the breaker:
1. Commit early and often. After each meaningful change, commit it.
2. If something is not working after 2 attempts, change your approach fundamentally. Do not keep retrying the same fix.
3. If blocked by an external issue, document what you have tried and what is blocking you in the scratchpad rather than silently retrying.
"

# Completion promise anti-circumvention (task mode)
if [[ "$MODE" == "task" && "$COMPLETION_PROMISE" != "null" ]]; then
  PROMPT_ADDITIONS+="
--- COMPLETION PROMISE ---

To complete this loop, output this EXACT text: <promise>${COMPLETION_PROMISE}</promise>

STRICT REQUIREMENTS:
- The statement MUST be completely and unequivocally TRUE
- Do NOT output false statements to exit the loop
- Do NOT lie even if you think you should exit or are stuck
- The loop is designed to continue until the promise is GENUINELY TRUE

Even if you believe you are stuck, the task is impossible, or you have been running too long -- you MUST NOT output a false promise. Trust the process.
"
fi

# State file
[[ "$COMPLETION_PROMISE" != "null" ]] && CP_YAML="\"$COMPLETION_PROMISE\"" || CP_YAML="null"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > .claude/auto-research-loop.local.md <<STATE_EOF
---
active: true
mode: ${MODE}
iteration: 1
max_iterations: ${MAX_ITERATIONS}
completion_promise: ${CP_YAML}
metric_name: ${METRIC_NAME:-none}
metric_direction: ${METRIC_DIRECTION:-none}
verify_cmd: ${VERIFY_CMD:-none}
scope: ${SCOPE:-none}
read_only: ${READ_ONLY:-none}
verify_timeout: ${VERIFY_TIMEOUT}
started_at: "${STARTED_AT}"
test_cmd: ${TEST_CMD}
lint_cmd: ${LINT_CMD}
typecheck_cmd: ${TYPECHECK_CMD}
max_consecutive_failures: ${MAX_FAILURES}
consecutive_failures: 0
last_diff_hash: none
last_head_hash: none
best_metric: none
baseline_metric: none
---

${PROMPT}
${PROMPT_ADDITIONS}
STATE_EOF

# Scratchpad
SP=".claude/auto-research-loop-scratchpad.md"
if [[ ! -f "$SP" ]]; then
  cat > "$SP" << 'SP_EOF'
# Auto Research Loop — Scratchpad
> Persistent working memory. DO NOT DELETE.

## Current Understanding
_Not yet populated._

## Decisions Made
- (none yet)

## Approaches Tried
| # | Approach | Outcome | Metric Delta | Notes |
|---|----------|---------|-------------|-------|

## Blockers Found
- (none yet)

## Files Modified
- (none yet)

## Next Steps
1. _Read task prompt, fill Current Understanding._
2. _Plan approach._
3. _Begin._
SP_EOF
  echo "[auto-research-loop] Created scratchpad"
fi

# Implementation plan
PLAN="./IMPLEMENTATION_PLAN.md"
if [[ ! -f "$PLAN" ]]; then
  cat > "$PLAN" << PLAN_EOF
# Implementation Plan: $(echo "$PROMPT" | tr '\n' ' ' | head -c 120)
> Created: $(date '+%Y-%m-%d %H:%M') | Mode: ${MODE}

## Tasks
- [ ] _Analyze task and break into subtasks_ (priority: high)

## Completed
(none yet)

## Notes
- (none yet)
PLAN_EOF
  echo "[auto-research-loop] Created IMPLEMENTATION_PLAN.md"
fi

# Results log (metric mode)
if [[ "$MODE" == "metric" ]]; then
  RESULTS="./autoresearch-results.tsv"
  if [[ ! -f "$RESULTS" ]]; then
    echo "# metric_direction: ${METRIC_DIRECTION}" > "$RESULTS"
    printf 'iteration\tcommit\tmetric\tdelta\tstatus\tdescription\n' >> "$RESULTS"
    echo "[auto-research-loop] Created results log"
  fi
fi

# JSONL log
LOG=".claude/auto-research-loop-log.jsonl"
[[ -f "$LOG" ]] && mv "$LOG" "${LOG%.jsonl}-$(date '+%Y%m%d-%H%M%S').jsonl"
touch "$LOG"
if command -v jq >/dev/null 2>&1; then
  jq -n -c --arg event "loop_started" --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg mode "$MODE" --argjson mi "$MAX_ITERATIONS" \
    '{event:$event, timestamp:$ts, mode:$mode, max_iterations:$mi}' >> "$LOG"
fi

# --- Install stop hook ---
SETTINGS=".claude/settings.local.json"
if [[ -f "$SETTINGS" ]]; then
  if ! grep -q "auto-research-loop" "$SETTINGS" 2>/dev/null; then
    # Merge stop hook into existing settings
    if command -v jq >/dev/null 2>&1; then
      HOOK_CMD="$STOP_HOOK_PATH"
      jq --arg cmd "$HOOK_CMD" '
        .hooks.Stop = (.hooks.Stop // []) + [{
          "matcher": "",
          "hooks": [{"type": "command", "command": $cmd}]
        }]
      ' "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
      echo "[auto-research-loop] Added stop hook to settings"
    else
      echo "[auto-research-loop] Warning: jq not found, cannot auto-install hook" >&2
      echo "  Add manually to $SETTINGS:" >&2
      echo "  hooks.Stop: [{hooks: [{type: command, command: $STOP_HOOK_PATH}]}]" >&2
    fi
  fi
else
  cat > "$SETTINGS" <<HOOK_EOF
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$STOP_HOOK_PATH"
          }
        ]
      }
    ]
  }
}
HOOK_EOF
  echo "[auto-research-loop] Created settings with stop hook"
fi

# --- Baseline (metric mode) ---
if [[ "$MODE" == "metric" && -n "$VERIFY_CMD" ]]; then
  echo "[auto-research-loop] Running baseline verify command..."
  BASELINE=$(bash -c "$VERIFY_CMD" 2>&1 | grep -oE '[0-9]+\.?[0-9]*' | tail -1) || true
  if [[ -n "$BASELINE" ]]; then
    sed -i.bak "s/^baseline_metric: .*/baseline_metric: $BASELINE/" .claude/auto-research-loop.local.md
    sed -i.bak "s/^best_metric: .*/best_metric: $BASELINE/" .claude/auto-research-loop.local.md
    rm -f .claude/auto-research-loop.local.md.bak
    printf '0\tbaseline\t%s\t0\tbaseline\tinitial state\n' "$BASELINE" >> "./autoresearch-results.tsv"
    echo "[auto-research-loop] Baseline: ${METRIC_NAME} = ${BASELINE}"
  else
    echo "[auto-research-loop] Warning: baseline verify failed. Will capture on first iteration."
  fi
fi

# --- Output ---
cat <<OUTPUT_EOF
Auto Research Loop activated!

Mode: ${MODE}
Iteration: 1
Max iterations: $(if [[ $MAX_ITERATIONS -gt 0 ]]; then echo $MAX_ITERATIONS; else echo "unlimited"; fi)
OUTPUT_EOF

if [[ "$MODE" == "metric" ]]; then
  echo "Metric: ${METRIC_NAME} (${METRIC_DIRECTION} is better)"
  echo "Verify: ${VERIFY_CMD}"
  [[ -n "$SCOPE" ]] && echo "Scope: ${SCOPE}"
  [[ -n "$BASELINE" ]] && echo "Baseline: ${BASELINE}"
  echo "Decision: IMPROVED -> keep commit. WORSE -> git revert."
else
  echo "Completion: $(if [[ "$COMPLETION_PROMISE" != "null" ]]; then echo "${COMPLETION_PROMISE} (must be TRUE)"; else echo "none (runs forever)"; fi)"
fi

[[ -n "$TEST_CMD" ]] && echo "  Gate: test -> ${TEST_CMD}"
[[ -n "$LINT_CMD" ]] && echo "  Gate: lint -> ${LINT_CMD}"
[[ -n "$TYPECHECK_CMD" ]] && echo "  Gate: typecheck -> ${TYPECHECK_CMD}"
echo "  Circuit breaker: ${MAX_FAILURES} stalls"
echo "  Stop hook: installed"
echo ""
echo "To stop: delete .claude/auto-research-loop.local.md"
echo ""
echo "$PROMPT"

if [[ "$MODE" == "task" && "$COMPLETION_PROMISE" != "null" ]]; then
  echo ""
  echo "================================================================"
  echo "To exit: <promise>$COMPLETION_PROMISE</promise> (must be TRUE)"
  echo "================================================================"
fi
