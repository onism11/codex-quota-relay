# Codex Quota Relay

> Put long Codex work into automatic gear: pause safely at the quota wall, then resume after the reset.

Codex Quota Relay is a Windows-friendly Codex Skill plus lifecycle Hook. When remaining quota falls below 3%, it prepares a thread-specific recovery request and asks Codex to schedule a one-time wake-up after quota resets.

There is no daemon, tray process, account token, or hard-coded project path. You control it by talking to Codex.

## Beginner mode

After installing the repository as a Codex Skill, say:

```text
开启自动档
关闭自动档
自动档状态
查看自动档日志
彻底卸载自动档
```

`开启自动档` defaults to the one-shot Task mode. No PowerShell is required for day-to-day control.

Before every enable action, Relay checks the active network route up to five times with short backoff. A successful HTTP response proves the proxy route is reachable; it does **not** pretend to recreate Codex's authenticated WebSocket. If all five attempts fail, Relay leaves the previous mode unchanged, records the attempts locally, and reports that enabling was not applied.

## Four automatic gears

| Gear | Natural command | Applies to |
|---|---|---|
| Task | `开启自动档：任务` | The next task in this conversation; one-shot. |
| Session | `开启自动档：Session` | This Codex conversation until disabled. |
| Project | `开启自动档：项目` | Every conversation in the current trusted project. |
| All projects | `开启自动档：全部项目` | Every Codex project for this user on this machine. |

The narrowest setting wins: **Task → Session → Project → All projects**. This means `关闭自动档：任务` can keep one task manual even while Project or All-projects mode is on.

Project mode uses a project Hook; All-projects mode uses a user/global Hook. This follows Codex's documented configuration layers: project configuration has higher precedence, while user/global Hooks still load when a project is untrusted. See [Codex configuration precedence](https://learn.chatgpt.com/docs/config-file/config-basic#configuration-precedence).

## What Relay does

1. Reads the latest primary and secondary quota windows from the current Codex transcript.
2. Stops before a new expensive stage when any remaining window is below 3%.
3. Chooses the later reset time plus 15 minutes, or falls back to five hours when reset telemetry is missing.
4. Writes one recovery request per Codex thread.
5. Lets Codex create a one-time thread heartbeat and resume from project-local state.

Task and Session state live in invisible conversation markers. Project state lives in `.codex/quota-relay.json`; global state lives in `$CODEX_HOME/quota-relay.json`.

## Visual status

`自动档状态` produces a compact card:

```text
Codex Quota Relay
当前生效：任务档（一次性）
Session：继承
项目：关闭
全部项目：关闭
调用：12 | 接力：2 | 失败：0
网络：正常（1/5）
```

## Local audit log

Relay keeps a local JSONL audit log. It records:

- every Hook invocation;
- effective gear and outcome;
- total calls, successful relays, and failures;
- failure messages;
- the **full latest user task input** for that invocation.

Project events are stored in `.codex/runtime/quota-relay/events.jsonl`. Global events are stored in `$CODEX_HOME/runtime/quota-relay/events.jsonl`. Relay never uploads them, but task text may be sensitive; use `彻底卸载自动档` to remove Relay state, requests, and logs.

## Installation

Ask Codex to install the Skill directly from this repository:

```text
Install the skill from https://github.com/onism11/codex-quota-relay
```

Or clone it manually:

```powershell
git clone https://github.com/onism11/codex-quota-relay.git "$env:USERPROFILE\.codex\skills\quota-resume-hook"
```

Then start with `开启自动档`.

Requirements:

- Windows PowerShell 5.1 or newer;
- Codex lifecycle Hooks enabled;
- Codex thread heartbeat automations for wake-up scheduling.

## Closing versus completely uninstalling

`关闭自动档` writes a small local `off` override and leaves the Hook dormant. This is necessary so a narrower scope can override an enabled broader scope. It does not run in the background.

`彻底卸载自动档` removes Relay's marked Hook entries, unchanged installed scripts, mode state, thread requests, and logs. The Skill first attempts to delete any recorded external heartbeat automation. If Codex cannot access that automation, it reports the id instead of hiding the residue.

## Advanced PowerShell interface

Most users can ignore this section. From the package directory:

```powershell
.\relay.ps1 enable  -Scope project -ProjectRoot C:\path\to\project
.\relay.ps1 enable  -Scope global  -ProjectRoot C:\path\to\project
.\relay.ps1 disable -Scope project -ProjectRoot C:\path\to\project
.\relay.ps1 status  -ProjectRoot C:\path\to\project
.\relay.ps1 logs    -ProjectRoot C:\path\to\project
.\relay.ps1 purge   -Scope all -ProjectRoot C:\path\to\project
.\relay.ps1 test
```

Task and Session modes should be controlled through the Skill because their state is carried by conversation markers.

## Safety properties

- Preserves existing Stop Hooks and unrelated Hook events.
- Repeated installation stays idempotent.
- Keeps requests isolated by thread id.
- Waits for the later reset when both quota windows are low.
- Leaves user-modified installed scripts untouched during uninstall.
- Does not store credentials or copy full transcripts into recovery requests.
- Fails open: a Relay error is logged and does not trap Codex in a Stop loop.
- Checks network readiness up to five times before each enable and reports degraded connectivity honestly.

## Development

Run the isolated lifecycle suite after any script change:

```powershell
& .\relay.ps1 test
```

The suite covers install preservation, repeated install, threshold boundaries, dual quota windows, fallback timing, Task scope, Session override precedence, user/global installation, local logging, thread isolation, and safe uninstall.
