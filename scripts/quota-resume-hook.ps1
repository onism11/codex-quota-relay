[CmdletBinding()]
param(
    [string]$TranscriptPath = "",
    [string]$RequestPath = "",
    [double]$ThresholdRemainingPercent = 3.0,
    [string]$NowUtc = "",
    [switch]$HookMode,
    [ValidateSet("project", "global")]
    [string]$InstallScope = "project",
    [string]$ConfiguredRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$MarkerPattern = "[[]quota-resume-hook:v*] Checking quota resume threshold"

function Get-Prop {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Find-RateLimits {
    param([object]$Node, [int]$Depth = 0)
    if ($null -eq $Node -or $Depth -gt 8 -or $Node -is [string]) { return $null }
    $direct = Get-Prop -Object $Node -Name "rate_limits"
    if ($null -ne $direct) { return $direct }
    if ($Node -is [System.Collections.IEnumerable] -and -not ($Node -is [pscustomobject])) {
        foreach ($item in $Node) {
            $found = Find-RateLimits -Node $item -Depth ($Depth + 1)
            if ($null -ne $found) { return $found }
        }
        return $null
    }
    foreach ($property in $Node.PSObject.Properties) {
        $found = Find-RateLimits -Node $property.Value -Depth ($Depth + 1)
        if ($null -ne $found) { return $found }
    }
    return $null
}

function Get-MessageText {
    param([object]$Content)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Content)) {
        $type = [string](Get-Prop -Object $item -Name "type")
        if ($type -in @("input_text", "output_text", "text")) {
            $value = [string](Get-Prop -Object $item -Name "text")
            if ($value) { $parts.Add($value) }
        }
    }
    return ($parts -join "`n")
}

function Get-TranscriptContext {
    param([string]$Path)
    $context = [ordered]@{
        rate_limits = $null
        task_input = ""
        task_marker = $null
        session_marker = $null
        user_positions = New-Object System.Collections.Generic.List[int]
    }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]$context
    }

    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8 -Tail 5000)
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index].Trim()
        if (-not $line) { continue }
        try { $event = $line | ConvertFrom-Json } catch { continue }

        $foundLimits = Find-RateLimits -Node $event
        if ($null -ne $foundLimits) { $context.rate_limits = $foundLimits }

        if ([string](Get-Prop -Object $event -Name "type") -ne "response_item") { continue }
        $payload = Get-Prop -Object $event -Name "payload"
        if ([string](Get-Prop -Object $payload -Name "type") -ne "message") { continue }
        $role = [string](Get-Prop -Object $payload -Name "role")
        $text = Get-MessageText -Content (Get-Prop -Object $payload -Name "content")

        if ($role -eq "user") {
            $context.user_positions.Add($index)
            if ($text) { $context.task_input = $text }
            continue
        }
        if ($role -ne "assistant" -or -not $text) { continue }

        foreach ($scope in @("task", "session")) {
            foreach ($action in @("on", "off")) {
                $marker = "<!-- codex-quota-relay:auto:$scope`:$action`:v2 -->"
                if ($text.Contains($marker)) {
                    $context["${scope}_marker"] = [pscustomobject]@{ action = $action; position = $index }
                }
            }
        }
    }
    return [pscustomobject]$context
}

function Find-ProjectRoot {
    param([string]$StartPath)
    $current = [System.IO.Path]::GetFullPath($StartPath)
    while ($current) {
        if ((Test-Path -LiteralPath (Join-Path $current ".git")) -or (Test-Path -LiteralPath (Join-Path $current ".codex"))) {
            return $current
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
    return [System.IO.Path]::GetFullPath($StartPath)
}

function Read-Mode {
    param([string]$Path, [string]$Default)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $Default }
    try {
        $state = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $mode = [string](Get-Prop -Object $state -Name "mode")
        if ($mode -in @("on", "off", "inherit")) { return $mode }
    } catch {}
    return $Default
}

function Write-JsonUtf8 {
    param([string]$Path, [object]$Value)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 12) + [Environment]::NewLine), $Utf8NoBom)
}

function Write-EventLog {
    param([string]$Path, [object]$Value)
    try {
        $directory = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        $line = ($Value | ConvertTo-Json -Compress -Depth 12) + [Environment]::NewLine
        [System.IO.File]::AppendAllText($Path, $line, $Utf8NoBom)
    } catch {}
}

function Merge-Event {
    param([object]$Base, [object]$Extra)
    $result = [ordered]@{}
    foreach ($key in $Base.Keys) { $result[$key] = $Base[$key] }
    foreach ($key in $Extra.Keys) { $result[$key] = $Extra[$key] }
    return [pscustomobject]$result
}

function Get-ThreadKey {
    param([string]$Path)
    $match = [regex]::Match([System.IO.Path]::GetFileName($Path), "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
    if ($match.Success) { return $match.Value.ToLowerInvariant() }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Path)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").Substring(0, 24).ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Has-RelayHookAt {
    param([string]$Base)
    $path = Join-Path $Base "hooks.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    try {
        $config = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($entry in @((Get-Prop -Object (Get-Prop -Object $config -Name "hooks") -Name "Stop"))) {
            foreach ($hook in @((Get-Prop -Object $entry -Name "hooks"))) {
                if ([string](Get-Prop -Object $hook -Name "statusMessage") -like $MarkerPattern) { return $true }
            }
        }
    } catch {}
    return $false
}

$rawInput = ""
$hookInput = $null
if ($HookMode) {
    $rawInput = [Console]::In.ReadToEnd().Trim()
    if ($rawInput) {
        try { $hookInput = $rawInput | ConvertFrom-Json } catch { $hookInput = $null }
    }
    if (-not $TranscriptPath) { $TranscriptPath = [string](Get-Prop -Object $hookInput -Name "transcript_path") }
}

$now = if ($NowUtc) { [DateTimeOffset]::Parse($NowUtc).ToUniversalTime() } else { [DateTimeOffset]::UtcNow }
$codexHome = if ($InstallScope -eq "global" -and $ConfiguredRoot) {
    [System.IO.Path]::GetFullPath($ConfiguredRoot)
} elseif ($env:CODEX_HOME) {
    [System.IO.Path]::GetFullPath($env:CODEX_HOME)
} else {
    Join-Path $env:USERPROFILE ".codex"
}
$cwdValue = [string](Get-Prop -Object $hookInput -Name "cwd")
if (-not $cwdValue) { $cwdValue = (Get-Location).Path }
$projectRoot = if ($InstallScope -eq "project" -and $ConfiguredRoot) {
    [System.IO.Path]::GetFullPath($ConfiguredRoot)
} else {
    Find-ProjectRoot -StartPath $cwdValue
}
$storageRoot = if ($InstallScope -eq "global") { $codexHome } else { Join-Path $projectRoot ".codex" }
$logPath = Join-Path $storageRoot "runtime\quota-relay\events.jsonl"
$threadKey = Get-ThreadKey -Path $TranscriptPath
$context = Get-TranscriptContext -Path $TranscriptPath
$suppressNextStop = $false
$suppressPath = Join-Path $storageRoot "runtime\quota-relay\suppress-next-stop.json"
if (Test-Path -LiteralPath $suppressPath -PathType Leaf) {
    try {
        $age = $now - [DateTimeOffset](Get-Item -LiteralPath $suppressPath).LastWriteTimeUtc
        $suppressNextStop = ($age.TotalMinutes -le 10)
        Remove-Item -LiteralPath $suppressPath -Force
    } catch {}
}

$eventBase = [ordered]@{
    timestamp_utc = $now.ToString("o")
    thread = $threadKey
    install_scope = $InstallScope
    project_root = $projectRoot
    task_input = [string]$context.task_input
}

try {
    if ($HookMode -and $InstallScope -eq "project" -and (Has-RelayHookAt -Base $codexHome)) {
        Write-EventLog -Path $logPath -Value (Merge-Event -Base $eventBase -Extra ([ordered]@{ effective_scope = "global"; outcome = "delegated-to-global-hook"; failure = $false }))
        [Console]::Out.WriteLine('{"continue":true}')
        exit 0
    }

    $projectMode = Read-Mode -Path (Join-Path $projectRoot ".codex\quota-relay.json") -Default "inherit"
    $globalMode = Read-Mode -Path (Join-Path $codexHome "quota-relay.json") -Default "off"
    $effectiveScope = "none"
    $enabled = $false
    $taskArmed = $false

    if ($null -ne $context.task_marker) {
        $usersAfter = @($context.user_positions | Where-Object { $_ -gt [int]$context.task_marker.position }).Count
        if ($usersAfter -eq 0) {
            $taskArmed = $true
        } elseif ($usersAfter -eq 1) {
            $effectiveScope = "task"
            $enabled = ([string]$context.task_marker.action -eq "on")
        }
    }
    if ($effectiveScope -eq "none" -and -not $taskArmed -and $null -ne $context.session_marker) {
        $effectiveScope = "session"
        $enabled = ([string]$context.session_marker.action -eq "on")
    }
    if ($effectiveScope -eq "none" -and -not $taskArmed -and $projectMode -ne "inherit") {
        $effectiveScope = "project"
        $enabled = ($projectMode -eq "on")
    }
    if ($effectiveScope -eq "none" -and -not $taskArmed) {
        $effectiveScope = "global"
        $enabled = ($globalMode -eq "on")
    }

    if ($HookMode -and ($taskArmed -or $suppressNextStop)) {
        $outcome = if ($taskArmed) { "task-armed" } else { "control-command" }
        Write-EventLog -Path $logPath -Value (Merge-Event -Base $eventBase -Extra ([ordered]@{ effective_scope = $effectiveScope; outcome = $outcome; failure = $false }))
        [Console]::Out.WriteLine('{"continue":true}')
        exit 0
    }
    if ($HookMode -and -not $enabled) {
        Write-EventLog -Path $logPath -Value (Merge-Event -Base $eventBase -Extra ([ordered]@{ effective_scope = $effectiveScope; outcome = "disabled"; failure = $false }))
        [Console]::Out.WriteLine('{"continue":true}')
        exit 0
    }

    $rateLimits = $context.rate_limits
    $lowLimits = New-Object System.Collections.Generic.List[object]
    if ($null -ne $rateLimits) {
        foreach ($scopeName in @("primary", "secondary")) {
            $limit = Get-Prop -Object $rateLimits -Name $scopeName
            if ($null -eq $limit) { continue }
            $usedValue = Get-Prop -Object $limit -Name "used_percent"
            if ($null -eq $usedValue) { continue }
            $used = [double]$usedValue
            $remaining = [math]::Max(0.0, 100.0 - $used)
            if ($remaining -lt $ThresholdRemainingPercent) {
                $lowLimits.Add([pscustomobject]@{
                    scope = $scopeName
                    used_percent = $used
                    remaining_percent = $remaining
                    resets_at = Get-Prop -Object $limit -Name "resets_at"
                })
            }
        }
    }

    if ($lowLimits.Count -eq 0) {
        $outcome = if ($null -eq $rateLimits) { "quota-telemetry-unavailable" } else { "quota-above-threshold" }
        if ($HookMode) {
            Write-EventLog -Path $logPath -Value (Merge-Event -Base $eventBase -Extra ([ordered]@{ effective_scope = $effectiveScope; outcome = $outcome; failure = $false }))
            [Console]::Out.WriteLine('{"continue":true}')
        } else {
            [ordered]@{ trigger = $false; reason = $outcome; threshold_remaining_percent = $ThresholdRemainingPercent; transcript_path = $TranscriptPath } | ConvertTo-Json -Depth 8
        }
        exit 0
    }

    $allResetsAvailable = $true
    $resetTimes = New-Object System.Collections.Generic.List[DateTimeOffset]
    foreach ($limit in $lowLimits) {
        if ($null -eq $limit.resets_at -or [string]::IsNullOrWhiteSpace([string]$limit.resets_at)) {
            $allResetsAvailable = $false
            continue
        }
        try { $resetTimes.Add([DateTimeOffset]::FromUnixTimeSeconds([int64]$limit.resets_at)) } catch { $allResetsAvailable = $false }
    }
    if ($allResetsAvailable -and $resetTimes.Count -eq $lowLimits.Count) {
        $latestReset = $resetTimes | Sort-Object -Descending | Select-Object -First 1
        $resumeAt = $latestReset.AddMinutes(15)
        $scheduleBasis = "quota-reset-plus-15m"
    } else {
        $resumeAt = $now.AddHours(5)
        $scheduleBasis = "fallback-now-plus-5h"
    }

    if (-not $RequestPath) { $RequestPath = Join-Path $storageRoot "runtime\quota-relay\requests\$threadKey.json" }
    $RequestPath = [System.IO.Path]::GetFullPath($RequestPath)
    $resetKey = (($lowLimits | ForEach-Object { "$($_.scope):$($_.resets_at)" }) -join "|")
    $existingScheduled = $false
    if (Test-Path -LiteralPath $RequestPath -PathType Leaf) {
        try {
            $existing = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $existingScheduled = ([string](Get-Prop -Object $existing -Name "reset_key") -eq $resetKey -and [string](Get-Prop -Object $existing -Name "status") -eq "scheduled")
        } catch {}
    }

    $activeRunPath = Join-Path $projectRoot ".codex\runtime\active-run.json"
    $runDirectory = ""
    $resumePrompt = ""
    if (Test-Path -LiteralPath $activeRunPath -PathType Leaf) {
        try {
            $activeRun = Get-Content -LiteralPath $activeRunPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $runDirectory = [string](Get-Prop -Object $activeRun -Name "run_directory")
            $resumePrompt = [string](Get-Prop -Object $activeRun -Name "resume_prompt")
        } catch {}
    }
    if (-not $resumePrompt) {
        $resumePrompt = if ($runDirectory) {
            "Resume the interrupted project task. First inspect $runDirectory and its run manifest, then continue from the first incomplete stage without rerunning completed work."
        } else {
            "Resume the interrupted project task in $projectRoot. Inspect project-local state and artifacts, then continue from the first incomplete stage without rerunning completed work."
        }
    }

    $request = [ordered]@{
        schema_version = 2
        status = if ($existingScheduled) { "scheduled" } else { "pending" }
        created_at_utc = $now.ToString("o")
        effective_scope = $effectiveScope
        task_input = [string]$context.task_input
        threshold_remaining_percent = $ThresholdRemainingPercent
        low_limits = @($lowLimits.ToArray())
        schedule_basis = $scheduleBasis
        resume_at_utc = $resumeAt.ToUniversalTime().ToString("o")
        resume_at_local = $resumeAt.ToLocalTime().ToString("o")
        reset_key = $resetKey
        transcript_path = $TranscriptPath
        project_root = $projectRoot
        run_directory = $runDirectory
        automation_prompt = $resumePrompt
    }
    Write-JsonUtf8 -Path $RequestPath -Value $request

    if (-not $HookMode) { $request | ConvertTo-Json -Depth 12; exit 0 }
    if ($existingScheduled) {
        Write-EventLog -Path $logPath -Value (Merge-Event -Base $eventBase -Extra ([ordered]@{ effective_scope = $effectiveScope; outcome = "already-scheduled"; failure = $false; request_path = $RequestPath }))
        [Console]::Out.WriteLine('{"continue":true,"systemMessage":"Quota resume is already scheduled for this reset window."}')
        exit 0
    }

    Write-EventLog -Path $logPath -Value (Merge-Event -Base $eventBase -Extra ([ordered]@{ effective_scope = $effectiveScope; outcome = "recovery-requested"; failure = $false; request_path = $RequestPath; schedule_basis = $scheduleBasis; resume_at_local = $resumeAt.ToLocalTime().ToString("o") }))
    $reason = @(
        "QUOTA_RESUME_REQUIRED",
        "Remaining quota is below $ThresholdRemainingPercent%.",
        "Only schedule recovery: call codex_app__automation_update to create a one-time thread heartbeat at $($resumeAt.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')); use automation_prompt from the request file.",
        "Request file: $RequestPath. After creation, set status to scheduled and record automation_id, then end this turn without starting another expensive stage."
    ) -join " "
    [Console]::Out.WriteLine((@{ decision = "block"; reason = $reason } | ConvertTo-Json -Compress))
} catch {
    Write-EventLog -Path $logPath -Value (Merge-Event -Base $eventBase -Extra ([ordered]@{ effective_scope = "unknown"; outcome = "failure"; failure = $true; error = $_.Exception.Message }))
    if ($HookMode) {
        [Console]::Out.WriteLine('{"continue":true,"systemMessage":"Codex Quota Relay failed safely; inspect the local Relay log."}')
        exit 0
    }
    throw
}
