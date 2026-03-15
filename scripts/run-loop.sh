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
LOG_FILE=".claude/auto-research-loop-log.jsonl"

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

# --- Check state file exists ---
if [[ ! -f "$STATE_FILE" ]]; then
  echo "Error: No active loop. Run /auto-research-loop first to set up." >&2
  echo "  This script runs iterations — setup creates the state file." >&2
  exit 1
fi

# --- Parse config ---
MAX_ITERATIONS=$(_read_key "$STATE_FILE" "max_iterations")
MAX_ITERATIONS="${MAX_ITERATIONS:-0}"
MODE=$(_read_key "$STATE_FILE" "mode")
MODE="${MODE:-task}"
METRIC_NAME=$(_read_key "$STATE_FILE" "metric_name")
VERIFY_CMD=$(_read_key "$STATE_FILE" "verify_cmd")
VERIFY_TIMEOUT=$(_read_key "$STATE_FILE" "verify_timeout")
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-300}"
METRIC_DIRECTION=$(_read_key "$STATE_FILE" "metric_direction")
BEST_METRIC=$(_read_key "$STATE_FILE" "best_metric")
MAX_FAILURES=$(_read_key "$STATE_FILE" "max_consecutive_failures")
MAX_FAILURES="${MAX_FAILURES:-5}"

# Extract prompt (everything after closing ---)
PROMPT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")

_log "Starting loop"
_log "  Mode: ${MODE}"
_log "  Max iterations: $(if [[ $MAX_ITERATIONS -gt 0 ]]; then echo $MAX_ITERATIONS; else echo unlimited; fi)"
[[ "$MODE" == "metric" ]] && _log "  Metric: ${METRIC_NAME} (best: ${BEST_METRIC})"
echo ""

ITERATION=$(_read_key "$STATE_FILE" "iteration")
ITERATION="${ITERATION:-1}"
CONSECUTIVE_FAILURES=0
LAST_DIFF_HASH="none"

while true; do
  # --- Check max iterations ---
  if [[ $MAX_ITERATIONS -gt 0 && $ITERATION -gt $MAX_ITERATIONS ]]; then
    _log "Max iterations ($MAX_ITERATIONS) reached."
    break
  fi

  # --- Build the prompt for this iteration ---
  ITER_PROMPT="Auto Research Loop — Iteration ${ITERATION}"
  [[ "$MODE" == "metric" ]] && ITER_PROMPT+=" | Mode: metric | ${METRIC_NAME}: best=${BEST_METRIC}"

  # Add scratchpad content
  if [[ -f "$SCRATCHPAD" ]]; then
    ITER_PROMPT+="

===== SCRATCHPAD (from previous iteration) =====
$(cat "$SCRATCHPAD")
===== END SCRATCHPAD ====="
  fi

  # Add results summary (metric mode)
  if [[ "$MODE" == "metric" && -f "./autoresearch-results.tsv" ]]; then
    LAST_RESULTS=$(tail -10 ./autoresearch-results.tsv)
    ITER_PROMPT+="

===== LAST 10 RESULTS =====
${LAST_RESULTS}
===== END RESULTS ====="
  fi

  # Add plan progress (task mode)
  if [[ -f "./IMPLEMENTATION_PLAN.md" ]]; then
    COMPLETED=$(grep -ciE '^\s*-\s*\[x\]' IMPLEMENTATION_PLAN.md 2>/dev/null || echo 0)
    UNCHECKED=$(grep -c '^\s*-\s*\[ \]' IMPLEMENTATION_PLAN.md 2>/dev/null || echo 0)
    ITER_PROMPT+="

Plan: ${COMPLETED}/$((COMPLETED + UNCHECKED)) tasks complete"
  fi

  ITER_PROMPT+="

${PROMPT}"

  _log "=== Iteration ${ITERATION} ==="

  # --- Run claude -p (fresh context each time) ---
  claude -p "$ITER_PROMPT" --allowedTools "Bash,Read,Write,Edit,Glob,Grep" 2>/dev/null || true

  # --- Post-iteration: metric mode keep/discard ---
  if [[ "$MODE" == "metric" && "$VERIFY_CMD" != "none" ]]; then
    METRIC_VAL=$(bash -c "$VERIFY_CMD" 2>&1 | grep -oE '[0-9]+\.?[0-9]*' | tail -1) || true

    if [[ -z "$METRIC_VAL" ]]; then
      STATUS="crash"
      DESC=$(git log -1 --format='%s' 2>/dev/null || echo "unknown")
      printf '%s\t-\t0\t0\tcrash\t%s\n' "$ITERATION" "$DESC" >> autoresearch-results.tsv 2>/dev/null
      git reset --hard HEAD~1 2>/dev/null || true
      _log "CRASH — verify failed, reverted"
    else
      # Compare
      if [[ "$BEST_METRIC" == "none" ]]; then
        IS_BETTER="true"
      elif [[ "$METRIC_DIRECTION" == "higher" ]]; then
        IS_BETTER=$(awk "BEGIN { print ($METRIC_VAL > $BEST_METRIC) ? \"true\" : \"false\" }")
      else
        IS_BETTER=$(awk "BEGIN { print ($METRIC_VAL < $BEST_METRIC) ? \"true\" : \"false\" }")
      fi

      DELTA=$(awk "BEGIN { printf \"%.6f\", $METRIC_VAL - ${BEST_METRIC:-0} }" 2>/dev/null || echo "0")
      COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "-")
      DESC=$(git log -1 --format='%s' 2>/dev/null || echo "unknown")

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

  # --- Circuit breaker ---
  CURRENT_DIFF=$(git diff 2>/dev/null; git diff --cached 2>/dev/null; git status --porcelain 2>/dev/null)
  CURRENT_HASH=$(echo "$CURRENT_DIFF" | md5 -q 2>/dev/null || echo "$CURRENT_DIFF" | md5sum 2>/dev/null | awk '{print $1}')
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
  if command -v jq >/dev/null 2>&1 && [[ -f "$LOG_FILE" ]]; then
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

# Clean up state file
rm -f "$STATE_FILE"
_log "State file removed. Loop finished."
