# screen-lease

Share one Mac between a human and AI agents that drive GUI apps (Claude Code or any other agent) without fighting over the screen.

When an agent drives an app on the computer you're using, things go wrong:

- the app covers the chat, so you can't tell whether the agent is working, stuck, waiting on you, or done;
- you glance at the chat, and the agent's next screenshot, or a command that needs the app in front, breaks;
- the agent grabs focus again after you thought it had finished, and your typing lands in the wrong app.

screen-lease fixes this with three pieces:

1. **A lease.** One shared lock file says which agent session has the screen, what it's doing, and whether it's still alive. Agents take it before any GUI action and hand it back when done. Two agents can't drive at once.
2. **A menu bar light** (`ScreenLeaseLight`) that never takes focus, with a sound on every change:
   - 🔴 driving, hands off
   - 🔴⏸ pausing: the agent is finishing its current step
   - 🟡 the agent needs you, or it has paused for you
   - 🟢 the screen is yours
   - ⚪ stale: the agent holds the screen but stopped responding

   Its menu shows the task and how long the agent has held the screen. It also lets you **pause** the agent ("I need the screen"), resume it, force-clear the lease, or jump to the agent's session.
3. **An agent skill** (`skill/SKILL.md.template`, installed for Claude Code): the protocol agents follow. It covers taking and releasing the lease, wrapping each UI step in `screen-lease run` so a pause waits for the current step to finish, capturing covered windows with `screencapture -l` (via `windowid`), and never sending blind keystrokes.

## Install (macOS)

```bash
./install.sh                      # CLI + windowid in ~/.local/bin, skill in ~/.claude/skills
BIN_DIR=~/bin ./install.sh        # elsewhere
SKILL_DIR= ./install.sh           # skip the Claude Code skill
./install.sh --uninstall          # remove (moves files to the Trash)
```

You need the Xcode command line tools (`swiftc`). The light starts at login via a LaunchAgent. Choosing Quit from its menu stops it until you next log in or run `install.sh`.

## Configure

Settings live in `~/.config/screen-lease/config.json`, created from [`config.example.json`](config.example.json):

| Key | Meaning |
|---|---|
| `stale_seconds` | How long without a heartbeat before a driving lease shows ⚪ and another agent may take it over. |
| `heartbeat_seconds` | How often `screen-lease run` heart-beats while a step runs. |
| `need_you_repeat_seconds` | Repeat the 🟡 sound this often while an agent waits on you (0 = once). |
| `sounds` | A macOS system sound name per state (`/System/Library/Sounds`); `""` = silent. |
| `on_need_you`, `on_free` | A shell command to run when the light turns 🟡 for need-you, or 🟢. For example, bring your agent's chat window to the front. |
| `owner_url_template` | A URL with `{owner}`, opened by "Open … session" in the menu. |

The owner id comes from `--owner`, `$SCREEN_LEASE_OWNER`, or Claude Code's session id env vars. `$SCREEN_LEASE_LABEL` or `--label` sets a friendly name.

## CLI

```
screen-lease acquire "<purpose>"     0 ok · 2 held by another agent · 3 paused by you
screen-lease run -- <cmd> [args]     one UI step: refuses while paused, heart-beats, marks busy
screen-lease heartbeat | check       keep alive / may I touch the UI now?
screen-lease need-you "<question>"   🟡, keep the lease
screen-lease working ["<purpose>"]   back to 🔴
screen-lease release ["<result>"]    🟢
screen-lease wait-resume [secs]      block until you resume
screen-lease status | clear
```

State lives in `~/Library/Application Support/screen-lease/` (override with `$SCREEN_LEASE_DIR`).

Tests: `tests/test_cli.sh`. They use a temporary state dir, so they never touch the real lease.

## Limits

The lease is cooperative. It protects you from agents that follow the skill, not from arbitrary scripts. A step already running when you click pause finishes first (🔴⏸ until it does).
