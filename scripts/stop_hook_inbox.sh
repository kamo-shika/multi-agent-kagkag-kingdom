#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# stop_hook_inbox.sh — Claude Code Stop Hook for inbox delivery
# ═══════════════════════════════════════════════════════════════
# When a Claude Code agent finishes its turn and is about to go idle,
# this hook checks the agent's inbox for unread messages.
# If unread messages exist, the hook BLOCKs the stop and feeds
# the message summary back as the reason — the agent processes it
# as its next action without any tmux send-keys interruption.
#
# This eliminates the "思考中にinboxをぶちこまれると思考が止まる" problem
# for Claude Code agents (minister, priest).
#
# Usage: Registered as a Stop hook in .claude/settings.json
#   The hook receives JSON on stdin; outputs JSON to stdout.
#
# Environment:
#   TMUX_PANE — used to identify which agent is running
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ─── Read stdin (hook input JSON) ───
INPUT=$(cat)

# ─── Infinite loop prevention ───
# When stop_hook_active=true, the agent is already continuing from a
# previous Stop hook block. Allow it to stop this time to prevent loops.
STOP_HOOK_ACTIVE=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stop_hook_active', False))" 2>/dev/null || echo "False")
if [ "$STOP_HOOK_ACTIVE" = "True" ]; then
    exit 0
fi

# ─── Identify agent ───
AGENT_ID=""
if [ -n "${TMUX_PANE:-}" ]; then
    AGENT_ID=$(tmux display-message -t "$TMUX_PANE" -p '#{@agent_id}' 2>/dev/null || true)
fi

# If we can't identify the agent, approve (exit 0 with no output = approve)
if [ -z "$AGENT_ID" ]; then
    exit 0
fi

# ─── King: always approve (human-controlled) ───
if [ "$AGENT_ID" = "king" ]; then
    exit 0
fi

# ─── Check inbox for unread messages ───
INBOX="$SCRIPT_DIR/queue/inbox/${AGENT_ID}.yaml"

if [ ! -f "$INBOX" ]; then
    exit 0
fi

# Count unread messages using grep (fast, no python dependency)
UNREAD_COUNT=$(grep -c 'read: false' "$INBOX" 2>/dev/null || true)

if [ "${UNREAD_COUNT:-0}" -eq 0 ]; then
    exit 0
fi

# ─── Extract unread message summaries ───
SUMMARY=$(python3 -c "
import yaml, sys, json
try:
    with open('$INBOX', 'r') as f:
        data = yaml.safe_load(f)
    msgs = data.get('messages', []) if data else []
    unread = [m for m in msgs if not m.get('read', True)]
    parts = []
    for m in unread[:5]:  # Max 5 messages in summary
        frm = m.get('from', '?')
        typ = m.get('type', '?')
        content = str(m.get('content', ''))[:80]
        parts.append(f'[{frm}/{typ}] {content}')
    print(' | '.join(parts))
except Exception as e:
    print(f'inbox parse error: {e}')
" 2>/dev/null || echo "inbox未読${UNREAD_COUNT}件あり")

# ─── Block the stop — feed inbox info back to agent ───
python3 -c "
import json
count = $UNREAD_COUNT
summary = '''$SUMMARY'''
reason = f'inbox未読{count}件あり。queue/inbox/${AGENT_ID}.yamlを読んで処理せよ。内容: {summary}'
print(json.dumps({'decision': 'block', 'reason': reason}))
" 2>/dev/null || echo "{\"decision\":\"block\",\"reason\":\"inbox未読${UNREAD_COUNT}件あり。queue/inbox/${AGENT_ID}.yamlを読んで処理せよ。\"}"
