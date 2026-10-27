# Plugstage

A window for managing Omarchy shell plugins in batches. Pick changes
(bar placement, on/off, uninstall), then **Apply changes** runs them one
after another. It's its own Quickshell process, so the bar rebuild each
change causes can't close it.

    plugstage            # launch, or raise the running window

- `app/` — Quickshell UI (`qs -p app`); IPC target `plugstage`
  (`show`, `state`, `queue <id> <off|on|left|center|right|remove>`, `apply`,
  `confirm`, `discard`, `snapshot <png>`).
- `tools/state.py` — read-only snapshot: `omarchy plugin list --json` +
  placement from `~/.config/omarchy/shell.json` + git state.
- `tools/removal-check.py` — fetches each plugin to uninstall and warns about
  uncommitted work or commits not on its remote (`remove` deletes git checkouts).
- `tools/apply.py` — runs the queue via `omarchy plugin …` / `omarchy bar …`,
  waits for the shell between steps, and reads each result back from the
  system rather than trusting the exit code. Log: `~/.local/state/plugstage/apply.log`.

Deliberate limits:
- Tray-drawer widgets are shown but not toggled — the plugin manager's
  disable path deletes their `plugins[]` entry and strands them. Uninstalling
  one takes it out of the drawer first.
- First-party plugins replaced by an active clone (e.g. `omarchy.clock` →
  `lcars.clock`) have no controls: `bar put` on them is a silent no-op.
- No marketplace/updates/shortcuts — Omaplug still does those.
