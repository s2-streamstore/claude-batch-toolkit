# claude-batch-toolkit

Send non-urgent work to the Anthropic Batch API at **50% cost** — directly from Claude Code.

Code reviews, documentation, architecture analysis, refactoring plans, security audits — anything that can wait ~1 hour gets half-price processing with Claude Opus.

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/your-org/claude-batch-toolkit/main/install.sh | bash -s -- --api-key sk-ant-...
```

Or clone and run locally:

```bash
git clone https://github.com/your-org/claude-batch-toolkit.git
cd claude-batch-toolkit
./install.sh --api-key sk-ant-your-key-here
```

### Install Options

| Flag | Description |
|------|-------------|
| `--api-key KEY` | Your Anthropic API key (required unless already in env) |
| `--no-poller` | Skip status line configuration |
| `--unattended` | No interactive prompts |

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
│  │ [Opus] 42% | $1.23 | batch: 1 done ✓                   │    │
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
| `CLAUDE_MAX_TOKENS` | `8192` | Max output tokens |
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
├── statusline.sh                # Status bar + cached poller
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
cat ~/.claude/settings.json | jq '.statusLine'

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

### Reinstall

```bash
./install.sh --api-key sk-ant-your-key
```

The installer is idempotent — safe to run multiple times.

### Uninstall

```bash
./uninstall.sh
```

This removes toolkit files but preserves your results in `~/.claude/batches/results/`.

## Architecture

- **MCP Server** (`claude_batch_mcp.py`): Python script run by `uv`. Exposes `send_to_batch`, `batch_status`, `batch_fetch`, `batch_list`, `batch_poll_once` tools. Also works as a CLI.
- **Skill** (`SKILL.md`): Teaches Claude Code how and when to use the batch tools. Loaded automatically.
- **Status Line** (`statusline.sh`): Bash script that renders batch job counts in the Claude Code status bar and triggers background polling via `curl`+`jq`.
- **Jobs Registry** (`jobs.json`): JSON file tracking all submitted batch jobs, their states, and result paths.

## License

MIT

