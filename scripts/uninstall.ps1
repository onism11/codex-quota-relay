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

$hookDirectory = Join-Path $root ".codex\hooks"
$hooksPath = Join-Path $root ".codex\hooks.json"
$targetScript = Join-Path $hookDirectory "quota-resume-hook.ps1"
$metadataPath = Join-Path $hookDirectory "quota-resume-hook.install.json"
$command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $targetScript + '" -HookMode'
$installedHash = ""

if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
    try {
        $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $metadataHash = Get-Prop -Object $metadata -Name "hook_sha256"
        if ($null -ne $metadataHash) { $installedHash = [string]$metadataHash }
    } catch {
        throw "Cannot parse install metadata; no changes were made: $metadataPath"
    }
}

if (Test-Path -LiteralPath $hooksPath -PathType Leaf) {
    try {
        $config = Get-Content -LiteralPath $hooksPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "Cannot parse existing hooks file; no changes were made: $hooksPath"
    }

    $hooks = Get-Prop -Object $config -Name "hooks"
    if ($null -ne $hooks) {
        $existingStop = Get-Prop -Object $hooks -Name "Stop"
        $keptStopEntries = New-Object System.Collections.Generic.List[object]

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

        if ($keptStopEntries.Count -gt 0) {
            Set-Prop -Object $hooks -Name "Stop" -Value @($keptStopEntries.ToArray())
        } else {
            $hooks.PSObject.Properties.Remove("Stop")
        }
        Write-JsonUtf8 -Path $hooksPath -Value $config
    }
}

$scriptRemoved = $false
if (Test-Path -LiteralPath $targetScript -PathType Leaf) {
    $currentHash = (Get-FileHash -LiteralPath $targetScript -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($installedHash -and $currentHash -eq $installedHash.ToLowerInvariant()) {
        Remove-Item -LiteralPath $targetScript -Force
        $scriptRemoved = $true
    } else {
        Write-Warning "Installed hook script was modified or metadata is missing; leaving it in place: $targetScript"
    }
}

if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
    Remove-Item -LiteralPath $metadataPath -Force
}

Write-Output "Removed quota resume hook entry from $root (script removed: $scriptRemoved)"
