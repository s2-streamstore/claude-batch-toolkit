#Requires -Version 5.1
# claude-batch-toolkit uninstaller for Windows
# Usage: .\uninstall.ps1 [-PurgeData] [-Unattended]

param(
    [switch]$PurgeData,
    [switch]$Unattended,
    [switch]$Help
)

$ErrorActionPreference = "Stop"

# --- Paths ------------------------------------------------------------------
$ClaudeDir    = Join-Path $HOME ".claude"
$BatchesDir   = Join-Path $ClaudeDir "batches"
$ResultsDir   = Join-Path $BatchesDir "results"
$ClaudeJson   = Join-Path $HOME ".claude.json"
$SettingsFile = Join-Path $ClaudeDir "settings.json"
$EnvFile      = Join-Path $ClaudeDir "env"

# --- Color helpers -----------------------------------------------------------
$Esc = [char]27
$C_Red    = "${Esc}[0;31m"
$C_Green  = "${Esc}[0;32m"
$C_Yellow = "${Esc}[0;33m"
$C_Cyan   = "${Esc}[0;36m"
$C_Bold   = "${Esc}[1m"
$C_NC     = "${Esc}[0m"

function Write-Info  { param([string]$Msg) Write-Host "${C_Cyan}[info]${C_NC}  $Msg" }
function Write-Ok    { param([string]$Msg) Write-Host "${C_Green}[ok]${C_NC}    $Msg" }
function Write-Warn  { param([string]$Msg) Write-Host "${C_Yellow}[warn]${C_NC}  $Msg" }
function Write-Err   { param([string]$Msg) [Console]::Error.WriteLine("${C_Red}[error]${C_NC} $Msg") }
function Stop-WithError { param([string]$Msg) Write-Err $Msg; exit 1 }

# --- Help --------------------------------------------------------------------
if ($Help) {
    Write-Host "Usage: .\uninstall.ps1 [-PurgeData] [-Unattended]"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -PurgeData     Also remove jobs.json and results/ (default: preserve)"
    Write-Host "  -Unattended    No interactive prompts"
    exit 0
}

# --- Pre-flight ---------------------------------------------------------------
Write-Host ""
Write-Host "${C_Bold}claude-batch-toolkit uninstaller${C_NC}"
Write-Host ([string][char]0x2500 * 33)
Write-Host ""

# --- Helpers ------------------------------------------------------------------
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory)][object]$JsonObject,
        [Parameter(Mandatory)][string]$Path
    )
    $tmpFile = "$Path.uninstall_tmp.$PID"
    try {
        $jsonString = $JsonObject | ConvertTo-Json -Depth 10
        $null = $jsonString | ConvertFrom-Json
        [System.IO.File]::WriteAllText($tmpFile, $jsonString, $Utf8NoBom)
        Move-Item -Force $tmpFile $Path
    } catch {
        Remove-Item -Force $tmpFile -ErrorAction SilentlyContinue
        Stop-WithError "BUG: Generated invalid JSON for $Path. Aborting."
    }
}

# --- Build change manifest ----------------------------------------------------
Write-Host "${C_Bold}Planned changes:${C_NC}"
Write-Host ""

$Changes = @()
$Warnings = @()

# 1. ~/.claude.json - remove mcpServers["claude-batch"] only
if (Test-Path $ClaudeJson) {
    try {
        $cjContent = Get-Content -Raw $ClaudeJson | ConvertFrom-Json
        if ($cjContent.mcpServers -and $cjContent.mcpServers.PSObject.Properties['claude-batch']) {
            $Changes += "BACKUP      $ClaudeJson -> ${ClaudeJson}.bak"
            $Changes += "MODIFY      $ClaudeJson  (remove mcpServers.claude-batch)"
        } else {
            $Changes += "NO CHANGE   $ClaudeJson  (claude-batch entry not found)"
        }
    } catch {
        $Warnings += "$ClaudeJson is not valid JSON - will skip modifying it"
    }
} else {
    $Changes += "NO CHANGE   $ClaudeJson  (file not found)"
}

# 2. settings.json - remove statusLine only if it points to our script
$StatuslinePath = Join-Path $ClaudeDir "statusline.ps1"
$StatusCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$StatuslinePath`""

if (Test-Path $SettingsFile) {
    try {
        $sfContent = Get-Content -Raw $SettingsFile | ConvertFrom-Json
        $existingStatusCmd = $null
        if ($sfContent.statusLine -and $sfContent.statusLine.command) {
            $existingStatusCmd = $sfContent.statusLine.command
        }
        if ($existingStatusCmd -eq $StatusCmd) {
            $Changes += "BACKUP      $SettingsFile -> ${SettingsFile}.bak"
            $Changes += "MODIFY      $SettingsFile  (remove statusLine)"
        } elseif ($existingStatusCmd) {
            $Changes += "NO CHANGE   $SettingsFile  (statusLine points to different script)"
        } else {
            $Changes += "NO CHANGE   $SettingsFile  (statusLine not set)"
        }
    } catch {
        $Warnings += "$SettingsFile is not valid JSON - will skip modifying it"
    }
} else {
    $Changes += "NO CHANGE   $SettingsFile  (file not found)"
}

# 3. Env file - remove ANTHROPIC_API_KEY line only
if (Test-Path $EnvFile) {
    $envContent = Get-Content -Path $EnvFile -ErrorAction SilentlyContinue
    $hasKey = $envContent | Where-Object { $_ -match '^export ANTHROPIC_API_KEY=' }
    if ($hasKey) {
        $otherLines = @($envContent | Where-Object {
            $_ -notmatch '^export ANTHROPIC_API_KEY=' -and $_.Trim()
        })
        if ($otherLines.Count -gt 0) {
            $Changes += "MODIFY      $EnvFile  (remove ANTHROPIC_API_KEY, preserve other vars)"
        } else {
            $Changes += "REMOVE      $EnvFile  (contains only ANTHROPIC_API_KEY)"
        }
    } else {
        $Changes += "NO CHANGE   $EnvFile  (ANTHROPIC_API_KEY not found)"
    }
} else {
    $Changes += "NO CHANGE   $EnvFile  (file not found)"
}

# 4. Toolkit files
$mcpFile   = Join-Path $ClaudeDir "mcp\claude_batch_mcp.py"
$skillFile = Join-Path $ClaudeDir "skills\batch\SKILL.md"
$slFile    = Join-Path $ClaudeDir "statusline.ps1"

if (Test-Path $mcpFile)   { $Changes += "REMOVE      $mcpFile" }
else                      { $Changes += "NO CHANGE   $mcpFile  (not found)" }

if (Test-Path $skillFile) { $Changes += "REMOVE      $skillFile" }
else                      { $Changes += "NO CHANGE   $skillFile  (not found)" }

if (Test-Path $slFile)    { $Changes += "REMOVE      $slFile" }
else                      { $Changes += "NO CHANGE   $slFile  (not found)" }

# 5. Poll cache and lock
$pollCache = Join-Path $BatchesDir ".poll_cache"
$pollLock  = Join-Path $BatchesDir ".poll.lock"
$pollLockD = Join-Path $BatchesDir ".poll.lock.d"

if (Test-Path $pollCache) { $Changes += "REMOVE      $pollCache" }
if (Test-Path $pollLock)  { $Changes += "REMOVE      $pollLock" }
if (Test-Path $pollLockD) { $Changes += "REMOVE      $pollLockD" }

# 6. Empty directory cleanup
foreach ($d in @(
    (Join-Path $ClaudeDir "mcp"),
    (Join-Path $ClaudeDir "skills\batch"),
    (Join-Path $ClaudeDir "skills")
)) {
    if (Test-Path $d) {
        $Changes += "RMDIR       $d  (only if empty after removal)"
    }
}

# 7. Data files
if ($PurgeData) {
    $jf = Join-Path $BatchesDir "jobs.json"
    if (Test-Path $jf) {
        $Changes += "REMOVE      $jf  (-PurgeData)"
    }
    if (Test-Path $ResultsDir) {
        $resultCount = @(Get-ChildItem -Path $ResultsDir -File -Recurse -ErrorAction SilentlyContinue).Count
        if ($resultCount -gt 0) {
            $Changes += "REMOVE      $ResultsDir  ($resultCount result file(s), -PurgeData)"
        } else {
            $Changes += "RMDIR       $ResultsDir  (empty, -PurgeData)"
        }
    }
    if (Test-Path $BatchesDir) {
        $Changes += "RMDIR       $BatchesDir  (only if empty after removal)"
    }
} else {
    $jf = Join-Path $BatchesDir "jobs.json"
    if (Test-Path $jf) {
        $Changes += "PRESERVE    $jf  (use -PurgeData to remove)"
    }
    if (Test-Path $ResultsDir) {
        $resultCount = @(Get-ChildItem -Path $ResultsDir -File -Recurse -ErrorAction SilentlyContinue).Count
        if ($resultCount -gt 0) {
            $Changes += "PRESERVE    $ResultsDir  ($resultCount result file(s), use -PurgeData to remove)"
        }
    }
}

# Print the manifest
foreach ($change in $Changes) {
    Write-Host "  ${C_Cyan}$([char]0x2022)${C_NC} $change"
}

if ($Warnings.Count -gt 0) {
    Write-Host ""
    foreach ($w in $Warnings) {
        Write-Warn $w
    }
}

Write-Host ""

# --- Confirm with user -------------------------------------------------------
if (-not $Unattended) {
    Write-Host -NoNewline "${C_Bold}Proceed with uninstall? [Y/n]${C_NC} "
    $confirm = Read-Host
    if ($confirm -and $confirm -notmatch '^[Yy]') {
        Write-Host "Aborted."
        exit 0
    }
    Write-Host ""
}

# --- Track removals -----------------------------------------------------------
$Removed = 0

# --- Remove MCP server registration from ~/.claude.json ----------------------
if (Test-Path $ClaudeJson) {
    try {
        $cjContent = Get-Content -Raw $ClaudeJson | ConvertFrom-Json
        if ($cjContent.mcpServers -and $cjContent.mcpServers.PSObject.Properties['claude-batch']) {
            Copy-Item -Path $ClaudeJson -Destination "${ClaudeJson}.bak"
            Write-Info "Backed up ${ClaudeJson} -> ${ClaudeJson}.bak"

            $cjContent.mcpServers.PSObject.Properties.Remove('claude-batch')

            Write-JsonAtomic -JsonObject $cjContent -Path $ClaudeJson
            Write-Ok "Removed claude-batch from $ClaudeJson"
            $Removed++
        } else {
            Write-Info "claude-batch not found in $ClaudeJson (already removed)"
        }
    } catch {
        Write-Warn "$ClaudeJson is not valid JSON - skipping"
    }
} else {
    Write-Info "$ClaudeJson not found"
}

# --- Remove statusLine from settings.json ------------------------------------
if (Test-Path $SettingsFile) {
    try {
        $sfContent = Get-Content -Raw $SettingsFile | ConvertFrom-Json
        $existingStatusCmd = $null
        if ($sfContent.statusLine -and $sfContent.statusLine.command) {
            $existingStatusCmd = $sfContent.statusLine.command
        }
        if ($existingStatusCmd -eq $StatusCmd) {
            Copy-Item -Path $SettingsFile -Destination "${SettingsFile}.bak"
            Write-Info "Backed up ${SettingsFile} -> ${SettingsFile}.bak"

            $sfContent.PSObject.Properties.Remove('statusLine')

            Write-JsonAtomic -JsonObject $sfContent -Path $SettingsFile
            Write-Ok "Removed statusLine from $SettingsFile"
            $Removed++
        } elseif ($existingStatusCmd) {
            Write-Info "statusLine points to a different script - leaving as-is"
        } else {
            Write-Info "statusLine not set in $SettingsFile"
        }
    } catch {
        Write-Warn "$SettingsFile is not valid JSON - skipping"
    }
} else {
    Write-Info "$SettingsFile not found"
}

# --- Remove ANTHROPIC_API_KEY from env file -----------------------------------
if (Test-Path $EnvFile) {
    $envLines = @(Get-Content -Path $EnvFile)
    $hasKey = $envLines | Where-Object { $_ -match '^export ANTHROPIC_API_KEY=' }
    if ($hasKey) {
        $filtered = @($envLines | Where-Object { $_ -notmatch '^export ANTHROPIC_API_KEY=' })
        $meaningful = @($filtered | Where-Object { $_.Trim() })

        if ($meaningful.Count -gt 0) {
            $tmpFile = "$EnvFile.uninstall_tmp.$PID"
            [System.IO.File]::WriteAllText($tmpFile, ($filtered -join "`n") + "`n", $Utf8NoBom)
            Move-Item -Force $tmpFile $EnvFile
            Write-Ok "Removed ANTHROPIC_API_KEY from $EnvFile (other vars preserved)"
        } else {
            Remove-Item -Force $EnvFile
            Write-Ok "Removed $EnvFile (contained only ANTHROPIC_API_KEY)"
        }
        $Removed++
    } else {
        Write-Info "ANTHROPIC_API_KEY not found in $EnvFile"
    }
} else {
    Write-Info "$EnvFile not found"
}

# --- Remove toolkit files -----------------------------------------------------
if (Test-Path $mcpFile) {
    Remove-Item -Force $mcpFile
    Write-Ok "Removed $mcpFile"
    $Removed++
}

if (Test-Path $skillFile) {
    Remove-Item -Force $skillFile
    Write-Ok "Removed $skillFile"
    $Removed++
}

if (Test-Path $slFile) {
    Remove-Item -Force $slFile
    Write-Ok "Removed $slFile"
    $Removed++
}

# --- Remove poll cache and lock files -----------------------------------------
if (Test-Path $pollCache) {
    Remove-Item -Force $pollCache
    Write-Info "Removed poll cache"
}
if (Test-Path $pollLock) {
    Remove-Item -Force $pollLock
    Write-Info "Removed poll lock"
}
if (Test-Path $pollLockD) {
    Remove-Item -Force $pollLockD -Recurse
    Write-Info "Removed poll lock directory"
}

# --- Clean up empty directories -----------------------------------------------
foreach ($d in @(
    (Join-Path $ClaudeDir "mcp"),
    (Join-Path $ClaudeDir "skills\batch"),
    (Join-Path $ClaudeDir "skills")
)) {
    if ((Test-Path $d) -and @(Get-ChildItem $d -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item $d
        Write-Info "Removed empty directory $d"
    }
}

# --- Handle data files --------------------------------------------------------
if ($PurgeData) {
    if (Test-Path $ResultsDir) {
        $resultCount = @(Get-ChildItem -Path $ResultsDir -File -Recurse -ErrorAction SilentlyContinue).Count
        if ($resultCount -gt 0) {
            Get-ChildItem -Path $ResultsDir -File -Recurse | Remove-Item -Force
            Write-Ok "Removed $resultCount result file(s) from $ResultsDir"
        }
        # Remove empty subdirectories bottom-up
        Get-ChildItem -Path $ResultsDir -Directory -Recurse -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } -Descending |
            ForEach-Object {
                if (@(Get-ChildItem $_.FullName -ErrorAction SilentlyContinue).Count -eq 0) {
                    Remove-Item $_.FullName
                }
            }
        if ((Test-Path $ResultsDir) -and @(Get-ChildItem $ResultsDir -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item $ResultsDir
            Write-Info "Removed empty directory $ResultsDir"
        }
    }

    $jf = Join-Path $BatchesDir "jobs.json"
    if (Test-Path $jf) {
        Remove-Item -Force $jf
        Write-Ok "Removed $jf"
    }

    if ((Test-Path $BatchesDir) -and @(Get-ChildItem $BatchesDir -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item $BatchesDir
        Write-Info "Removed empty directory $BatchesDir"
    }
} else {
    if (Test-Path $ResultsDir) {
        $resultCount = @(Get-ChildItem -Path $ResultsDir -File -Recurse -ErrorAction SilentlyContinue).Count
        if ($resultCount -gt 0) {
            Write-Warn "Preserving $resultCount result file(s) in $ResultsDir"
        }
    }
    $jf = Join-Path $BatchesDir "jobs.json"
    if (Test-Path $jf) {
        Write-Warn "Preserving $jf"
    }
}

# --- Done ---------------------------------------------------------------------
Write-Host ""
Write-Host ([string][char]0x2500 * 33)
if ($Removed -gt 0) {
    Write-Host "${C_Green}${C_Bold}Uninstall complete!${C_NC}"
} else {
    Write-Host "${C_Yellow}${C_Bold}Nothing to uninstall (toolkit files not found).${C_NC}"
}
Write-Host ""

if (-not $PurgeData) {
    Write-Host "Preserved:"
    Write-Host "  * Results:   $ResultsDir"
    Write-Host "  * Jobs log:  $(Join-Path $BatchesDir 'jobs.json')"
    Write-Host ""
    Write-Host "To fully remove all data:"
    Write-Host "  .\uninstall.ps1 -PurgeData -Unattended"
    Write-Host ""
} else {
    Write-Host "All toolkit files and data have been removed."
    Write-Host ""
}
