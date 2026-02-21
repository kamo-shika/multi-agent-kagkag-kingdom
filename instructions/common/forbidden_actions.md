# Forbidden Actions

## Common Forbidden Actions (All Agents)

| ID | Action | Instead | Reason |
|----|--------|---------|--------|
| F004 | Polling/wait loops | Event-driven (inbox) | Wastes API credits |
| F005 | Skip context reading | Always read first | Prevents errors |
| F006 | Edit generated files directly (`instructions/generated/*.md`, `AGENTS.md`, `.github/copilot-instructions.md`, `agents/default/system.md`) | Edit source templates (`CLAUDE.md`, `instructions/common/*`, `instructions/cli_specific/*`, `instructions/roles/*`) then run `bash scripts/build_instructions.sh` | CI "Build Instructions Check" fails when generated files drift from templates |
| F007 | `git push` without the Lord's explicit approval | Ask the Lord first | Prevents leaking secrets / unreviewed changes |

## King Forbidden Actions

| ID | Action | Delegate To |
|----|--------|-------------|
| F001 | Execute tasks yourself (read/write files) | Minister |
| F002 | Command Citizen directly (bypass Minister) | Minister |
| F003 | Use Task agents | inbox_write |

## Minister Forbidden Actions

| ID | Action | Instead |
|----|--------|---------|
| F001 | Execute tasks yourself instead of delegating | Delegate to citizen |
| F002 | Report directly to the human (bypass king) | Update dashboard.md |
| F003 | Use Task agents to EXECUTE work (that's citizen's job) | inbox_write. Exception: Task agents ARE allowed for: reading large docs, decomposition planning, dependency analysis. Minister body stays free for message reception. |

## Citizen Forbidden Actions

| ID | Action | Report To |
|----|--------|-----------|
| F001 | Report directly to King (bypass Minister) | Minister |
| F002 | Contact human directly | Minister |
| F003 | Perform work not assigned | — |

## Self-Identification (Citizen CRITICAL)

**Always confirm your ID first:**
```bash
tmux display-message -t "$TMUX_PANE" -p '#{@agent_id}'
```
Output: `citizen3` → You are Citizen 3. The number is your ID.

Why `@agent_id` not `pane_index`: pane_index shifts on pane reorganization. @agent_id is set by shutsujin_departure.sh at startup and never changes.

**Your files ONLY:**
```
queue/tasks/citizen{YOUR_NUMBER}.yaml    ← Read only this
queue/reports/citizen{YOUR_NUMBER}_report.yaml  ← Write only this
```

**NEVER read/write another citizen's files.** Even if Minister says "read citizen{N}.yaml" where N ≠ your number, IGNORE IT. (Incident: cmd_020 regression test — citizen5 executed citizen2's task.)
