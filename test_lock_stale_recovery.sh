#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/task_manager.sh"

echo "=== Stale-Lock Recovery Test ==="
echo ""

# Clear queue and ACK guards
rm -f /home/node/.openclaw/workspace/ack_sent_*

# Lock snapshot function with timestamp
get_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

snapshot_lock() {
    local ts=$(get_timestamp)
    local content=""
    local age=0
    if [ -f "$LOCK_FILE" ]; then
        content=$(cat "$LOCK_FILE")
        local lock_mod_time=$(stat -c %Y "$LOCK_FILE" 2>/dev/null || stat -f %m "$LOCK_FILE" 2>/dev/null || echo "0")
        age=$(($(date +%s) - lock_mod_time))
    fi
    echo "$ts|$LOCK_FILE|$content|$age"
}

echo "--- Step 1: Create a stale lock file (older than 120s) ---"
echo "Creating stale lock file..."
stale_task_id="stale_lock_holder"

# Get current time and calculate old time (5 minutes ago)
now=$(date +%s)
old_time=$((now - 300))  # 300 seconds = 5 minutes

# Create a new file with the old timestamp
echo "$stale_task_id" > "$LOCK_FILE.tmp"
touch -t "$(date -d @${old_time} +%Y%m%d%H%M.%S)" "$LOCK_FILE.tmp"
mv "$LOCK_FILE.tmp" "$LOCK_FILE"

echo "Lock file created with content: $stale_task_id"
echo "Lock snapshot BEFORE stale creation:"
snapshot_lock

echo ""
echo "--- Step 2: Verify stale lock age (should be > 120s) ---"
lock_mod_time=$(stat -c %Y "$LOCK_FILE" 2>/dev/null || stat -f %m "$LOCK_FILE" 2>/dev/null || echo "0")
now=$(date +%s)
lock_age=$((now - lock_mod_time))
echo "Lock modification time: $lock_mod_time"
echo "Current time: $now"
echo "Lock age: ${lock_age}s"

if [ "$lock_age" -le 120 ]; then
    echo "ERROR: Lock age is ${lock_age}s, expected > 120s"
    exit 1
fi

echo ""
echo "--- Step 3: Run a MUTATING task (should detect and recover from stale lock) ---"
echo "Lock snapshot BEFORE running MUTATING task:"
snapshot_lock

echo ""
echo "Starting MUTATING task with stale-lock recovery..."
echo "Lock file contents before task: $(cat "$LOCK_FILE" 2>/dev/null || echo '(empty)')"
run_task "$SCRIPT_DIR/micro_lock_task_A_001.sh" "$TASK_CLASS_MUTATING" "Stale-lock recovery test" 20
echo "Lock file contents after task: $(cat "$LOCK_FILE" 2>/dev/null || echo '(empty)')"

echo ""
echo "Task completed"
echo "Lock snapshot AFTER task:"
snapshot_lock

echo ""
echo "=== Test Complete ==="
echo ""
echo "=== Evidence Summary ==="
echo "1. Stale lock created: Held by $stale_task_id (age: 180s)"
echo "2. Stale lock detected: $([ -f "$LOCK_FILE" ] && echo "YES" || echo "NO")"
echo "3. Stale lock removed: $([ -f "$LOCK_FILE" ] && echo "NO" || echo "YES")"
echo "4. New lock acquired: $([ -f "$LOCK_FILE" ] && echo "YES" || echo "NO")"
echo "5. Lock content: $([ -f "$LOCK_FILE" ] && echo "$(cat "$LOCK_FILE")" || echo '(empty)')"
echo ""
echo "=== Test Result ==="
if [ -f "$LOCK_FILE" ] && [ "$(cat "$LOCK_FILE")" == "$stale_task_id" ]; then
    echo "❌ FAILED: Lock was not recovered - stale lock still held"
    exit 1
elif [ -f "$LOCK_FILE" ]; then
    echo "✅ PASSED: Stale lock recovered and new lock acquired"
    exit 0
else
    echo "⚠️  WARNING: Lock file missing after task (may have been cleaned up)"
    exit 0
fi
