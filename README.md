# claude-batch-toolkit

Send non-urgent work to the Anthropic Batch API at **50% cost** — directly from Claude Code.

Code reviews, documentation, architecture analysis, refactoring plans, security audits — anything that can wait ~1 hour gets half-price processing with Claude Opus.

## Install

```bash
git clone git@github.com:s2-streamstore/claude-batch-toolkit.git
cd claude-batch-toolkit
./install.sh --api-key sk-ant-your-key-here
```

**Windows (PowerShell):**

```powershell
git clone git@github.com:s2-streamstore/claude-batch-toolkit.git
cd claude-batch-toolkit
.\install.ps1 -ApiKey sk-ant-your-key-here
```

> If you get a script execution error, run: `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned`

The installer shows a manifest of every change it will make and asks for confirmation before proceeding. You can also create a `.env` file with your API key instead of passing it on the command line (see `.env.example`).

### Install Options

| Bash Flag | PowerShell Flag | Description |
|-----------|----------------|-------------|
| `--api-key KEY` | `-ApiKey KEY` | Your Anthropic API key (required unless already in env or `.env`) |
| `--no-poller` | `-NoPoller` | Skip status line configuration |
| `--unattended` | `-Unattended` | No interactive prompts |

### Uninstall

```bash
./uninstall.sh
```

**Windows:**

```powershell
.\uninstall.ps1
```

This shows what will be removed, asks for confirmation, and preserves your results in `~/.claude/batches/results/`. Use `--purge-data` / `-PurgeData` to also remove results.

<details>
<summary><strong>Manual Installation (no script)</strong></summary>

If you prefer not to run the install script — or need to install in a restricted environment — follow these steps to set up each component by hand.

#### Prerequisites

| Dependency | Purpose | Install |
|------------|---------|---------|
| **uv** | Runs the Python MCP server (no virtualenv needed) | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |
| **jq** | JSON processing in statusline + installer | `brew install jq` or `apt-get install jq` |
| **curl** | Polls the Anthropic API from statusline | `brew install curl` or `apt-get install curl` |

You also need an **Anthropic API key** (`sk-ant-...`). Get one from [console.anthropic.com](https://console.anthropic.com/).

Verify prerequisites:

```bash
command -v uv   && echo "uv ok"   || echo "uv MISSING"
command -v jq   && echo "jq ok"   || echo "jq MISSING"
command -v curl && echo "curl ok" || echo "curl MISSING"
```

#### Step 1: Create directory structure

```bash
mkdir -p ~/.claude/mcp
mkdir -p ~/.claude/skills/batch
mkdir -p ~/.claude/batches/results
```

#### Step 2: Install the MCP server

```bash
cp mcp/claude_batch_mcp.py ~/.claude/mcp/claude_batch_mcp.py
```

#### Step 3: Install the skill file

```bash
cp skills/batch/SKILL.md ~/.claude/skills/batch/SKILL.md
```

#### Step 4 *(optional)*: Install the statusline script

> Skip this step if you don't want batch job counts in your Claude Code status bar. Everything else works without it.

```bash
cp statusline.sh ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

#### Step 5: Set up your API key

The toolkit reads `ANTHROPIC_API_KEY` from `~/.claude/env`. This file **must** be mode `600`.

**If `~/.claude/env` does not exist yet:**

```bash
echo 'export ANTHROPIC_API_KEY="sk-ant-YOUR-KEY-HERE"' > ~/.claude/env
chmod 600 ~/.claude/env
```

**If `~/.claude/env` already exists**, open it in your editor and add (or replace) the `ANTHROPIC_API_KEY` line, then ensure `chmod 600 ~/.claude/env`.

#### Step 6: Register the MCP server in `~/.claude.json`

Claude Code discovers MCP servers through `~/.claude.json`. You need to add a `claude-batch` entry under the `mcpServers` key.

**If `~/.claude.json` does not exist yet:**

```bash
API_KEY=$(grep ANTHROPIC_API_KEY ~/.claude/env | cut -d'"' -f2)

jq -n --arg home "$HOME" --arg key "$API_KEY" '{
  "mcpServers": {
    "claude-batch": {
      "command": "uv",
      "args": ["run", ($home + "/.claude/mcp/claude_batch_mcp.py"), "--mcp"],
      "env": { "ANTHROPIC_API_KEY": $key }
    }
  }
}' > ~/.claude.json
```

**If `~/.claude.json` already exists** — merge (don't overwrite):

```bash
API_KEY=$(grep ANTHROPIC_API_KEY ~/.claude/env | cut -d'"' -f2)

jq --arg home "$HOME" --arg key "$API_KEY" '
  .mcpServers["claude-batch"] = {
    "command": "uv",
    "args": ["run", ($home + "/.claude/mcp/claude_batch_mcp.py"), "--mcp"],
    "env": { "ANTHROPIC_API_KEY": $key }
  }
' ~/.claude.json > ~/.claude.json.tmp && mv ~/.claude.json.tmp ~/.claude.json
```

Or edit by hand — the path in `args` must be an **absolute path** (use `echo $HOME` to get yours).

#### Step 7 *(optional)*: Configure the statusline in `~/.claude/settings.json`

> Skip this if you skipped Step 4. The statusLine value **must** be an object, not a bare string.

**If `~/.claude/settings.json` does not exist yet:**

```bash
jq -n --arg cmd "bash $HOME/.claude/statusline.sh" '{
  "statusLine": {"type": "command", "command": $cmd}
}' > ~/.claude/settings.json
```

**If it already exists:**

```bash
jq --arg cmd "bash $HOME/.claude/statusline.sh" '
  .statusLine = {"type": "command", "command": $cmd}
' ~/.claude/settings.json > ~/.claude/settings.json.tmp \
  && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
```

> **Warning:** This overwrites any existing `statusLine`. If you have a custom statusline, incorporate the batch script manually.

#### Step 8: Initialize the jobs registry

```bash
if [ ! -f ~/.claude/batches/jobs.json ]; then
  echo '{"version": 1, "jobs": {}}' | jq '.' > ~/.claude/batches/jobs.json
  echo "Created jobs.json"
else
  echo "jobs.json already exists"
fi
```

#### Step 9: Smoke test

```bash
source ~/.claude/env
uv run ~/.claude/mcp/claude_batch_mcp.py list --base-dir ~/.claude/batches
```

Expected: an empty list or JSON showing no jobs. First run may take a moment while `uv` resolves dependencies.

If you installed the statusline:

```bash
echo '{}' | bash ~/.claude/statusline.sh
```

#### Verify Installation

```bash
echo "=== File check ==="
[ -f ~/.claude/mcp/claude_batch_mcp.py ] && echo "ok MCP server"     || echo "MISSING MCP server"
[ -f ~/.claude/skills/batch/SKILL.md ]   && echo "ok Skill file"     || echo "MISSING Skill file"
[ -f ~/.claude/statusline.sh ]           && echo "ok Statusline"     || echo "-- Statusline (optional)"
[ -f ~/.claude/env ]                     && echo "ok Env file"       || echo "MISSING Env file"
[ -f ~/.claude/batches/jobs.json ]       && echo "ok Jobs registry"  || echo "MISSING Jobs registry"

echo ""
echo "=== Config check ==="
jq -e '.mcpServers["claude-batch"]' ~/.claude.json &>/dev/null \
  && echo "ok MCP registered in ~/.claude.json" \
  || echo "MISSING MCP entry in ~/.claude.json"

echo ""
echo "=== Permissions check ==="
PERMS=$(stat -f '%A' ~/.claude/env 2>/dev/null || stat -c '%a' ~/.claude/env 2>/dev/null)
[ "$PERMS" = "600" ] && echo "ok ~/.claude/env is mode 600" || echo "WARN ~/.claude/env is mode $PERMS (should be 600)"
```

#### Manual Uninstall

**Step 1: Remove toolkit files**

```bash
rm -f ~/.claude/mcp/claude_batch_mcp.py
rm -f ~/.claude/skills/batch/SKILL.md
rm -f ~/.claude/statusline.sh
rmdir ~/.claude/skills/batch 2>/dev/null || true
rmdir ~/.claude/skills 2>/dev/null || true
```

**Step 2: Remove MCP entry from `~/.claude.json`**

```bash
jq 'del(.mcpServers["claude-batch"])' ~/.claude.json > ~/.claude.json.tmp \
  && mv ~/.claude.json.tmp ~/.claude.json
```

**Step 3: Remove statusline from `~/.claude/settings.json`** (if installed)

```bash
jq 'del(.statusLine)' ~/.claude/settings.json > ~/.claude/settings.json.tmp \
  && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
```

**Step 4: Remove API key** (optional)

```bash
grep -v '^export ANTHROPIC_API_KEY=' ~/.claude/env > ~/.claude/env.tmp \
  && mv ~/.claude/env.tmp ~/.claude/env && chmod 600 ~/.claude/env
[ ! -s ~/.claude/env ] && rm -f ~/.claude/env
```

**Step 5: Remove jobs data** (optional)

```bash
rm -f ~/.claude/batches/jobs.json
rm -f ~/.claude/batches/.poll_cache
rm -f ~/.claude/batches/.poll.lock
# To also remove all batch results:
# rm -f ~/.claude/batches/results/*.md ~/.claude/batches/results/*.jsonl ~/.claude/batches/results/*.json
# rmdir ~/.claude/batches/results 2>/dev/null
# rmdir ~/.claude/batches 2>/dev/null
```

</details>

## Usage

### Submit work to batch

In Claude Code, just say:

```
/batch Review this codebase for security issues
```

```
/batch Generate comprehensive tests for src/auth/
```

```
/batch Write API documentation for all public endpoints
```

Claude will gather all relevant context, build a self-contained prompt, submit it to the Batch API, and tell you the job ID.

### Check results

```
/batch check
```

```
/batch status
```

```
/batch list
```

Results appear in your status bar automatically. When a job completes, Claude reads the result from disk and presents it.

### Direct CLI usage

The MCP server also works as a standalone CLI:

```bash
# Submit a job
uv run ~/.claude/mcp/claude_batch_mcp.py submit --packet-path prompt.md --label "security-review"

# List all jobs
uv run ~/.claude/mcp/claude_batch_mcp.py list

# Poll for completed jobs
uv run ~/.claude/mcp/claude_batch_mcp.py poll

# Fetch a specific result
uv run ~/.claude/mcp/claude_batch_mcp.py fetch msgbatch_xxx --print
```

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│ Claude Code Session                                             │
│                                                                 │
│  User: "/batch review src/ for security issues"                 │
│                                                                 │
│  Claude:                                                        │
│    1. Reads all files in src/                                   │
│    2. Assembles self-contained prompt (bash → temp file)        │
│    3. Calls send_to_batch MCP tool with packet_path             │
│    4. Reports: "Submitted job msgbatch_abc123"                  │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ Status Bar                                              │    │
│  │ [Opus] 42% | $1.23 | batch: 1 pending                  │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
│  ... ~30 minutes later ...                                      │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ Status Bar                                              │    │
│  │ [Opus] 42% | $1.23 | batch: 1 done                     │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
│  User: "/batch check"                                           │
│  Claude: reads ~/.claude/batches/results/msgbatch_abc123.md     │
│          presents formatted results                             │
└─────────────────────────────────────────────────────────────────┘

                          │
                          ▼
              ┌──────────────────────┐
              │  Anthropic Batch API │
              │  (50% cost)          │
              │  ~1hr turnaround     │
              └──────────────────────┘
```

### Status Line + Cached Poller

The status line is the only moving part — no daemons, no background services, no launchd/systemd.

```
Assistant message arrives
        │
        ▼
 statusline.sh runs
        │
        ├─► Render (instant): Read jobs.json → print status bar
        │
        └─► Poll (async fork): If pending jobs + cache stale (>60s)
            └─► curl Anthropic API → update jobs.json
                (never blocks the status line)
```

| Property | Value |
|----------|-------|
| Blocks status line? | **Never** — poll is forked |
| Polls when idle? | **No** — only during active Claude sessions |
| Poll frequency | At most once per 60s |
| Extra processes | **None** — no daemon |
| Wasted API calls | **Zero** when no pending jobs |

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ANTHROPIC_API_KEY` | — | Your Anthropic API key (required) |
| `CLAUDE_BATCH_DIR` | `~/.claude/batches` | Where jobs.json and results live |
| `CLAUDE_MODEL` | `claude-opus-4-6` | Model for batch jobs |
| `CLAUDE_MAX_TOKENS` | `32768` | Max output tokens |
| `CLAUDE_THINKING` | — | Set to `enabled` for extended thinking |
| `CLAUDE_THINKING_BUDGET` | — | Token budget for thinking |

### Vertex AI (optional)

| Variable | Description |
|----------|-------------|
| `VERTEX_PROJECT` | GCP project ID |
| `VERTEX_LOCATION` | e.g., `us-central1` |
| `VERTEX_GCS_BUCKET` | GCS bucket for input/output |
| `VERTEX_GCS_PREFIX` | Folder prefix (default: `claude-batch`) |

### File Locations

```
~/.claude/
├── env                          # ANTHROPIC_API_KEY (mode 600)
├── settings.json                # statusLine config
├── mcp/
│   └── claude_batch_mcp.py      # MCP server
├── skills/
│   └── batch/
│       └── SKILL.md             # Skill definition
├── statusline.sh                # Status bar + cached poller (macOS/Linux)
├── statusline.ps1               # Status bar + cached poller (Windows)
└── batches/
    ├── jobs.json                # Job registry
    ├── .poll_cache              # Last poll timestamp
    ├── .poll.lock               # Prevents concurrent polls
    └── results/
        ├── msgbatch_xxx.md      # Completed results
        └── msgbatch_xxx.meta.json
```

## Cost Reference

| Model | Standard | Batch (50% off) |
|-------|----------|-----------------|
| Claude Opus 4 | $15 / $75 per 1M tokens | **$7.50 / $37.50** |
| Claude Sonnet 4 | $3 / $15 per 1M tokens | **$1.50 / $7.50** |

(Input / Output per million tokens)

Typical turnaround: **under 1 hour**. Maximum: 24 hours.

## Troubleshooting

### "MCP server not responding"

```bash
# Test the MCP server directly
uv run ~/.claude/mcp/claude_batch_mcp.py list

# Check if uv is installed
which uv

# Verify API key
grep ANTHROPIC_API_KEY ~/.claude/env
```

### "No batch info in status bar"

```bash
# Check statusline config
jq '.statusLine' ~/.claude/settings.json

# Test statusline manually
echo '{}' | bash ~/.claude/statusline.sh

# Check jobs.json exists
cat ~/.claude/batches/jobs.json
```

### "Job stuck in pending"

```bash
# Manual poll
uv run ~/.claude/mcp/claude_batch_mcp.py poll

# Check API status directly
source ~/.claude/env
curl -s -H "x-api-key: $ANTHROPIC_API_KEY" \
     -H "anthropic-version: 2023-06-01" \
     https://api.anthropic.com/v1/messages/batches/BATCH_ID
```

### "Permission denied on env file"

```bash
chmod 600 ~/.claude/env
```

### Windows: "execution of scripts is disabled"

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

### Windows: "MCP server not responding"

```powershell
# Test the MCP server directly
uv run $HOME\.claude\mcp\claude_batch_mcp.py list

# Check if uv is installed
Get-Command uv

# Verify API key
Get-Content $HOME\.claude\env | Select-String ANTHROPIC_API_KEY
```

### Windows: "No batch info in status bar"

```powershell
# Check statusline config
Get-Content $HOME\.claude\settings.json | ConvertFrom-Json | Select-Object -ExpandProperty statusLine

# Test statusline manually
echo '{}' | powershell -NoProfile -ExecutionPolicy Bypass -File $HOME\.claude\statusline.ps1

# Check jobs.json exists
Get-Content $HOME\.claude\batches\jobs.json
```

## Architecture

- **MCP Server** (`claude_batch_mcp.py`): Python script run by `uv`. Exposes `send_to_batch`, `batch_status`, `batch_fetch`, `batch_list`, `batch_poll_once` tools. Also works as a CLI.
- **Skill** (`SKILL.md`): Teaches Claude Code how and when to use the batch tools. Loaded automatically.
- **Status Line** (`statusline.sh` / `statusline.ps1`): Renders batch job counts in the Claude Code status bar and triggers background polling. The bash version uses `curl`+`jq`; the PowerShell version uses `Invoke-RestMethod` with native JSON.
- **Jobs Registry** (`jobs.json`): JSON file tracking all submitted batch jobs, their states, and result paths.

## License

MIT
