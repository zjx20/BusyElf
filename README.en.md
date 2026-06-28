# BusyElf 🧝‍⚡

> **English** · [中文](README.md)

> Keeps your Mac awake while an AI agent is busy with a long task — and gives you a single menu-bar panel to see what every agent is doing at a glance.

An ultra-lightweight, native macOS menu-bar app. It pairs with AI agents like Claude Code to **block system sleep only while an agent is actually working, and release it the moment the task finishes**. At the same time it collects all your running agents into one panel, so you can tell at a glance who's working, who's waiting on you, who finished, and who failed.

## Why you'd want it

You ask Claude Code to run a 15-minute refactor, then go grab a coffee. You come back to find your Mac asleep, the task stalled halfway, the network dropped — because you weren't touching the keyboard or mouse, so the system assumed you'd left.

The usual "fixes" are both bad:

- **Manual keep-awake tools** (caffeine and friends): flip one on and your Mac never sleeps, even long after the agent is done. Pure wasted power, and you always forget to turn it off.
- **Wiggling the mouse now and then**: you have to keep babysitting it, which defeats the point of letting the agent run on its own.

BusyElf does this right: **it blocks sleep only while an agent is working, and lifts the block as soon as the work is done** — hands-off the whole time.

And when you've got several agents / terminals going at once, it's easy to lose track — which one is still running? Which one stopped to wait for you to click "Allow"? Which one already finished? BusyElf gives you **one unified panel** in the menu bar:

- **The menu-bar icon** reflects state in real time: working / waiting on you / done / failed, plus the count currently working.
- **The popover list** shows each task one by one — the tool it's running right now, its latest reply, and subtasks.
- **It proactively nudges you when you're needed** (e.g. an agent waiting on a permission prompt), with done / failed alerts too.
- If an agent gets stuck, you can **remove it with one click** from the panel to lift the sleep block.

## How it knows what an agent is doing: hooks

BusyElf doesn't watch processes or read your project files. Instead it **passively receives events that the agent reports on its own**. Tools like Claude Code support [hooks](https://docs.claude.com/en/docs/claude-code/hooks) — they call back to a URL at moments like "a turn started", "a tool was invoked", "stopped to wait on you", "finished". BusyElf listens on a local port (default `127.0.0.1:17872`), catches these events, and uses them to decide whether to block sleep and what to show in the panel.

Integration is **purely additive**: BusyElf only observes — it never injects anything into the agent, never blocks a tool, never changes the agent's flow. With BusyElf off, your agent works exactly as before; it just isn't being tracked.

## Install & connect (3 steps)

### 1. Download and run

Grab the build matching your Mac's chip from the [Releases page](https://github.com/zjx20/BusyElf/releases):

| Your Mac | Download |
|---|---|
| **Apple silicon** (M1/M2/M3/M4…) | `BusyElf-<version>-arm64.zip` or `.dmg` |
| **Intel** | `BusyElf-<version>-x86_64.zip` or `.dmg` |

> Not sure which chip? Click the  menu (top-left) → "About This Mac" and look at "Chip / Processor".

Unzip (or mount the dmg), drag `BusyElf.app` into Applications, and double-click to open. A ⚡ icon in the menu bar means it's running.

> **The first launch will be blocked by macOS.** BusyElf is open source and ad-hoc signed, but not Apple-notarized (notarization requires a paid developer account). Allow it once and you'll never be prompted again: open **System Settings → Privacy & Security**, scroll to the **Security** section at the bottom, and click **"Open Anyway"**, then authenticate. Full steps (including a one-command shortcut) are in the [Release notes](.github/RELEASE_BODY.md).
>
> ⚠️ As of macOS Sequoia (15) / Tahoe (26), right-click → Open **no longer** bypasses the first-launch block — you must go through **System Settings** as above.

### 2. Open the connect screen

Click the ⚡ icon to open the panel, click the **⋯** button in the top-right corner → choose **"Connect an agent…"**. A window pops up with one row per supported harness, each with a **Copy prompt** button. The prompt already has **BusyElf's current listening port filled in automatically** — you don't need to know what the port is.

### 3. Send the prompt to your agent

Click **Copy prompt** on the matching row, then **paste it into your agent's conversation** (e.g. send it straight to Claude Code). The agent reads the prompt and idempotently merges the hooks into its own config file (for Claude Code, `~/.claude/settings.json`) — backing it up first and leaving your existing hooks untouched — then self-checks whether ⚡ lights up.

Throughout this, **BusyElf never touches any of your files** — your own agent does the configuring, in front of you. Once set up, the next launch reuses the same port, so you write the config once and it stays valid.

> To verify it's working: have the agent run any task — the ⚡ icon should light up and the count go +1; it returns to zero when the task ends. To check by hand, run `pmset -g assertions | grep BusyElf` — you'll see a `PreventUserIdleSystemSleep` entry while a task is running.
>
> Prefer not to use the wizard? You can also write the hooks into the config file by hand per [docs/SETUP.md](docs/SETUP.md) — same result.

## Which agents (harnesses) are supported

| Harness | Support |
|---|---|
| **Claude Code** | ✅ Native. A built-in `/claude/hooks` endpoint consumes Claude Code's hook events directly — zero dependencies, zero scripts. |
| Others (Codex, etc.) | ⚙️ Generic protocol. BusyElf's core is **agent-agnostic**: any harness can connect by mapping its "start / progress / wait / done / fail" lifecycle to the generic `POST /v1/task/*` protocol. The "Other" row in the connect wizard copies a ready-made prompt for this generic protocol that you can feed to your harness; success depends on the harness's own capabilities. See [docs/PROTOCOL.md](docs/PROTOCOL.md). |

For now, **only Claude Code is supported natively out of the box**. Contributions for more harnesses are welcome.

## Why it's so light

BusyElf lives in the background, so it has to use almost no resources:

- **0% CPU at idle**: fully event-driven — no polling, no always-on timers.
- **~12 MB of memory**: the UI is **entirely hand-written AppKit**, deliberately not linking SwiftUI (using SwiftUI would push memory up to ~129 MB).
- After the process exits, the system automatically reclaims the sleep-blocking assertion it held — so a crashed app can never leave your Mac unable to sleep forever.

> **Sleep correctness is the top priority.** The rule for "block sleep" is "does any task exist that is working and has been active recently", judged by set membership rather than a counter, so lost or out-of-order events can't make it drift. If an agent hard-crashes without sending an end event, a **watchdog** automatically releases the sleep block once it's been inactive past a threshold (15 minutes by default).

> ℹ️ `PreventUserIdleSystemSleep` only blocks *idle* sleep — it can't stop lid-close / manual sleep / low battery. For long tasks with the lid closed, use an external display + power.

## Documentation

The docs below are currently in Chinese:

- [docs/SETUP.md](docs/SETUP.md) — **Connection guide**: connect Claude Code to BusyElf in 2 minutes (incl. manual config & troubleshooting)
- [docs/DESIGN.md](docs/DESIGN.md) — architecture overview, sleep-blocking mechanism, state machine, resource strategy, module breakdown, key decisions
- [docs/PROTOCOL.md](docs/PROTOCOL.md) — the BusyElf v1 neutral task protocol (adapters for other agents target this)
- [docs/UX.md](docs/UX.md) — UI/UX design of the menu-bar icon / popover / alerts / force-stop
- [docs/adapters/claude-code.md](docs/adapters/claude-code.md) — Claude Code adapter details (built-in `/claude/hooks`, or generic jq+curl)
- [docs/BUILD.md](docs/BUILD.md) — pure-CLI build & release (XcodeGen + xcodebuild + dual-arch packaging via GitHub Actions)

## Development & build

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The project is defined in `project.yml`; the `.xcodeproj` is generated from it (gitignored, never hand-edited).

```bash
# One-shot launch (most common): build → kill the old instance → start in background, ⚡ appears in the menu bar
scripts/run.sh           # --build force rebuild / --debug enable debug endpoints / --stop just stop

# Or build & run manually
xcodegen generate
xcodebuild -project BusyElf.xcodeproj -scheme BusyElf -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
open build/Build/Products/Release/BusyElf.app
pmset -g assertions | grep BusyElf     # the sleep assertion is visible while a task runs

# Tests
scripts/test-unit.sh        # white-box unit tests (state machine / adapter mapping / parsing)
scripts/test-busyelf.sh     # end-to-end: self-launch an instance → hit real endpoints → assert internal state
```

Contributor-facing details — project layout, extension points, debugging lessons — are in [CLAUDE.md](CLAUDE.md).
