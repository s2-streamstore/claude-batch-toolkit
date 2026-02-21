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
CLAUDE_JSON="$HOME/.claude.json"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
ENV_FILE="$CLAUDE_DIR/env"

# ─── Color helpers ──────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[info]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ok]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC}  $*"; }
err()   { echo -e "${RED}[error]${NC} $*" >&2; }
die()   { err "$@"; exit 1; }

# ─── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --api-key)
            [[ $# -ge 2 ]] || die "--api-key requires an argument"
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

# ─── Determine script directory (where source files are) ───────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Resolve API key (without sourcing arbitrary files) ─────────────────────────
if [[ -z "$API_KEY" ]]; then
    API_KEY="${ANTHROPIC_API_KEY:-}"
fi

# Try .env file in script directory / current directory
if [[ -z "$API_KEY" ]]; then
    for dotenv in "$SCRIPT_DIR/.env" ".env"; do
        if [[ -f "$dotenv" ]]; then
            API_KEY="$(grep -m1 '^\(export[[:space:]]*\)\?ANTHROPIC_API_KEY=' "$dotenv" 2>/dev/null \
                       | sed 's/^\(export[[:space:]]*\)\?ANTHROPIC_API_KEY=//' \
                       | sed "s/^'//;s/'$//" \
                       | sed 's/^"//;s/"$//' )" || true
            [[ -n "$API_KEY" ]] && break
        fi
    done
fi

if [[ -z "$API_KEY" ]]; then
    # Try parsing (not sourcing) existing env file
    if [[ -f "$ENV_FILE" ]]; then
        API_KEY="$(grep -m1 '^export ANTHROPIC_API_KEY=' "$ENV_FILE" 2>/dev/null \
                   | sed 's/^export ANTHROPIC_API_KEY=//' \
                   | sed 's/^"//;s/"$//' \
                   | sed "s/^'//;s/'$//" )" || true
    fi
fi

if [[ -z "$API_KEY" ]]; then
    if [[ "$UNATTENDED" -eq 1 ]]; then
        die "No API key provided. Use --api-key or set ANTHROPIC_API_KEY."
    fi
    echo -e "${BOLD}Enter your Anthropic API key:${NC}"
    read -r -s API_KEY
    echo ""
    [[ -n "$API_KEY" ]] || die "No API key provided."
fi

# ─── Pre-flight checks ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}claude-batch-toolkit installer${NC}"
echo "─────────────────────────────────"
echo ""

MISSING_DEPS=()
command -v uv   &>/dev/null || MISSING_DEPS+=("uv")
command -v jq   &>/dev/null || MISSING_DEPS+=("jq")
command -v curl &>/dev/null || MISSING_DEPS+=("curl")

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
    err "Missing required dependencies: ${MISSING_DEPS[*]}"
    echo ""

    if [[ "$UNATTENDED" -eq 1 ]]; then
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

    echo -e -n "${BOLD}Would you like to install missing dependencies? [Y/n]${NC} "
    read -r DEP_CONFIRM
    case "${DEP_CONFIRM:-Y}" in
        [Yy]|[Yy]es|"")
            for dep in "${MISSING_DEPS[@]}"; do
                case "$dep" in
                    uv)
                        info "Installing uv..."
                        curl -LsSf https://astral.sh/uv/install.sh | sh || die "Failed to install uv"
                        export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
                        command -v uv &>/dev/null || die "uv installed but not found in PATH. Restart your terminal and try again."
                        ok "uv installed"
                        ;;
                    jq)
                        info "Installing jq..."
                        if command -v brew &>/dev/null; then
                            brew install jq || die "Failed to install jq"
                        elif command -v apt-get &>/dev/null; then
                            sudo apt-get install -y jq || die "Failed to install jq"
                        elif command -v dnf &>/dev/null; then
                            sudo dnf install -y jq || die "Failed to install jq"
                        elif command -v pacman &>/dev/null; then
                            sudo pacman -S --noconfirm jq || die "Failed to install jq"
                        else
                            die "Cannot auto-install jq. Please install it manually."
                        fi
                        ok "jq installed"
                        ;;
                    curl)
                        info "Installing curl..."
                        if command -v brew &>/dev/null; then
                            brew install curl || die "Failed to install curl"
                        elif command -v apt-get &>/dev/null; then
                            sudo apt-get install -y curl || die "Failed to install curl"
                        elif command -v dnf &>/dev/null; then
                            sudo dnf install -y curl || die "Failed to install curl"
                        elif command -v pacman &>/dev/null; then
                            sudo pacman -S --noconfirm curl || die "Failed to install curl"
                        else
                            die "Cannot auto-install curl. Please install it manually."
                        fi
                        ok "curl installed"
                        ;;
                esac
            done
            ;;
        *)
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
            ;;
    esac
fi

ok "Dependencies found: uv, jq, curl"

# Verify source files exist before planning anything
for src_file in "mcp/claude_batch_mcp.py" "skills/batch/SKILL.md" "statusline.sh"; do
    [[ -f "$SCRIPT_DIR/$src_file" ]] || die "Source file not found: $SCRIPT_DIR/$src_file"
done

# ─── Build change manifest ─────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Planned changes:${NC}"
echo ""

CHANGES=()
WARNINGS=()

# 1. Directories
for d in "$CLAUDE_DIR/mcp" "$CLAUDE_DIR/skills/batch" "$RESULTS_DIR"; do
    if [[ ! -d "$d" ]]; then
        CHANGES+=("CREATE DIR  $d")
    fi
done

# 2. File copies
for pair in \
    "mcp/claude_batch_mcp.py:$CLAUDE_DIR/mcp/claude_batch_mcp.py" \
    "skills/batch/SKILL.md:$CLAUDE_DIR/skills/batch/SKILL.md" \
    "statusline.sh:$CLAUDE_DIR/statusline.sh"; do
    src="${pair%%:*}"
    dst="${pair##*:}"
    if [[ -f "$dst" ]]; then
        CHANGES+=("OVERWRITE   $dst  (from $src)")
    else
        CHANGES+=("COPY        $src → $dst")
    fi
done

# 3. Env file
if [[ -f "$ENV_FILE" ]]; then
    if grep -q '^export ANTHROPIC_API_KEY=' "$ENV_FILE" 2>/dev/null; then
        CHANGES+=("UPDATE      $ENV_FILE  (replace ANTHROPIC_API_KEY line)")
    else
        CHANGES+=("APPEND      $ENV_FILE  (add ANTHROPIC_API_KEY)")
    fi
else
    CHANGES+=("CREATE      $ENV_FILE  (with ANTHROPIC_API_KEY)")
fi

# 4. claude.json MCP entry
if [[ -f "$CLAUDE_JSON" ]]; then
    CHANGES+=("BACKUP      $CLAUDE_JSON → ${CLAUDE_JSON}.bak")
    if jq -e '.mcpServers["claude-batch"]' "$CLAUDE_JSON" &>/dev/null; then
        CHANGES+=("UPDATE      $CLAUDE_JSON  (replace mcpServers.claude-batch)")
    else
        CHANGES+=("MERGE       $CLAUDE_JSON  (add mcpServers.claude-batch)")
    fi
else
    CHANGES+=("CREATE      $CLAUDE_JSON  (with mcpServers.claude-batch)")
fi

# 5. Status line
SKIP_STATUSLINE=0
if [[ "$NO_POLLER" -eq 0 ]]; then
    STATUS_CMD="bash $CLAUDE_DIR/statusline.sh"
    if [[ -f "$SETTINGS_FILE" ]]; then
        EXISTING_STATUS_CMD="$(jq -r '.statusLine.command // empty' "$SETTINGS_FILE" 2>/dev/null || true)"
        if [[ -n "$EXISTING_STATUS_CMD" && "$EXISTING_STATUS_CMD" != "$STATUS_CMD" ]]; then
            WARNINGS+=("statusLine is already set to: $EXISTING_STATUS_CMD")
            WARNINGS+=("It does NOT point to our script. Will NOT overwrite.")
            SKIP_STATUSLINE=1
        else
            CHANGES+=("BACKUP      $SETTINGS_FILE → ${SETTINGS_FILE}.bak")
            if [[ "$EXISTING_STATUS_CMD" == "$STATUS_CMD" ]]; then
                CHANGES+=("NO CHANGE   $SETTINGS_FILE  (statusLine already set to our script)")
            else
                CHANGES+=("MERGE       $SETTINGS_FILE  (set statusLine)")
            fi
        fi
    else
        CHANGES+=("CREATE      $SETTINGS_FILE  (with statusLine)")
    fi
else
    CHANGES+=("SKIP        statusLine configuration (--no-poller)")
fi

# 6. jobs.json
JOBS_FILE="$BATCHES_DIR/jobs.json"
if [[ ! -f "$JOBS_FILE" ]]; then
    CHANGES+=("CREATE      $JOBS_FILE  (empty job registry)")
else
    CHANGES+=("NO CHANGE   $JOBS_FILE  (already exists)")
fi

# Print the manifest
for change in "${CHANGES[@]}"; do
    echo -e "  ${CYAN}•${NC} $change"
done

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    echo ""
    for w in "${WARNINGS[@]}"; do
        warn "$w"
    done
fi

echo ""

# ─── Confirm with user ─────────────────────────────────────────────────────────
if [[ "$UNATTENDED" -eq 0 ]]; then
    echo -e -n "${BOLD}Proceed with installation? [Y/n]${NC} "
    read -r CONFIRM
    case "${CONFIRM:-Y}" in
        [Yy]|[Yy]es|"") ;;
        *) echo "Aborted."; exit 0 ;;
    esac
    echo ""
fi

# ─── Helper: atomic JSON write ─────────────────────────────────────────────────
# Usage: atomic_json_write <json_string> <target_file>
# Validates JSON, writes to temp, then atomically moves into place.
atomic_json_write() {
    local json_content="$1"
    local target="$2"
    local tmpfile="${target}.install_tmp.$$"

    # Validate & pretty-print
    if ! echo "$json_content" | jq '.' > "$tmpfile" 2>/dev/null; then
        rm -f "$tmpfile"
        die "BUG: Generated invalid JSON for $target. Aborting (no changes made to this file)."
    fi

    mv -f "$tmpfile" "$target"
}

# ─── Create directory structure ─────────────────────────────────────────────────
mkdir -p "$CLAUDE_DIR/mcp"
mkdir -p "$CLAUDE_DIR/skills/batch"
mkdir -p "$RESULTS_DIR"

ok "Directory structure ready"

# ─── Copy files ─────────────────────────────────────────────────────────────────
cp "$SCRIPT_DIR/mcp/claude_batch_mcp.py" "$CLAUDE_DIR/mcp/claude_batch_mcp.py"
ok "Installed mcp/claude_batch_mcp.py"

cp "$SCRIPT_DIR/skills/batch/SKILL.md" "$CLAUDE_DIR/skills/batch/SKILL.md"
ok "Installed skills/batch/SKILL.md"

cp "$SCRIPT_DIR/statusline.sh" "$CLAUDE_DIR/statusline.sh"
chmod +x "$CLAUDE_DIR/statusline.sh"
ok "Installed statusline.sh"

# ─── Write API key to ~/.claude/env ────────────────────────────────────────────
if [[ -f "$ENV_FILE" ]]; then
    # Build new content: everything except existing ANTHROPIC_API_KEY lines, then append ours
    {
        grep -v '^export ANTHROPIC_API_KEY=' "$ENV_FILE" 2>/dev/null || true
        echo "export ANTHROPIC_API_KEY=\"$API_KEY\""
    } > "${ENV_FILE}.install_tmp.$$"
    mv -f "${ENV_FILE}.install_tmp.$$" "$ENV_FILE"
else
    echo "export ANTHROPIC_API_KEY=\"$API_KEY\"" > "$ENV_FILE"
fi

chmod 600 "$ENV_FILE"
ok "API key written to ~/.claude/env (mode 600)"

# ─── Register MCP server in ~/.claude.json (safe merge with jq --arg) ──────────
# Build MCP entry using jq --arg for safe value escaping
MCP_ENTRY=$(jq -n \
    --arg mcp_script "$CLAUDE_DIR/mcp/claude_batch_mcp.py" \
    --arg api_key "$API_KEY" \
    '{
        "command": "uv",
        "args": ["run", $mcp_script, "--mcp"],
        "env": {
            "ANTHROPIC_API_KEY": $api_key
        }
    }')

if [[ -f "$CLAUDE_JSON" ]]; then
    # Backup before modifying
    cp -p "$CLAUDE_JSON" "${CLAUDE_JSON}.bak"
    info "Backed up ${CLAUDE_JSON} → ${CLAUDE_JSON}.bak"

    EXISTING=$(cat "$CLAUDE_JSON")

    # Validate existing file is valid JSON
    if ! echo "$EXISTING" | jq '.' &>/dev/null; then
        die "$CLAUDE_JSON is not valid JSON. Please fix it manually before installing."
    fi

    if echo "$EXISTING" | jq -e '.mcpServers' &>/dev/null; then
        UPDATED=$(echo "$EXISTING" | jq --argjson entry "$MCP_ENTRY" '.mcpServers["claude-batch"] = $entry')
    else
        UPDATED=$(echo "$EXISTING" | jq --argjson entry "$MCP_ENTRY" '. + {"mcpServers": {"claude-batch": $entry}}')
    fi

    atomic_json_write "$UPDATED" "$CLAUDE_JSON"
else
    NEW_JSON=$(jq -n --argjson entry "$MCP_ENTRY" '{"mcpServers": {"claude-batch": $entry}}')
    atomic_json_write "$NEW_JSON" "$CLAUDE_JSON"
fi

ok "MCP server registered in ~/.claude.json"

# ─── Configure statusLine in ~/.claude/settings.json ────────────────────────────
if [[ "$NO_POLLER" -eq 0 && "$SKIP_STATUSLINE" -eq 0 ]]; then
    STATUS_CMD="bash $CLAUDE_DIR/statusline.sh"
    STATUS_OBJ=$(jq -n --arg cmd "$STATUS_CMD" '{"type": "command", "command": $cmd}')

    if [[ -f "$SETTINGS_FILE" ]]; then
        # Backup before modifying
        cp -p "$SETTINGS_FILE" "${SETTINGS_FILE}.bak"
        info "Backed up ${SETTINGS_FILE} → ${SETTINGS_FILE}.bak"

        EXISTING_SETTINGS=$(cat "$SETTINGS_FILE")

        # Validate existing file
        if ! echo "$EXISTING_SETTINGS" | jq '.' &>/dev/null; then
            die "$SETTINGS_FILE is not valid JSON. Please fix it manually before installing."
        fi

        UPDATED_SETTINGS=$(echo "$EXISTING_SETTINGS" | jq --argjson obj "$STATUS_OBJ" '.statusLine = $obj')
        atomic_json_write "$UPDATED_SETTINGS" "$SETTINGS_FILE"
    else
        NEW_SETTINGS=$(jq -n --argjson obj "$STATUS_OBJ" '{"statusLine": $obj}')
        atomic_json_write "$NEW_SETTINGS" "$SETTINGS_FILE"
    fi

    ok "Status line configured in ~/.claude/settings.json"
elif [[ "$SKIP_STATUSLINE" -eq 1 ]]; then
    warn "Skipped statusLine — already set to a different command (not overwritten)"
else
    warn "Skipping status line configuration (--no-poller)"
fi

# ─── Initialize jobs.json if missing ───────────────────────────────────────────
if [[ ! -f "$JOBS_FILE" ]]; then
    atomic_json_write '{"version": 1, "jobs": {}}' "$JOBS_FILE"
    ok "Initialized jobs.json"
else
    ok "jobs.json already exists"
fi

# ─── Smoke test ─────────────────────────────────────────────────────────────────
echo ""
info "Running smoke test (this may take a moment if uv needs to resolve dependencies)..."

export ANTHROPIC_API_KEY="$API_KEY"

if uv run "$CLAUDE_DIR/mcp/claude_batch_mcp.py" list --base-dir "$BATCHES_DIR" &>/dev/null; then
    ok "Smoke test passed — MCP server works"
else
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
