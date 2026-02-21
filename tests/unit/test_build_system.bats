#!/usr/bin/env bats
# test_build_system.bats — ビルドシステム（build_instructions.sh）ユニットテスト
# Phase 2+3 品質テスト基盤
#
# テスト構成:
#   - ビルド実行テスト: スクリプト正常終了、ディレクトリ生成
#   - ファイル生成テスト: claude/codex/copilot各ロールの生成確認
#   - 内容検証テスト: 空でないこと、ロール名・CLI固有セクション含有
#   - AGENTS.md / copilot-instructions.md 生成テスト
#   - 冪等性テスト: 2回ビルドで差分なし
#
# Phase 2+3未実装テストについて:
#   copilot生成、AGENTS.md、copilot-instructions.md のテストは
#   build_instructions.shが拡張されるまでFAILする（受入基準）。
#   SKIP は使用しない（SKIP=0ルール遵守）。

# --- セットアップ ---

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export BUILD_SCRIPT="$PROJECT_ROOT/scripts/build_instructions.sh"
    export OUTPUT_DIR="$PROJECT_ROOT/instructions/generated"

    # パーツディレクトリの存在確認（前提条件）
    [ -d "$PROJECT_ROOT/instructions/roles" ] || return 1
    [ -d "$PROJECT_ROOT/instructions/common" ] || return 1
    [ -d "$PROJECT_ROOT/instructions/cli_specific" ] || return 1

    # ビルド実行（全テストの前に1回のみ）
    bash "$BUILD_SCRIPT" > /dev/null 2>&1 || true
}

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    BUILD_SCRIPT="$PROJECT_ROOT/scripts/build_instructions.sh"
    OUTPUT_DIR="$PROJECT_ROOT/instructions/generated"
}

# =============================================================================
# ビルド実行テスト
# =============================================================================

@test "build: build_instructions.sh exits with status 0" {
    run bash "$BUILD_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "build: generated/ directory exists after build" {
    [ -d "$OUTPUT_DIR" ]
}

@test "build: generated/ contains at least 6 files" {
    local count
    count=$(find "$OUTPUT_DIR" -name "*.md" -type f | wc -l)
    [ "$count" -ge 6 ]
}

# =============================================================================
# ファイル生成テスト — Claude
# =============================================================================

@test "claude: king.md generated" {
    [ -f "$OUTPUT_DIR/king.md" ]
}

@test "claude: minister.md generated" {
    [ -f "$OUTPUT_DIR/minister.md" ]
}

@test "claude: citizen.md generated" {
    [ -f "$OUTPUT_DIR/citizen.md" ]
}

# =============================================================================
# ファイル生成テスト — Codex
# =============================================================================

@test "codex: codex-king.md generated" {
    [ -f "$OUTPUT_DIR/codex-king.md" ]
}

@test "codex: codex-minister.md generated" {
    [ -f "$OUTPUT_DIR/codex-minister.md" ]
}

@test "codex: codex-citizen.md generated" {
    [ -f "$OUTPUT_DIR/codex-citizen.md" ]
}

# =============================================================================
# ファイル生成テスト — Copilot (Phase 2+3 受入基準)
# =============================================================================

@test "copilot: copilot-king.md generated [Phase 2+3]" {
    [ -f "$OUTPUT_DIR/copilot-king.md" ]
}

@test "copilot: copilot-minister.md generated [Phase 2+3]" {
    [ -f "$OUTPUT_DIR/copilot-minister.md" ]
}

@test "copilot: copilot-citizen.md generated [Phase 2+3]" {
    [ -f "$OUTPUT_DIR/copilot-citizen.md" ]
}

# =============================================================================
# 内容検証テスト — 空でないこと
# =============================================================================

@test "content: king.md is not empty" {
    [ -s "$OUTPUT_DIR/king.md" ]
}

@test "content: minister.md is not empty" {
    [ -s "$OUTPUT_DIR/minister.md" ]
}

@test "content: citizen.md is not empty" {
    [ -s "$OUTPUT_DIR/citizen.md" ]
}

@test "content: codex-king.md is not empty" {
    [ -s "$OUTPUT_DIR/codex-king.md" ]
}

@test "content: codex-minister.md is not empty" {
    [ -s "$OUTPUT_DIR/codex-minister.md" ]
}

@test "content: codex-citizen.md is not empty" {
    [ -s "$OUTPUT_DIR/codex-citizen.md" ]
}

# =============================================================================
# 内容検証テスト — ロール名含有
# =============================================================================

@test "content: king.md contains king role reference" {
    grep -qi "king\|キング" "$OUTPUT_DIR/king.md"
}

@test "content: minister.md contains minister role reference" {
    grep -qi "minister\|大臣" "$OUTPUT_DIR/minister.md"
}

@test "content: citizen.md contains citizen role reference" {
    grep -qi "citizen\|市民" "$OUTPUT_DIR/citizen.md"
}

@test "content: codex-king.md contains king role reference" {
    grep -qi "king\|キング" "$OUTPUT_DIR/codex-king.md"
}

@test "content: codex-minister.md contains minister role reference" {
    grep -qi "minister\|大臣" "$OUTPUT_DIR/codex-minister.md"
}

@test "content: codex-citizen.md contains citizen role reference" {
    grep -qi "citizen\|市民" "$OUTPUT_DIR/codex-citizen.md"
}

# =============================================================================
# 内容検証テスト — CLI固有セクション
# =============================================================================

@test "content: claude files contain Claude-specific tools" {
    # Claude Code固有ツール: Read, Write, Edit, Bash等
    grep -qi "claude\|Read\|Write\|Edit\|Bash" "$OUTPUT_DIR/king.md"
}

@test "content: codex files contain Codex-specific content" {
    grep -qi "codex\|AGENTS.md\|Codex" "$OUTPUT_DIR/codex-king.md"
}

@test "content: copilot files contain Copilot-specific content [Phase 2+3]" {
    grep -qi "copilot\|Copilot" "$OUTPUT_DIR/copilot-king.md"
}

# =============================================================================
# AGENTS.md 生成テスト (Phase 2+3 受入基準)
# =============================================================================

@test "agents: AGENTS.md generated [Phase 2+3]" {
    [ -f "$PROJECT_ROOT/AGENTS.md" ]
}

@test "agents: AGENTS.md contains Codex-specific content [Phase 2+3]" {
    [ -f "$PROJECT_ROOT/AGENTS.md" ] && grep -qi "codex\|agent" "$PROJECT_ROOT/AGENTS.md"
}

# =============================================================================
# copilot-instructions.md 生成テスト (Phase 2+3 受入基準)
# =============================================================================

@test "copilot-inst: .github/copilot-instructions.md generated [Phase 2+3]" {
    [ -f "$PROJECT_ROOT/.github/copilot-instructions.md" ]
}

@test "copilot-inst: contains Copilot-specific content [Phase 2+3]" {
    [ -f "$PROJECT_ROOT/.github/copilot-instructions.md" ] && \
        grep -qi "copilot" "$PROJECT_ROOT/.github/copilot-instructions.md"
}

# =============================================================================
# 冪等性テスト
# =============================================================================

@test "idempotent: second build produces identical output" {
    # 1st build
    bash "$BUILD_SCRIPT" > /dev/null 2>&1
    local checksums_first
    checksums_first=$(find "$OUTPUT_DIR" -name "*.md" -type f -exec md5sum {} \; | sort)

    # 2nd build
    bash "$BUILD_SCRIPT" > /dev/null 2>&1
    local checksums_second
    checksums_second=$(find "$OUTPUT_DIR" -name "*.md" -type f -exec md5sum {} \; | sort)

    [ "$checksums_first" = "$checksums_second" ]
}
