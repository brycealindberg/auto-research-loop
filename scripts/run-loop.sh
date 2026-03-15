#!/bin/bash

# Auto Research Loop — Bash Launcher
# Spawns a FRESH claude -p process per iteration = clean context every time.
# Memory persists via scratchpad + git history + results TSV, not conversation.
#
# This is how Karpathy's autoresearch and Ralph Loop work:
# each iteration gets a brand new context window.

set -euo pipefail

STATE_FILE=".claude/auto-research-loop.local.md"
SCRATCHPAD=".claude/auto-research-loop-scratchpad.md"
SCRATCHPAD_MTIME_MARKER=".claude/.auto-research-loop-scratchpad-mtime"
LOG_FILE=".claude/auto-research-loop-log.jsonl"
ITERATION_TIMEOUT=1800  # 30 minutes max per iteration

# --- Helpers ---
_log() { echo "[auto-research-loop] $*"; }

_read_key() {
  sed -n "s/^${2}:[[:space:]]*//p" "$1" 2>/dev/null | head -1
}

_write_key() {
  local file="$1" key="$2" value="$3"
  if grep -q "^${key}:" "$file" 2>/dev/null; then
    sed -i.bak "s/^${key}:.*/${key}: ${value}/" "$file"
    rm -f "${file}.bak"
  fi
}

_portable_mtime() {
  if [[ "$(uname)" == "Darwin" ]]; then stat -f "%m" "$1" 2>/dev/null || echo "0"
  else stat -c "%Y" "$1" 2>/dev/null || echo "0"; fi
}

_run_with_timeout() {
  local timeout_sec="$1"; shift
  if command -v timeout &>/dev/null; then timeout "${timeout_sec}" "$@"; return $?
  elif command -v gtimeout &>/dev/null; then gtimeout "${timeout_sec}" "$@"; return $?; fi
  "$@" &
  local cmd_pid=$!
  ( sleep "${timeout_sec}"; kill -TERM "$cmd_pid" 2>/dev/null; sleep 2; kill -KILL "$cmd_pid" 2>/dev/null ) &
  local watcher_pid=$!
  wait "$cmd_pid" 2>/dev/null; local exit_code=$?
  kill "$watcher_pid" 2>/dev/null; wait "$watcher_pid" 2>/dev/null || true
  return $exit_code
}

# --- Check state file exists ---
if [[ ! -f "$STATE_FILE" ]]; then
  echo "Error: No active loop. Run /auto-research-loop first to set up." >&2
  exit 1
fi

# --- Parse config ---
MAX_ITERATIONS=$(_read_key "$STATE_FILE" "max_iterations"); MAX_ITERATIONS="${MAX_ITERATIONS:-0}"
MODE=$(_read_key "$STATE_FILE" "mode"); MODE="${MODE:-task}"
METRIC_NAME=$(_read_key "$STATE_FILE" "metric_name")
VERIFY_CMD=$(_read_key "$STATE_FILE" "verify_cmd"); VERIFY_CMD="${VERIFY_CMD:-none}"
VERIFY_TIMEOUT=$(_read_key "$STATE_FILE" "verify_timeout"); VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-300}"
METRIC_DIRECTION=$(_read_key "$STATE_FILE" "metric_direction"); METRIC_DIRECTION="${METRIC_DIRECTION:-higher}"
BEST_METRIC=$(_read_key "$STATE_FILE" "best_metric"); BEST_METRIC="${BEST_METRIC:-none}"
MAX_FAILURES=$(_read_key "$STATE_FILE" "max_consecutive_failures"); MAX_FAILURES="${MAX_FAILURES:-5}"
COMPLETION_PROMISE=$(_read_key "$STATE_FILE" "completion_promise" | sed 's/^"\(.*\)"$/\1/')
TEST_CMD=$(_read_key "$STATE_FILE" "test_cmd")
LINT_CMD=$(_read_key "$STATE_FILE" "lint_cmd")
TYPECHECK_CMD=$(_read_key "$STATE_FILE" "typecheck_cmd")

# Extract prompt (everything after closing ---)
PROMPT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")
# Replace stop-hook references with run-loop reality
PROMPT=$(echo "$PROMPT" | sed 's/The stop hook automatically runs verify.*$/After you commit, exit. The bash launcher will run verify and keep\/discard./')

_log "Starting loop (fresh context per iteration)"
_log "  Mode: ${MODE}"
_log "  Max iterations: $(if [[ $MAX_ITERATIONS -gt 0 ]]; then echo $MAX_ITERATIONS; else echo unlimited; fi)"
[[ "$MODE" == "metric" ]] && _log "  Metric: ${METRIC_NAME} (best: ${BEST_METRIC})"
[[ -n "$COMPLETION_PROMISE" && "$COMPLETION_PROMISE" != "null" ]] && _log "  Promise: ${COMPLETION_PROMISE}"
[[ -n "$TEST_CMD" ]] && _log "  Gate: test -> ${TEST_CMD}"
[[ -n "$LINT_CMD" ]] && _log "  Gate: lint -> ${LINT_CMD}"
[[ -n "$TYPECHECK_CMD" ]] && _log "  Gate: typecheck -> ${TYPECHECK_CMD}"
echo ""

ITERATION=$(_read_key "$STATE_FILE" "iteration"); ITERATION="${ITERATION:-1}"
CONSECUTIVE_FAILURES=0
LAST_DIFF_HASH="none"
STALL_THRESHOLD=3

while true; do
  # --- Check max iterations ---
  if [[ $MAX_ITERATIONS -gt 0 && $ITERATION -gt $MAX_ITERATIONS ]]; then
    _log "Max iterations ($MAX_ITERATIONS) reached."
    break
  fi

  # --- Snapshot scratchpad mtime ---
  SCRATCHPAD_MTIME_BEFORE=""
  if [[ -f "$SCRATCHPAD" ]]; then
    SCRATCHPAD_MTIME_BEFORE=$(_portable_mtime "$SCRATCHPAD")
  fi

  # --- Build the prompt for this iteration ---
  ITER_PROMPT="Auto Research Loop — Iteration ${ITERATION} | Mode: ${MODE}"
  [[ "$MODE" == "metric" ]] && ITER_PROMPT+=" | ${METRIC_NAME}: best=${BEST_METRIC}"

  # Scratchpad content
  if [[ -f "$SCRATCHPAD" ]]; then
    ITER_PROMPT+="

===== SCRATCHPAD (from previous iteration) =====
$(cat "$SCRATCHPAD")
===== END SCRATCHPAD ====="
  fi

  # Scratchpad update warning
  if [[ -n "$SCRATCHPAD_MTIME_BEFORE" && -f "$SCRATCHPAD_MTIME_MARKER" ]]; then
    PREV_MTIME=$(cat "$SCRATCHPAD_MTIME_MARKER" 2>/dev/null || echo "0")
    if [[ "$SCRATCHPAD_MTIME_BEFORE" == "$PREV_MTIME" && "$ITERATION" -gt 1 ]]; then
      ITER_PROMPT+="

WARNING: You did not update the scratchpad last iteration. Update .claude/auto-research-loop-scratchpad.md before exiting."
    fi
  fi

  # Results summary (metric mode)
  if [[ "$MODE" == "metric" && -f "./autoresearch-results.tsv" ]]; then
    ITER_PROMPT+="

===== LAST 10 RESULTS =====
$(tail -10 ./autoresearch-results.tsv)
===== END RESULTS ====="

    # Periodic summary every 5 iterations
    if [[ $(( ITERATION % 5 )) -eq 0 ]]; then
      KEEPS=$(grep -c "	keep	" autoresearch-results.tsv 2>/dev/null || echo 0)
      DISCARDS=$(grep -c "	discard	" autoresearch-results.tsv 2>/dev/null || echo 0)
      CRASHES=$(grep -c "	crash	" autoresearch-results.tsv 2>/dev/null || echo 0)
      ITER_PROMPT+="

--- Progress: ${KEEPS} keeps / ${DISCARDS} discards / ${CRASHES} crashes | Best: ${BEST_METRIC} ---"
    fi
  fi

  # Plan progress with warnings (task mode)
  if [[ -f "./IMPLEMENTATION_PLAN.md" ]]; then
    COMPLETED=$(grep -ciE '^\s*-\s*\[x\]' IMPLEMENTATION_PLAN.md 2>/dev/null || echo 0)
    UNCHECKED=$(grep -c '^\s*-\s*\[ \]' IMPLEMENTATION_PLAN.md 2>/dev/null || echo 0)
    TOTAL=$((COMPLETED + UNCHECKED))
    ITER_PROMPT+="

--- Plan: ${COMPLETED}/${TOTAL} tasks complete ---"

    # Stall warning
    if [[ "$ITERATION" -ge "$STALL_THRESHOLD" && "$COMPLETED" -eq 0 ]]; then
      ITER_PROMPT+="
WARNING: ${ITERATION} iterations but NO tasks checked off. Are you updating IMPLEMENTATION_PLAN.md?"
    fi

    # Plan empty warning
    HAS_REAL_TASKS=true
    if [[ "$TOTAL" -le 1 ]] && grep -q '_Analyze task and break into subtasks_' IMPLEMENTATION_PLAN.md 2>/dev/null; then
      [[ "$COMPLETED" -eq 0 ]] && HAS_REAL_TASKS=false
    fi
    if [[ "$HAS_REAL_TASKS" == "false" && "$ITERATION" -ge "$STALL_THRESHOLD" ]]; then
      ITER_PROMPT+="
WARNING: Plan still has no real tasks. Break down the task into subtasks FIRST."
    fi

    # All done message
    if [[ "$TOTAL" -gt 0 && "$UNCHECKED" -eq 0 ]]; then
      ITER_PROMPT+="
ALL TASKS COMPLETE. Review implementation, run final checks, and signal completion."
    fi

    ITER_PROMPT+="

Next: Read IMPLEMENTATION_PLAN.md, pick the highest-priority unchecked task, execute it, mark it [x]."
  fi

  # Append the full prompt with instructions
  ITER_PROMPT+="

${PROMPT}"

  _log "=== Iteration ${ITERATION} ==="

  # --- Save scratchpad mtime marker ---
  [[ -f "$SCRATCHPAD" ]] && _portable_mtime "$SCRATCHPAD" > "$SCRATCHPAD_MTIME_MARKER"

  # --- Run claude -p (fresh context each time) ---
  CLAUDE_OUTPUT_FILE=".claude/auto-research-loop-last-output.txt"
  _run_with_timeout "$ITERATION_TIMEOUT" claude -p "$ITER_PROMPT" --allowedTools "Bash,Read,Write,Edit,Glob,Grep,LSP" > "$CLAUDE_OUTPUT_FILE" 2>> .claude/auto-research-loop-claude-stderr.log || true

  CLAUDE_OUTPUT=$(cat "$CLAUDE_OUTPUT_FILE" 2>/dev/null || echo "")

  # --- Post-iteration: metric mode keep/discard ---
  if [[ "$MODE" == "metric" && "$VERIFY_CMD" != "none" ]]; then
    METRIC_VAL=$(_run_with_timeout "$VERIFY_TIMEOUT" bash -c "$VERIFY_CMD" 2>&1 | grep -oE '[0-9]+\.?[0-9]*' | tail -1) || true

    COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "-")
    DESC=$(git log -1 --format='%s' 2>/dev/null || echo "unknown")

    if [[ -z "$METRIC_VAL" ]]; then
      STATUS="crash"
      printf '%s\t-\t0\t0\tcrash\t%s\n' "$ITERATION" "$DESC" >> autoresearch-results.tsv 2>/dev/null
      git reset --hard HEAD~1 2>/dev/null || true
      _log "CRASH — verify failed, reverted"
    else
      if [[ "$BEST_METRIC" == "none" ]]; then
        IS_BETTER="true"
      elif [[ "$METRIC_DIRECTION" == "higher" ]]; then
        IS_BETTER=$(awk "BEGIN { print ($METRIC_VAL > $BEST_METRIC) ? \"true\" : \"false\" }")
      else
        IS_BETTER=$(awk "BEGIN { print ($METRIC_VAL < $BEST_METRIC) ? \"true\" : \"false\" }")
      fi

      BEST_FOR_DELTA=$(if [[ "$BEST_METRIC" == "none" ]]; then echo 0; else echo "$BEST_METRIC"; fi)
      DELTA=$(awk "BEGIN { printf \"%.6f\", $METRIC_VAL - $BEST_FOR_DELTA }" 2>/dev/null || echo "0")

      if [[ "$IS_BETTER" == "true" ]]; then
        STATUS="keep"
        BEST_METRIC="$METRIC_VAL"
        _write_key "$STATE_FILE" "best_metric" "$BEST_METRIC"
        printf '%s\t%s\t%s\t%s\tkeep\t%s\n' "$ITERATION" "$COMMIT" "$METRIC_VAL" "$DELTA" "$DESC" >> autoresearch-results.tsv 2>/dev/null
        _log "KEEP — ${METRIC_NAME}: ${METRIC_VAL} (best: ${BEST_METRIC}, delta: ${DELTA})"
      else
        STATUS="discard"
        printf '%s\t-\t%s\t%s\tdiscard\t%s\n' "$ITERATION" "$METRIC_VAL" "$DELTA" "$DESC" >> autoresearch-results.tsv 2>/dev/null
        git reset --hard HEAD~1 2>/dev/null || true
        _log "DISCARD — ${METRIC_NAME}: ${METRIC_VAL} (best: ${BEST_METRIC}, delta: ${DELTA})"
      fi
    fi
  fi

  # --- Post-iteration: task mode promise + gates ---
  if [[ "$MODE" == "task" && -n "$COMPLETION_PROMISE" && "$COMPLETION_PROMISE" != "null" ]]; then
    # Check for promise in output
    PROMISE_TEXT=$(echo "$CLAUDE_OUTPUT" | perl -0777 -pe 's/.*?<promise>(.*?)<\/promise>.*/$1/s; s/^\s+|\s+$//g; s/\s+/ /g' 2>/dev/null || echo "")

    if [[ -n "$PROMISE_TEXT" && "$PROMISE_TEXT" == "$COMPLETION_PROMISE" ]]; then
      _log "Promise detected: ${PROMISE_TEXT}"

      # Run backpressure gates
      GATES_PASSED=true
      if [[ -n "$TEST_CMD" ]]; then
        _log "Running gate: test -> ${TEST_CMD}"
        if ! _run_with_timeout 60 bash -c "$TEST_CMD" >/dev/null 2>&1; then
          _log "GATE FAILED: test"
          GATES_PASSED=false
        fi
      fi
      if [[ -n "$LINT_CMD" ]]; then
        _log "Running gate: lint -> ${LINT_CMD}"
        if ! _run_with_timeout 60 bash -c "$LINT_CMD" >/dev/null 2>&1; then
          _log "GATE FAILED: lint"
          GATES_PASSED=false
        fi
      fi
      if [[ -n "$TYPECHECK_CMD" ]]; then
        _log "Running gate: typecheck -> ${TYPECHECK_CMD}"
        if ! _run_with_timeout 60 bash -c "$TYPECHECK_CMD" >/dev/null 2>&1; then
          _log "GATE FAILED: typecheck"
          GATES_PASSED=false
        fi
      fi

      if [[ "$GATES_PASSED" == "true" ]]; then
        _log "Promise met + all gates passed. Loop complete!"
        break
      else
        _log "Promise detected but gates failed. Continuing loop."
      fi
    fi
  fi

  # --- Circuit breaker ---
  CURRENT_DIFF=$(git diff 2>/dev/null; git diff --cached 2>/dev/null; git status --porcelain 2>/dev/null)
  CURRENT_HASH=$(echo "$CURRENT_DIFF" | md5 -q 2>/dev/null || echo "$CURRENT_DIFF" | md5sum 2>/dev/null | awk '{print $1}' || shasum -a 256 2>/dev/null | awk '{print $1}')
  CURRENT_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "none")
  PREV_HEAD=$(_read_key "$STATE_FILE" "last_head_hash")

  if [[ "$CURRENT_HASH" == "$LAST_DIFF_HASH" && "$CURRENT_HEAD" == "$PREV_HEAD" && "$ITERATION" -gt 1 ]]; then
    CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
    _log "No progress. Stalls: ${CONSECUTIVE_FAILURES}/${MAX_FAILURES}"
    if [[ $CONSECUTIVE_FAILURES -ge $MAX_FAILURES ]]; then
      _log "CIRCUIT BREAKER — ${CONSECUTIVE_FAILURES} consecutive stalls. Stopping."
      break
    fi
  else
    CONSECUTIVE_FAILURES=0
  fi
  LAST_DIFF_HASH="$CURRENT_HASH"
  _write_key "$STATE_FILE" "last_head_hash" "$CURRENT_HEAD"

  # --- Log iteration ---
  if command -v jq >/dev/null 2>&1; then
    [[ ! -f "$LOG_FILE" ]] && touch "$LOG_FILE"
    jq -n -c \
      --arg event "iteration_complete" \
      --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
      --argjson iter "$ITERATION" \
      --arg mode "$MODE" \
      --arg metric "${METRIC_VAL:-}" \
      --arg status "${STATUS:-}" \
      '{event:$event, timestamp:$ts, iteration:$iter, mode:$mode, metric_value:$metric, metric_status:$status}' \
      >> "$LOG_FILE"
  fi

  # --- Increment ---
  ITERATION=$((ITERATION + 1))
  _write_key "$STATE_FILE" "iteration" "$ITERATION"

  _log ""
done

# --- Final summary ---
if [[ "$MODE" == "metric" && -f "./autoresearch-results.tsv" ]]; then
  KEEPS=$(grep -c "	keep	" autoresearch-results.tsv 2>/dev/null || echo 0)
  DISCARDS=$(grep -c "	discard	" autoresearch-results.tsv 2>/dev/null || echo 0)
  CRASHES=$(grep -c "	crash	" autoresearch-results.tsv 2>/dev/null || echo 0)
  BASELINE=$(_read_key "$STATE_FILE" "baseline_metric")
  echo ""
  echo "=== Auto Research Loop Complete ==="
  echo "Iterations: $((ITERATION - 1))"
  echo "Baseline: ${BASELINE} → Best: ${BEST_METRIC}"
  echo "Keeps: ${KEEPS} | Discards: ${DISCARDS} | Crashes: ${CRASHES}"
  echo "Results: autoresearch-results.tsv"
else
  echo ""
  echo "=== Auto Research Loop Complete ==="
  echo "Iterations: $((ITERATION - 1))"
fi

# Log completion
if command -v jq >/dev/null 2>&1 && [[ -f "$LOG_FILE" ]]; then
  jq -n -c \
    --arg event "loop_completed" \
    --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson iter "$((ITERATION - 1))" \
    --arg reason "$(if [[ $MAX_ITERATIONS -gt 0 && $ITERATION -gt $MAX_ITERATIONS ]]; then echo max_iterations; elif [[ $CONSECUTIVE_FAILURES -ge $MAX_FAILURES ]]; then echo circuit_breaker; else echo promise; fi)" \
    '{event:$event, timestamp:$ts, total_iterations:$iter, completion_reason:$reason}' \
    >> "$LOG_FILE"
fi

# Clean up
rm -f "$STATE_FILE" "$CLAUDE_OUTPUT_FILE"
_log "Loop finished."
