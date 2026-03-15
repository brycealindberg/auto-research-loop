#!/bin/bash

# Auto Research Loop — Stop Hook
# Prevents session exit when loop is active. Feeds prompt back as input.
# Supports both METRIC MODE (autoresearch keep/discard) and TASK MODE (ralph-style).

set -euo pipefail

PROJECT_DIR="."
STATE_FILE=".claude/auto-research-loop.local.md"
SCRATCHPAD_PATH=".claude/auto-research-loop-scratchpad.md"
SCRATCHPAD_MTIME_MARKER=".claude/.auto-research-loop-scratchpad-mtime"
ARL_LOG_FILE=".claude/auto-research-loop-log.jsonl"
RESULTS_FILE="./autoresearch-results.tsv"
GATE_TIMEOUT_SECONDS=60

# =============================================================================
# Helper Functions
# =============================================================================

_arl_log() { echo "[auto-research-loop] $*" >&2; }

_cb_md5() {
  if command -v md5sum >/dev/null 2>&1; then md5sum | awk '{print $1}'
  elif command -v md5 >/dev/null 2>&1; then md5 -q
  else shasum -a 256 | awk '{print $1}'; fi
}

_portable_mtime() {
  local f="$1"
  if [[ "$(uname)" == "Darwin" ]]; then stat -f "%m" "$f" 2>/dev/null || echo "0"
  else stat -c "%Y" "$f" 2>/dev/null || echo "0"; fi
}

_read_key() {
  local file="$1" key="$2"
  sed -n "s/^${key}:[[:space:]]*//p" "$file" 2>/dev/null | head -1
}

_write_key() {
  local file="$1" key="$2" value="$3"
  if grep -q "^${key}:" "$file" 2>/dev/null; then
    sed -i.bak "s/^${key}:.*/${key}: ${value}/" "$file"
    rm -f "${file}.bak"
  else
    echo "${key}: ${value}" >> "$file"
  fi
}

run_with_timeout() {
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

# =============================================================================
# Backpressure Gates
# =============================================================================

GATE_RESULT_MSG=""
GATES_FEEDBACK=""

has_gates() {
  [[ -n "${GATE_TEST_CMD:-}" || -n "${GATE_LINT_CMD:-}" || -n "${GATE_TYPECHECK_CMD:-}" ]]
}

run_gate() {
  local gate_name="$1" gate_cmd="$2"
  [[ -z "$gate_cmd" ]] && return 0
  _arl_log "Running gate: ${gate_name} -> ${gate_cmd}"
  local output exit_code
  output=$(run_with_timeout "$GATE_TIMEOUT_SECONDS" bash -c "$gate_cmd" 2>&1) || true
  exit_code=${PIPESTATUS[0]:-$?}
  if [[ $exit_code -eq 124 || $exit_code -eq 137 ]]; then
    _arl_log "GATE TIMEOUT: ${gate_name}"
    GATE_RESULT_MSG+="Gate TIMEOUT: \`${gate_cmd}\` exceeded ${GATE_TIMEOUT_SECONDS}s.\n\n"
    return 1
  fi
  if [[ $exit_code -ne 0 ]]; then
    _arl_log "GATE FAILED: ${gate_name} (exit ${exit_code})"
    local truncated; truncated=$(echo "$output" | tail -80)
    local total; total=$(echo "$output" | wc -l | tr -d ' ')
    GATE_RESULT_MSG+="Gate failed: \`${gate_cmd}\` exit ${exit_code}."
    [[ "$total" -gt 80 ]] && GATE_RESULT_MSG+=" (last 80 of ${total} lines)"
    GATE_RESULT_MSG+="\n\`\`\`\n${truncated}\n\`\`\`\n\n"
    return 1
  fi
  _arl_log "GATE PASSED: ${gate_name}"
  return 0
}

evaluate_gates() {
  has_gates || { _arl_log "No gates configured"; return 0; }
  _arl_log "=== Evaluating gates ==="
  GATE_RESULT_MSG=""
  local any_failed=0 summary=""
  if [[ -n "${GATE_TEST_CMD:-}" ]]; then
    if run_gate "test" "$GATE_TEST_CMD"; then summary+="  [PASS] test: ${GATE_TEST_CMD}\n"
    else summary+="  [FAIL] test: ${GATE_TEST_CMD}\n"; any_failed=1; fi
  fi
  if [[ -n "${GATE_LINT_CMD:-}" ]]; then
    if run_gate "lint" "$GATE_LINT_CMD"; then summary+="  [PASS] lint: ${GATE_LINT_CMD}\n"
    else summary+="  [FAIL] lint: ${GATE_LINT_CMD}\n"; any_failed=1; fi
  fi
  if [[ -n "${GATE_TYPECHECK_CMD:-}" ]]; then
    if run_gate "typecheck" "$GATE_TYPECHECK_CMD"; then summary+="  [PASS] typecheck: ${GATE_TYPECHECK_CMD}\n"
    else summary+="  [FAIL] typecheck: ${GATE_TYPECHECK_CMD}\n"; any_failed=1; fi
  fi
  if [[ $any_failed -eq 1 ]]; then
    GATES_FEEDBACK="## Gates: BLOCKED\n\n$(echo -e "$summary")\n\n### Errors\n${GATE_RESULT_MSG}\nFix issues and try again."
    _arl_log "Gates BLOCKED completion"
    return 1
  fi
  GATES_FEEDBACK="## Gates: ALL PASSED\n$(echo -e "$summary")"
  _arl_log "All gates passed"
  return 0
}

# =============================================================================
# Circuit Breaker
# =============================================================================

run_circuit_breaker() {
  local state_file="$1" iteration="$2" project_dir="$3"
  [[ ! -f "$state_file" ]] && return 0
  local max_failures; max_failures="$(_read_key "$state_file" "max_consecutive_failures")"; max_failures="${max_failures:-5}"
  local consecutive_failures; consecutive_failures="$(_read_key "$state_file" "consecutive_failures")"; consecutive_failures="${consecutive_failures:-0}"
  local last_diff_hash; last_diff_hash="$(_read_key "$state_file" "last_diff_hash")"; last_diff_hash="${last_diff_hash:-none}"
  local made_commit=false diff_changed=false
  local last_head_hash; last_head_hash="$(_read_key "$state_file" "last_head_hash")"; last_head_hash="${last_head_hash:-none}"
  local current_head_hash="none"
  if git -C "$project_dir" rev-parse --git-dir >/dev/null 2>&1; then
    current_head_hash="$(git -C "$project_dir" rev-parse HEAD 2>/dev/null || echo none)"
    [[ "$last_head_hash" != "none" && "$current_head_hash" != "$last_head_hash" ]] && made_commit=true
  fi
  _write_key "$state_file" "last_head_hash" "$current_head_hash"
  local current_diff_hash="none"
  if git -C "$project_dir" rev-parse --git-dir >/dev/null 2>&1; then
    current_diff_hash="$( { git -C "$project_dir" diff 2>/dev/null; git -C "$project_dir" diff --cached 2>/dev/null; git -C "$project_dir" status --porcelain 2>/dev/null; } | _cb_md5)"
    [[ -z "$current_diff_hash" ]] && current_diff_hash="empty"
  fi
  [[ "$current_diff_hash" != "$last_diff_hash" ]] && diff_changed=true
  _write_key "$state_file" "last_diff_hash" "$current_diff_hash"
  if [[ "$made_commit" == true ]] || [[ "$diff_changed" == true ]]; then
    _write_key "$state_file" "consecutive_failures" "0"
  else
    if [[ "$iteration" -gt 1 ]]; then
      consecutive_failures=$(( consecutive_failures + 1 ))
      _write_key "$state_file" "consecutive_failures" "$consecutive_failures"
      _arl_log "No progress. Failures: ${consecutive_failures}/${max_failures}"
    fi
  fi
  if [[ "$consecutive_failures" -ge "$max_failures" ]]; then
    echo "CIRCUIT BREAKER: Stopped after ${consecutive_failures} stalls." >&2
    rm -f "$state_file"
    return 1
  fi
  return 0
}

# =============================================================================
# Metric Mode Functions
# =============================================================================

run_verify_command() {
  local verify_cmd="$1"
  local output
  output=$(run_with_timeout "${VERIFY_TIMEOUT:-300}" bash -c "$verify_cmd" 2>&1) || true
  # Extract last number from output
  local metric_val
  metric_val=$(echo "$output" | grep -oE '[0-9]+\.?[0-9]*' | tail -1)
  echo "${metric_val:-}"
}

metric_is_better() {
  local new="$1" best="$2" direction="$3"
  if [[ -z "$new" || -z "$best" || "$best" == "none" ]]; then
    echo "true"; return
  fi
  if [[ "$direction" == "higher" ]]; then
    awk "BEGIN { print ($new > $best) ? \"true\" : \"false\" }"
  else
    awk "BEGIN { print ($new < $best) ? \"true\" : \"false\" }"
  fi
}

metric_delta() {
  local new="$1" best="$2"
  if [[ -z "$best" || "$best" == "none" ]]; then echo "0"; return; fi
  awk "BEGIN { printf \"%.6f\", $new - $best }"
}

append_results_tsv() {
  local iteration="$1" commit="$2" metric="$3" delta="$4" status="$5" desc="$6"
  [[ ! -f "$RESULTS_FILE" ]] && return
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$iteration" "$commit" "$metric" "$delta" "$status" "$desc" >> "$RESULTS_FILE"
}

# =============================================================================
# Structured Logging
# =============================================================================

_log_duration() {
  [[ ! -f "$ARL_LOG_FILE" ]] && { echo "0"; return; }
  local last_ts; last_ts="$(tail -1 "$ARL_LOG_FILE" 2>/dev/null | jq -r '.timestamp // empty' 2>/dev/null)"
  [[ -z "$last_ts" ]] && { echo "0"; return; }
  local now_epoch last_epoch
  now_epoch="$(date -u '+%s')"
  if date -j >/dev/null 2>&1; then
    last_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$last_ts" '+%s' 2>/dev/null || echo 0)"
  else
    last_epoch="$(date -u -d "$last_ts" '+%s' 2>/dev/null || echo 0)"
  fi
  [[ "$last_epoch" -eq 0 ]] && { echo "0"; return; }
  echo $(( now_epoch - last_epoch ))
}

log_iteration() {
  command -v jq >/dev/null 2>&1 || return 0
  mkdir -p "$(dirname "$ARL_LOG_FILE")"
  [[ ! -f "$ARL_LOG_FILE" ]] && touch "$ARL_LOG_FILE"
  local dur; dur="$(_log_duration)"
  local files_changed=0 files_added=0 commits=0 diff_summary=""
  if git rev-parse --git-dir >/dev/null 2>&1; then
    files_changed="$(git diff --name-only HEAD 2>/dev/null | wc -l | tr -d ' ')"
    files_added="$(git status --porcelain 2>/dev/null | grep -c '^?' || echo 0)"
    commits="$(git log --oneline --since='5 minutes ago' 2>/dev/null | wc -l | tr -d ' ')"
    diff_summary="$(git diff --stat HEAD~1 2>/dev/null | head -5 | tr '\n' ' ' | head -c 200)"
  fi
  local transcript_bytes=0 estimated_tokens=0 estimated_cost=0
  if [[ -n "${TRANSCRIPT_PATH:-}" && -f "$TRANSCRIPT_PATH" ]]; then
    transcript_bytes="$(wc -c < "$TRANSCRIPT_PATH" | tr -d ' ')"
    estimated_tokens=$(( transcript_bytes / 4 ))
    estimated_cost="$(awk "BEGIN { printf \"%.4f\", ($estimated_tokens * 0.039) / 1000 }")"
  fi
  jq -n -c \
    --arg event "iteration_complete" \
    --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson iter "${ITERATION:-0}" \
    --argjson dur "$dur" \
    --argjson fc "$files_changed" \
    --argjson fa "$files_added" \
    --argjson cm "$commits" \
    --argjson tb "$transcript_bytes" \
    --argjson et "$estimated_tokens" \
    --argjson ec "$estimated_cost" \
    --argjson pd "${PROMISE_DETECTED:-false}" \
    --arg ds "$diff_summary" \
    --arg mode "${MODE:-task}" \
    --arg metric_val "${CURRENT_METRIC:-}" \
    --arg metric_status "${METRIC_STATUS:-}" \
    '{ event:$event, timestamp:$ts, iteration:$iter, duration_seconds:$dur, files_changed:$fc, files_added:$fa, commits_made:$cm, transcript_size_bytes:$tb, estimated_tokens:$et, estimated_cost_usd:$ec, promise_detected:$pd, git_diff_summary:$ds, mode:$mode, metric_value:$metric_val, metric_status:$metric_status }' \
    >> "$ARL_LOG_FILE"
}

log_completion() {
  command -v jq >/dev/null 2>&1 || return 0
  local reason="${LOOP_EXIT_REASON:-unknown}"
  local total_iterations=0 total_duration=0 total_cost="0.0000"
  if [[ -f "$ARL_LOG_FILE" ]]; then
    total_iterations="$(grep -c '"event":"iteration_complete"' "$ARL_LOG_FILE" 2>/dev/null || echo 0)"
    total_duration="$(jq -s '[.[] | select(.event == "iteration_complete") | .duration_seconds] | add // 0' "$ARL_LOG_FILE" 2>/dev/null || echo 0)"
    total_cost="$(jq -s '[.[] | select(.event == "iteration_complete") | .estimated_cost_usd] | add // 0' "$ARL_LOG_FILE" 2>/dev/null || echo 0)"
  fi
  jq -n -c \
    --arg event "loop_completed" \
    --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson ti "$total_iterations" \
    --argjson td "$total_duration" \
    --argjson tc "$total_cost" \
    --arg cr "$reason" \
    '{ event:$event, timestamp:$ts, total_iterations:$ti, total_duration_seconds:$td, total_estimated_cost_usd:$tc, completion_reason:$cr }' \
    >> "$ARL_LOG_FILE"
}

# =============================================================================
# Main Stop Hook
# =============================================================================

HOOK_INPUT=$(cat)

# No active loop? Allow exit
[[ ! -f "$STATE_FILE" ]] && exit 0

# --- Parse state file --------------------------------------------------------
FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE")
ITERATION=$(echo "$FRONTMATTER" | grep '^iteration:' | sed 's/iteration: *//')
MAX_ITERATIONS=$(echo "$FRONTMATTER" | grep '^max_iterations:' | sed 's/max_iterations: *//')
COMPLETION_PROMISE=$(echo "$FRONTMATTER" | grep '^completion_promise:' | sed 's/completion_promise: *//' | sed 's/^"\(.*\)"$/\1/')
MODE=$(_read_key "$STATE_FILE" "mode"); MODE="${MODE:-task}"
METRIC_NAME=$(_read_key "$STATE_FILE" "metric_name"); METRIC_NAME="${METRIC_NAME:-none}"
METRIC_DIRECTION=$(_read_key "$STATE_FILE" "metric_direction"); METRIC_DIRECTION="${METRIC_DIRECTION:-higher}"
VERIFY_CMD=$(_read_key "$STATE_FILE" "verify_cmd"); VERIFY_CMD="${VERIFY_CMD:-none}"
BEST_METRIC=$(_read_key "$STATE_FILE" "best_metric"); BEST_METRIC="${BEST_METRIC:-none}"
VERIFY_TIMEOUT=$(_read_key "$STATE_FILE" "verify_timeout"); VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-300}"
GATE_TEST_CMD=$(_read_key "$STATE_FILE" "test_cmd")
GATE_LINT_CMD=$(_read_key "$STATE_FILE" "lint_cmd")
GATE_TYPECHECK_CMD=$(_read_key "$STATE_FILE" "typecheck_cmd")

# Validate
if [[ ! "$ITERATION" =~ ^[0-9]+$ ]] || [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
  _arl_log "State file corrupted. Stopping."
  rm -f "$STATE_FILE"
  exit 0
fi

# Max iterations check
if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $ITERATION -ge $MAX_ITERATIONS ]]; then
  _arl_log "Max iterations ($MAX_ITERATIONS) reached."
  LOOP_EXIT_REASON="max_iterations"
  log_iteration; log_completion
  rm -f "$STATE_FILE"
  exit 0
fi

# --- Get transcript ----------------------------------------------------------
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path' 2>/dev/null)
if [[ -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]]; then
  _arl_log "No transcript found. Stopping."
  rm -f "$STATE_FILE"
  exit 0
fi

if ! grep -q '"role":"assistant"' "$TRANSCRIPT_PATH" 2>/dev/null; then
  _arl_log "No assistant messages in transcript. Stopping."
  rm -f "$STATE_FILE"
  exit 0
fi

LAST_LINE=$(grep '"role":"assistant"' "$TRANSCRIPT_PATH" | tail -1)
LAST_OUTPUT=$(echo "$LAST_LINE" | jq -r '.message.content | map(select(.type == "text")) | map(.text) | join("\n")' 2>/dev/null)

if [[ -z "$LAST_OUTPUT" ]]; then
  _arl_log "Empty assistant output. Stopping."
  rm -f "$STATE_FILE"
  exit 0
fi

# =============================================================================
# MODE-SPECIFIC LOGIC
# =============================================================================

CURRENT_METRIC=""
METRIC_STATUS=""
PROMISE_DETECTED="false"
GATE_BLOCKED="false"
METRIC_FEEDBACK=""

if [[ "$MODE" == "metric" ]]; then
  # --- METRIC MODE: Run verify, compare, keep/discard -----------------------
  _arl_log "=== Metric Mode: Running verify command ==="

  if [[ "$VERIFY_CMD" != "none" ]]; then
    CURRENT_METRIC=$(run_verify_command "$VERIFY_CMD")
    _arl_log "Metric value: ${CURRENT_METRIC:-FAILED}"

    commit_hash=$(git rev-parse --short HEAD 2>/dev/null || echo "-")
    desc=$(git log -1 --format='%s' 2>/dev/null || echo "unknown")

    if [[ -z "$CURRENT_METRIC" ]]; then
      # Verify command crashed
      METRIC_STATUS="crash"
      append_results_tsv "$ITERATION" "-" "0" "0" "crash" "$desc"
      git reset --hard HEAD~1 2>/dev/null || true
      METRIC_FEEDBACK="## Metric: CRASH\nVerify command failed to produce a number.\nReverted last commit. Try a different approach."
    else
      is_better=$(metric_is_better "$CURRENT_METRIC" "$BEST_METRIC" "$METRIC_DIRECTION")
      delta=$(metric_delta "$CURRENT_METRIC" "$BEST_METRIC")

      if [[ "$is_better" == "true" ]]; then
        METRIC_STATUS="keep"
        _arl_log "KEEP: ${CURRENT_METRIC} is better than ${BEST_METRIC} (delta: ${delta})"
        _write_key "$STATE_FILE" "best_metric" "$CURRENT_METRIC"
        BEST_METRIC="$CURRENT_METRIC"
        append_results_tsv "$ITERATION" "$commit_hash" "$CURRENT_METRIC" "$delta" "keep" "$desc"
        METRIC_FEEDBACK="## Metric: KEEP\n${METRIC_NAME}: ${CURRENT_METRIC} (best: ${BEST_METRIC}, delta: ${delta})\nCommit ${commit_hash} kept. Keep exploring improvements."
      else
        METRIC_STATUS="discard"
        _arl_log "DISCARD: ${CURRENT_METRIC} not better than ${BEST_METRIC} (delta: ${delta})"
        append_results_tsv "$ITERATION" "-" "$CURRENT_METRIC" "$delta" "discard" "$desc"
        git reset --hard HEAD~1 2>/dev/null || true
        METRIC_FEEDBACK="## Metric: DISCARD\n${METRIC_NAME}: ${CURRENT_METRIC} (best: ${BEST_METRIC}, delta: ${delta})\nReverted. Try a different approach."
      fi
    fi
  fi

  # Metric mode: also check gates if configured
  if has_gates; then
    evaluate_gates || true  # Gates are informational in metric mode, don't block
  fi

else
  # --- TASK MODE: Check promise + gates --------------------------------------
  if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
    PROMISE_TEXT=$(echo "$LAST_OUTPUT" | perl -0777 -pe 's/.*?<promise>(.*?)<\/promise>.*/$1/s; s/^\s+|\s+$//g; s/\s+/ /g' 2>/dev/null || echo "")

    if [[ -n "$PROMISE_TEXT" ]] && [[ "$PROMISE_TEXT" = "$COMPLETION_PROMISE" ]]; then
      PROMISE_DETECTED="true"

      if has_gates; then
        if ! evaluate_gates; then
          GATE_BLOCKED="true"
          _arl_log "Blocked by gates"
        else
          log_iteration
          LOOP_EXIT_REASON="promise"
          log_completion
          echo "Auto Research Loop: Promise met, all gates passed."
          rm -f "$STATE_FILE"
          exit 0
        fi
      else
        log_iteration
        LOOP_EXIT_REASON="promise"
        log_completion
        echo "Auto Research Loop: Promise met."
        rm -f "$STATE_FILE"
        exit 0
      fi
    fi
  fi
fi

# --- Circuit Breaker ---------------------------------------------------------
if ! run_circuit_breaker "$STATE_FILE" "$ITERATION" "$PROJECT_DIR"; then
  LOOP_EXIT_REASON="circuit_breaker"
  log_iteration; log_completion
  exit 0
fi

# --- Prepare next iteration --------------------------------------------------
NEXT_ITERATION=$((ITERATION + 1))

# Extract prompt (after closing ---)
PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")
if [[ -z "$PROMPT_TEXT" ]]; then
  _arl_log "No prompt in state file. Stopping."
  rm -f "$STATE_FILE"
  exit 0
fi

# Update iteration
TEMP_FILE="${STATE_FILE}.tmp.$$"
sed "s/^iteration: .*/iteration: $NEXT_ITERATION/" "$STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$STATE_FILE"

# --- Build system message ----------------------------------------------------
if [[ "$MODE" == "metric" ]]; then
  SYSTEM_MSG="Auto Research Loop iteration $NEXT_ITERATION | Mode: metric | ${METRIC_NAME}: ${CURRENT_METRIC:-?} (best: ${BEST_METRIC}) | Last: ${METRIC_STATUS:-?}"
elif [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
  SYSTEM_MSG="Auto Research Loop iteration $NEXT_ITERATION | Mode: task | To stop: <promise>$COMPLETION_PROMISE</promise> (ONLY when TRUE)"
else
  SYSTEM_MSG="Auto Research Loop iteration $NEXT_ITERATION | Mode: task | No promise set - loops infinitely"
fi

# Metric feedback
if [[ -n "$METRIC_FEEDBACK" ]]; then
  SYSTEM_MSG="${SYSTEM_MSG}

$(echo -e "$METRIC_FEEDBACK")"
fi

# Scratchpad enforcement
scratchpad_warning=""
if [[ -f "$SCRATCHPAD_PATH" ]]; then
  current_mtime=$(_portable_mtime "$SCRATCHPAD_PATH")
  if [[ -f "$SCRATCHPAD_MTIME_MARKER" ]]; then
    start_mtime=$(cat "$SCRATCHPAD_MTIME_MARKER" 2>/dev/null || echo "0")
    [[ "$current_mtime" == "$start_mtime" ]] && scratchpad_warning="WARNING: You did not update the scratchpad."
  elif grep -q "Not yet populated" "$SCRATCHPAD_PATH" 2>/dev/null; then
    scratchpad_warning="WARNING: Scratchpad not yet populated."
  fi
else
  scratchpad_warning="WARNING: Scratchpad missing. Recreate .claude/auto-research-loop-scratchpad.md"
fi
[[ -n "$scratchpad_warning" ]] && SYSTEM_MSG="${SYSTEM_MSG}

---
${scratchpad_warning}
---"

# Append scratchpad content
if [[ -f "$SCRATCHPAD_PATH" ]]; then
  SYSTEM_MSG="${SYSTEM_MSG}

===== SCRATCHPAD =====
$(cat "$SCRATCHPAD_PATH")
===== END SCRATCHPAD ====="
fi

# Save mtime marker
[[ -f "$SCRATCHPAD_PATH" ]] && _portable_mtime "$SCRATCHPAD_PATH" > "$SCRATCHPAD_MTIME_MARKER"

# Plan progress with stall/empty/done warnings
PLAN_FILE="./IMPLEMENTATION_PLAN.md"
STALL_THRESHOLD=3
if [[ -f "$PLAN_FILE" ]]; then
  completed=$(grep -ciE '^\s*-\s*\[x\]' "$PLAN_FILE" 2>/dev/null || echo 0)
  unchecked=$(grep -c '^\s*-\s*\[ \]' "$PLAN_FILE" 2>/dev/null || echo 0)
  total=$((completed + unchecked))

  has_real_tasks=true
  if [[ "$total" -le 1 ]]; then
    if grep -q '_Analyze task and break into subtasks_' "$PLAN_FILE" 2>/dev/null; then
      [[ "$completed" -eq 0 ]] && has_real_tasks=false
    fi
  fi

  progress_line="Plan: ${completed}/${total} tasks complete"
  [[ "$total" -eq 0 ]] && progress_line="Plan: No tasks defined yet"

  stall_warning=""
  if [[ "$ITERATION" -ge "$STALL_THRESHOLD" && "$completed" -eq 0 ]]; then
    stall_warning="
WARNING: ${ITERATION} iterations completed but NO tasks checked off.
- Are you updating IMPLEMENTATION_PLAN.md after completing work?
- Are tasks scoped correctly (completable in one iteration)?
- If blocked, document the blocker in Notes and move on."
  fi

  plan_empty_warning=""
  if [[ "$has_real_tasks" == "false" && "$ITERATION" -ge "$STALL_THRESHOLD" ]]; then
    plan_empty_warning="
WARNING: ${ITERATION} iterations but plan has no real tasks.
- You MUST break down the task into discrete subtasks.
- Populate the Tasks section in IMPLEMENTATION_PLAN.md before doing any work."
  fi

  all_done_message=""
  if [[ "$total" -gt 0 && "$unchecked" -eq 0 ]]; then
    all_done_message="
ALL TASKS COMPLETE. Review the implementation, run final checks, and signal completion."
  fi

  SYSTEM_MSG="${SYSTEM_MSG}

--- ${progress_line} ---${stall_warning}${plan_empty_warning}${all_done_message}

Next: Read IMPLEMENTATION_PLAN.md, pick the highest-priority unchecked task, execute it, mark it [x].
Path: ${PLAN_FILE}"
fi

# Gate feedback (task mode)
if [[ "$GATE_BLOCKED" == "true" ]]; then
  SYSTEM_MSG="${SYSTEM_MSG}

$(echo -e "$GATES_FEEDBACK")"
fi

# Results summary (metric mode, every 5 iterations)
if [[ "$MODE" == "metric" && -f "$RESULTS_FILE" && $(( NEXT_ITERATION % 5 )) -eq 0 ]]; then
  keeps=$(grep -c "	keep	" "$RESULTS_FILE" 2>/dev/null || echo 0)
  discards=$(grep -c "	discard	" "$RESULTS_FILE" 2>/dev/null || echo 0)
  crashes=$(grep -c "	crash	" "$RESULTS_FILE" 2>/dev/null || echo 0)
  SYSTEM_MSG="${SYSTEM_MSG}

--- Results: ${keeps} keeps / ${discards} discards / ${crashes} crashes | Best: ${BEST_METRIC} ---"
fi

# --- Log and output ----------------------------------------------------------
log_iteration

jq -n \
  --arg prompt "$PROMPT_TEXT" \
  --arg msg "$SYSTEM_MSG" \
  '{ "decision": "block", "reason": $prompt, "systemMessage": $msg }'

exit 0
