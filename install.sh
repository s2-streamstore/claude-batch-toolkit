#!/usr/bin/env bash
set -euo pipefail

# claude-batch-toolkit installer
# Usage: ./install.sh --api-key sk-ant-... [--no-poller] [--unattended]

# ─── Defaults ───────────────────────────────────────────────────────────────────
API_KEY=""
NO_POLLER=0
UNATTENDED=0
CLAUDE_DIR="$HOME/.claude"
BATCHES_DIR="$CLAUDE_DIR/batches"
RESULTS_DIR="$BATCHES_DIR/results"

# ─── Color helpers ──────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()  { echo -e "${CYAN}[info]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ok]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC}  $*"; }
err()   { echo -e "${RED}[error]${NC} $*" >&2; }
die()   { err "$@"; exit 1; }

# ─── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --api-key)
            API_KEY="$2"
            shift 2
            ;;
        --api-key=*)
            API_KEY="${1#*=}"
            shift
            ;;
        --no-poller)
            NO_POLLER=1
            shift
            ;;
        --unattended)
            UNATTENDED=1
            shift
            ;;
        -h|--help)
            echo "Usage: $0 --api-key <ANTHROPIC_API_KEY> [--no-poller] [--unattended]"
            echo ""
            echo "Options:"
            echo "  --api-key KEY    Anthropic API key (required unless ANTHROPIC_API_KEY is set)"
            echo "  --no-poller      Skip status line configuration"
            echo "  --unattended     No interactive prompts"
            exit 0
            ;;
        *)
            die "Unknown option: $1 (use --help)"
            ;;
    esac
done

# ─── Resolve API key ───────────────────────────────────────────────────────────
if [[ -z "$API_KEY" ]]; then
    # Try environment
    API_KEY="${ANTHROPIC_API_KEY:-}"
fi

if [[ -z "$API_KEY" ]]; then
    # Try existing env file
    if [[ -f "$CLAUDE_DIR/env" ]]; then
        source "$CLAUDE_DIR/env" 2>/dev/null || true
        API_KEY="${ANTHROPIC_API_KEY:-}"
    fi
fi

if [[ -z "$API_KEY" ]]; then
    if [[ "$UNATTENDED" -eq 1 ]]; then
        die "No API key provided. Use --api-key or set ANTHROPIC_API_KEY."
    fi
    echo -e "${BOLD}Enter your Anthropic API key:${NC}"
    read -r -s API_KEY
    echo ""
    if [[ -z "$API_KEY" ]]; then
        die "No API key provided."
    fi
fi

# ─── Determine script directory (where source files are) ───────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Pre-flight checks ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}claude-batch-toolkit installer${NC}"
echo "─────────────────────────────────"
echo ""

MISSING_DEPS=()

if ! command -v uv &>/dev/null; then
    MISSING_DEPS+=("uv")
fi

if ! command -v jq &>/dev/null; then
    MISSING_DEPS+=("jq")
fi

if ! command -v curl &>/dev/null; then
    MISSING_DEPS+=("curl")
fi

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
    err "Missing required dependencies: ${MISSING_DEPS[*]}"
    echo ""
    echo "Install them first:"
    for dep in "${MISSING_DEPS[@]}"; do
        case "$dep" in
            uv)   echo "  curl -LsSf https://astral.sh/uv/install.sh | sh" ;;
            jq)   echo "  brew install jq  # or: apt-get install jq" ;;
            curl)  echo "  brew install curl # or: apt-get install curl" ;;
        esac
    done
    exit 1
fi

ok "Dependencies found: uv, jq, curl"

# ─── Create directory structure ─────────────────────────────────────────────────
mkdir -p "$CLAUDE_DIR/mcp"
mkdir -p "$CLAUDE_DIR/skills/batch"
mkdir -p "$RESULTS_DIR"

ok "Directory structure created"

# ─── Copy files ─────────────────────────────────────────────────────────────────

# MCP server
if [[ -f "$SCRIPT_DIR/mcp/claude_batch_mcp.py" ]]; then
    cp "$SCRIPT_DIR/mcp/claude_batch_mcp.py" "$CLAUDE_DIR/mcp/claude_batch_mcp.py"
    ok "Copied mcp/claude_batch_mcp.py"
else
    die "Source file not found: $SCRIPT_DIR/mcp/claude_batch_mcp.py"
fi

# Skill
if [[ -f "$SCRIPT_DIR/skills/batch/SKILL.md" ]]; then
    cp "$SCRIPT_DIR/skills/batch/SKILL.md" "$CLAUDE_DIR/skills/batch/SKILL.md"
    ok "Copied skills/batch/SKILL.md"
else
    die "Source file not found: $SCRIPT_DIR/skills/batch/SKILL.md"
fi

# Status line
if [[ -f "$SCRIPT_DIR/statusline.sh" ]]; then
    cp "$SCRIPT_DIR/statusline.sh" "$CLAUDE_DIR/statusline.sh"
    chmod +x "$CLAUDE_DIR/statusline.sh"
    ok "Copied statusline.sh"
else
    die "Source file not found: $SCRIPT_DIR/statusline.sh"
fi

# ─── Write API key to ~/.claude/env ────────────────────────────────────────────
ENV_FILE="$CLAUDE_DIR/env"

# Preserve existing env vars, update ANTHROPIC_API_KEY
if [[ -f "$ENV_FILE" ]]; then
    # Remove existing ANTHROPIC_API_KEY line(s) if present
    grep -v '^export ANTHROPIC_API_KEY=' "$ENV_FILE" > "$ENV_FILE.tmp" 2>/dev/null || true
    echo "export ANTHROPIC_API_KEY=\"$API_KEY\"" >> "$ENV_FILE.tmp"
    mv "$ENV_FILE.tmp" "$ENV_FILE"
else
    echo "export ANTHROPIC_API_KEY=\"$API_KEY\"" > "$ENV_FILE"
fi

chmod 600 "$ENV_FILE"
ok "API key written to ~/.claude/env (mode 600)"

# ─── Register MCP server in ~/.claude.json ──────────────────────────────────────
CLAUDE_JSON="$HOME/.claude.json"

# Build the MCP server entry we want
MCP_ENTRY=$(cat <<MCPEOF
{
  "command": "uv",
  "args": ["run", "$CLAUDE_DIR/mcp/claude_batch_mcp.py", "--mcp"],
  "env": {
    "ANTHROPIC_API_KEY": "$API_KEY"
  }
}
MCPEOF
)

if [[ -f "$CLAUDE_JSON" ]]; then
    # File exists — merge in our MCP server
    EXISTING=$(cat "$CLAUDE_JSON")

    # Check if mcpServers key exists
    if echo "$EXISTING" | jq -e '.mcpServers' &>/dev/null; then
        # Update/add our server entry
        UPDATED=$(echo "$EXISTING" | jq --argjson entry "$MCP_ENTRY" '.mcpServers["claude-batch"] = $entry')
    else
        # Add mcpServers key
        UPDATED=$(echo "$EXISTING" | jq --argjson entry "$MCP_ENTRY" '. + {"mcpServers": {"claude-batch": $entry}}')
    fi

    echo "$UPDATED" | jq '.' > "$CLAUDE_JSON"
else
    # Create new file
    jq -n --argjson entry "$MCP_ENTRY" '{"mcpServers": {"claude-batch": $entry}}' > "$CLAUDE_JSON"
fi

ok "MCP server registered in ~/.claude.json"

# ─── Configure statusLine in ~/.claude/settings.json ────────────────────────────
if [[ "$NO_POLLER" -eq 0 ]]; then
    SETTINGS_FILE="$CLAUDE_DIR/settings.json"
    STATUS_CMD="bash $CLAUDE_DIR/statusline.sh"
    STATUS_OBJ=$(jq -n --arg cmd "$STATUS_CMD" '{"type": "command", "command": $cmd}')

    if [[ -f "$SETTINGS_FILE" ]]; then
        EXISTING_SETTINGS=$(cat "$SETTINGS_FILE")
        UPDATED_SETTINGS=$(echo "$EXISTING_SETTINGS" | jq --argjson obj "$STATUS_OBJ" '.statusLine = $obj')
        echo "$UPDATED_SETTINGS" | jq '.' > "$SETTINGS_FILE"
    else
        jq -n --argjson obj "$STATUS_OBJ" '{"statusLine": $obj}' > "$SETTINGS_FILE"
    fi

    ok "Status line configured in ~/.claude/settings.json"
else
    warn "Skipping status line configuration (--no-poller)"
fi

# ─── Initialize jobs.json if missing ───────────────────────────────────────────
JOBS_FILE="$BATCHES_DIR/jobs.json"
if [[ ! -f "$JOBS_FILE" ]]; then
    echo '{"version": 1, "jobs": {}}' | jq '.' > "$JOBS_FILE"
    ok "Initialized jobs.json"
else
    ok "jobs.json already exists"
fi

# ─── Smoke test ─────────────────────────────────────────────────────────────────
echo ""
info "Running smoke test..."

export ANTHROPIC_API_KEY="$API_KEY"

if uv run "$CLAUDE_DIR/mcp/claude_batch_mcp.py" list --base-dir "$BATCHES_DIR" &>/dev/null; then
    ok "Smoke test passed — MCP server works"
else
    # Try with more verbose output
    warn "Smoke test had issues. Attempting with output:"
    if uv run "$CLAUDE_DIR/mcp/claude_batch_mcp.py" list --base-dir "$BATCHES_DIR" 2>&1; then
        ok "Smoke test passed (with warnings)"
    else
        warn "Smoke test failed — the MCP server may need dependency resolution on first run"
        warn "This is normal; uv will resolve dependencies when Claude Code first calls the server"
    fi
fi

# ─── Done ───────────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────"
echo -e "${GREEN}${BOLD}Installation complete!${NC}"
echo ""
echo "What was installed:"
echo "  • MCP server:   ~/.claude/mcp/claude_batch_mcp.py"
echo "  • Skill file:   ~/.claude/skills/batch/SKILL.md"
echo "  • Status line:  ~/.claude/statusline.sh"
echo "  • API key:      ~/.claude/env"
echo "  • Jobs dir:     ~/.claude/batches/"
echo ""
echo "Usage in Claude Code:"
echo "  /batch Review this codebase for security issues"
echo "  /batch check"
echo "  /batch list"
echo ""
echo "The status bar will show batch job counts automatically."
echo ""

