[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("install", "status", "stop", "test")]
    [string]$Action = "status",
    [string]$ProjectRoot = ".",
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Marker = "[quota-resume-hook:v1] Checking quota resume threshold"
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

function Get-RelayStatus {
    param([string]$Root)

    $hooksPath = Join-Path $Root ".codex\hooks.json"
    $runtimeHook = Join-Path $Root ".codex\hooks\quota-resume-hook.ps1"
    $requestPath = Join-Path $Root ".codex\runtime\quota-resume-request.json"
    $enabled = $false
    $configuration = "not-found"

    if (Test-Path -LiteralPath $hooksPath -PathType Leaf) {
        try {
            $config = Get-Content -LiteralPath $hooksPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $configuration = "readable"
            $hooks = Get-Prop -Object $config -Name "hooks"
            $stopEntries = Get-Prop -Object $hooks -Name "Stop"
            foreach ($entry in @($stopEntries)) {
                foreach ($hook in @((Get-Prop -Object $entry -Name "hooks"))) {
                    if ([string](Get-Prop -Object $hook -Name "statusMessage") -eq $Marker) {
                        $enabled = $true
                    }
                }
            }
        } catch {
            $configuration = "unreadable"
        }
    }

    $requestStatus = "none"
    $resumeAtLocal = ""
    $automationId = ""
    if (Test-Path -LiteralPath $requestPath -PathType Leaf) {
        try {
            $request = Get-Content -LiteralPath $requestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $requestStatus = [string](Get-Prop -Object $request -Name "status")
            if (-not $requestStatus) { $requestStatus = "present" }
            $resumeAtLocal = [string](Get-Prop -Object $request -Name "resume_at_local")
            $automationId = [string](Get-Prop -Object $request -Name "automation_id")
        } catch {
            $requestStatus = "unreadable"
        }
    }

    return [pscustomobject][ordered]@{
        project_root = $Root
        hook_enabled = $enabled
        runtime_hook_present = (Test-Path -LiteralPath $runtimeHook -PathType Leaf)
        hooks_configuration = $configuration
        recovery_request = $requestStatus
        resume_at_local = $resumeAtLocal
        automation_id = $automationId
    }
}

function Write-RelayStatus {
    param([object]$Status, [switch]$AsJson)

    if ($AsJson) {
        $Status | ConvertTo-Json -Depth 6
        return
    }

    Write-Output "Codex Quota Relay"
    Write-Output "  Project:          $($Status.project_root)"
    Write-Output "  Hook:             $(if ($Status.hook_enabled) { 'enabled' } else { 'disabled' })"
    Write-Output "  Runtime script:   $(if ($Status.runtime_hook_present) { 'present' } else { 'missing' })"
    Write-Output "  Recovery request: $($Status.recovery_request)"
    if ($Status.resume_at_local) { Write-Output "  Resume at:        $($Status.resume_at_local)" }
    if ($Status.automation_id) { Write-Output "  Automation id:    $($Status.automation_id)" }
}

if ($Action -eq "test") {
    & $TestPackage
    exit 0
}

$root = [System.IO.Path]::GetFullPath($ProjectRoot)
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    throw "Project root does not exist: $root"
}

switch ($Action) {
    "install" { & $Install -ProjectRoot $root | Out-Null }
    "stop" { & $Uninstall -ProjectRoot $root | Out-Null }
}

$status = Get-RelayStatus -Root $root
Write-RelayStatus -Status $status -AsJson:$Json

if ($Action -eq "stop" -and $status.automation_id) {
    Write-Warning "The project hook is stopped, but scheduled automation '$($status.automation_id)' may still exist. Delete it in Codex Automations or ask Codex to delete that automation."
}
