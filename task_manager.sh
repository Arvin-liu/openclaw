#!/bin/bash

# Task Manager with Lifecycle Guarantees
TASK_DIR="/home/node/.openclaw/workspace/tasks"
LOCK_FILE="/home/node/.openclaw/workspace/task_lock"
TASK_QUEUE_FILE="/home/node/.openclaw/workspace/task_queue.json"
TASK_LIFECYCLE_FILE="/home/node/.openclaw/workspace/task_lifecycle.json"
TASK_LOG_DIR="/home/node/.openclaw/workspace/logs"

ACK_SLA_SECONDS=3
TASK_CLASS_SAFE="safe"
TASK_CLASS_MUTATING="mutating"

mkdir -p "$TASK_DIR" "$TASK_LOG_DIR"

if [ ! -f "$TASK_QUEUE_FILE" ]; then
    echo '{"tasks":[]}' > "$TASK_QUEUE_FILE"
fi

if [ ! -f "$TASK_LIFECYCLE_FILE" ]; then
    echo '{"tasks":{},"max_position":0}' > "$TASK_LIFECYCLE_FILE"
fi

touch "$LOCK_FILE"

get_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

send_ack() {
    local task_id="$1"
    local received_at="$2"
    local summary="$3"
    echo "[ACK][task_id=${task_id}][received_at=${received_at}] status=accepted action=started summary=\"${summary}\""
}

send_queued() {
    local task_id="$1"
    local position="$2"
    echo "[QUEUED][task_id=${task_id}][position=${position}] eta_seconds=5 summary=\"MUTATING task queued\""
}

acquire_lock() {
    local task_id="$1"
    local timeout_seconds="${2:-30}"
    local elapsed=0
    local lock_age_seconds=0
    local stale_detected=0

    # Check if lock file exists and is stale
    if [ -f "$LOCK_FILE" ] && [ -n "$(cat "$LOCK_FILE")" ]; then
        # Get file modification time in seconds since epoch
        lock_mod_time=$(stat -c %Y "$LOCK_FILE" 2>/dev/null || stat -f %m "$LOCK_FILE" 2>/dev/null || echo "0")
        now=$(date +%s)
        lock_age_seconds=$((now - lock_mod_time))

        if [ "$lock_age_seconds" -gt 120 ]; then
            echo "[STALE_LOCK][task_id=${task_id}] Detected stale lock (age: ${lock_age_seconds}s, held by: $(cat "$LOCK_FILE"))"
            rm -f "$LOCK_FILE"
            stale_detected=1
        fi
    fi

    # Wait for lock if present and not stale
    while [ -f "$LOCK_FILE" ] && [ -n "$(cat "$LOCK_FILE")" ]; do
        if [ $elapsed -ge $timeout_seconds ]; then
            return 1
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    echo "$task_id" > "$LOCK_FILE"

    if [ $stale_detected -eq 1 ]; then
        echo "[STALE_LOCK][task_id=${task_id}] Stale lock removed, new lock acquired"
    fi
    return 0
}

release_lock() {
    rm -f "$LOCK_FILE"
}

log_task_event() {
    local task_id="$1"
    local level="$2"
    local message="$3"
    echo "[LOG][task_id=${task_id}][level=${level}] message=\"${message}\"" >> "${TASK_LOG_DIR}/${task_id}.log"
}

send_status() {
    local task_id="$1"
    local status="$2"
    local level="$3"
    local timestamp="$4"
    local log_file="$5"
    local message="$6"
    echo "[STATUS][task_id=${task_id}][status=${status}][level=${level}][timestamp=${timestamp}] message=\"${message}\"" >> "${TASK_LOG_DIR}/${task_id}.log"
}

send_error() {
    local task_id="$1"
    local error_code="$2"
    local error_message="$3"
    local context="$4"
    local next_action="$5"
    log_task_event "$task_id" "ERROR" "${error_code}: ${error_message} (context: ${context})"
    send_status "$task_id" "error" "ERROR" "$(get_timestamp)" "logs/${task_id}.log" "${error_code}: ${error_message}"
}

safe_sed_replace() {
    local pattern="$1"
    local replacement="$2"
    local file="$3"
    # Simple sed replacement with error handling
    if command -v sed >/dev/null 2>&1; then
        sed -i "s${pattern}${replacement}g" "$file" 2>/dev/null || echo "$file" | sed "s${pattern}${replacement}g" > "${file}.tmp" && mv "${file}.tmp" "$file"
    else
        # Fallback if sed is not available
        echo "sed not available, skipping replacement"
    fi
}

# Terminal event guarantee handler (must be defined before run_task)
task_terminal_handler() {
    local terminal_state="${1:-DONE}"
    local timestamp=$(get_timestamp)
    echo "[${terminal_state}][task_id=${task_id}] Task terminated with ${terminal_state}"
    echo "{\"task_id\":\"${task_id}\",\"state\":\"${terminal_state}\",\"last_event\":\"${terminal_state}\",\"last_update_at\":\"${timestamp}\"}" > "$TASK_LIFECYCLE_FILE"
}

enqueue_task() {
    local task_id="$1"
    local task_class="$2"
    local summary="$3"
    local timestamp=$(get_timestamp)
    local queue=$(cat "$TASK_QUEUE_FILE")
    local max_position=$(echo "$queue" | grep -o '"max_position":[0-9]*' | cut -d':' -f2)
    [ -z "$max_position" ] && max_position=0
    local new_position=$((max_position + 1))
    local new_queue=$(echo "$queue" | sed "s/\"tasks\":\[/\"tasks\":[{\"id\":\"${task_id}\",\"class\":\"${task_class}\",\"summary\":\"${summary}\",\"position\":${new_position},\"status\":\"queued\",\"queued_at\":\"${timestamp}\"},/")
    echo "$new_queue" > "$TASK_QUEUE_FILE"
    echo "$new_queue" | sed "s/\"max_position\":[0-9]*/\"max_position\":${new_position}/" > "$TASK_QUEUE_FILE.tmp"
    mv "$TASK_QUEUE_FILE.tmp" "$TASK_QUEUE_FILE"
    echo "$new_position"
}

run_task() {
    local task_id="$1"
    local task_class="$2"
    local summary="$3"
    local timeout_seconds="${4:-300}"
    local received_at=$(get_timestamp)
    local ack_guard_file="/home/node/.openclaw/workspace/ack_sent_$(echo "$task_id" | tr -c 'a-zA-Z0-9_' '_')"

    # Check if ACK has already been sent for this task_id (guard against duplicate ACKs)
    if [ -f "$ack_guard_file" ]; then
        echo "[INFO][task_id=${task_id}] ACK already sent, skipping"
        return 0
    fi

    # Set trap for terminal event guarantee
    # This ensures exactly one terminal event (DONE or ERROR)
    trap 'task_terminal_handler DONE' EXIT
    trap 'task_terminal_handler ERROR' ERR
    trap 'task_terminal_handler ERROR' INT
    trap 'task_terminal_handler ERROR' TERM

    # Send ACK (only once per task_id)
    send_ack "$task_id" "$received_at" "$summary"

    # Mark ACK as sent (guard file)
    echo "$(get_timestamp)" > "$ack_guard_file"

    # Check SLA
    if [ $(( $(date -d "$(get_timestamp)" +%s) - $(date -d "$received_at" +%s) )) -ge $ACK_SLA_SECONDS ]; then
        return 1
    fi

    # Enqueue task
    if ! queued_position=$(enqueue_task "$task_id" "$task_class" "$summary" 2>/dev/null); then
        return 1
    fi

    # For MUTATING tasks, try to acquire lock immediately (including stale-lock recovery)
    if [ "$task_class" == "$TASK_CLASS_MUTATING" ]; then
        if ! acquire_lock "$task_id" 30; then
            # Lock timeout - fresh lock is still held
            echo "[QUEUED][task_id=${task_id}][position=${queued_position}] eta_seconds=5 summary=\"${summary}\""
            return 0
        fi
        echo "[LOCK_ACQUIRED][task_id=${task_id}] MUTATING task lock acquired"
    fi

    # Execute task (SAFE tasks or MUTATING tasks with lock acquired)
    "$task_id" "$task_class" "$summary" "$timeout_seconds" || return $?

    # Release lock if MUTATING
    if [ "$task_class" == "$TASK_CLASS_MUTATING" ]; then
        release_lock
        echo "[LOCK_RELEASED][task_id=${task_id}] MUTATING task lock released"
    fi

    return 0
}
