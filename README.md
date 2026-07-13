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

## 30-second quick start

Clone the repository into your Codex skills directory:

```powershell
git clone https://github.com/onism11/codex-quota-relay.git "$env:USERPROFILE\.codex\skills\quota-resume-hook"
```

Install and activate Relay for a target project:

```powershell
$relay = "$env:USERPROFILE\.codex\skills\quota-resume-hook\relay.ps1"
& $relay install -ProjectRoot "C:\path\to\your-project"
```

Check it at any time:

```powershell
& $relay status -ProjectRoot "C:\path\to\your-project"
```

Stop and remove the project hook:

```powershell
& $relay stop -ProjectRoot "C:\path\to\your-project"
```

There is no service or background process to start. **Installing is enabling.** After installation, Codex invokes Relay automatically whenever that project's `Stop` event runs.

## One command, four actions

Run these commands from the cloned package directory, or use the full path shown above:

```powershell
.\relay.ps1 install -ProjectRoot C:\path\to\project
.\relay.ps1 status  -ProjectRoot C:\path\to\project
.\relay.ps1 stop    -ProjectRoot C:\path\to\project
.\relay.ps1 test
```

| Action | Effect |
|---|---|
| `install` | Installs and enables the project Stop hook. Safe to run repeatedly. |
| `status` | Shows whether the hook and runtime script are active, plus any recovery request or automation id. |
| `stop` | Removes Relay's hook entry and its unchanged installed runtime script. |
| `test` | Runs the package's isolated install/trigger/uninstall lifecycle tests. |

Under the hood, installation:

- copies the runtime hook to `.codex/hooks/quota-resume-hook.ps1`;
- appends one marked Stop hook to `.codex/hooks.json`;
- records the installed script hash for safe removal.

## Use it through Codex

You can ask Codex to operate the skill instead of typing PowerShell commands:

```text
Use $quota-resume-hook to install Codex Quota Relay in this project.
Use $quota-resume-hook to show Codex Quota Relay status for this project.
Use $quota-resume-hook to stop and remove Codex Quota Relay from this project.
```

When Relay reports low quota, Codex should create the one-time heartbeat using the request file, record the returned automation id, and end the expensive turn.

## What happens when quota is low

Relay reads quota telemetry from the current transcript and writes:

```text
.codex/runtime/quota-resume-request.json
```

The request contains the selected resume time and a continuation prompt. It does not copy transcript contents or credentials. Codex then schedules the one-time thread heartbeat through its automation interface.

## Optional: give Relay a precise checkpoint

Relay works without extra configuration. For a more precise continuation prompt, a controller can write `.codex/runtime/active-run.json`:

```json
{
  "run_directory": "C:\\path\\to\\current-run",
  "resume_prompt": "Inspect the run manifest and continue from the first incomplete stage. Do not rerun completed work."
}
```

Codex uses the request's `resume_at_local` and `automation_prompt` to create the one-time heartbeat, then records the automation id and marks the request as scheduled.

## Stop Relay completely

`relay.ps1 stop` prevents future project Stop events from creating recovery requests. It does **not** silently delete an already scheduled heartbeat, because that automation lives outside the repository.

If `status` shows an automation id, cancel it in the Codex Automations UI or ask Codex:

```text
Delete the quota-resume automation with id <automation-id>.
```

The JSON recovery request remains as a small audit record and is ignored after the project hook is stopped.

## Verify the package

Run the full lifecycle test after cloning or changing a script:

```powershell
& .\relay.ps1 test
```

The test covers:

- preservation of existing hooks and top-level configuration;
- repeated installation;
- the exact 3% threshold boundary;
- simultaneous primary and secondary quota windows;
- reset time plus 15 minutes;
- the 5-hour fallback;
- safe uninstall behavior.

## Troubleshooting

- **No request was created:** Relay triggers only below 3% remaining. Exactly 3% does not trigger. The latest transcript must also contain readable quota telemetry.
- **PowerShell blocks script execution:** run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\relay.ps1 status -ProjectRoot C:\path\to\project`.
- **The heartbeat fired but quota still looks exhausted:** restart or reopen Codex so the client refreshes its quota state, then continue the task. Relay cannot refresh client authentication by itself.
- **`status` says the hook is disabled:** run `install` again. Installation is idempotent and preserves unrelated hooks.
- **You edited the installed runtime script:** `stop` removes the hook entry but intentionally leaves that modified script in place.

Advanced users can call `scripts/install.ps1`, `scripts/uninstall.ps1`, and `scripts/test-package.ps1` directly; `relay.ps1` is the recommended interface.


## Current scope

Codex Quota Relay is intentionally small and auditable. It prepares and requests recovery; the actual one-time wake-up is created by Codex through its automation interface. It does not run a background service, store credentials, or copy transcript contents into the recovery request.
