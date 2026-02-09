#!/usr/bin/env bash
set -euo pipefail

# claude-batch-toolkit uninstaller
# Removes toolkit files but preserves results

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[info]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ok]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC}  $*"; }

CLAUDE_DIR="$HOME/.claude"
BATCHES_DIR="$CLAUDE_DIR/batches"

echo ""
echo -e "${BOLD}claude-batch-toolkit uninstaller${NC}"
echo "─────────────────────────────────"
echo ""

# ─── Remove MCP server registration from ~/.claude.json ────────────────────────
CLAUDE_JSON="$HOME/.claude.json"
if [[ -f "$CLAUDE_JSON" ]]; then
    if jq -e '.mcpServers["claude-batch"]' "$CLAUDE_JSON" &>/dev/null; then
        UPDATED=$(jq 'del(.mcpServers["claude-batch"])' "$CLAUDE_JSON")
        # If mcpServers is now empty, optionally remove it
        if echo "$UPDATED" | jq -e '.mcpServers == {}' &>/dev/null; then
            UPDATED=$(echo "$UPDATED" | jq 'del(.mcpServers)')
        fi
        echo "$UPDATED" | jq '.' > "$CLAUDE_JSON"
        ok "Removed claude-batch from ~/.claude.json"
    else
        info "claude-batch not found in ~/.claude.json (already removed)"
    fi
else
    info "~/.claude.json not found"
fi

# ─── Remove statusLine from settings.json ───────────────────────────────────────
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
if [[ -f "$SETTINGS_FILE" ]]; then
    CURRENT_CMD=$(jq -r '.statusLine // ""' "$SETTINGS_FILE")
    if [[ "$CURRENT_CMD" == *"statusline.sh"* ]]; then
        UPDATED=$(jq 'del(.statusLine)' "$SETTINGS_FILE")
        echo "$UPDATED" | jq '.' > "$SETTINGS_FILE"
        ok "Removed statusLine from settings.json"
    else
        info "statusLine not set to our script (leaving as-is)"
    fi
else
    info "settings.json not found"
fi

# ─── Remove ANTHROPIC_API_KEY from env file ─────────────────────────────────────
ENV_FILE="$CLAUDE_DIR/env"
if [[ -f "$ENV_FILE" ]]; then
    if grep -q 'ANTHROPIC_API_KEY' "$ENV_FILE"; then
        grep -v '^export ANTHROPIC_API_KEY=' "$ENV_FILE" > "$ENV_FILE.tmp" 2>/dev/null || true
        if [[ -s "$ENV_FILE.tmp" ]]; then
            mv "$ENV_FILE.tmp" "$ENV_FILE"
            info "Removed ANTHROPIC_API_KEY from ~/.claude/env (other vars preserved)"
        else
            rm -f "$ENV_FILE.tmp" "$ENV_FILE"
            ok "Removed ~/.claude/env (was only our key)"
        fi
    else
        info "ANTHROPIC_API_KEY not found in ~/.claude/env"
    fi
fi

# ─── Remove toolkit files ──────────────────────────────────────────────────────
REMOVED=0

if [[ -f "$CLAUDE_DIR/mcp/claude_batch_mcp.py" ]]; then
    rm -f "$CLAUDE_DIR/mcp/claude_batch_mcp.py"
    ok "Removed mcp/claude_batch_mcp.py"
    REMOVED=$((REMOVED + 1))
    # Remove mcp dir if empty
    rmdir "$CLAUDE_DIR/mcp" 2>/dev/null && info "Removed empty mcp/ directory" || true
fi

if [[ -f "$CLAUDE_DIR/skills/batch/SKILL.md" ]]; then
    rm -f "$CLAUDE_DIR/skills/batch/SKILL.md"
    ok "Removed skills/batch/SKILL.md"
    REMOVED=$((REMOVED + 1))
    # Remove skill dirs if empty
    rmdir "$CLAUDE_DIR/skills/batch" 2>/dev/null || true
    rmdir "$CLAUDE_DIR/skills" 2>/dev/null || true
fi

if [[ -f "$CLAUDE_DIR/statusline.sh" ]]; then
    rm -f "$CLAUDE_DIR/statusline.sh"
    ok "Removed statusline.sh"
    REMOVED=$((REMOVED + 1))
fi

# ─── Remove poll cache and lock files ──────────────────────────────────────────
rm -f "$BATCHES_DIR/.poll_cache" 2>/dev/null && info "Removed poll cache" || true
rm -f "$BATCHES_DIR/.poll.lock" 2>/dev/null && info "Removed poll lock" || true

# ─── Preserve results ──────────────────────────────────────────────────────────
RESULTS_DIR="$BATCHES_DIR/results"
if [[ -d "$RESULTS_DIR" ]]; then
    RESULT_COUNT=$(find "$RESULTS_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$RESULT_COUNT" -gt 0 ]]; then
        warn "Preserving $RESULT_COUNT result file(s) in $RESULTS_DIR"
        warn "To remove them manually: rm -rf $RESULTS_DIR"
    fi
fi

if [[ -f "$BATCHES_DIR/jobs.json" ]]; then
    warn "Preserving jobs.json in $BATCHES_DIR"
    warn "To remove it manually: rm -f $BATCHES_DIR/jobs.json"
fi

# ─── Done ───────────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────"
if [[ "$REMOVED" -gt 0 ]]; then
    echo -e "${GREEN}${BOLD}Uninstall complete!${NC}"
else
    echo -e "${YELLOW}${BOLD}Nothing to uninstall (toolkit files not found).${NC}"
fi
echo ""
echo "Preserved:"
echo "  • Results:   $RESULTS_DIR"
echo "  • Jobs log:  $BATCHES_DIR/jobs.json"
echo ""
echo "To fully remove all data:"
echo "  rm -rf $BATCHES_DIR"
echo ""

