#!/usr/bin/env bash
# claude-batch-toolkit status line with integrated cached poller
# Called by Claude Code for each assistant message.
# Reads JSON from stdin, renders status bar, optionally polls batch API in background.
#
# MUST NEVER block, crash, or produce stderr output that breaks Claude Code.

# ─── Configuration ──────────────────────────────────────────────────────────────
BATCHES_DIR="$HOME/.claude/batches"
JOBS_FILE="$BATCHES_DIR/jobs.json"
POLL_CACHE="$BATCHES_DIR/.poll_cache"
POLL_LOCK="$BATCHES_DIR/.poll.lock"
RESULTS_DIR="$BATCHES_DIR/results"
ENV_FILE="$HOME/.claude/env"
POLL_INTERVAL=60        # seconds between polls
LOCK_STALE_SECONDS=120  # consider lock stale after this

# ─── ANSI colors ────────────────────────────────────────────────────────────────
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_CYAN='\033[0;36m'
C_DIM='\033[2m'
C_BOLD='\033[1m'

# ─── Read stdin (Claude Code JSON) ─────────────────────────────────────────────
# Claude Code pipes a JSON object with model info, context %, cost.
# We read it all at once to avoid blocking.
INPUT=""
if ! read -t 1 -r INPUT; then
    INPUT="{}"
fi

# ─── Parse Claude Code JSON with jq ────────────────────────────────────────────
# Safely extract fields; default to empty/zero if missing
MODEL=""
CONTEXT_PCT=""
COST=""

if command -v jq &>/dev/null && [[ -n "$INPUT" ]]; then
    MODEL=$(echo "$INPUT" | jq -r '.model // empty' 2>/dev/null) || MODEL=""
    CONTEXT_PCT=$(echo "$INPUT" | jq -r '.contextPercent // empty' 2>/dev/null) || CONTEXT_PCT=""
    COST=$(echo "$INPUT" | jq -r '.cost // empty' 2>/dev/null) || COST=""
fi

# ─── Format model name (shorten) ───────────────────────────────────────────────
format_model() {
    local m="$1"
    case "$m" in
        *opus*)   echo "Opus" ;;
        *sonnet*) echo "Sonnet" ;;
        *haiku*)  echo "Haiku" ;;
        *)
            if [[ -n "$m" ]]; then
                echo "$m"
            fi
            ;;
    esac
}

MODEL_SHORT=$(format_model "$MODEL")

# ─── Read batch job counts from jobs.json ───────────────────────────────────────
PENDING=0
RUNNING=0
SUCCEEDED=0
FAILED=0
HAS_BATCH=0

if [[ -f "$JOBS_FILE" ]] && command -v jq &>/dev/null; then
    # Count jobs by state
    PENDING=$(jq '[.jobs // {} | to_entries[] | select(.value.state == "submitted")] | length' "$JOBS_FILE" 2>/dev/null) || PENDING=0
    RUNNING=$(jq '[.jobs // {} | to_entries[] | select(.value.state == "running")] | length' "$JOBS_FILE" 2>/dev/null) || RUNNING=0
    SUCCEEDED=$(jq '[.jobs // {} | to_entries[] | select(.value.state == "succeeded")] | length' "$JOBS_FILE" 2>/dev/null) || SUCCEEDED=0
    FAILED=$(jq '[.jobs // {} | to_entries[] | select(.value.state == "failed")] | length' "$JOBS_FILE" 2>/dev/null) || FAILED=0

    TOTAL=$((PENDING + RUNNING + SUCCEEDED + FAILED))
    if [[ "$TOTAL" -gt 0 ]]; then
        HAS_BATCH=1
    fi
fi

ACTIVE=$((PENDING + RUNNING))

# ─── Build status bar ──────────────────────────────────────────────────────────
STATUS_PARTS=()

# Model
if [[ -n "$MODEL_SHORT" ]]; then
    STATUS_PARTS+=("${C_CYAN}[${MODEL_SHORT}]${C_RESET}")
fi

# Context percentage
if [[ -n "$CONTEXT_PCT" ]]; then
    CTX_INT="${CONTEXT_PCT%.*}"
    if [[ -z "$CTX_INT" ]]; then
        CTX_INT=0
    fi
    if [[ "$CTX_INT" -ge 80 ]]; then
        STATUS_PARTS+=("${C_RED}${CTX_INT}%${C_RESET}")
    elif [[ "$CTX_INT" -ge 60 ]]; then
        STATUS_PARTS+=("${C_YELLOW}${CTX_INT}%${C_RESET}")
    else
        STATUS_PARTS+=("${CTX_INT}%")
    fi
fi

# Cost
if [[ -n "$COST" ]]; then
    STATUS_PARTS+=("\$${COST}")
fi

# Batch section
if [[ "$HAS_BATCH" -eq 1 ]]; then
    BATCH_PARTS=()

    if [[ "$ACTIVE" -gt 0 ]]; then
        BATCH_PARTS+=("${C_YELLOW}${ACTIVE} pending${C_RESET}")
    fi

    if [[ "$SUCCEEDED" -gt 0 ]]; then
        BATCH_PARTS+=("${C_GREEN}${SUCCEEDED} done${C_RESET}")
    fi

    if [[ "$FAILED" -gt 0 ]]; then
        BATCH_PARTS+=("${C_RED}${FAILED} failed${C_RESET}")
    fi

    if [[ ${#BATCH_PARTS[@]} -gt 0 ]]; then
        BATCH_STR=""
        for i in "${!BATCH_PARTS[@]}"; do
            if [[ "$i" -gt 0 ]]; then
                BATCH_STR+=", "
            fi
            BATCH_STR+="${BATCH_PARTS[$i]}"
        done
        STATUS_PARTS+=("${C_DIM}batch:${C_RESET} ${BATCH_STR}")
    fi
fi

# Join with separator
OUTPUT=""
for i in "${!STATUS_PARTS[@]}"; do
    if [[ "$i" -gt 0 ]]; then
        OUTPUT+=" ${C_DIM}|${C_RESET} "
    fi
    OUTPUT+="${STATUS_PARTS[$i]}"
done

# ─── Print status bar (synchronous — always immediate) ─────────────────────────
if [[ -n "$OUTPUT" ]]; then
    echo -e "$OUTPUT"
fi

# ─── Poll phase (async, forked background) ─────────────────────────────────────
# Only runs if:
# 1. There are pending/running jobs
# 2. Poll cache is stale (>POLL_INTERVAL seconds)
# 3. No other poll is already running

if [[ "$ACTIVE" -eq 0 ]]; then
    # No pending jobs — nothing to poll
    exit 0
fi

# Check if poll cache is fresh
if [[ -f "$POLL_CACHE" ]]; then
    NOW=$(date +%s)
    if [[ "$(uname)" == "Darwin" ]]; then
        CACHE_MTIME=$(stat -f %m "$POLL_CACHE" 2>/dev/null) || CACHE_MTIME=0
    else
        CACHE_MTIME=$(stat -c %Y "$POLL_CACHE" 2>/dev/null) || CACHE_MTIME=0
    fi
    CACHE_AGE=$((NOW - CACHE_MTIME))
    if [[ "$CACHE_AGE" -lt "$POLL_INTERVAL" ]]; then
        # Cache is fresh — skip poll
        exit 0
    fi
fi

# Touch cache file to mark poll time (prevents other invocations from polling)
mkdir -p "$BATCHES_DIR"
touch "$POLL_CACHE"

# ─── Fork background poll ──────────────────────────────────────────────────────
(
    # All errors swallowed — status line must never crash
    exec 2>/dev/null

    # ── Acquire lock (non-blocking) ──
    # Check for stale lock first
    if [[ -f "$POLL_LOCK" ]]; then
        NOW=$(date +%s)
        if [[ "$(uname)" == "Darwin" ]]; then
            LOCK_MTIME=$(stat -f %m "$POLL_LOCK" 2>/dev/null) || LOCK_MTIME=0
        else
            LOCK_MTIME=$(stat -c %Y "$POLL_LOCK" 2>/dev/null) || LOCK_MTIME=0
        fi
        LOCK_AGE=$((NOW - LOCK_MTIME))
        if [[ "$LOCK_AGE" -gt "$LOCK_STALE_SECONDS" ]]; then
            # Stale lock — previous poll probably died
            rm -f "$POLL_LOCK"
        else
            # Lock is held by another poll — exit
            exit 0
        fi
    fi

    # Try to create lock (atomic-ish via mkdir)
    if ! mkdir "$POLL_LOCK.d" 2>/dev/null; then
        # Another process beat us — exit
        exit 0
    fi
    # Use the directory as the lock; also create the file for mtime tracking
    touch "$POLL_LOCK"

    # Cleanup function
    cleanup_lock() {
        rm -f "$POLL_LOCK"
        rmdir "$POLL_LOCK.d" 2>/dev/null
    }
    trap cleanup_lock EXIT

    # ── Load API key ──
    ANTHROPIC_API_KEY=""
    if [[ -f "$ENV_FILE" ]]; then
        # Source the env file to get the API key
        # shellcheck disable=SC1090
        source "$ENV_FILE"
    fi

    if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
        exit 0
    fi

    # ── Find pending/running jobs ──
    if [[ ! -f "$JOBS_FILE" ]]; then
        exit 0
    fi

    # Get list of job IDs that are submitted or running, and their custom_ids
    PENDING_JOBS=$(jq -r '
        .jobs // {} | to_entries[]
        | select(.value.state == "submitted" or .value.state == "running")
        | select(.value.backend == "anthropic")
        | .key
    ' "$JOBS_FILE" 2>/dev/null) || exit 0

    if [[ -z "$PENDING_JOBS" ]]; then
        exit 0
    fi

    ANTHROPIC_VERSION="2023-06-01"
    JOBS_UPDATED=0

    while IFS= read -r JOB_ID; do
        [[ -z "$JOB_ID" ]] && continue

        # Get job status from API
        RESPONSE=$(curl -s --max-time 5 \
            -H "x-api-key: ${ANTHROPIC_API_KEY}" \
            -H "anthropic-version: ${ANTHROPIC_VERSION}" \
            "https://api.anthropic.com/v1/messages/batches/${JOB_ID}" 2>/dev/null) || continue

        # Check processing_status
        PROC_STATUS=$(echo "$RESPONSE" | jq -r '.processing_status // empty' 2>/dev/null) || continue

        if [[ "$PROC_STATUS" == "ended" ]]; then
            # Fetch results
            RESULTS_JSONL=$(curl -s --max-time 30 \
                -H "x-api-key: ${ANTHROPIC_API_KEY}" \
                -H "anthropic-version: ${ANTHROPIC_VERSION}" \
                "https://api.anthropic.com/v1/messages/batches/${JOB_ID}/results" 2>/dev/null) || continue

            if [[ -z "$RESULTS_JSONL" ]]; then
                continue
            fi

            # Get custom_id for this job
            CUSTOM_ID=$(jq -r --arg jid "$JOB_ID" '
                .jobs[$jid].anthropic_custom_id // empty
            ' "$JOBS_FILE" 2>/dev/null) || CUSTOM_ID=""

            # Save raw JSONL
            SAFE_ID="${JOB_ID//\//_}"
            mkdir -p "$RESULTS_DIR"
            echo "$RESULTS_JSONL" > "$RESULTS_DIR/${SAFE_ID}.raw.jsonl"

            # Extract text content from JSONL
            # For each line, find the matching custom_id (or take all), extract text blocks
            RESULT_TEXT=""
            while IFS= read -r LINE; do
                [[ -z "$LINE" ]] && continue

                # Check custom_id match if we have one
                if [[ -n "$CUSTOM_ID" ]]; then
                    LINE_CID=$(echo "$LINE" | jq -r '.custom_id // empty' 2>/dev/null) || continue
                    if [[ "$LINE_CID" != "$CUSTOM_ID" ]]; then
                        continue
                    fi
                fi

                # Check if result type is succeeded
                RESULT_TYPE=$(echo "$LINE" | jq -r '.result.type // empty' 2>/dev/null) || continue
                if [[ "$RESULT_TYPE" != "succeeded" ]]; then
                    # Save the error as the result
                    RESULT_TEXT=$(echo "$LINE" | jq '.' 2>/dev/null) || RESULT_TEXT="$LINE"
                    break
                fi

                # Extract text blocks from content array
                TEXTS=$(echo "$LINE" | jq -r '
                    .result.message.content[]
                    | select(.type == "text")
                    | .text
                ' 2>/dev/null) || continue

                if [[ -n "$TEXTS" ]]; then
                    if [[ -n "$RESULT_TEXT" ]]; then
                        RESULT_TEXT="${RESULT_TEXT}

${TEXTS}"
                    else
                        RESULT_TEXT="$TEXTS"
                    fi
                fi
            done <<< "$RESULTS_JSONL"

            # Write result markdown
            if [[ -n "$RESULT_TEXT" ]]; then
                echo "$RESULT_TEXT" > "$RESULTS_DIR/${SAFE_ID}.md"
                NEW_STATE="succeeded"
            else
                NEW_STATE="failed"
            fi

            # Update jobs.json — read, modify, write atomically
            UPDATED_JOBS=$(jq --arg jid "$JOB_ID" --arg state "$NEW_STATE" '
                .jobs[$jid].state = $state
            ' "$JOBS_FILE" 2>/dev/null) || continue

            if [[ -n "$UPDATED_JOBS" ]]; then
                # Atomic write via temp file
                echo "$UPDATED_JOBS" > "$JOBS_FILE.tmp"
                mv "$JOBS_FILE.tmp" "$JOBS_FILE"
                JOBS_UPDATED=$((JOBS_UPDATED + 1))
            fi

            # Update meta file
            RESULT_PATH="$RESULTS_DIR/${SAFE_ID}.md"
            META_PATH="$RESULTS_DIR/${SAFE_ID}.meta.json"
            if [[ -f "$META_PATH" ]]; then
                UPDATED_META=$(jq --arg state "$NEW_STATE" '.state = $state' "$META_PATH" 2>/dev/null) || true
                if [[ -n "$UPDATED_META" ]]; then
                    echo "$UPDATED_META" > "$META_PATH"
                fi
            fi

        elif [[ "$PROC_STATUS" == "in_progress" ]]; then
            # Update state to running if currently submitted
            CURRENT_STATE=$(jq -r --arg jid "$JOB_ID" '.jobs[$jid].state // empty' "$JOBS_FILE" 2>/dev/null) || continue
            if [[ "$CURRENT_STATE" == "submitted" ]]; then
                UPDATED_JOBS=$(jq --arg jid "$JOB_ID" '
                    .jobs[$jid].state = "running"
                ' "$JOBS_FILE" 2>/dev/null) || continue

                if [[ -n "$UPDATED_JOBS" ]]; then
                    echo "$UPDATED_JOBS" > "$JOBS_FILE.tmp"
                    mv "$JOBS_FILE.tmp" "$JOBS_FILE"
                fi
            fi
        fi
        # else: status is "created" or unknown — leave as-is, will check next time

    done <<< "$PENDING_JOBS"

) &
# Disown the background process so the shell doesn't wait for it
disown 2>/dev/null

exit 0
