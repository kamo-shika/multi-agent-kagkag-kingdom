#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# E2E-002: Inbox Delivery Test
# ═══════════════════════════════════════════════════════════════
# Validates the inbox messaging pipeline:
#   1. inbox_write.sh correctly writes messages to YAML
#   2. Messages are recorded with correct fields
#   3. Mock CLI processes inbox when nudged
#   4. Messages are marked as read after processing
#   5. Multiple messages are handled correctly
#
# Tests inbox_write.sh → (nudge) → mock_cli processes → read: true
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
# E2E-002-A: inbox_write.sh writes message to YAML correctly
# ═══════════════════════════════════════════════════════════════

@test "E2E-002-A: inbox_write.sh creates message with correct fields" {
    # 1. Write a message to citizen1's inbox
    run bash "$E2E_QUEUE/scripts/inbox_write.sh" "citizen1" \
        "テスト配信メッセージ" "task_assigned" "minister"
    assert_success

    # 2. Verify YAML file exists and has correct structure
    [ -f "$E2E_QUEUE/queue/inbox/citizen1.yaml" ]

    # 3. Verify message fields
    run assert_inbox_message_exists "$E2E_QUEUE/queue/inbox/citizen1.yaml" "minister" "task_assigned"
    assert_success

    # 4. Verify message is unread
    run assert_inbox_unread_count "$E2E_QUEUE/queue/inbox/citizen1.yaml" 1
    assert_success
}

# ═══════════════════════════════════════════════════════════════
# E2E-002-B: Mock CLI processes inbox on nudge
# ═══════════════════════════════════════════════════════════════

@test "E2E-002-B: mock CLI reads and processes inbox after nudge" {
    # 1. Place a task for citizen1
    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_citizen1_basic.yaml" \
       "$E2E_QUEUE/queue/tasks/citizen1.yaml"

    # 2. Write task_assigned to inbox
    bash "$E2E_QUEUE/scripts/inbox_write.sh" "citizen1" \
        "タスクYAMLを読んで作業開始せよ。" "task_assigned" "minister"

    # 3. Verify 1 unread message
    run assert_inbox_unread_count "$E2E_QUEUE/queue/inbox/citizen1.yaml" 1
    assert_success

    # 4. Send nudge to mock CLI
    local citizen1_pane
    citizen1_pane=$(pane_target 1)
    send_to_pane "$citizen1_pane" "inbox1"

    # 5. Wait for processing (task goes to done)
    run wait_for_yaml_value "$E2E_QUEUE/queue/tasks/citizen1.yaml" "task.status" "done" 30
    assert_success

    # 6. Verify all inbox messages are now read
    run assert_inbox_unread_count "$E2E_QUEUE/queue/inbox/citizen1.yaml" 0
    assert_success
}

# ═══════════════════════════════════════════════════════════════
# E2E-002-C: Multiple messages in inbox are all processed
# ═══════════════════════════════════════════════════════════════

@test "E2E-002-C: multiple inbox messages are all marked as read" {
    # 1. Write 3 messages to citizen1's inbox
    bash "$E2E_QUEUE/scripts/inbox_write.sh" "citizen1" \
        "メッセージ1" "info" "system"
    bash "$E2E_QUEUE/scripts/inbox_write.sh" "citizen1" \
        "メッセージ2" "info" "system"
    bash "$E2E_QUEUE/scripts/inbox_write.sh" "citizen1" \
        "メッセージ3" "info" "system"

    # 2. Verify 3 unread
    run assert_inbox_unread_count "$E2E_QUEUE/queue/inbox/citizen1.yaml" 3
    assert_success

    # 3. Send nudge
    local citizen1_pane
    citizen1_pane=$(pane_target 1)
    send_to_pane "$citizen1_pane" "inbox3"

    # 4. Wait for processing
    sleep 5

    # 5. All messages should be read
    run assert_inbox_unread_count "$E2E_QUEUE/queue/inbox/citizen1.yaml" 0
    assert_success
}

# ═══════════════════════════════════════════════════════════════
# E2E-002-D: inbox_write.sh to different agents are isolated
# ═══════════════════════════════════════════════════════════════

@test "E2E-002-D: messages to different agents stay in separate inboxes" {
    # 1. Write to minister and citizen1
    bash "$E2E_QUEUE/scripts/inbox_write.sh" "minister" \
        "大臣向けメッセージ" "cmd_new" "king"
    bash "$E2E_QUEUE/scripts/inbox_write.sh" "citizen1" \
        "市民1向けメッセージ" "task_assigned" "minister"

    # 2. Each inbox should have exactly 1 unread
    run assert_inbox_unread_count "$E2E_QUEUE/queue/inbox/minister.yaml" 1
    assert_success
    run assert_inbox_unread_count "$E2E_QUEUE/queue/inbox/citizen1.yaml" 1
    assert_success

    # 3. citizen2 inbox should be empty (0 unread)
    run assert_inbox_unread_count "$E2E_QUEUE/queue/inbox/citizen2.yaml" 0
    assert_success
}

# ═══════════════════════════════════════════════════════════════
# E2E-002-E: Report notification flows back via inbox
# ═══════════════════════════════════════════════════════════════

@test "E2E-002-E: citizen1 completion sends report_received to minister inbox" {
    # 1. Place task for citizen1
    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_citizen1_basic.yaml" \
       "$E2E_QUEUE/queue/tasks/citizen1.yaml"

    # 2. Trigger processing
    bash "$E2E_QUEUE/scripts/inbox_write.sh" "citizen1" \
        "タスクYAMLを読んで作業開始せよ。" "task_assigned" "minister"

    local citizen1_pane
    citizen1_pane=$(pane_target 1)
    send_to_pane "$citizen1_pane" "inbox1"

    # 3. Wait for task completion
    run wait_for_yaml_value "$E2E_QUEUE/queue/tasks/citizen1.yaml" "task.status" "done" 30
    assert_success

    # 4. Wait a moment for inbox_write to complete
    sleep 2

    # 5. Verify minister received report_received notification
    run assert_inbox_message_exists "$E2E_QUEUE/queue/inbox/minister.yaml" "citizen1" "report_received"
    assert_success
}
