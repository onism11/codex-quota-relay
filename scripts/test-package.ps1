[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Install = Join-Path $PSScriptRoot "install.ps1"
$Relay = Join-Path (Split-Path -Parent $PSScriptRoot) "relay.ps1"
$FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("quota-resume-hook-test-" + [guid]::NewGuid().ToString("n"))
$Project = Join-Path $FixtureRoot "sample-project"
$TestCodexHome = Join-Path $FixtureRoot "codex-home"
$OriginalCodexHome = $env:CODEX_HOME

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-Prop {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

try {
    $env:CODEX_HOME = $TestCodexHome
    New-Item -ItemType Directory -Path (Join-Path $Project ".codex") -Force | Out-Null
    $existingCommand = "powershell.exe -NoProfile -Command `"exit 0`""
    $existing = [ordered]@{
        version = 7
        hooks = [ordered]@{
            Stop = @(
                [ordered]@{
                    matcher = "existing"
                    hooks = @(
                        [ordered]@{
                            type = "command"
                            command = $existingCommand
                            statusMessage = "existing stop hook"
                        }
                    )
                }
            )
            PreToolUse = @(
                [ordered]@{
                    hooks = @([ordered]@{ type = "command"; command = $existingCommand })
                }
            )
        }
    }
    $hooksPath = Join-Path $Project ".codex\hooks.json"
    [System.IO.File]::WriteAllText($hooksPath, (($existing | ConvertTo-Json -Depth 12) + "`n"), $Utf8NoBom)

    & $Install -ProjectRoot $Project | Out-Null
    & $Install -ProjectRoot $Project | Out-Null

    $installedConfig = Get-Content -LiteralPath $hooksPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([int]$installedConfig.version -eq 7) "Installer changed an unrelated top-level property."
    Assert-True (@($installedConfig.hooks.PreToolUse).Count -eq 1) "Installer changed an unrelated hook event."
    Assert-True (@($installedConfig.hooks.Stop).Count -eq 2) "Idempotent install must leave exactly one package Stop entry."
    Assert-True ([string]$installedConfig.hooks.Stop[0].hooks[0].statusMessage -eq "existing stop hook") "Installer changed the existing Stop hook."

    $installedHook = Join-Path $Project ".codex\hooks\quota-resume-hook.ps1"
    Assert-True (Test-Path -LiteralPath $installedHook -PathType Leaf) "Installed runtime hook is missing."
    $packageEntry = @($installedConfig.hooks.Stop)[1]
    $packageCommand = [string]$packageEntry.hooks[0].commandWindows
    Assert-True ($packageCommand.Contains($installedHook)) "Installed command does not target the project-local hook."
    Assert-True (-not $packageCommand.Contains((Split-Path -Parent $PSScriptRoot))) "Installed command contains the package source path."

    $relayStatus = & $Relay status -ProjectRoot $Project -Json | ConvertFrom-Json
    Assert-True ([bool]$relayStatus.hook_enabled) "Relay status did not report the installed hook as enabled."
    Assert-True ([bool]$relayStatus.runtime_hook_present) "Relay status did not find the installed runtime script."

    $transcriptPath = Join-Path $FixtureRoot "transcript.jsonl"
    $rateEvent = [ordered]@{
        type = "event_msg"
        payload = [ordered]@{
            rate_limits = [ordered]@{
                primary = [ordered]@{ used_percent = 98.0; resets_at = 1783814400 }
                secondary = [ordered]@{ used_percent = 50.0; resets_at = 1783900800 }
            }
        }
    }
    [System.IO.File]::WriteAllText($transcriptPath, (($rateEvent | ConvertTo-Json -Compress -Depth 10) + "`n"), $Utf8NoBom)

    Push-Location $Project
    try {
        $requestPath = Join-Path $Project ".codex\runtime\quota-resume-request.json"
        $result = & $installedHook -TranscriptPath $transcriptPath -RequestPath $requestPath -NowUtc "2026-07-12T00:00:00Z" | ConvertFrom-Json
    } finally {
        Pop-Location
    }
    Assert-True ([string]$result.schedule_basis -eq "quota-reset-plus-15m") "Installed runtime did not trigger reset+15m scheduling."
    Assert-True ([DateTimeOffset]::Parse($result.resume_at_utc).ToUnixTimeSeconds() -eq 1783815300) "Installed runtime produced the wrong resume time."

    $rateEvent.payload.rate_limits.primary.used_percent = 97.0
    [System.IO.File]::WriteAllText($transcriptPath, (($rateEvent | ConvertTo-Json -Compress -Depth 10) + "`n"), $Utf8NoBom)
    $thresholdPath = Join-Path $Project ".codex\runtime\quota-resume-threshold.json"
    $threshold = & $installedHook -TranscriptPath $transcriptPath -RequestPath $thresholdPath -NowUtc "2026-07-12T00:00:00Z" | ConvertFrom-Json
    Assert-True (-not [bool]$threshold.trigger) "Exactly 3% remaining must not trigger recovery."
    Assert-True ([string]$threshold.reason -eq "quota-above-threshold") "Threshold boundary returned the wrong reason."

    $rateEvent.payload.rate_limits.primary.used_percent = 98.0
    $rateEvent.payload.rate_limits.secondary.used_percent = 99.0
    [System.IO.File]::WriteAllText($transcriptPath, (($rateEvent | ConvertTo-Json -Compress -Depth 10) + "`n"), $Utf8NoBom)
    $dualWindowPath = Join-Path $Project ".codex\runtime\quota-resume-dual-window.json"
    $dualWindow = & $installedHook -TranscriptPath $transcriptPath -RequestPath $dualWindowPath -NowUtc "2026-07-12T00:00:00Z" | ConvertFrom-Json
    Assert-True ([DateTimeOffset]::Parse($dualWindow.resume_at_utc).ToUnixTimeSeconds() -eq 1783901700) "Dual-window recovery did not wait for the later reset."

    $taskStatus = & $Relay enable -Scope task -ProjectRoot $Project -CodexHome $TestCodexHome -SkipNetworkPreflight -Json | ConvertFrom-Json
    Assert-True ([string]$taskStatus.conversation_marker -eq "<!-- codex-quota-relay:auto:task:on:v2 -->") "Task mode did not return its conversation marker."
    Remove-Item -LiteralPath (Join-Path $Project ".codex\runtime\quota-relay\suppress-next-stop.json") -Force
    $threadId = "11111111-2222-3333-4444-555555555555"
    $scopedTranscript = Join-Path $FixtureRoot "rollout-$threadId.jsonl"
    $taskEvents = @(
        [ordered]@{ type = "response_item"; payload = [ordered]@{ type = "message"; role = "user"; content = @([ordered]@{ type = "input_text"; text = "enable task mode" }) } },
        [ordered]@{ type = "response_item"; payload = [ordered]@{ type = "message"; role = "assistant"; content = @([ordered]@{ type = "output_text"; text = "<!-- codex-quota-relay:auto:task:on:v2 -->" }) } },
        [ordered]@{ type = "response_item"; payload = [ordered]@{ type = "message"; role = "user"; content = @([ordered]@{ type = "input_text"; text = "Build the release artifact." }) } },
        $rateEvent
    )
    $taskLines = ($taskEvents | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 12 }) -join "`n"
    [System.IO.File]::WriteAllText($scopedTranscript, ($taskLines + "`n"), $Utf8NoBom)
    $hookPayload = [ordered]@{ transcript_path = $scopedTranscript; cwd = $Project } | ConvertTo-Json -Compress
    $hookResult = $hookPayload | powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installedHook -HookMode -InstallScope project -ConfiguredRoot $Project -NowUtc "2026-07-12T00:00:00Z" | ConvertFrom-Json
    if ([string](Get-Prop -Object $hookResult -Name "decision") -ne "block") {
        $debugLog = Join-Path $Project ".codex\runtime\quota-relay\events.jsonl"
        $debugText = if (Test-Path -LiteralPath $debugLog) { Get-Content -LiteralPath $debugLog -Tail 1 -Encoding UTF8 } else { "no log" }
        throw "Task mode returned: $($hookResult | ConvertTo-Json -Compress -Depth 8); log: $debugText"
    }
    $threadRequest = Join-Path $Project ".codex\runtime\quota-relay\requests\$threadId.json"
    Assert-True (Test-Path -LiteralPath $threadRequest -PathType Leaf) "Task mode did not isolate its request by thread."
    $taskRequest = Get-Content -LiteralPath $threadRequest -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([string]$taskRequest.effective_scope -eq "task") "Task mode request recorded the wrong scope."
    Assert-True ([string]$taskRequest.task_input -eq "Build the release artifact.") "Task mode did not record the user task input."
    $projectLog = Join-Path $Project ".codex\runtime\quota-relay\events.jsonl"
    $logEvent = Get-Content -LiteralPath $projectLog -Encoding UTF8 | Select-Object -Last 1 | ConvertFrom-Json
    Assert-True ([string]$logEvent.outcome -eq "recovery-requested") "Local log did not record the Relay call."
    Assert-True ([string]$logEvent.task_input -eq "Build the release artifact.") "Local log did not record the task input."

    & $Relay enable -Scope project -ProjectRoot $Project -CodexHome $TestCodexHome -SkipNetworkPreflight -Json | Out-Null
    $sessionStatus = & $Relay disable -Scope session -ProjectRoot $Project -CodexHome $TestCodexHome -Json | ConvertFrom-Json
    Assert-True ([string]$sessionStatus.conversation_marker -eq "<!-- codex-quota-relay:auto:session:off:v2 -->") "Session mode did not return its off marker."
    Remove-Item -LiteralPath (Join-Path $Project ".codex\runtime\quota-relay\suppress-next-stop.json") -Force
    $sessionEvents = @(
        [ordered]@{ type = "response_item"; payload = [ordered]@{ type = "message"; role = "assistant"; content = @([ordered]@{ type = "output_text"; text = "<!-- codex-quota-relay:auto:session:off:v2 -->" }) } },
        [ordered]@{ type = "response_item"; payload = [ordered]@{ type = "message"; role = "user"; content = @([ordered]@{ type = "input_text"; text = "This task must stay manual." }) } },
        $rateEvent
    )
    $sessionLines = ($sessionEvents | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 12 }) -join "`n"
    [System.IO.File]::WriteAllText($scopedTranscript, ($sessionLines + "`n"), $Utf8NoBom)
    $sessionResult = $hookPayload | powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installedHook -HookMode -InstallScope project -ConfiguredRoot $Project | ConvertFrom-Json
    Assert-True ([bool]$sessionResult.continue) "Session off did not override project on."
    $sessionLog = Get-Content -LiteralPath $projectLog -Encoding UTF8 | Select-Object -Last 1 | ConvertFrom-Json
    Assert-True ([string]$sessionLog.effective_scope -eq "session" -and [string]$sessionLog.outcome -eq "disabled") "Session off precedence was not logged correctly."

    $globalStatus = & $Relay enable -Scope global -ProjectRoot $Project -CodexHome $TestCodexHome -SkipNetworkPreflight -Json | ConvertFrom-Json
    Assert-True ([string]$globalStatus.global -eq "on") "Global mode was not enabled."
    Assert-True (Test-Path -LiteralPath (Join-Path $TestCodexHome "hooks.json") -PathType Leaf) "Global mode did not install a user-level hook."

    $rateEvent.payload.rate_limits.secondary.used_percent = 50.0
    $rateEvent.payload.rate_limits.primary.resets_at = $null
    [System.IO.File]::WriteAllText($transcriptPath, (($rateEvent | ConvertTo-Json -Compress -Depth 10) + "`n"), $Utf8NoBom)
    $fallbackPath = Join-Path $Project ".codex\runtime\quota-resume-fallback.json"
    $fallback = & $installedHook -TranscriptPath $transcriptPath -RequestPath $fallbackPath -NowUtc "2026-07-12T00:00:00Z" | ConvertFrom-Json
    Assert-True ([string]$fallback.schedule_basis -eq "fallback-now-plus-5h") "Installed runtime did not use the 5h fallback."
    Assert-True ([DateTimeOffset]::Parse($fallback.resume_at_utc).ToString("o") -eq "2026-07-12T05:00:00.0000000+00:00") "Installed runtime produced the wrong fallback time."

    $stopped = & $Relay stop -ProjectRoot $Project -Json | ConvertFrom-Json
    Assert-True (-not [bool]$stopped.hook_enabled) "Relay stop did not report the hook as disabled."
    Assert-True (-not [bool]$stopped.runtime_hook_present) "Relay stop did not remove the unchanged runtime script."
    $uninstalledConfig = Get-Content -LiteralPath $hooksPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([int]$uninstalledConfig.version -eq 7) "Uninstaller changed an unrelated top-level property."
    Assert-True (@($uninstalledConfig.hooks.PreToolUse).Count -eq 1) "Uninstaller changed an unrelated hook event."
    Assert-True (@($uninstalledConfig.hooks.Stop).Count -eq 1) "Uninstaller did not remove only the package Stop entry."
    Assert-True ([string]$uninstalledConfig.hooks.Stop[0].hooks[0].statusMessage -eq "existing stop hook") "Uninstaller changed the existing Stop hook."
    Assert-True (-not (Test-Path -LiteralPath $installedHook)) "Uninstaller did not remove the unchanged installed script."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $Project ".codex\hooks\quota-resume-hook.install.json"))) "Uninstaller did not remove install metadata."

    Write-Output "portable quota-resume-hook: install/trigger/uninstall passed"
} finally {
    $env:CODEX_HOME = $OriginalCodexHome
    if (Test-Path -LiteralPath $FixtureRoot) {
        Remove-Item -LiteralPath $FixtureRoot -Recurse -Force
    }
}
