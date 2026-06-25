# tmux-sort-session

Reorder tmux sessions up and down in the session list (`choose-tree`) — something
tmux has no native support for.

## Why this exists

tmux has **no concept of custom session ordering**. The session list (`choose-tree`)
can only sort by `name`, `time` (activity), or `index`, and the `S-Up` / `S-Down`
swap keys inside `choose-tree` operate on **windows**, not sessions. Sessions have
no writable position/index attribute.

This plugin works around that by encoding order into the **session name**: it
prefixes each session with a hidden, zero-padded numeric token (e.g. `010|work`).
With `choose-tree` sorted by name, those tokens drive the visible order. Moving a
session "up" or "down" simply swaps the tokens of two adjacent sessions via
`rename-session`. A display format strips the token everywhere it would show, so
you only ever see your real session names.

```
raw session names      what you see in choose-tree / status bar
-----------------      ----------------------------------------
010|work          ->   work
020|mail          ->   mail
030|music         ->   music
```

Because the order lives in the session name, it **persists automatically** across
restarts when used with [tmux-resurrect] / [tmux-continuum].

## Install (TPM)

Add to `~/.config/tmux/tmux.conf` (or `~/.tmux.conf`):

```tmux
set -g @plugin 'badloop/tmux-sort-session'
```

Then hit `prefix + I` to fetch it.

You must also (1) sort `choose-tree` by name and (2) strip the order token from
any place a session name is displayed. See **Display setup** below — without it,
the `NNN|` prefixes will be visible.

## Keys

| Binding (default)        | Action                                            |
| ------------------------ | ------------------------------------------------- |
| `prefix` + `Shift-Up`    | Move the attached session **up** one slot         |
| `prefix` + `Shift-Down`  | Move the attached session **down** one slot       |
| `prefix` + `Shift-Left`* | Normalize / re-number all order tokens (optional) |

\* Only bound if you set `@session_order_key_normalize` (see Options).

Moves act on the **currently attached** session and work from anywhere — you do
not need the list open. (tmux does not allow custom key bindings *inside*
`choose-tree`, which is why reordering is driven from the prefix table.)

## Display setup

The plugin maintains the hidden tokens but does **not** force a particular
`choose-tree` invocation or status-bar layout — that's yours to control. Add the
token-stripping format wherever a session name is shown.

Strip format (works for any token width):

```
#{s/^[0-9]+\|//:session_name}
```

> Note: tmux's format regex does **not** support `{n}` interval quantifiers, so
> use `[0-9]+` (or `[0-9][0-9][0-9]`), not `[0-9]{3}`.

**Status bar** — replace `#S` with the stripped form:

```tmux
set -g status-left "... #{s/^[0-9]+\\|//:session_name} ..."
```

**Session chooser** — sort by name and pass a custom `-F` that strips the token:

```tmux
bind-key l choose-tree -Zs -O name \
  -F "#{?pane_format,#{pane_current_command},#{?window_format,#{window_name}#{window_flags}: #{pane_current_command},#{s/^[0-9]+\\|//:session_name}: #{session_windows} windows#{?session_attached, (attached),}}}"
```

## Options

| Option                            | Default  | Description                                                      |
| --------------------------------- | -------- | --------------------------------------------------------------- |
| `@session_order_key_up`           | `S-Up`   | Key (prefix table) to move the attached session up.             |
| `@session_order_key_down`         | `S-Down` | Key (prefix table) to move the attached session down.           |
| `@session_order_key_normalize`    | *(unset)*| If set, binds a key to re-number tokens evenly.                 |
| `@session_order_sep`              | `\|`     | Token/name separator. Must not appear in your session names.    |
| `@session_order_step`             | `10`     | Gap between tokens on normalize (room to insert between slots).  |
| `@session_order_pad`              | `3`      | Zero-pad width for tokens. `3` supports up to 999 slots.        |
| `@session_order_ignore`           | *(empty)*| Extended-regex of **base** names to never tokenize or move.     |

Example:

```tmux
set -g @session_order_key_up        'S-Up'
set -g @session_order_key_down      'S-Down'
set -g @session_order_key_normalize 'S-Left'
```

### Pinning sessions (`@session_order_ignore`)

**Important:** the order token becomes part of the real session name, so a
session named `work` becomes `010|work`. Anything that targets a session by its
**exact name** — most commonly `tmux has-session -t "NAME"` in a startup/daemon
script — will no longer match a tokenized session and may, e.g., spawn a
duplicate.

To protect such sessions, list them (as an extended regex matched against the
full base name) in `@session_order_ignore`. Ignored sessions are never
tokenized, never renamed, and cannot be moved; reorder operations simply skip
over them.

```tmux
# Never touch these infrastructure sessions (managed by external scripts that
# do `tmux has-session -t "M365 SENTINEL"` etc.).
set -g @session_order_ignore 'M365 SENTINEL|TELEGRAM BOT'
```

The value is a POSIX extended regex anchored to the whole name (the plugin wraps
it as `^(...)$`), so `M365 SENTINEL|TELEGRAM BOT` matches exactly those two
names, while something like `infra-.*` would match any `infra-` prefixed
session.

## How it behaves

- **Untokenized sessions** (newly created, or pre-existing) are left alone until
  you first move one. On any move, the plugin lazily assigns tokens to all
  sessions, appending untokenized ones **after** already-ordered sessions
  (preserving their current sorted position relative to each other).
- **Edge moves** (up at the top, down at the bottom) are no-ops with a status
  message.
- **`normalize`** re-numbers every session to clean, evenly spaced tokens
  (`010, 020, 030, …`) in the current order — useful after lots of moves, or to
  re-space tokens so you can insert between them again.
- A session **without** a token displays unchanged, so the plugin degrades
  gracefully if you remove it.

## Manual usage

The worker script can be run directly (the same one the key bindings call):

```sh
scripts/session-order.sh up        # move attached session up
scripts/session-order.sh down      # move attached session down
scripts/session-order.sh up work   # move a named session up
scripts/session-order.sh normalize # re-number all tokens
```

## Caveats

- The order token becomes part of the real session name. Anything that targets
  sessions **by exact name** (scripts, `tmux switch -t work`, and especially
  `tmux has-session -t "NAME"` in daemons) must account for the token — or,
  better, add those sessions to `@session_order_ignore` so they are never
  tokenized. See **Pinning sessions** above.
- Don't use your `@session_order_sep` character inside session names.

## License

MIT — see [LICENSE](LICENSE).

[tmux-resurrect]: https://github.com/tmux-plugins/tmux-resurrect
[tmux-continuum]: https://github.com/tmux-plugins/tmux-continuum
