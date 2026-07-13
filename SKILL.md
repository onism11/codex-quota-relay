---
name: quota-resume-hook
description: Install, verify, or remove Codex Quota Relay, a project-local Stop hook that prepares safe task recovery when remaining quota falls below 3 percent. Use when long-running Codex work should continue across quota resets without hard-coded project paths.
---

# Codex Quota Relay

Use the unified control command from the package root:

```powershell
& <skill-path>\relay.ps1 install -ProjectRoot .
& <skill-path>\relay.ps1 status -ProjectRoot .
& <skill-path>\relay.ps1 stop -ProjectRoot .
& <skill-path>\relay.ps1 test
```

Installation is also activation: there is no daemon to start. Codex invokes the hook automatically on the project `Stop` event. The installer copies the runtime hook into `.codex/hooks/` and adds one marked `Stop` command to `.codex/hooks.json` without replacing existing hooks.

The runtime writes `.codex/runtime/quota-resume-request.json`; when quota is low, use its `resume_at_local` and `automation_prompt` with `codex_app__automation_update`, then record `status: scheduled` and the automation id. `stop` removes the project hook, but an already scheduled heartbeat is external to the project: delete that automation separately through Codex.

Remove only this package's entry and unchanged installed files:

```powershell
& <skill-path>\relay.ps1 stop -ProjectRoot .
```

Run `scripts/test-package.ps1` after changing any bundled script.
