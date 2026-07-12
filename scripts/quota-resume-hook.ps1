[CmdletBinding()]
param(
    [string]$TranscriptPath = "",
    [string]$RequestPath = "",
    [double]$ThresholdRemainingPercent = 3.0,
    [string]$NowUtc = "",
    [switch]$HookMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

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

function Get-LatestRateLimits {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8 -Tail 5000)
    for ($index = $lines.Count - 1; $index -ge 0; $index--) {
        $line = $lines[$index].Trim()
        if (-not $line -or $line.IndexOf("rate_limits", [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            continue
        }
        try {
            $event = $line | ConvertFrom-Json
            $rateLimits = Find-RateLimits -Node $event
            if ($null -ne $rateLimits) { return $rateLimits }
        } catch {
            continue
        }
    }
    return $null
}

function Resolve-ProjectRoot {
    return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
}

function Write-JsonUtf8 {
    param([string]$Path, [object]$Value)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $json = ($Value | ConvertTo-Json -Depth 12) + [Environment]::NewLine
    [System.IO.File]::WriteAllText($Path, $json, $Utf8NoBom)
}

if ($HookMode) {
    $rawInput = [Console]::In.ReadToEnd().Trim()
    if ($rawInput) {
        $hookInput = $rawInput | ConvertFrom-Json
        if (-not $TranscriptPath) {
            $TranscriptPath = [string](Get-Prop -Object $hookInput -Name "transcript_path")
        }
    }
}

$projectRoot = Resolve-ProjectRoot
if (-not $RequestPath) { $RequestPath = Join-Path $projectRoot ".codex\runtime\quota-resume-request.json" }
$RequestPath = [System.IO.Path]::GetFullPath($RequestPath)
$now = if ($NowUtc) {
    [DateTimeOffset]::Parse($NowUtc).ToUniversalTime()
} else {
    [DateTimeOffset]::UtcNow
}

$rateLimits = Get-LatestRateLimits -Path $TranscriptPath
$lowLimits = New-Object System.Collections.Generic.List[object]
if ($null -ne $rateLimits) {
    foreach ($scope in @("primary", "secondary")) {
        $limit = Get-Prop -Object $rateLimits -Name $scope
        if ($null -eq $limit) { continue }
        $usedValue = Get-Prop -Object $limit -Name "used_percent"
        if ($null -eq $usedValue) { continue }

        $used = [double]$usedValue
        $remaining = [math]::Max(0.0, 100.0 - $used)
        if ($remaining -lt $ThresholdRemainingPercent) {
            $lowLimits.Add([pscustomobject]@{
                scope = $scope
                used_percent = $used
                remaining_percent = $remaining
                resets_at = Get-Prop -Object $limit -Name "resets_at"
            })
        }
    }
}

if ($lowLimits.Count -eq 0) {
    if ($HookMode) {
        [Console]::Out.WriteLine('{"continue":true}')
    } else {
        [ordered]@{
            trigger = $false
            reason = if ($null -eq $rateLimits) { "quota-telemetry-unavailable" } else { "quota-above-threshold" }
            threshold_remaining_percent = $ThresholdRemainingPercent
            transcript_path = $TranscriptPath
        } | ConvertTo-Json -Depth 8
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
    try {
        $resetTimes.Add([DateTimeOffset]::FromUnixTimeSeconds([int64]$limit.resets_at))
    } catch {
        $allResetsAvailable = $false
    }
}

if ($allResetsAvailable -and $resetTimes.Count -eq $lowLimits.Count) {
    $latestReset = $resetTimes | Sort-Object -Descending | Select-Object -First 1
    $resumeAt = $latestReset.AddMinutes(15)
    $scheduleBasis = "quota-reset-plus-15m"
} else {
    $resumeAt = $now.AddHours(5)
    $scheduleBasis = "fallback-now-plus-5h"
}

$resetKey = (($lowLimits | ForEach-Object { "$($_.scope):$($_.resets_at)" }) -join "|")
$existingScheduled = $false
if (Test-Path -LiteralPath $RequestPath -PathType Leaf) {
    try {
        $existing = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $existingScheduled = (
            [string](Get-Prop -Object $existing -Name "reset_key") -eq $resetKey -and
            [string](Get-Prop -Object $existing -Name "status") -eq "scheduled"
        )
    } catch {
        $existingScheduled = $false
    }
}

$activeRunPath = Join-Path (Split-Path -Parent $RequestPath) "active-run.json"
$runDirectory = ""
$resumePrompt = ""
if (Test-Path -LiteralPath $activeRunPath -PathType Leaf) {
    try {
        $activeRun = Get-Content -LiteralPath $activeRunPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $runDirectory = [string](Get-Prop -Object $activeRun -Name "run_directory")
        $resumePrompt = [string](Get-Prop -Object $activeRun -Name "resume_prompt")
    } catch {
        $runDirectory = ""
        $resumePrompt = ""
    }
}

if (-not $resumePrompt) {
    if ($runDirectory) {
        $resumePrompt = "Resume the interrupted project task. First inspect $runDirectory and its run manifest, then continue from the first incomplete stage without rerunning completed work."
    } else {
        $resumePrompt = "Resume the interrupted project task in $projectRoot. Inspect project-local state and artifacts, then continue from the first incomplete stage without rerunning completed work."
    }
}

$request = [ordered]@{
    schema_version = 1
    status = if ($existingScheduled) { "scheduled" } else { "pending" }
    created_at_utc = $now.ToString("o")
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

if (-not $HookMode) {
    $request | ConvertTo-Json -Depth 12
    exit 0
}

if ($existingScheduled) {
    [Console]::Out.WriteLine('{"continue":true,"systemMessage":"Quota resume is already scheduled for this reset window."}')
    exit 0
}

$reason = @(
    "QUOTA_RESUME_REQUIRED",
    "Remaining quota is below $ThresholdRemainingPercent%.",
    "Only schedule recovery: call codex_app__automation_update to create a one-time thread heartbeat at $($resumeAt.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')); use automation_prompt from the request file.",
    "Request file: $RequestPath. After creation, set status to scheduled and record automation_id, then end this turn without starting another expensive stage."
) -join " "
[Console]::Out.WriteLine((@{ decision = "block"; reason = $reason } | ConvertTo-Json -Compress))
