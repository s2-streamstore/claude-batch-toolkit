#Requires -Version 5.1
# claude-batch-toolkit status line with integrated cached poller
# Called by Claude Code for each assistant message.
# Reads JSON from stdin, renders status bar, optionally polls batch API in background.
#
# MUST NEVER block, crash, or produce stderr output that breaks Claude Code.

param(
    [switch]$Poll   # Internal: run poll logic (launched by the render pass)
)

$ErrorActionPreference = "SilentlyContinue"

# --- Configuration -----------------------------------------------------------
$BatchesDir   = Join-Path $HOME ".claude\batches"
$JobsFile     = Join-Path $BatchesDir "jobs.json"
$PollCache    = Join-Path $BatchesDir ".poll_cache"
$PollLock     = Join-Path $BatchesDir ".poll.lock"
$ResultsDir   = Join-Path $BatchesDir "results"
$EnvFile      = Join-Path $HOME ".claude\env"
$PollInterval = 60        # seconds between polls
$LockStaleS   = 120       # consider lock stale after this

# --- ANSI colors -------------------------------------------------------------
$E = [char]27
$C_Reset  = "${E}[0m"
$C_Red    = "${E}[0;31m"
$C_Green  = "${E}[0;32m"
$C_Yellow = "${E}[0;33m"
$C_Cyan   = "${E}[0;36m"
$C_Dim    = "${E}[2m"
$C_Bold   = "${E}[1m"

# --- .env reader -------------------------------------------------------------
function Read-DotEnv {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path $Path)) { return $null }
    foreach ($line in (Get-Content $Path -ErrorAction SilentlyContinue)) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        $prefix = '^(?:export\s+)?' + [regex]::Escape($Key) + '=(.*)'
        if ($trimmed -match $prefix) {
            $val = $Matches[1].Trim()
            if ($val.Length -ge 2) {
                if (($val[0] -eq "'" -and $val[-1] -eq "'") -or
                    ($val[0] -eq '"' -and $val[-1] -eq '"')) {
                    return $val.Substring(1, $val.Length - 2)
                }
            }
            return $val
        }
    }
    return $null
}

# =============================================================================
# POLL MODE - background API polling (launched as a hidden process)
# =============================================================================
if ($Poll) {
    try {
        # -- Acquire lock (non-blocking) --
        if (Test-Path $PollLock) {
            $lockAge = ((Get-Date) - (Get-Item $PollLock).LastWriteTime).TotalSeconds
            if ($lockAge -gt $LockStaleS) {
                Remove-Item -Force $PollLock -ErrorAction SilentlyContinue
                Remove-Item -Force "$PollLock.d" -Recurse -ErrorAction SilentlyContinue
            } else {
                exit 0  # lock held by another poll
            }
        }

        try {
            New-Item -ItemType Directory -Path "$PollLock.d" -ErrorAction Stop | Out-Null
        } catch {
            exit 0  # another process beat us
        }
        # Track via file mtime
        Set-Content -Path $PollLock -Value "" -ErrorAction SilentlyContinue

        try {
            # -- Load API key --
            $apiKey = $env:ANTHROPIC_API_KEY
            if (-not $apiKey) { $apiKey = Read-DotEnv -Path $EnvFile -Key "ANTHROPIC_API_KEY" }
            if (-not $apiKey) { $apiKey = Read-DotEnv -Path (Join-Path $HOME ".claude\.env") -Key "ANTHROPIC_API_KEY" }
            if (-not $apiKey) { exit 0 }

            # -- Find pending/running jobs --
            if (-not (Test-Path $JobsFile)) { exit 0 }

            $Utf8NoBom = New-Object System.Text.UTF8Encoding $false
            $jobsData = Get-Content -Raw $JobsFile | ConvertFrom-Json
            if (-not $jobsData.jobs) { exit 0 }

            $pendingJobs = @($jobsData.jobs.PSObject.Properties | Where-Object {
                ($_.Value.state -eq "submitted" -or $_.Value.state -eq "running") -and
                $_.Value.backend -eq "anthropic"
            })

            if ($pendingJobs.Count -eq 0) { exit 0 }

            $headers = @{
                "x-api-key"         = $apiKey
                "anthropic-version" = "2023-06-01"
            }

            foreach ($job in $pendingJobs) {
                $jobId = $job.Name
                try {
                    $response = Invoke-RestMethod `
                        -Uri "https://api.anthropic.com/v1/messages/batches/$jobId" `
                        -Headers $headers -TimeoutSec 5

                    $procStatus = $response.processing_status

                    if ($procStatus -eq "ended") {
                        # Fetch results (JSONL)
                        try {
                            $resultsResp = Invoke-WebRequest `
                                -Uri "https://api.anthropic.com/v1/messages/batches/$jobId/results" `
                                -Headers $headers -TimeoutSec 30
                            $resultsJsonl = $resultsResp.Content
                        } catch { continue }

                        if (-not $resultsJsonl) { continue }

                        $customId = $jobsData.jobs.$jobId.anthropic_custom_id
                        $safeId = $jobId -replace '[/\\]', '_'
                        New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null

                        # Save raw JSONL
                        [System.IO.File]::WriteAllText(
                            (Join-Path $ResultsDir "$safeId.raw.jsonl"),
                            $resultsJsonl, $Utf8NoBom)

                        # Extract text content
                        $resultText = ""
                        foreach ($line in ($resultsJsonl -split "`n")) {
                            if (-not $line.Trim()) { continue }
                            try { $lineObj = $line | ConvertFrom-Json } catch { continue }

                            if ($customId -and $lineObj.custom_id -ne $customId) { continue }

                            if ($lineObj.result.type -ne "succeeded") {
                                $resultText = $line | ConvertFrom-Json | ConvertTo-Json -Depth 10
                                break
                            }

                            foreach ($block in $lineObj.result.message.content) {
                                if ($block.type -eq "text" -and $block.text) {
                                    if ($resultText) { $resultText += "`n`n" }
                                    $resultText += $block.text
                                }
                            }
                        }

                        $newState = if ($resultText) { "succeeded" } else { "failed" }

                        if ($resultText) {
                            [System.IO.File]::WriteAllText(
                                (Join-Path $ResultsDir "$safeId.md"),
                                $resultText, $Utf8NoBom)
                        }

                        # Update jobs.json atomically
                        $jobsData.jobs.$jobId.state = $newState
                        $tmpPath = "$JobsFile.tmp"
                        $jsonOut = $jobsData | ConvertTo-Json -Depth 10
                        [System.IO.File]::WriteAllText($tmpPath, $jsonOut, $Utf8NoBom)
                        Move-Item -Force $tmpPath $JobsFile

                        # Update meta file if present
                        $metaPath = Join-Path $ResultsDir "$safeId.meta.json"
                        if (Test-Path $metaPath) {
                            try {
                                $meta = Get-Content -Raw $metaPath | ConvertFrom-Json
                                $meta.state = $newState
                                $meta | ConvertTo-Json -Depth 10 |
                                    ForEach-Object { [System.IO.File]::WriteAllText($metaPath, $_, $Utf8NoBom) }
                            } catch {}
                        }

                    } elseif ($procStatus -eq "in_progress") {
                        if ($jobsData.jobs.$jobId.state -eq "submitted") {
                            $jobsData.jobs.$jobId.state = "running"
                            $tmpPath = "$JobsFile.tmp"
                            $jsonOut = $jobsData | ConvertTo-Json -Depth 10
                            [System.IO.File]::WriteAllText($tmpPath, $jsonOut, $Utf8NoBom)
                            Move-Item -Force $tmpPath $JobsFile
                        }
                    }
                } catch {
                    continue
                }
            }
        } finally {
            # Release lock
            Remove-Item -Force $PollLock -ErrorAction SilentlyContinue
            Remove-Item -Force "$PollLock.d" -Recurse -ErrorAction SilentlyContinue
        }
    } catch {}

    exit 0
}

# =============================================================================
# RENDER MODE - read stdin, show status bar, optionally launch poll
# =============================================================================

# --- Read stdin (Claude Code JSON) -------------------------------------------
$InputText = ""
try {
    $collected = @($input)
    if ($collected.Count -gt 0) {
        $InputText = $collected -join "`n"
    }
} catch {}

# --- Parse Claude Code JSON --------------------------------------------------
$Model = ""
$ContextPct = ""
$Cost = ""

if ($InputText.Trim()) {
    try {
        $data = $InputText | ConvertFrom-Json
        if ($data.model)          { $Model = "$($data.model)" }
        if ($null -ne $data.contextPercent) { $ContextPct = "$($data.contextPercent)" }
        if ($null -ne $data.cost) { $Cost = "$($data.cost)" }
    } catch {}
}

# --- Format model name -------------------------------------------------------
$ModelShort = ""
if ($Model) {
    if     ($Model -match 'opus')   { $ModelShort = "Opus" }
    elseif ($Model -match 'sonnet') { $ModelShort = "Sonnet" }
    elseif ($Model -match 'haiku')  { $ModelShort = "Haiku" }
    else                            { $ModelShort = $Model }
}

# --- Read batch job counts from jobs.json ------------------------------------
$Pending   = 0
$Running   = 0
$Succeeded = 0
$Failed    = 0
$HasBatch  = $false

if (Test-Path $JobsFile) {
    try {
        $jobsData = Get-Content -Raw $JobsFile | ConvertFrom-Json
        if ($jobsData.jobs) {
            $entries = @($jobsData.jobs.PSObject.Properties)
            $Pending   = @($entries | Where-Object { $_.Value.state -eq 'submitted' }).Count
            $Running   = @($entries | Where-Object { $_.Value.state -eq 'running'   }).Count
            $Succeeded = @($entries | Where-Object { $_.Value.state -eq 'succeeded' }).Count
            $Failed    = @($entries | Where-Object { $_.Value.state -eq 'failed'    }).Count

            if (($Pending + $Running + $Succeeded + $Failed) -gt 0) {
                $HasBatch = $true
            }
        }
    } catch {}
}

$Active = $Pending + $Running

# --- Build status bar --------------------------------------------------------
$StatusParts = @()

# Model
if ($ModelShort) {
    $StatusParts += "${C_Cyan}[${ModelShort}]${C_Reset}"
}

# Context percentage
if ($ContextPct) {
    $ctxInt = [int][Math]::Floor([double]$ContextPct)
    if ($ctxInt -ge 80) {
        $StatusParts += "${C_Red}${ctxInt}%${C_Reset}"
    } elseif ($ctxInt -ge 60) {
        $StatusParts += "${C_Yellow}${ctxInt}%${C_Reset}"
    } else {
        $StatusParts += "${ctxInt}%"
    }
}

# Cost
if ($Cost) {
    $StatusParts += "`$$Cost"
}

# Batch section
if ($HasBatch) {
    $batchParts = @()

    if ($Active -gt 0)    { $batchParts += "${C_Yellow}${Active} pending${C_Reset}" }
    if ($Succeeded -gt 0) { $batchParts += "${C_Green}${Succeeded} done${C_Reset}" }
    if ($Failed -gt 0)    { $batchParts += "${C_Red}${Failed} failed${C_Reset}" }

    if ($batchParts.Count -gt 0) {
        $batchStr = $batchParts -join ", "
        $StatusParts += "${C_Dim}batch:${C_Reset} $batchStr"
    }
}

# Join with separator
$Output = $StatusParts -join " ${C_Dim}|${C_Reset} "

# --- Print status bar (synchronous - always immediate) -----------------------
if ($Output) {
    [Console]::Out.WriteLine($Output)
}

# --- Poll phase (async, hidden background process) ---------------------------
if ($Active -eq 0) {
    exit 0
}

# Check if poll cache is fresh
if (Test-Path $PollCache) {
    $cacheAge = ((Get-Date) - (Get-Item $PollCache).LastWriteTime).TotalSeconds
    if ($cacheAge -lt $PollInterval) {
        exit 0  # cache is fresh
    }
}

# Touch cache file to mark poll time
New-Item -ItemType Directory -Force -Path $BatchesDir | Out-Null
Set-Content -Path $PollCache -Value ""

# Launch background poll as hidden process
try {
    $scriptPath = $MyInvocation.MyCommand.Path
    Start-Process -WindowStyle Hidden -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $scriptPath,
        "-Poll"
    )
} catch {}

exit 0
