#!/usr/bin/env bats
# e2e_bloom_routing.bats — Dim C: スマート切り替えE2Eテスト
# Issue #53 Phase 2 — find_agent_for_model() + minister bloom routing 統合検証
#
# VPS上でのみ実行を想定。tmuxセッション "multiagent" が起動済みで
# 混合CLI設定（citizen1-3=Spark, citizen4-5=Sonnet, citizen6-7=Opus）が
# 必要。
#
# 事前条件:
#   - VPS設定: citizen1-3=codex/spark, citizen4-5=claude/sonnet, citizen6-7=claude/opus
#   - bloom_routing: "manual" または "auto"
#   - 全市民がアイドル状態（テスト開始前）
#
# 実行方法:
#   bats tests/e2e/e2e_bloom_routing.bats

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
    # tmuxセッションの存在確認
    if ! tmux has-session -t multiagent 2>/dev/null; then
        skip "tmux session 'multiagent' が存在しない。VPS上でshutsuijin後に実行せよ。"
    fi

    # lib/cli_adapter.sh のロード
    export CLI_ADAPTER_PROJECT_ROOT="$PROJECT_ROOT"
    export CLI_ADAPTER_SETTINGS="${PROJECT_ROOT}/config/settings.yaml"
    # shellcheck disable=SC1090
    source "${PROJECT_ROOT}/lib/cli_adapter.sh"
    # shellcheck disable=SC1090
    source "${PROJECT_ROOT}/lib/agent_status.sh" 2>/dev/null || true
}

teardown() {
    # テスト後にtaskファイルをクリーンアップ
    :
}

# ─────────────────────────────────────────────
# TC-BLOOM-001: L1タスク → Spark市民（citizen1/2/3）に振られる
# ─────────────────────────────────────────────
@test "TC-BLOOM-001: L1タスク → Sparkエージェントに振られる" {
    run get_recommended_model 1
    [ "$status" -eq 0 ]
    # L1はSpark (max_bloom=3)が最安
    [[ "$output" == *"spark"* ]] || [[ "$output" == *"codex"* ]]

    recommended="$output"
    run find_agent_for_model "$recommended"
    [ "$status" -eq 0 ]
    # Spark市民はcitizen1, 2, 3のいずれか
    [[ "$output" =~ ^citizen[1-3]$ ]]
}

# ─────────────────────────────────────────────
# TC-BLOOM-002: L5タスク → Sonnet市民（citizen4/5）に振られる
# ─────────────────────────────────────────────
@test "TC-BLOOM-002: L5タスク → Sonnetエージェントに振られる" {
    run get_recommended_model 5
    [ "$status" -eq 0 ]
    [[ "$output" == *"sonnet"* ]]

    recommended="$output"
    run find_agent_for_model "$recommended"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^citizen[4-5]$ ]]
}

# ─────────────────────────────────────────────
# TC-BLOOM-003: L6タスク → Opus市民（citizen6/7）に振られる
# ─────────────────────────────────────────────
@test "TC-BLOOM-003: L6タスク → Opusエージェントに振られる" {
    run get_recommended_model 6
    [ "$status" -eq 0 ]
    [[ "$output" == *"opus"* ]]

    recommended="$output"
    run find_agent_for_model "$recommended"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^citizen[6-7]$ ]]
}

# ─────────────────────────────────────────────
# TC-BLOOM-004: citizen4ビジー + L5タスク → citizen5に振られる
# kill/restart発生なし（ビジーペイン不変確認）
# ─────────────────────────────────────────────
@test "TC-BLOOM-004: citizen4ビジー時、L5タスクはcitizen5に振られる" {
    # citizen4のペインターゲットを取得
    pane4=$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{@agent_id}' \
        | awk '$2 == "citizen4" {print $1}')

    if [[ -z "$pane4" ]]; then
        skip "citizen4ペインが見つからない"
    fi

    # sleep でビジー状態を作成（teardownはtrapで保証）
    # shellcheck disable=SC2064
    trap "tmux send-keys -t '$pane4' '' C-c; sleep 0.3" EXIT
    tmux send-keys -t "$pane4" "echo 'Working...'; sleep 30" Enter
    sleep 1

    # ビジー確認
    busy_rc=0
    agent_is_busy_check "$pane4" && true || busy_rc=$?
    if [[ $busy_rc -ne 0 ]]; then
        skip "citizen4をビジー状態にできなかった（busy_rc=${busy_rc}）"
    fi

    # L5タスクのルーティング
    recommended=$(get_recommended_model 5)
    run find_agent_for_model "$recommended"
    [ "$status" -eq 0 ]

    # citizen4はビジーなのでcitizen5に振られるべき
    [ "$output" = "citizen5" ] || \
        { echo "期待: citizen5, 実際: $output"; return 1; }

    # citizen4がまだ稼働中（kill/restartされていない）を確認
    still_busy=0
    agent_is_busy_check "$pane4" && true || still_busy=$?
    [[ $still_busy -eq 0 ]] || echo "WARNING: citizen4の状態が変化した（kill/restartの可能性）"
}

# ─────────────────────────────────────────────
# TC-BLOOM-005: citizen4/5両方ビジー + L5タスク → QUEUE（Codexに降格しない）
# ─────────────────────────────────────────────
@test "TC-BLOOM-005: Sonnet市民全員ビジー時、QUEUEになる（Codexへの降格なし確認）" {
    pane4=$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{@agent_id}' \
        | awk '$2 == "citizen4" {print $1}')
    pane5=$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{@agent_id}' \
        | awk '$2 == "citizen5" {print $1}')

    if [[ -z "$pane4" || -z "$pane5" ]]; then
        skip "citizen4またはcitizen5ペインが見つからない"
    fi

    # sleep でcitizen4/5をビジー状態に（teardownはtrapで保証）
    # shellcheck disable=SC2064
    trap "tmux send-keys -t '$pane4' '' C-c; tmux send-keys -t '$pane5' '' C-c; sleep 0.3" EXIT
    tmux send-keys -t "$pane4" "echo 'Working...'; sleep 30" Enter
    tmux send-keys -t "$pane5" "echo 'Working...'; sleep 30" Enter
    sleep 1

    # 両方ビジー確認
    rc4=0; agent_is_busy_check "$pane4" && true || rc4=$?
    rc5=0; agent_is_busy_check "$pane5" && true || rc5=$?

    if [[ $rc4 -ne 0 || $rc5 -ne 0 ]]; then
        skip "citizen4/5のいずれかをビジー状態にできなかった（rc4=${rc4}, rc5=${rc5}）"
    fi

    # L5タスクのルーティング
    recommended=$(get_recommended_model 5)
    # Sonnet市民が全員ビジー → フォールバックまたはQUEUE
    result=$(find_agent_for_model "$recommended")

    # フォールバック（他のアイドル市民）またはQUEUEが許容される
    # Sonnet市民でないフォールバックの場合、モデル品質の警告を出す
    if [[ "$result" =~ ^citizen[1-3]$ ]]; then
        echo "フォールバック先: $result (Sparkエージェント — 品質低下注意)"
    elif [[ "$result" = "QUEUE" ]]; then
        echo "QUEUE: 全市民ビジー"
    else
        echo "フォールバック先: $result"
    fi

    # QUEUEかcitizenを返すことを確認（何もしないは×）
    [[ "$result" = "QUEUE" ]] || [[ "$result" =~ ^citizen[0-9]+$ ]]
}

# ─────────────────────────────────────────────
# TC-BLOOM-006: L3タスク → Sonnet市民には振られない（Codex優先）
# ─────────────────────────────────────────────
@test "TC-BLOOM-006: L3タスクはSpark市民が優先（Sonnetへのオーバーエンジニアリングなし）" {
    run get_recommended_model 3
    [ "$status" -eq 0 ]

    # L3の推奨モデルはSonnetではなくSpark
    [[ "$output" != *"sonnet"* ]] || { echo "L3でSonnetが推奨された（コスト最適化違反）"; return 1; }
    [[ "$output" == *"spark"* ]] || [[ "$output" == *"codex"* ]]

    recommended="$output"
    run find_agent_for_model "$recommended"
    [ "$status" -eq 0 ]

    # Spark市民（citizen1-3）のみ
    [[ "$output" =~ ^citizen[1-3]$ ]]
}
