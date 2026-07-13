---
name: quota-resume-hook
description: Control Codex Quota Relay with beginner-friendly natural-language commands. Use when the user says 开启自动档, 关闭自动档, 自动档状态, 查看自动档日志, or 彻底卸载自动档, or wants a task-, session-, project-, or machine-wide quota recovery relay.
---

# Codex Quota Relay

Operate Relay for the user. Do not ask them to type PowerShell.

## Commands

Map the user's wording to `relay.ps1`:

| User command | Internal action |
|---|---|
| `开启自动档` or `开启自动档：任务` | `enable -Scope task` |
| `开启自动档：Session` | `enable -Scope session` |
| `开启自动档：项目` | `enable -Scope project` |
| `开启自动档：全部项目` | `enable -Scope global` |
| `关闭自动档` | `disable -Scope task` |
| `关闭自动档：<范围>` | `disable` with the matching scope |
| `自动档状态` | `status -Json` |
| `查看自动档日志` | `logs -Json` |
| `彻底卸载自动档` | `purge -Scope all` |

Use the current project root. Run the wrapper from this skill directory and request JSON when interpreting its result.

Every `enable` performs up to five network-route checks before changing mode. If `network_preflight=degraded`, report that enabling was not applied and leave the previous mode unchanged. The check cannot recreate Codex's authenticated WebSocket and must not be described as a successful main-session reconnect.

For task or session actions, include the returned `conversation_marker` unchanged in the assistant response. It is an HTML comment and must remain invisible to the user. Never invent or edit a marker.

## Scope rules

- Task: the next user task in this conversation. It is one-shot and expires when another user task starts.
- Session: this Codex conversation until explicitly disabled.
- Project: every conversation in the current trusted project.
- Global: every Codex project for this user on this machine.
- Precedence is Task, Session, Project, Global. A narrower `off` overrides a broader `on`.

Task and Session use transcript markers. Project uses `.codex/quota-relay.json` and a project hook. Global uses `$CODEX_HOME/quota-relay.json` and a user hook. No mode starts a daemon.

## Response card

After every action, show a compact Chinese card:

```text
Codex Quota Relay
当前生效：任务档（一次性）
Session：继承
项目：关闭
全部项目：关闭
调用：0 | 接力：0 | 失败：0
网络：正常（1/5）
```

Translate `on`, `off`, and `inherit` as `开启`, `关闭`, and `继承`. For Task and Session, infer the current conversation marker and label unknown state as `继承`.

## Logs and cleanup

Relay logs every hook invocation locally as JSONL. Each event includes time, effective scope, outcome, failure details, and the full latest user task input. Clearly disclose this when first enabling Relay. Never upload the log.

Before `purge -Scope all`, inspect Relay request files for recorded automation ids and delete those thread heartbeats through the Codex automation interface when available. Then purge hooks, state, requests, and logs. If an external automation cannot be deleted, report its id instead of claiming a residue-free uninstall.

Run `scripts/test-package.ps1` after changing bundled scripts.
