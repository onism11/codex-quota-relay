[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("enable", "disable", "status", "logs", "purge", "install", "stop", "test")]
    [string]$Action = "status",
    [ValidateSet("task", "session", "project", "global", "all")]
    [string]$Scope = "task",
    [string]$ProjectRoot = ".",
    [string]$CodexHome = "",
    [int]$Tail = 20,
    [switch]$SkipNetworkPreflight,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$MarkerPattern = "[[]quota-resume-hook:v*] Checking quota resume threshold"
$Install = Join-Path $PSScriptRoot "scripts\install.ps1"
$Uninstall = Join-Path $PSScriptRoot "scripts\uninstall.ps1"
$TestPackage = Join-Path $PSScriptRoot "scripts\test-package.ps1"

function Get-Prop {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-HookState {
    param([string]$Base)
    $hooksPath = Join-Path $Base "hooks.json"
    $runtimeHook = Join-Path $Base "hooks\quota-resume-hook.ps1"
    $enabled = $false
    if (Test-Path -LiteralPath $hooksPath -PathType Leaf) {
        try {
            $config = Get-Content -LiteralPath $hooksPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($entry in @((Get-Prop -Object (Get-Prop -Object $config -Name "hooks") -Name "Stop"))) {
                foreach ($hook in @((Get-Prop -Object $entry -Name "hooks"))) {
                    if ([string](Get-Prop -Object $hook -Name "statusMessage") -like $MarkerPattern) { $enabled = $true }
                }
            }
        } catch {}
    }
    return [pscustomobject]@{ enabled = $enabled; runtime_present = (Test-Path -LiteralPath $runtimeHook -PathType Leaf) }
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

function Write-Mode {
    param([string]$Path, [string]$Mode, [string]$StateScope)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $state = [ordered]@{ schema_version = 2; scope = $StateScope; mode = $Mode; updated_at_utc = [DateTimeOffset]::UtcNow.ToString("o") }
    [System.IO.File]::WriteAllText($Path, (($state | ConvertTo-Json -Depth 6) + [Environment]::NewLine), $Utf8NoBom)
}

function Write-SuppressNextStop {
    param([string]$Base)
    $path = Join-Path $Base "runtime\quota-relay\suppress-next-stop.json"
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $value = [ordered]@{ created_at_utc = [DateTimeOffset]::UtcNow.ToString("o") }
    [System.IO.File]::WriteAllText($path, (($value | ConvertTo-Json -Compress) + [Environment]::NewLine), $Utf8NoBom)
}

function Test-NetworkRoute {
    param([int]$MaxAttempts = 5)
    $curlCommand = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($null -eq $curlCommand) {
        return [pscustomobject]@{ status = "degraded"; attempts = 0; http_code = ""; route = "curl-missing"; results = @() }
    }

    $proxy = ""
    $route = "system-default"
    try {
        $tun = Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq "Up" -and ($_.Name -match "Meta|Clash|Mihomo" -or $_.InterfaceDescription -match "Meta|Clash|Mihomo") } | Select-Object -First 1
        if ($null -ne $tun) { $route = "tun" }
    } catch {}
    try {
        $internetSettings = Get-ItemProperty -LiteralPath "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
        if ($route -ne "tun" -and [int]$internetSettings.ProxyEnable -eq 1) {
            $proxy = [string]$internetSettings.ProxyServer
            if ($proxy.Contains(";")) {
                $httpsEntry = @($proxy.Split(";") | Where-Object { $_ -like "https=*" } | Select-Object -First 1)
                if ($httpsEntry.Count -gt 0) { $proxy = $httpsEntry[0].Substring(6) }
            }
            if ($proxy -and -not $proxy.Contains("://")) { $proxy = "http://$proxy" }
            if ($proxy) { $route = "system-proxy" }
        }
    } catch { $proxy = "" }

    $endpoint = "https://chatgpt.com/backend-api/codex/responses"
    $lastCode = "000"
    $results = New-Object System.Collections.Generic.List[object]
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if ($attempt -gt 1) {
            $delays = @(0, 250, 500, 1000, 2000)
            Start-Sleep -Milliseconds ($delays[$attempt - 1] + (Get-Random -Minimum 0 -Maximum 151))
        }
        $arguments = @("-I", "--silent", "--show-error", "--connect-timeout", "4", "--max-time", "8")
        if ($proxy) { $arguments += @("--proxy", $proxy) }
        $arguments += $endpoint
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $output = @(& $curlCommand.Source @arguments 2>&1)
        $exitCode = $LASTEXITCODE
        $stopwatch.Stop()
        $codes = @($output | ForEach-Object {
            $match = [regex]::Match([string]$_, "^HTTP/[^ ]+ ([0-9]{3})")
            if ($match.Success) { $match.Groups[1].Value }
        })
        if ($codes.Count -gt 0) { $lastCode = [string]$codes[-1] } else { $lastCode = "000" }
        $errorText = if ($exitCode -eq 0 -and $lastCode -ne "000") { "" } else { (@($output | Select-Object -Last 2) -join " ").Trim() }
        $results.Add([pscustomobject]@{ attempt = $attempt; duration_ms = $stopwatch.ElapsedMilliseconds; http_code = $lastCode; exit_code = $exitCode; error = $errorText })
        if ($exitCode -eq 0 -and $lastCode -in @("401", "403", "405")) {
            return [pscustomobject]@{ status = "ready"; attempts = $attempt; http_code = $lastCode; route = $route; results = @($results.ToArray()) }
        }
    }
    return [pscustomobject]@{ status = "degraded"; attempts = $MaxAttempts; http_code = $lastCode; route = $route; results = @($results.ToArray()) }
}

function Write-NetworkFailure {
    param([string]$Base, [string]$ModeScope, [object]$Preflight)
    $path = Join-Path $Base "runtime\quota-relay\events.jsonl"
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $event = [ordered]@{
        timestamp_utc = [DateTimeOffset]::UtcNow.ToString("o")
        thread = "control"
        install_scope = $ModeScope
        project_root = $root
        task_input = "enable:$ModeScope"
        effective_scope = $ModeScope
        outcome = "network-preflight-failed"
        failure = $true
        network_route = $Preflight.route
        network_attempts = $Preflight.results
    }
    [System.IO.File]::AppendAllText($path, (($event | ConvertTo-Json -Compress -Depth 10) + [Environment]::NewLine), $Utf8NoBom)
}

function Read-Events {
    param([string[]]$Paths)
    $events = New-Object System.Collections.Generic.List[object]
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        foreach ($line in @(Get-Content -LiteralPath $path -Encoding UTF8)) {
            if (-not $line.Trim()) { continue }
            try { $events.Add(($line | ConvertFrom-Json)) } catch {}
        }
    }
    return @($events | Sort-Object { [string](Get-Prop -Object $_ -Name "timestamp_utc") })
}

function Get-Status {
    param([string]$Root, [string]$CodexRoot)
    $projectBase = Join-Path $Root ".codex"
    $projectHook = Get-HookState -Base $projectBase
    $globalHook = Get-HookState -Base $CodexRoot
    $events = @(Read-Events -Paths @(
        (Join-Path $projectBase "runtime\quota-relay\events.jsonl"),
        (Join-Path $CodexRoot "runtime\quota-relay\events.jsonl")
    ))
    return [pscustomobject][ordered]@{
        project_root = $Root
        task = "conversation-marker"
        session = "conversation-marker"
        project = Read-Mode -Path (Join-Path $projectBase "quota-relay.json") -Default "inherit"
        global = Read-Mode -Path (Join-Path $CodexRoot "quota-relay.json") -Default "off"
        project_hook = [bool]$projectHook.enabled
        global_hook = [bool]$globalHook.enabled
        hook_enabled = [bool]$projectHook.enabled
        runtime_hook_present = [bool]$projectHook.runtime_present
        calls = $events.Count
        relays = @($events | Where-Object { [string](Get-Prop -Object $_ -Name "outcome") -eq "recovery-requested" }).Count
        failures = @($events | Where-Object { [bool](Get-Prop -Object $_ -Name "failure") }).Count
    }
}

function Write-StatusCard {
    param([object]$Status, [switch]$AsJson)
    if ($AsJson) { $Status | ConvertTo-Json -Depth 8; return }
    Write-Output "Codex Quota Relay"
    Write-Output "  Task:       conversation marker"
    Write-Output "  Session:    conversation marker"
    Write-Output "  Project:    $($Status.project)"
    Write-Output "  Global:     $($Status.global)"
    Write-Output "  Hooks:      project=$(if ($Status.project_hook) { 'installed' } else { 'missing' }) / global=$(if ($Status.global_hook) { 'installed' } else { 'missing' })"
    Write-Output "  Calls: $($Status.calls) | Relays: $($Status.relays) | Failures: $($Status.failures)"
    $network = [string](Get-Prop -Object $Status -Name "network_preflight")
    if ($network) { Write-Output "  Network:    $network ($([string](Get-Prop -Object $Status -Name 'network_attempts'))/5 attempts)" }
}

if ($Action -eq "test") { & $TestPackage; exit 0 }

$root = [System.IO.Path]::GetFullPath($ProjectRoot)
if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Project root does not exist: $root" }
if (-not $CodexHome) { $CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" } }
$relayHome = [System.IO.Path]::GetFullPath($CodexHome)
$projectState = Join-Path $root ".codex\quota-relay.json"
$globalState = Join-Path $relayHome "quota-relay.json"

if ($Action -eq "install") { $Action = "enable"; $Scope = "project" }
if ($Action -eq "stop") {
    & $Uninstall -ProjectRoot $root -Scope project | Out-Null
    Write-StatusCard -Status (Get-Status -Root $root -CodexRoot $relayHome) -AsJson:$Json
    exit 0
}

$networkPreflight = $null
$enableApplied = $true
if ($Action -eq "enable" -and -not $SkipNetworkPreflight) {
    $networkPreflight = Test-NetworkRoute -MaxAttempts 5
    if ($networkPreflight.status -ne "ready") {
        $enableApplied = $false
        $failureBase = if ($Scope -eq "global") { $relayHome } else { Join-Path $root ".codex" }
        Write-NetworkFailure -Base $failureBase -ModeScope $Scope -Preflight $networkPreflight
    }
}

if ($Action -eq "enable" -and $enableApplied) {
    switch ($Scope) {
        "task" { & $Install -ProjectRoot $root -Scope project | Out-Null }
        "session" { & $Install -ProjectRoot $root -Scope project | Out-Null }
        "project" { & $Install -ProjectRoot $root -Scope project | Out-Null; Write-Mode -Path $projectState -Mode "on" -StateScope "project" }
        "global" { New-Item -ItemType Directory -Path $relayHome -Force | Out-Null; & $Install -ProjectRoot $relayHome -Scope global | Out-Null; Write-Mode -Path $globalState -Mode "on" -StateScope "global" }
        "all" { throw "Use scope 'global' to enable all projects." }
    }
}

if ($Action -eq "disable") {
    switch ($Scope) {
        "task" { & $Install -ProjectRoot $root -Scope project | Out-Null }
        "session" { & $Install -ProjectRoot $root -Scope project | Out-Null }
        "project" { & $Install -ProjectRoot $root -Scope project | Out-Null; Write-Mode -Path $projectState -Mode "off" -StateScope "project" }
        "global" { New-Item -ItemType Directory -Path $relayHome -Force | Out-Null; Write-Mode -Path $globalState -Mode "off" -StateScope "global" }
        "all" { Write-Mode -Path $projectState -Mode "off" -StateScope "project"; New-Item -ItemType Directory -Path $relayHome -Force | Out-Null; Write-Mode -Path $globalState -Mode "off" -StateScope "global" }
    }
}

if (($Action -eq "enable" -and $enableApplied) -or $Action -eq "disable") {
    if ($Scope -in @("task", "session", "project", "all")) { Write-SuppressNextStop -Base (Join-Path $root ".codex") }
    if ($Scope -in @("global", "all")) { Write-SuppressNextStop -Base $relayHome }
}

if ($Action -eq "purge") {
    if ($Scope -in @("task", "session", "project", "all")) { & $Uninstall -ProjectRoot $root -Scope project -PurgeData | Out-Null }
    if ($Scope -in @("global", "all")) {
        if (Test-Path -LiteralPath $relayHome -PathType Container) { & $Uninstall -ProjectRoot $relayHome -Scope global -PurgeData | Out-Null }
    }
}

if ($Action -eq "logs") {
    $events = @(Read-Events -Paths @(
        (Join-Path $root ".codex\runtime\quota-relay\events.jsonl"),
        (Join-Path $relayHome "runtime\quota-relay\events.jsonl")
    ) | Select-Object -Last $Tail)
    if ($Json) { $events | ConvertTo-Json -Depth 10; exit 0 }
    foreach ($event in $events) {
        Write-Output "[$([string](Get-Prop -Object $event -Name 'timestamp_utc'))] $([string](Get-Prop -Object $event -Name 'outcome')) / $([string](Get-Prop -Object $event -Name 'effective_scope'))"
        Write-Output "  Task: $([string](Get-Prop -Object $event -Name 'task_input'))"
        $errorText = [string](Get-Prop -Object $event -Name "error")
        if ($errorText) { Write-Output "  Failure: $errorText" }
    }
    exit 0
}

$status = Get-Status -Root $root -CodexRoot $relayHome
if ($null -ne $networkPreflight) {
    $status | Add-Member -NotePropertyName network_preflight -NotePropertyValue $networkPreflight.status
    $status | Add-Member -NotePropertyName network_attempts -NotePropertyValue $networkPreflight.attempts
    $status | Add-Member -NotePropertyName network_route -NotePropertyValue $networkPreflight.route
    $status | Add-Member -NotePropertyName enable_applied -NotePropertyValue $enableApplied
}
if (($Action -eq "enable" -and $enableApplied) -or $Action -eq "disable") {
    $markerAction = if ($Action -eq "enable") { "on" } else { "off" }
    $marker = switch ($Scope) {
        "task" { "<!-- codex-quota-relay:auto:task:$markerAction`:v2 -->" }
        "session" { "<!-- codex-quota-relay:auto:session:$markerAction`:v2 -->" }
        default { "" }
    }
    if ($marker) { $status | Add-Member -NotePropertyName conversation_marker -NotePropertyValue $marker }
}
Write-StatusCard -Status $status -AsJson:$Json
