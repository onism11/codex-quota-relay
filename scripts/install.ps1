[CmdletBinding()]
param(
    [string]$ProjectRoot = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Marker = "[quota-resume-hook:v1] Checking quota resume threshold"

function Get-Prop {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Set-Prop {
    param([object]$Object, [string]$Name, [object]$Value)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    } else {
        $property.Value = $Value
    }
}

function Write-JsonUtf8 {
    param([string]$Path, [object]$Value)
    $json = ($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine
    [System.IO.File]::WriteAllText($Path, $json, $Utf8NoBom)
}

$root = [System.IO.Path]::GetFullPath($ProjectRoot)
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    throw "Project root does not exist: $root"
}

$codexDirectory = Join-Path $root ".codex"
$hookDirectory = Join-Path $codexDirectory "hooks"
$hooksPath = Join-Path $codexDirectory "hooks.json"
$sourceScript = Join-Path $PSScriptRoot "quota-resume-hook.ps1"
$targetScript = Join-Path $hookDirectory "quota-resume-hook.ps1"
$metadataPath = Join-Path $hookDirectory "quota-resume-hook.install.json"

if (-not (Test-Path -LiteralPath $sourceScript -PathType Leaf)) {
    throw "Bundled runtime hook is missing: $sourceScript"
}

if (Test-Path -LiteralPath $hooksPath -PathType Leaf) {
    try {
        $config = Get-Content -LiteralPath $hooksPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "Cannot parse existing hooks file; no changes were made: $hooksPath"
    }
} else {
    $config = [pscustomobject]@{ hooks = [pscustomobject]@{} }
}

$hooks = Get-Prop -Object $config -Name "hooks"
if ($null -eq $hooks) {
    $hooks = [pscustomobject]@{}
    Set-Prop -Object $config -Name "hooks" -Value $hooks
} elseif ($hooks -is [string] -or $hooks -is [System.Collections.IEnumerable]) {
    throw "Existing hooks property must be a JSON object: $hooksPath"
}

$command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $targetScript + '" -HookMode'
$keptStopEntries = New-Object System.Collections.Generic.List[object]
$existingStop = Get-Prop -Object $hooks -Name "Stop"

foreach ($entry in @($existingStop)) {
    if ($null -eq $entry) { continue }
    $innerHooks = Get-Prop -Object $entry -Name "hooks"
    if ($null -eq $innerHooks) {
        $keptStopEntries.Add($entry)
        continue
    }

    $keptInner = New-Object System.Collections.Generic.List[object]
    foreach ($inner in @($innerHooks)) {
        $status = [string](Get-Prop -Object $inner -Name "statusMessage")
        $innerCommand = [string](Get-Prop -Object $inner -Name "commandWindows")
        if (-not $innerCommand) { $innerCommand = [string](Get-Prop -Object $inner -Name "command") }
        $isThisPackage = ($status -eq $Marker -and $innerCommand -eq $command)
        if (-not $isThisPackage) { $keptInner.Add($inner) }
    }

    if ($keptInner.Count -gt 0) {
        Set-Prop -Object $entry -Name "hooks" -Value @($keptInner.ToArray())
        $keptStopEntries.Add($entry)
    }
}

$packageEntry = [pscustomobject]@{
    hooks = @(
        [pscustomobject]@{
            type = "command"
            command = $command
            commandWindows = $command
            timeout = 20
            statusMessage = $Marker
        }
    )
}
$keptStopEntries.Add($packageEntry)
Set-Prop -Object $hooks -Name "Stop" -Value @($keptStopEntries.ToArray())

New-Item -ItemType Directory -Path $hookDirectory -Force | Out-Null
Copy-Item -LiteralPath $sourceScript -Destination $targetScript -Force
Write-JsonUtf8 -Path $hooksPath -Value $config

$installedHash = (Get-FileHash -LiteralPath $targetScript -Algorithm SHA256).Hash.ToLowerInvariant()
$metadata = [ordered]@{
    schema_version = 1
    marker = $Marker
    hook_path = $targetScript
    hook_sha256 = $installedHash
    command = $command
}
Write-JsonUtf8 -Path $metadataPath -Value $metadata

Write-Output "Installed quota resume hook in $root"
