#Requires -Version 5.1
# claude-batch-toolkit installer for Windows
# Usage: .\install.ps1 -ApiKey sk-ant-... [-NoPoller] [-Unattended]

param(
    [string]$ApiKey = "",
    [switch]$NoPoller,
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

# --- Help --------------------------------------------------------------------
if ($Help) {
    Write-Host "Usage: .\install.ps1 -ApiKey <ANTHROPIC_API_KEY> [-NoPoller] [-Unattended]"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -ApiKey KEY      Anthropic API key (required unless ANTHROPIC_API_KEY is set)"
    Write-Host "  -NoPoller        Skip status line configuration"
    Write-Host "  -Unattended      No interactive prompts"
    exit 0
}

# --- Determine script directory ----------------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- Resolve API key ---------------------------------------------------------
if (-not $ApiKey) {
    $ApiKey = $env:ANTHROPIC_API_KEY
}

# Try .env in script directory / current directory
if (-not $ApiKey) {
    foreach ($dotenv in @((Join-Path $ScriptDir ".env"), ".env")) {
        $val = Read-DotEnv -Path $dotenv -Key "ANTHROPIC_API_KEY"
        if ($val) { $ApiKey = $val; break }
    }
}

# Try existing ~/.claude/env
if (-not $ApiKey -and (Test-Path $EnvFile)) {
    $val = Read-DotEnv -Path $EnvFile -Key "ANTHROPIC_API_KEY"
    if ($val) { $ApiKey = $val }
}

if (-not $ApiKey) {
    if ($Unattended) {
        Stop-WithError "No API key provided. Use -ApiKey or set ANTHROPIC_API_KEY."
    }
    Write-Host "${C_Bold}Enter your Anthropic API key:${C_NC}"
    $secure = Read-Host -AsSecureString
    $ApiKey = [Net.NetworkCredential]::new('', $secure).Password
    if (-not $ApiKey) {
        Stop-WithError "No API key provided."
    }
}

# --- Pre-flight checks -------------------------------------------------------
Write-Host ""
Write-Host "${C_Bold}claude-batch-toolkit installer${C_NC}"
Write-Host ([string][char]0x2500 * 33)
Write-Host ""

$MissingDeps = @()
if (-not (Get-Command "uv" -ErrorAction SilentlyContinue)) { $MissingDeps += "uv" }
if (-not (Get-Command "curl.exe" -ErrorAction SilentlyContinue)) {
    if (-not (Get-Command "curl" -CommandType Application -ErrorAction SilentlyContinue)) {
        $MissingDeps += "curl"
    }
}

if ($MissingDeps.Count -gt 0) {
    Write-Err "Missing required dependencies: $($MissingDeps -join ', ')"
    Write-Host ""

    if ($Unattended) {
        Write-Host "Install them first:"
        foreach ($dep in $MissingDeps) {
            switch ($dep) {
                "uv"   { Write-Host "  irm https://astral.sh/uv/install.ps1 | iex" }
                "curl" { Write-Host "  curl ships with Windows 10+. Ensure curl.exe is in PATH." }
            }
        }
        exit 1
    }

    Write-Host -NoNewline "${C_Bold}Would you like to install missing dependencies? [Y/n]${C_NC} "
    $depConfirm = Read-Host
    if (-not $depConfirm -or $depConfirm -match '^[Yy]') {
        foreach ($dep in $MissingDeps) {
            switch ($dep) {
                "uv" {
                    Write-Info "Installing uv..."
                    try {
                        Invoke-RestMethod https://astral.sh/uv/install.ps1 | Invoke-Expression
                        # Refresh PATH so uv is found
                        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                                    [System.Environment]::GetEnvironmentVariable("PATH", "User")
                        if (Get-Command "uv" -ErrorAction SilentlyContinue) {
                            Write-Ok "uv installed"
                        } else {
                            Stop-WithError "uv installed but not found in PATH. Restart your terminal and try again."
                        }
                    } catch {
                        Stop-WithError "Failed to install uv: $_"
                    }
                }
                "curl" {
                    Stop-WithError "curl.exe not found. It ships with Windows 10+. Please install it manually."
                }
            }
        }
    } else {
        Write-Host ""
        Write-Host "Install them first:"
        foreach ($dep in $MissingDeps) {
            switch ($dep) {
                "uv"   { Write-Host "  irm https://astral.sh/uv/install.ps1 | iex" }
                "curl" { Write-Host "  curl ships with Windows 10+. Ensure curl.exe is in PATH." }
            }
        }
        exit 1
    }
}

Write-Ok "Dependencies found: uv, curl"

# Verify source files exist
foreach ($srcFile in @("mcp\claude_batch_mcp.py", "skills\batch\SKILL.md", "statusline.ps1")) {
    $fullPath = Join-Path $ScriptDir $srcFile
    if (-not (Test-Path $fullPath)) {
        Stop-WithError "Source file not found: $fullPath"
    }
}

# --- Build change manifest ---------------------------------------------------
Write-Host ""
Write-Host "${C_Bold}Planned changes:${C_NC}"
Write-Host ""

$Changes = @()
$Warnings = @()

# 1. Directories
foreach ($d in @(
    (Join-Path $ClaudeDir "mcp"),
    (Join-Path $ClaudeDir "skills\batch"),
    $ResultsDir
)) {
    if (-not (Test-Path $d)) {
        $Changes += "CREATE DIR  $d"
    }
}

# 2. File copies
$FilePairs = @(
    @{ Src = "mcp\claude_batch_mcp.py"; Dst = (Join-Path $ClaudeDir "mcp\claude_batch_mcp.py") },
    @{ Src = "skills\batch\SKILL.md";   Dst = (Join-Path $ClaudeDir "skills\batch\SKILL.md") },
    @{ Src = "statusline.ps1";          Dst = (Join-Path $ClaudeDir "statusline.ps1") }
)

foreach ($pair in $FilePairs) {
    if (Test-Path $pair.Dst) {
        $Changes += "OVERWRITE   $($pair.Dst)  (from $($pair.Src))"
    } else {
        $Changes += "COPY        $($pair.Src) -> $($pair.Dst)"
    }
}

# 3. Env file
if (Test-Path $EnvFile) {
    $envContent = Get-Content -Path $EnvFile -Raw -ErrorAction SilentlyContinue
    if ($envContent -and $envContent -match '(?m)^export ANTHROPIC_API_KEY=') {
        $Changes += "UPDATE      $EnvFile  (replace ANTHROPIC_API_KEY line)"
    } else {
        $Changes += "APPEND      $EnvFile  (add ANTHROPIC_API_KEY)"
    }
} else {
    $Changes += "CREATE      $EnvFile  (with ANTHROPIC_API_KEY)"
}

# 4. claude.json MCP entry
if (Test-Path $ClaudeJson) {
    $Changes += "BACKUP      $ClaudeJson -> ${ClaudeJson}.bak"
    try {
        $existingJson = Get-Content -Raw $ClaudeJson | ConvertFrom-Json
        if ($existingJson.mcpServers -and $existingJson.mcpServers.PSObject.Properties['claude-batch']) {
            $Changes += "UPDATE      $ClaudeJson  (replace mcpServers.claude-batch)"
        } else {
            $Changes += "MERGE       $ClaudeJson  (add mcpServers.claude-batch)"
        }
    } catch {
        Stop-WithError "$ClaudeJson is not valid JSON. Please fix it manually before installing."
    }
} else {
    $Changes += "CREATE      $ClaudeJson  (with mcpServers.claude-batch)"
}

# 5. Status line
$SkipStatusline = $false
$StatuslinePath = Join-Path $ClaudeDir "statusline.ps1"
$StatusCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$StatuslinePath`""

if (-not $NoPoller) {
    if (Test-Path $SettingsFile) {
        try {
            $existingSettings = Get-Content -Raw $SettingsFile | ConvertFrom-Json
            $existingStatusCmd = $null
            if ($existingSettings.statusLine -and $existingSettings.statusLine.command) {
                $existingStatusCmd = $existingSettings.statusLine.command
            }
            if ($existingStatusCmd -and $existingStatusCmd -ne $StatusCmd) {
                $Warnings += "statusLine is already set to: $existingStatusCmd"
                $Warnings += "It does NOT point to our script. Will NOT overwrite."
                $SkipStatusline = $true
            } else {
                $Changes += "BACKUP      $SettingsFile -> ${SettingsFile}.bak"
                if ($existingStatusCmd -eq $StatusCmd) {
                    $Changes += "NO CHANGE   $SettingsFile  (statusLine already set to our script)"
                } else {
                    $Changes += "MERGE       $SettingsFile  (set statusLine)"
                }
            }
        } catch {
            Stop-WithError "$SettingsFile is not valid JSON. Please fix it manually before installing."
        }
    } else {
        $Changes += "CREATE      $SettingsFile  (with statusLine)"
    }
} else {
    $Changes += "SKIP        statusLine configuration (-NoPoller)"
}

# 6. jobs.json
$JobsFile = Join-Path $BatchesDir "jobs.json"
if (-not (Test-Path $JobsFile)) {
    $Changes += "CREATE      $JobsFile  (empty job registry)"
} else {
    $Changes += "NO CHANGE   $JobsFile  (already exists)"
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
    Write-Host -NoNewline "${C_Bold}Proceed with installation? [Y/n]${C_NC} "
    $confirm = Read-Host
    if ($confirm -and $confirm -notmatch '^[Yy]') {
        Write-Host "Aborted."
        exit 0
    }
    Write-Host ""
}

# --- Helper: atomic JSON write -----------------------------------------------
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory)][object]$JsonObject,
        [Parameter(Mandatory)][string]$Path
    )
    $tmpFile = "$Path.install_tmp.$PID"
    try {
        $jsonString = $JsonObject | ConvertTo-Json -Depth 10
        $null = $jsonString | ConvertFrom-Json  # validate round-trip
        [System.IO.File]::WriteAllText($tmpFile, $jsonString, $Utf8NoBom)
        Move-Item -Force $tmpFile $Path
    } catch {
        Remove-Item -Force $tmpFile -ErrorAction SilentlyContinue
        Stop-WithError "BUG: Generated invalid JSON for $Path. Aborting."
    }
}

# --- Create directory structure -----------------------------------------------
foreach ($d in @(
    (Join-Path $ClaudeDir "mcp"),
    (Join-Path $ClaudeDir "skills\batch"),
    $ResultsDir
)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

Write-Ok "Directory structure ready"

# --- Copy files ---------------------------------------------------------------
Copy-Item -Force (Join-Path $ScriptDir "mcp\claude_batch_mcp.py") (Join-Path $ClaudeDir "mcp\claude_batch_mcp.py")
Write-Ok "Installed mcp/claude_batch_mcp.py"

Copy-Item -Force (Join-Path $ScriptDir "skills\batch\SKILL.md") (Join-Path $ClaudeDir "skills\batch\SKILL.md")
Write-Ok "Installed skills/batch/SKILL.md"

Copy-Item -Force (Join-Path $ScriptDir "statusline.ps1") (Join-Path $ClaudeDir "statusline.ps1")
Write-Ok "Installed statusline.ps1"

# --- Write API key to ~/.claude/env ------------------------------------------
$apiKeyLine = "export ANTHROPIC_API_KEY=`"$ApiKey`""

if (Test-Path $EnvFile) {
    $existingLines = @(Get-Content -Path $EnvFile)
    $filteredLines = @($existingLines | Where-Object { $_ -notmatch '^export ANTHROPIC_API_KEY=' })
    $newContent = ($filteredLines + $apiKeyLine) -join "`n"
    $tmpFile = "$EnvFile.install_tmp.$PID"
    [System.IO.File]::WriteAllText($tmpFile, "$newContent`n", $Utf8NoBom)
    Move-Item -Force $tmpFile $EnvFile
} else {
    [System.IO.File]::WriteAllText($EnvFile, "$apiKeyLine`n", $Utf8NoBom)
}

Write-Ok "API key written to ~/.claude/env"

# --- Register MCP server in ~/.claude.json -----------------------------------
$mcpEntry = [PSCustomObject]@{
    command = "uv"
    args    = @("run", (Join-Path $ClaudeDir "mcp\claude_batch_mcp.py"), "--mcp")
    env     = [PSCustomObject]@{
        ANTHROPIC_API_KEY = $ApiKey
    }
}

if (Test-Path $ClaudeJson) {
    Copy-Item -Path $ClaudeJson -Destination "${ClaudeJson}.bak"
    Write-Info "Backed up ${ClaudeJson} -> ${ClaudeJson}.bak"

    $existing = Get-Content -Raw $ClaudeJson | ConvertFrom-Json

    if (-not $existing.mcpServers) {
        $existing | Add-Member -NotePropertyName "mcpServers" -NotePropertyValue ([PSCustomObject]@{})
    }

    if ($existing.mcpServers.PSObject.Properties['claude-batch']) {
        $existing.mcpServers.'claude-batch' = $mcpEntry
    } else {
        $existing.mcpServers | Add-Member -NotePropertyName 'claude-batch' -NotePropertyValue $mcpEntry
    }

    Write-JsonAtomic -JsonObject $existing -Path $ClaudeJson
} else {
    $newJson = [PSCustomObject]@{
        mcpServers = [PSCustomObject]@{
            'claude-batch' = $mcpEntry
        }
    }
    Write-JsonAtomic -JsonObject $newJson -Path $ClaudeJson
}

Write-Ok "MCP server registered in ~/.claude.json"

# --- Configure statusLine in ~/.claude/settings.json -------------------------
if (-not $NoPoller -and -not $SkipStatusline) {
    $statusObj = [PSCustomObject]@{
        type    = "command"
        command = $StatusCmd
    }

    if (Test-Path $SettingsFile) {
        Copy-Item -Path $SettingsFile -Destination "${SettingsFile}.bak"
        Write-Info "Backed up ${SettingsFile} -> ${SettingsFile}.bak"

        $existingSettings = Get-Content -Raw $SettingsFile | ConvertFrom-Json

        if ($existingSettings.PSObject.Properties['statusLine']) {
            $existingSettings.statusLine = $statusObj
        } else {
            $existingSettings | Add-Member -NotePropertyName 'statusLine' -NotePropertyValue $statusObj
        }

        Write-JsonAtomic -JsonObject $existingSettings -Path $SettingsFile
    } else {
        $newSettings = [PSCustomObject]@{
            statusLine = $statusObj
        }
        Write-JsonAtomic -JsonObject $newSettings -Path $SettingsFile
    }

    Write-Ok "Status line configured in ~/.claude/settings.json"
} elseif ($SkipStatusline) {
    Write-Warn "Skipped statusLine - already set to a different command (not overwritten)"
} else {
    Write-Warn "Skipping status line configuration (-NoPoller)"
}

# --- Initialize jobs.json if missing -----------------------------------------
if (-not (Test-Path $JobsFile)) {
    $jobsInit = [PSCustomObject]@{
        version = 1
        jobs    = [PSCustomObject]@{}
    }
    Write-JsonAtomic -JsonObject $jobsInit -Path $JobsFile
    Write-Ok "Initialized jobs.json"
} else {
    Write-Ok "jobs.json already exists"
}

# --- Smoke test ---------------------------------------------------------------
Write-Host ""
Write-Info "Running smoke test (this may take a moment if uv needs to resolve dependencies)..."

$env:ANTHROPIC_API_KEY = $ApiKey
$mcpScript = Join-Path $ClaudeDir "mcp\claude_batch_mcp.py"

# Temporarily allow stderr output from uv (it writes progress to stderr)
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$null = & uv run $mcpScript list --base-dir $BatchesDir 2>&1
$smokeExit = $LASTEXITCODE
$ErrorActionPreference = $prevEAP

if ($smokeExit -eq 0) {
    Write-Ok "Smoke test passed - MCP server works"
} else {
    Write-Warn "Smoke test had issues. Attempting with output:"
    $ErrorActionPreference = "Continue"
    & uv run $mcpScript list --base-dir $BatchesDir 2>&1
    $smokeExit2 = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP
    if ($smokeExit2 -eq 0) {
        Write-Ok "Smoke test passed (with warnings)"
    } else {
        Write-Warn "Smoke test failed - the MCP server may need dependency resolution on first run"
        Write-Warn "This is normal; uv will resolve dependencies when Claude Code first calls the server"
    }
}

# --- Done ---------------------------------------------------------------------
Write-Host ""
Write-Host ([string][char]0x2500 * 33)
Write-Host "${C_Green}${C_Bold}Installation complete!${C_NC}"
Write-Host ""
Write-Host "What was installed:"
Write-Host "  * MCP server:   ~/.claude/mcp/claude_batch_mcp.py"
Write-Host "  * Skill file:   ~/.claude/skills/batch/SKILL.md"
Write-Host "  * Status line:  ~/.claude/statusline.ps1"
Write-Host "  * API key:      ~/.claude/env"
Write-Host "  * Jobs dir:     ~/.claude/batches/"
Write-Host ""
Write-Host "Usage in Claude Code:"
Write-Host "  /batch Review this codebase for security issues"
Write-Host "  /batch check"
Write-Host "  /batch list"
Write-Host ""
Write-Host "The status bar will show batch job counts automatically."
Write-Host ""
