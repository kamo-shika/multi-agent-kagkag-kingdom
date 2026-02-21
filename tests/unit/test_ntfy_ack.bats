#!/usr/bin/env bats
# test_ntfy_ack.bats — ntfy ACK自動返信ユニットテスト
# PR #46: ntfyメッセージ受信時の自動ACK返信機能
#
# テスト構成:
#   T-ACK-001: 正常メッセージ → ACK送信
#   T-ACK-002: outboundタグ付き → ACKスキップ（ループ防御）
#   T-ACK-003: ACKメッセージ形式確認
#   T-ACK-004: ACK送信失敗 → inbox_write継続
#   T-ACK-005: 空メッセージ → ACKスキップ
#   T-ACK-006: keepaliveイベント → ACKスキップ
#   T-ACK-007: append_ntfy_inbox失敗 → ACK・inbox_write両方スキップ
#   T-ACK-008: 特殊文字がACKに保持される

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    [ -x "$PROJECT_ROOT/.venv/bin/python3" ] || skip "python3 not found in .venv"
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/ntfy_ack_test.XXXXXX")"
    export MOCK_PROJECT="$TEST_TMPDIR/mock_project"
    export MOCK_BIN="$TEST_TMPDIR/mock_bin"
    export ACK_LOG="$TEST_TMPDIR/ack.log"
    export INBOX_LOG="$TEST_TMPDIR/inbox.log"
    export MOCK_CURL_OUTPUT="$TEST_TMPDIR/curl_output.json"

    # モックプロジェクト構築
    mkdir -p "$MOCK_PROJECT"/{config,lib,scripts,queue,logs/ntfy_inbox_corrupt}
    mkdir -p "$MOCK_PROJECT/.venv/bin"
    mkdir -p "$MOCK_BIN"

    # settings.yaml
    cat > "$MOCK_PROJECT/config/settings.yaml" << 'YAML'
ntfy_topic: "test-ack-topic-12345"
YAML

    # 空の認証ファイル
    touch "$MOCK_PROJECT/config/ntfy_auth.env"

    # 本物のntfy_auth.shをコピー
    cp "$PROJECT_ROOT/lib/ntfy_auth.sh" "$MOCK_PROJECT/lib/"

    # python3シンボリックリンク
    ln -sf "$PROJECT_ROOT/.venv/bin/python3" "$MOCK_PROJECT/.venv/bin/python3"

    # ntfy_inbox初期化
    echo "inbox:" > "$MOCK_PROJECT/queue/ntfy_inbox.yaml"

    # --- モックスクリプト ---

    # mock curl
    cat > "$MOCK_BIN/curl" << 'CURL_MOCK'
#!/bin/bash
if [ -f "$MOCK_CURL_OUTPUT" ]; then
    cat "$MOCK_CURL_OUTPUT"
fi
CURL_MOCK
    chmod +x "$MOCK_BIN/curl"

    # mock ntfy.sh
    cat > "$MOCK_PROJECT/scripts/ntfy.sh" << 'NTFY_MOCK'
#!/bin/bash
echo "$1" >> "$ACK_LOG"
exit ${MOCK_NTFY_EXIT_CODE:-0}
NTFY_MOCK
    chmod +x "$MOCK_PROJECT/scripts/ntfy.sh"

    # mock inbox_write.sh
    cat > "$MOCK_PROJECT/scripts/inbox_write.sh" << 'INBOX_MOCK'
#!/bin/bash
echo "$@" >> "$INBOX_LOG"
INBOX_MOCK
    chmod +x "$MOCK_PROJECT/scripts/inbox_write.sh"

    # ntfy_listener.shコピー（SCRIPT_DIR差し替え）
    sed "s|^SCRIPT_DIR=.*|SCRIPT_DIR=\"$MOCK_PROJECT\"|" \
        "$PROJECT_ROOT/scripts/ntfy_listener.sh" \
        > "$MOCK_PROJECT/ntfy_listener_test.sh"
    chmod +x "$MOCK_PROJECT/ntfy_listener_test.sh"

    # ログ初期化
    touch "$ACK_LOG" "$INBOX_LOG"

    # PATHにモックcurlを先頭配置
    export PATH="$MOCK_BIN:$PATH"

    # デフォルト: ntfy.sh正常終了
    unset MOCK_NTFY_EXIT_CODE
}

teardown() {
    # Restore permissions if changed (T-ACK-007)
    chmod 755 "$MOCK_PROJECT/queue" 2>/dev/null || true
    rm -rf "$TEST_TMPDIR"
}

# --- ヘルパー ---

run_listener() {
    timeout 3 bash "$MOCK_PROJECT/ntfy_listener_test.sh" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-001: Normal message triggers ACK send
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-001: Normal message triggers ACK send" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"msg001","time":1234567890,"message":"テスト通知","tags":[]}
JSON
    run_listener
    [ -s "$ACK_LOG" ]
    grep -q "📱受信:" "$ACK_LOG"
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-002: Outbound message does NOT trigger ACK (loop prevention)
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-002: Outbound message does NOT trigger ACK (loop prevention)" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"msg002","time":1234567890,"message":"📱受信: echo","tags":["outbound"]}
JSON
    run_listener
    [ ! -s "$ACK_LOG" ]
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-003: ACK format is '📱受信: {original message}'
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-003: ACK format is '📱受信: {original message}'" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"msg003","time":1234567890,"message":"テスト通知です","tags":[]}
JSON
    run_listener
    grep -qF "📱受信: テスト通知です" "$ACK_LOG"
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-004: ACK failure does not block inbox_write
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-004: ACK failure does not block inbox_write" {
    export MOCK_NTFY_EXIT_CODE=1
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"msg004","time":1234567890,"message":"test msg","tags":[]}
JSON
    run_listener
    [ -s "$INBOX_LOG" ]
    grep -q "king" "$INBOX_LOG"
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-005: Empty message skips ACK
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-005: Empty message skips ACK" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"msg005","time":1234567890,"message":"","tags":[]}
JSON
    run_listener
    [ ! -s "$ACK_LOG" ]
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-006: Non-message event (keepalive) skips ACK
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-006: Non-message event (keepalive) skips ACK" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"keepalive","id":"","time":1234567890,"message":""}
JSON
    run_listener
    [ ! -s "$ACK_LOG" ]
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-007: append_ntfy_inbox failure skips both ACK and inbox_write
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-007: append_ntfy_inbox failure skips both ACK and inbox_write" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"msg007","time":1234567890,"message":"should not ack","tags":[]}
JSON
    # Make queue directory read-only to force mkstemp/flock failure
    chmod 555 "$MOCK_PROJECT/queue"
    run_listener
    # Both ACK and inbox_write should be skipped (L159 continue)
    [ ! -s "$ACK_LOG" ]
    [ ! -s "$INBOX_LOG" ]
    # Restore for teardown
    chmod 755 "$MOCK_PROJECT/queue"
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-008: Special characters in message preserved in ACK
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-008: Special characters in message preserved in ACK" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"msg008","time":1234567890,"message":"こんにちは 'world' & <test>","tags":[]}
JSON
    run_listener
    grep -qF "📱受信: こんにちは 'world' & <test>" "$ACK_LOG"
}
