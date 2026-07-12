# Codex Quota Relay

> Let long-running Codex tasks pause at the quota wall—and pick up safely after the reset.

Codex Quota Relay is a portable, project-local Stop hook for Codex on Windows. When remaining quota drops below 3%, it prepares a recovery request for the current task, chooses a safe resume time, and asks Codex to schedule a one-time thread heartbeat.

No more watching the quota meter, restarting completed stages, or leaving a long run stranded overnight.

## Why “Relay”?

This is more than a quota monitor. A monitor tells you that work stopped; a relay carries the task state across the interruption:

1. Read the latest quota telemetry from the current transcript.
2. Stop before another expensive stage starts.
3. Schedule recovery 15 minutes after the latest quota reset—or use a 5-hour fallback when reset time is unavailable.
4. Resume from project-local state without rerunning completed work.

## What it protects

- Existing `Stop`, `PreToolUse`, and unrelated hook configuration.
- Idempotent installs: installing twice still creates only one Relay entry.
- Modified runtime scripts: uninstall leaves user-edited installed scripts in place.
- Project portability: no source-project paths are hard-coded into the installed hook.
- Primary and secondary quota windows: if both are low, Relay waits for the later reset.

## Requirements

- Windows PowerShell 5.1 or newer.
- A Codex environment that supports project-local `.codex/hooks.json` Stop hooks.
- Codex thread heartbeat automations for the scheduled wake-up step.

## Install

Clone the repository into your Codex skills directory:

```powershell
git clone https://github.com/onism11/codex-quota-relay.git "$env:USERPROFILE\.codex\skills\quota-resume-hook"
```

From any target project, install the hook:

```powershell
& "$env:USERPROFILE\.codex\skills\quota-resume-hook\scripts\install.ps1" -ProjectRoot .
```

The installer:

- copies the runtime hook to `.codex/hooks/quota-resume-hook.ps1`;
- appends one marked Stop hook to `.codex/hooks.json`;
- records the installed script hash for safe removal.

## Optional: give Relay a precise checkpoint

Relay works without extra configuration. For a more precise continuation prompt, a controller can write `.codex/runtime/active-run.json`:

```json
{
  "run_directory": "C:\\path\\to\\current-run",
  "resume_prompt": "Inspect the run manifest and continue from the first incomplete stage. Do not rerun completed work."
}
```

When quota is low, Relay writes `.codex/runtime/quota-resume-request.json`. Codex uses its `resume_at_local` and `automation_prompt` to create the one-time heartbeat, then records the automation id and marks the request as scheduled.

## Verify the package

Run the full lifecycle test after cloning or changing a script:

```powershell
& .\scripts\test-package.ps1
```

The test covers:

- preservation of existing hooks and top-level configuration;
- repeated installation;
- reset time plus 15 minutes;
- the 5-hour fallback;
- safe uninstall behavior.

## Uninstall

```powershell
& "$env:USERPROFILE\.codex\skills\quota-resume-hook\scripts\uninstall.ps1" -ProjectRoot .
```

Uninstall removes only Codex Quota Relay's marked hook entry and its unchanged installed files.

## Current scope

Codex Quota Relay is intentionally small and auditable. It prepares and requests recovery; the actual one-time wake-up is created by Codex through its automation interface. It does not run a background service, store credentials, or copy transcript contents into the recovery request.
