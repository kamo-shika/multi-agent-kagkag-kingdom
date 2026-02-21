#!/usr/bin/env bash
# scripts/ratelimit_check.sh — CLI Rate Limit Monitor
# CLI種別ごとに重複排除し、共有クォータの消費状況を統合表示する。
#
# Usage:
#   bash scripts/ratelimit_check.sh              # 日本語出力
#   bash scripts/ratelimit_check.sh --lang en    # English output
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ─── Defaults ───
LANG_MODE="ja"

# ─── Parse args ───
while [[ $# -gt 0 ]]; do
    case "$1" in
        --lang)  LANG_MODE="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: ratelimit_check.sh [--lang en|ja]"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Load shared libraries ───
source "$SCRIPT_DIR/lib/agent_status.sh"
source "$SCRIPT_DIR/lib/cli_adapter.sh"

PYTHON="${SCRIPT_DIR}/.venv/bin/python3"

# ─── Constants ───
CLAUDE_STATS="$HOME/.claude/stats-cache.json"
CODEX_LOG="$HOME/.codex/log/codex-tui.log"
TODAY=$(date +%Y-%m-%d)

# Warning thresholds
CODEX_CONTEXT_WARN=20
CODEX_CONTEXT_CRIT=10
CODEX_LIMIT_HITS_WARN=3

# ─── Agent list (dynamic from settings.yaml) ───
_citizen_ids_str=$(get_citizen_ids 2>/dev/null || echo "citizen1 citizen2 citizen3 citizen4 citizen5 citizen6 citizen7")
ALL_AGENTS=("king" "minister")
for _aid in $_citizen_ids_str; do ALL_AGENTS+=("$_aid"); done
ALL_AGENTS+=("priest")

# ═══════════════════════════════════════════════════════
# Phase 1: Scan all tmux panes for metadata
# ═══════════════════════════════════════════════════════
declare -A AGENT_CLI AGENT_MODEL AGENT_PANE

for agent in "${ALL_AGENTS[@]}"; do
    # Determine pane target using @agent_id tmux option (dynamic, no hardcoded pane indices)
    if [[ "$agent" == "king" ]]; then
        pane_target="king:main"
    else
        pane_target=$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{@agent_id}' 2>/dev/null \
            | awk -v a="$agent" '$2 == a {print $1}' | head -1)
    fi

    # Read pane metadata (fallback to cli_adapter)
    cli=$(timeout 2 tmux display-message -t "$pane_target" -p '#{@agent_cli}' 2>/dev/null || echo "")
    if [[ -z "$cli" ]]; then
        cli=$(get_cli_type "$agent" 2>/dev/null || echo "?")
    fi

    model=$(timeout 2 tmux display-message -t "$pane_target" -p '#{@model_name}' 2>/dev/null || echo "")
    if [[ -z "$model" ]]; then
        model=$(get_agent_model "$agent" 2>/dev/null || echo "?")
    fi
    # Shorten long model names for display (e.g., "Claude-sonnet-4-5-20250929" → "sonnet")
    model=$(echo "$model" | sed -E 's/[Cc]laude-?//g; s/-20[0-9]{6}//g; s/-[0-9]+-[0-9]+$//; s/^-//')

    AGENT_CLI["$agent"]="$cli"
    AGENT_MODEL["$agent"]="$model"
    AGENT_PANE["$agent"]="$pane_target"
done

# ═══════════════════════════════════════════════════════
# Phase 2: Group agents by CLI type
# ═══════════════════════════════════════════════════════
declare -a CLAUDE_AGENTS=() CODEX_AGENTS=() OTHER_AGENTS=()

for agent in "${ALL_AGENTS[@]}"; do
    case "${AGENT_CLI[$agent]}" in
        claude) CLAUDE_AGENTS+=("$agent") ;;
        codex)  CODEX_AGENTS+=("$agent") ;;
        *)      OTHER_AGENTS+=("$agent") ;;
    esac
done

# ═══════════════════════════════════════════════════════
# Phase 3: Collect data per CLI group
# ═══════════════════════════════════════════════════════

# --- 3a: Claude OAuth usage API + stats-cache ---
CLAUDE_5H_UTIL=""
CLAUDE_5H_RESET=""
CLAUDE_7D_UTIL=""
CLAUDE_7D_RESET=""
CLAUDE_7D_SONNET_UTIL=""
CLAUDE_7D_OPUS_UTIL=""
CLAUDE_EXTRA_ENABLED="false"
CLAUDE_STATUS="OK"

# OAuth usage API (primary source — real subscription rate limits)
CLAUDE_CREDS="$HOME/.claude/.credentials.json"
if [[ ${#CLAUDE_AGENTS[@]} -gt 0 ]] && [[ -f "$CLAUDE_CREDS" ]] && [[ -x "$PYTHON" ]]; then
    oauth_data=$("$PYTHON" -c "
import json, subprocess, sys

with open('${CLAUDE_CREDS}') as f:
    creds = json.load(f)
token = creds.get('claudeAiOauth', {}).get('accessToken', '')
if not token:
    sys.exit(1)

result = subprocess.run([
    'curl', '-s', '-m', '10',
    '-H', f'Authorization: Bearer {token}',
    '-H', 'Accept: application/json',
    '-H', 'anthropic-beta: oauth-2025-04-20',
    'https://api.anthropic.com/api/oauth/usage'
], capture_output=True, text=True)

data = json.loads(result.stdout)

fh = data.get('five_hour') or {}
sd = data.get('seven_day') or {}
ss = data.get('seven_day_sonnet') or {}
so = data.get('seven_day_opus') or {}
ex = data.get('extra_usage') or {}

print(f'5H_UTIL={fh.get(\"utilization\", \"?\")}')
print(f'5H_RESET={fh.get(\"resets_at\", \"?\")[:16]}')
print(f'7D_UTIL={sd.get(\"utilization\", \"?\")}')
print(f'7D_RESET={sd.get(\"resets_at\", \"?\")[:10]}')
print(f'7D_SONNET={ss.get(\"utilization\", \"-\")}')
print(f'7D_OPUS={so.get(\"utilization\", \"-\")}')
print(f'EXTRA={ex.get(\"is_enabled\", False)}')
" 2>/dev/null) || oauth_data=""

    if [[ -n "$oauth_data" ]]; then
        CLAUDE_5H_UTIL=$(echo "$oauth_data" | grep '^5H_UTIL=' | cut -d= -f2)
        CLAUDE_5H_RESET=$(echo "$oauth_data" | grep '^5H_RESET=' | cut -d= -f2)
        CLAUDE_7D_UTIL=$(echo "$oauth_data" | grep '^7D_UTIL=' | cut -d= -f2)
        CLAUDE_7D_RESET=$(echo "$oauth_data" | grep '^7D_RESET=' | cut -d= -f2)
        CLAUDE_7D_SONNET_UTIL=$(echo "$oauth_data" | grep '^7D_SONNET=' | cut -d= -f2)
        CLAUDE_7D_OPUS_UTIL=$(echo "$oauth_data" | grep '^7D_OPUS=' | cut -d= -f2)
        CLAUDE_EXTRA_ENABLED=$(echo "$oauth_data" | grep '^EXTRA=' | cut -d= -f2)
    fi
fi

# Stats-cache (secondary source — token counts)
CLAUDE_TODAY_TOTAL=0
CLAUDE_TODAY_DETAIL=""
CLAUDE_DATA_DATE=""
CLAUDE_SESSIONS=""
CLAUDE_MESSAGES=""

if [[ ${#CLAUDE_AGENTS[@]} -gt 0 ]] && [[ -f "$CLAUDE_STATS" ]] && [[ -x "$PYTHON" ]]; then
    claude_data=$("$PYTHON" -c "
import json
with open('${CLAUDE_STATS}') as f:
    data = json.load(f)
today = '${TODAY}'
all_token_entries = data.get('dailyModelTokens', [])
target_tokens = {}
target_date = today
for entry in all_token_entries:
    if entry['date'] == today:
        target_tokens = entry.get('tokensByModel', {})
        target_date = today
        break
else:
    if all_token_entries:
        latest = all_token_entries[-1]
        target_tokens = latest.get('tokensByModel', {})
        target_date = latest['date']
total_today = sum(target_tokens.values())
short = {}
for k, v in target_tokens.items():
    name = k.replace('claude-', '')
    for prefix in ('opus-4-6', 'opus-4-5', 'sonnet-4-5', 'haiku-4-5'):
        if name.startswith(prefix):
            name = prefix.split('-')[0]
            break
    short[name] = v
all_activity = data.get('dailyActivity', [])
target_activity = {}
for entry in all_activity:
    if entry['date'] == today:
        target_activity = entry
        break
else:
    if all_activity:
        target_activity = all_activity[-1]
sessions = target_activity.get('sessionCount', '?')
messages = target_activity.get('messageCount', '?')
print(f'TOTAL={total_today}')
print(f'DATE={target_date}')
for k, v in short.items():
    print(f'MODEL_{k}={v}')
print(f'SESSIONS={sessions}')
print(f'MESSAGES={messages}')
" 2>/dev/null) || claude_data=""

    if [[ -n "$claude_data" ]]; then
        CLAUDE_TODAY_TOTAL=$(echo "$claude_data" | grep '^TOTAL=' | cut -d= -f2)
        CLAUDE_DATA_DATE=$(echo "$claude_data" | grep '^DATE=' | cut -d= -f2)
        CLAUDE_SESSIONS=$(echo "$claude_data" | grep '^SESSIONS=' | cut -d= -f2)
        CLAUDE_MESSAGES=$(echo "$claude_data" | grep '^MESSAGES=' | cut -d= -f2)

        # Build model detail string
        CLAUDE_TODAY_DETAIL=""
        while IFS= read -r line; do
            model_name=$(echo "$line" | sed 's/^MODEL_//' | cut -d= -f1)
            model_val=$(echo "$line" | cut -d= -f2)
            if [[ -n "$CLAUDE_TODAY_DETAIL" ]]; then
                CLAUDE_TODAY_DETAIL="${CLAUDE_TODAY_DETAIL} | ${model_name}: $(printf "%'d" "$model_val")"
            else
                CLAUDE_TODAY_DETAIL="${model_name}: $(printf "%'d" "$model_val")"
            fi
        done < <(echo "$claude_data" | grep '^MODEL_')

        # Warning is now handled by OAuth utilization in Phase 4 display
    fi
fi

# --- 3b: Codex context from panes ---
declare -A CODEX_CONTEXT
CODEX_WARNINGS=""
CODEX_STATUS="OK"

if [[ ${#CODEX_AGENTS[@]} -gt 0 ]]; then
    for agent in "${CODEX_AGENTS[@]}"; do
        pane="${AGENT_PANE[$agent]}"
        ctx=$(tmux capture-pane -t "$pane" -p 2>/dev/null \
            | grep -oE '[0-9]+% context left' | tail -1 \
            | grep -oE '[0-9]+' || echo "?")
        [[ -z "$ctx" ]] && ctx="?"
        CODEX_CONTEXT["$agent"]="$ctx"

        # Check thresholds
        if [[ "$ctx" != "?" ]]; then
            if [[ "$ctx" -lt "$CODEX_CONTEXT_CRIT" ]]; then
                CODEX_WARNINGS="${CODEX_WARNINGS} ${agent}(${ctx}%)!!"
                CODEX_STATUS="CRITICAL"
            elif [[ "$ctx" -lt "$CODEX_CONTEXT_WARN" ]]; then
                CODEX_WARNINGS="${CODEX_WARNINGS} ${agent}(${ctx}%)!"
                if [[ "$CODEX_STATUS" != "CRITICAL" ]]; then
                    CODEX_STATUS="WARNING"
                fi
            fi
        fi
    done
fi

# --- 3c: Codex log — token_limit_reached in last hour ---
CODEX_LIMIT_HITS=0
if [[ ${#CODEX_AGENTS[@]} -gt 0 ]] && [[ -f "$CODEX_LOG" ]]; then
    current_hour=$(date -u +%Y-%m-%dT%H)
    CODEX_LIMIT_HITS=$(tail -5000 "$CODEX_LOG" 2>/dev/null \
        | grep "token_limit_reached=true" \
        | grep -c "$current_hour" || true)
    CODEX_LIMIT_HITS="${CODEX_LIMIT_HITS:-0}"
    # Sanitize: strip whitespace, ensure integer
    CODEX_LIMIT_HITS=$(echo "$CODEX_LIMIT_HITS" | tr -d '[:space:]')
    [[ "$CODEX_LIMIT_HITS" =~ ^[0-9]+$ ]] || CODEX_LIMIT_HITS=0

    if [[ "$CODEX_LIMIT_HITS" -ge "$CODEX_LIMIT_HITS_WARN" ]]; then
        if [[ "$CODEX_STATUS" == "OK" ]]; then
            CODEX_STATUS="WARNING"
        fi
        CODEX_WARNINGS="${CODEX_WARNINGS} limit_hits=${CODEX_LIMIT_HITS}/h"
    fi
fi

# ═══════════════════════════════════════════════════════
# Phase 4: Display
# ═══════════════════════════════════════════════════════

printf "\n"
if [[ "$LANG_MODE" == "en" ]]; then
    printf "══ Rate Limit Status (%s) ══\n" "$TODAY"
else
    printf "══ レートリミット状況 (%s) ══\n" "$TODAY"
fi

# --- Claude group ---
if [[ ${#CLAUDE_AGENTS[@]} -gt 0 ]]; then
    printf "\n── Claude Max ────────────────────────\n"

    # Agent list with models
    agent_list=""
    for agent in "${CLAUDE_AGENTS[@]}"; do
        model="${AGENT_MODEL[$agent]}"
        if [[ -n "$agent_list" ]]; then
            agent_list="${agent_list}, ${agent}(${model})"
        else
            agent_list="${agent}(${model})"
        fi
    done
    printf "  Agents: %s\n" "$agent_list"

    # OAuth rate limits (primary display)
    if [[ -n "$CLAUDE_5H_UTIL" && "$CLAUDE_5H_UTIL" != "?" ]]; then
        printf "  ── Quota ──\n"
        # 5-hour window
        fh_int=${CLAUDE_5H_UTIL%.*}
        if [[ "$fh_int" -ge 80 ]]; then
            printf "  5h window:  %s%% used ⚠️  (resets %s)\n" "$CLAUDE_5H_UTIL" "$CLAUDE_5H_RESET"
            CLAUDE_STATUS="WARNING (5h: ${CLAUDE_5H_UTIL}%)"
        else
            printf "  5h window:  %s%% used  (resets %s)\n" "$CLAUDE_5H_UTIL" "$CLAUDE_5H_RESET"
        fi
        # 7-day window
        sd_int=${CLAUDE_7D_UTIL%.*}
        if [[ "$sd_int" -ge 80 ]]; then
            printf "  7d window:  %s%% used ⚠️  (resets %s)\n" "$CLAUDE_7D_UTIL" "$CLAUDE_7D_RESET"
            CLAUDE_STATUS="WARNING (7d: ${CLAUDE_7D_UTIL}%)"
        else
            printf "  7d window:  %s%% used  (resets %s)\n" "$CLAUDE_7D_UTIL" "$CLAUDE_7D_RESET"
        fi
        # Per-model breakdown
        if [[ "$CLAUDE_7D_SONNET_UTIL" != "-" && -n "$CLAUDE_7D_SONNET_UTIL" ]]; then
            printf "    sonnet 7d: %s%%\n" "$CLAUDE_7D_SONNET_UTIL"
        fi
        if [[ "$CLAUDE_7D_OPUS_UTIL" != "-" && -n "$CLAUDE_7D_OPUS_UTIL" ]]; then
            printf "    opus 7d:   %s%%\n" "$CLAUDE_7D_OPUS_UTIL"
        fi
        # Extra usage
        if [[ "$CLAUDE_EXTRA_ENABLED" == "True" ]]; then
            printf "  Extra usage: ENABLED\n"
        fi
    fi

    # Token stats from stats-cache (secondary)
    if [[ "$CLAUDE_TODAY_TOTAL" -gt 0 ]]; then
        printf "  ── Tokens ──\n"
        if [[ "${CLAUDE_DATA_DATE:-$TODAY}" != "$TODAY" ]]; then
            printf "  Latest (%s): %'d tokens\n" "$CLAUDE_DATA_DATE" "$CLAUDE_TODAY_TOTAL"
        else
            printf "  Today: %'d tokens\n" "$CLAUDE_TODAY_TOTAL"
        fi
        if [[ -n "$CLAUDE_TODAY_DETAIL" ]]; then
            printf "    %s\n" "$CLAUDE_TODAY_DETAIL"
        fi
        printf "  Sessions: %s | Messages: %s\n" "$CLAUDE_SESSIONS" "$CLAUDE_MESSAGES"
    fi

    printf "  Status: %s\n" "$CLAUDE_STATUS"
fi

# --- Codex group ---
if [[ ${#CODEX_AGENTS[@]} -gt 0 ]]; then
    printf "\n── ChatGPT Pro ───────────────────────\n"

    # Shared model
    codex_model="${AGENT_MODEL[${CODEX_AGENTS[0]}]}"
    printf "  Agents: citizen1-%d (%s)\n" "${#CODEX_AGENTS[@]}" "$codex_model"

    # Context display
    if [[ "$LANG_MODE" == "en" ]]; then
        printf "  Context left:\n    "
    else
        printf "  コンテキスト残量:\n    "
    fi

    count=0
    for agent in "${CODEX_AGENTS[@]}"; do
        ctx="${CODEX_CONTEXT[$agent]}"
        num="${agent#citizen}"  # extract number
        # Add warning markers
        marker=""
        if [[ "$ctx" != "?" ]]; then
            if [[ "$ctx" -lt "$CODEX_CONTEXT_CRIT" ]]; then
                marker="!!"
            elif [[ "$ctx" -lt "$CODEX_CONTEXT_WARN" ]]; then
                marker="!"
            fi
        fi
        printf "%s:%s%%%s  " "$num" "$ctx" "$marker"
        count=$((count + 1))
        if [[ $((count % 4)) -eq 0 ]] && [[ $count -lt ${#CODEX_AGENTS[@]} ]]; then
            printf "\n    "
        fi
    done
    printf "\n"

    printf "  Limit hits (1h): %d\n" "$CODEX_LIMIT_HITS"

    if [[ "$CODEX_STATUS" != "OK" ]]; then
        printf "  Status: %s (%s)\n" "$CODEX_STATUS" "${CODEX_WARNINGS# }"
    else
        printf "  Status: OK\n"
    fi
fi

# --- Other CLIs ---
if [[ ${#OTHER_AGENTS[@]} -gt 0 ]]; then
    printf "\n── Other ─────────────────────────────\n"
    for agent in "${OTHER_AGENTS[@]}"; do
        cli="${AGENT_CLI[$agent]}"
        model="${AGENT_MODEL[$agent]}"
        printf "  %s: %s (%s) — no rate limit data\n" "$agent" "$cli" "$model"
    done
fi

printf "\n"
