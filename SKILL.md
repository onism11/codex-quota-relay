---
name: quota-resume-hook
description: Install, verify, or remove Codex Quota Relay, a project-local Stop hook that prepares safe task recovery when remaining quota falls below 3 percent. Use when long-running Codex work should continue across quota resets without hard-coded project paths.
---

# Codex Quota Relay

Install from the target repository root:

```powershell
& <skill-path>\scripts\install.ps1 -ProjectRoot .
```

The installer copies the runtime hook into `.codex/hooks/` and adds one marked `Stop` command to `.codex/hooks.json` without replacing existing hooks. The runtime writes `.codex/runtime/quota-resume-request.json`; when quota is low, use its `resume_at_local` and `automation_prompt` with `codex_app__automation_update`, then record `status: scheduled` and the automation id.

Remove only this package's entry and unchanged installed files:

```powershell
& <skill-path>\scripts\uninstall.ps1 -ProjectRoot .
```

Run `scripts/test-package.ps1` after changing any bundled script.
