---
name: batch
description: Send non-urgent tasks to Claude's Batch API at 50% off. Use for code reviews, documentation, analysis, refactoring plans, or any work that can wait ~1hr. Trigger with "/batch", "batch this", or "send to batch".
argument-hint: [task description or "check"/"status"/"list"]
---

You have access to the `claude-batch` MCP server with these tools:
- `send_to_batch` — submit a prompt (use `packet_path` for large prompts, `packet_text` for short ones)
- `batch_status` — check a job by ID
- `batch_fetch` — download results of a completed job
- `batch_list` — list all tracked jobs
- `batch_poll_once` — poll all pending jobs and auto-fetch completed ones

## Pre-flight check

**Always call `batch_list` first** before building any prompt. This:
1. Verifies the MCP server is connected and working
2. Shows you the current state of all jobs (avoids duplicate submissions)
3. Reveals any completed jobs the user might want to see first

If `batch_list` fails, stop and tell the user: "The batch MCP server isn't responding. Run `uv run ~/.claude/mcp/claude_batch_mcp.py list` to debug."

## Submitting work — the packet_path pattern

For any non-trivial prompt (which is almost all batch work), **assemble the prompt as a file on disk** and pass it via `packet_path`. Never inline large content as `packet_text` — it wastes context window tokens and can hit argument size limits.

### Step-by-step process

1. **Gather context** — Read all files, diffs, or code the task needs. The batch model has NO access to the codebase or conversation history. The prompt must be completely self-contained.

2. **Write the prompt to a temp file using bash**:

```bash
# Single file task
cat > /tmp/batch_prompt.md << 'PROMPT_EOF'
You are an expert software engineer.

## Task
Review the following code for security vulnerabilities, focusing on injection attacks, auth bypass, and data leaks.

## Code
PROMPT_EOF

# Append source files
echo '### src/auth/login.ts' >> /tmp/batch_prompt.md
echo '```typescript' >> /tmp/batch_prompt.md
cat src/auth/login.ts >> /tmp/batch_prompt.md
echo '```' >> /tmp/batch_prompt.md

echo '### src/auth/session.ts' >> /tmp/batch_prompt.md
echo '```typescript' >> /tmp/batch_prompt.md
cat src/auth/session.ts >> /tmp/batch_prompt.md
echo '```' >> /tmp/batch_prompt.md

# Append instructions
cat >> /tmp/batch_prompt.md << 'PROMPT_EOF'

## Instructions
- List each vulnerability with severity (Critical/High/Medium/Low)
- Include the file path and line number
- Provide a fix for each issue
- Respond in markdown
PROMPT_EOF
```

3. **For multi-file tasks, use a loop**:

```bash
cat > /tmp/batch_prompt.md << 'PROMPT_EOF'
You are an expert software engineer. Generate comprehensive unit tests for the following source files.

## Source Files
PROMPT_EOF

# Include all source files from a directory
for f in src/services/*.ts; do
    echo "### $f" >> /tmp/batch_prompt.md
    echo '```typescript' >> /tmp/batch_prompt.md
    cat "$f" >> /tmp/batch_prompt.md
    echo '```' >> /tmp/batch_prompt.md
    echo "" >> /tmp/batch_prompt.md
done

cat >> /tmp/batch_prompt.md << 'PROMPT_EOF'

## Instructions
- Use Jest as the testing framework
- Aim for >90% line coverage
- Include edge cases and error handling tests
- Mock external dependencies
- Output each test file with its target path as a header
PROMPT_EOF
```

4. **Submit with `packet_path`**:

Call `send_to_batch` with:
- `packet_path`: `/tmp/batch_prompt.md`
- `backend`: `"anthropic"`
- `label`: A descriptive label like `"security-review-auth"` or `"test-gen-services"`

5. **Report to user** — Tell the user:
   - The job ID
   - Results typically arrive within 1 hour
   - Their status bar will show when it completes
   - They can check with `/batch check`

### Prompt template structure

```
You are an expert software engineer. [Specific role if needed.]

## Task
[Clear description of what to do]

## Context
### path/to/file1.rs
```rust
[full file contents]
```

### path/to/file2.rs
```rust
[full file contents]
```

## Instructions
[Specific output format, constraints, what to focus on]
```

Keep prompts focused. If a task covers many files or multiple distinct concerns, split into separate batch jobs with clear labels.

## Checking results

When the user says "check", "status", "list", or asks about batch results:

1. Call `batch_poll_once` to check for any newly completed jobs
2. Call `batch_list` to show all jobs with their states
3. **Read results from disk** instead of calling `batch_fetch` — this saves tokens since `batch_fetch` returns the full text through MCP:
   - Job results live at `~/.claude/batches/results/<job_id>.md`
   - Read the file directly: `cat ~/.claude/batches/results/<job_id>.md`
   - This is especially important for large results
4. Present the results to the user in a readable format

**Status bar awareness**: The user's status bar already shows batch job counts (pending/done/failed). Don't repeat these counts — focus on presenting the actual results.

## Cost awareness

Batch API = **50% off** standard pricing:
- Claude Opus 4: $7.50 / $37.50 per million tokens (input/output)
- Claude Sonnet 4: $1.50 / $7.50 per million tokens (input/output)

Typical turnaround: under 1 hour. Max: 24 hours.

**Good batch candidates**: code reviews, documentation generation, architecture analysis, test generation, refactoring plans, security audits, bulk file analysis, API documentation, changelog generation.

**Bad batch candidates**: anything the user needs answered right now, interactive debugging, quick questions, tasks requiring back-and-forth.

## Error handling

- If `send_to_batch` fails with a connection error, the MCP server may not be running. Suggest: "Try restarting Claude Code, or run `uv run ~/.claude/mcp/claude_batch_mcp.py list` to check."
- If a job is stuck in "submitted" for >2 hours, suggest running `batch_poll_once` and checking `batch_status` with the job ID.
- If results are empty or show errors, check the raw JSONL at `~/.claude/batches/results/<job_id>.raw.jsonl`.

