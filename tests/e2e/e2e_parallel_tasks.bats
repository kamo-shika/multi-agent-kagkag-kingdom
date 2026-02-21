#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# E2E-006: Parallel Tasks Test
# ═══════════════════════════════════════════════════════════════
# Validates that multiple citizen can process tasks simultaneously:
#   1. Two tasks assigned to citizen1 and citizen2
#   2. Both receive inbox nudges
#   3. Both complete independently
#   4. Both reports are written
#
# Uses 3-pane setup (minister + citizen1 + citizen2).
# ═══════════════════════════════════════════════════════════════

# bats file_tags=e2e

load "../test_helper/bats-support/load"
load "../test_helper/bats-assert/load"

# Load E2E helpers
E2E_HELPERS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/helpers" && pwd)"
source "$E2E_HELPERS_DIR/setup.bash"
source "$E2E_HELPERS_DIR/assertions.bash"
source "$E2E_HELPERS_DIR/tmux_helpers.bash"

# ─── Lifecycle ───

setup_file() {
    command -v tmux &>/dev/null || skip "tmux not available"
    command -v python3 &>/dev/null || skip "python3 not available"
    python3 -c "import yaml" 2>/dev/null || skip "python3-yaml not available"

    setup_e2e_session 3
}

teardown_file() {
    teardown_e2e_session
}

setup() {
    reset_queues
    sleep 1
}

# ═══════════════════════════════════════════════════════════════
# E2E-006-A: Two citizen process tasks in parallel
# ═══════════════════════════════════════════════════════════════

@test "E2E-006-A: citizen1 and citizen2 complete tasks in parallel" {
    # 1. Place tasks for both citizen
    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_citizen1_basic.yaml" \
       "$E2E_QUEUE/queue/tasks/citizen1.yaml"
    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_citizen2_basic.yaml" \
       "$E2E_QUEUE/queue/tasks/citizen2.yaml"

    # 2. Send task_assigned to both inboxes
    bash "$E2E_QUEUE/scripts/inbox_write.sh" "citizen1" \
        "タスクYAMLを読んで作業開始せよ。" "task_assigned" "minister"
    bash "$E2E_QUEUE/scripts/inbox_write.sh" "citizen2" \
        "タスクYAMLを読んで作業開始せよ。" "task_assigned" "minister"

    # 3. Nudge both simultaneously
    local citizen1_pane citizen2_pane
    citizen1_pane=$(pane_target 1)
    citizen2_pane=$(pane_target 2)

    send_to_pane "$citizen1_pane" "inbox1"
    send_to_pane "$citizen2_pane" "inbox1"

    # 4. Both should complete
    run wait_for_yaml_value "$E2E_QUEUE/queue/tasks/citizen1.yaml" "task.status" "done" 30
    assert_success
    run wait_for_yaml_value "$E2E_QUEUE/queue/tasks/citizen2.yaml" "task.status" "done" 30
    assert_success

    # 5. Both reports should exist
    run wait_for_file "$E2E_QUEUE/queue/reports/citizen1_report.yaml" 10
    assert_success
    run wait_for_file "$E2E_QUEUE/queue/reports/citizen2_report.yaml" 10
    assert_success

    # 6. Reports should have correct agent IDs
    assert_yaml_field "$E2E_QUEUE/queue/reports/citizen1_report.yaml" "worker_id" "citizen1"
    assert_yaml_field "$E2E_QUEUE/queue/reports/citizen2_report.yaml" "worker_id" "citizen2"
}

# ═══════════════════════════════════════════════════════════════
# E2E-006-B: Parallel tasks don't interfere with each other's inbox
# ═══════════════════════════════════════════════════════════════

@test "E2E-006-B: parallel tasks maintain inbox isolation" {
    # 1. Place tasks and send notifications
    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_citizen1_basic.yaml" \
       "$E2E_QUEUE/queue/tasks/citizen1.yaml"
    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_citizen2_basic.yaml" \
       "$E2E_QUEUE/queue/tasks/citizen2.yaml"

    bash "$E2E_QUEUE/scripts/inbox_write.sh" "citizen1" \
        "タスクYAMLを読んで作業開始せよ。" "task_assigned" "minister"
    bash "$E2E_QUEUE/scripts/inbox_write.sh" "citizen2" \
        "タスクYAMLを読んで作業開始せよ。" "task_assigned" "minister"

    local citizen1_pane citizen2_pane
    citizen1_pane=$(pane_target 1)
    citizen2_pane=$(pane_target 2)

    send_to_pane "$citizen1_pane" "inbox1"
    send_to_pane "$citizen2_pane" "inbox1"

    # 2. Wait for both to complete
    run wait_for_yaml_value "$E2E_QUEUE/queue/tasks/citizen1.yaml" "task.status" "done" 30
    assert_success
    run wait_for_yaml_value "$E2E_QUEUE/queue/tasks/citizen2.yaml" "task.status" "done" 30
    assert_success

    # 3. Each inbox should have its own messages (task_assigned from minister + no cross-contamination)
    # citizen1's inbox should NOT have citizen2's messages
    run python3 -c "
import yaml
with open('$E2E_QUEUE/queue/inbox/citizen1.yaml') as f:
    data = yaml.safe_load(f) or {}
msgs = data.get('messages', [])
# All messages in citizen1's inbox should be addressed to citizen1 context
# (no citizen2 task_assigned should appear here)
for m in msgs:
    if m.get('type') == 'task_assigned' and 'citizen2' in str(m.get('content', '')):
        print('CROSS-CONTAMINATION DETECTED')
        exit(1)
"
    assert_success
}
