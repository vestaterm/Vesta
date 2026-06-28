# Writing Vesta plugins

A Vesta plugin is just a folder with an `init.lua`. No build step, no packaging.
This page is the full API reference; `examples/starter/` is a working plugin you
can copy and trim.

## Your first plugin

```
~/.config/vesta/plugins/hello/
  init.lua
```

```lua
-- init.lua
vesta.command("hello", function()
  vesta.notify("hello from my plugin")
end)
vesta.bind("cmd+shift+h", function() vesta.notify("hi") end)
```

Reload (`vesta reload`) and it's live. That's the whole contract: a folder under
`~/.config/vesta/plugins/`, with an `init.lua` (or `plugin/init.lua`) that runs
with the `vesta` global available.

## Installing & sharing

- **Drop-in:** put a folder in `~/.config/vesta/plugins/`.
- **Declared:** in your own `~/.config/vesta/init.lua`, call
  `vesta.plugin("owner/repo")` — Vesta clones it from GitHub into `plugins/` on
  first run. A full git URL or local path works too.
- **Pinning:** `vesta.plugin("owner/repo", { ref = "v1.2.0", priority = 10 })`.
  `ref` is a tag/branch/commit; `priority` sets load order (higher first, ties by
  name). Resolved commits are written to `plugins.lock`.
- **Enable/disable:** `vesta plugins`, `vesta plugins disable <name>`,
  `vesta plugins enable <name>` (or the Settings UI). Disabled names live in
  `~/.config/vesta/plugins/disabled-plugins`.

A plugin is a git repo + `init.lua` — to share one, push it and hand over the
URL. (A discovery registry is planned but not built yet.)

### manifest.lua (optional)

```lua
return { version = "1.0.0", priority = 0 }
```

## API reference

### Building blocks

| Call | Description |
|------|-------------|
| `vesta.command(name, fn)` | Register a named command (runnable from a keybind or CLI). |
| `vesta.bind(chord, fn)` | Keybind, e.g. `"cmd+shift+p"`. |
| `vesta.on(event, fn)` | Register an event handler (see Events). |
| `vesta.timer(seconds, fn)` | Call `fn` every `seconds` (repeating). |
| `vesta.set(key, value)` | Override a config value (Vesta or ghostty key). |
| `vesta.plugin(repo [, opts])` | Declare a plugin dependency (clone/pin). |

### Acting on the terminal

| Call | Description |
|------|-------------|
| `vesta.send(text)` | Send text/keystrokes to the active pane. |
| `vesta.active()` | `{ cwd, title, paneID }` of the focused pane, or `nil`. |
| `vesta.capture([scrollback])` | Focused pane's text as a string. |
| `vesta.state()` | The full project/session tree as a table. |
| `vesta.split([horizontal])` | Split the focused pane. |
| `vesta.tab([action])` | `"new"` / `"next"` / `"prev"` / `"close"`. |
| `vesta.select(project, session)` | Jump to a session by index (0-based). |
| `vesta.zoom()` | Toggle zoom on the focused pane. |
| `vesta.open(path)` | Open a new session at a path. |
| `vesta.browser([url])` | Open a browser pane. |
| `vesta.focus([id])` | Focus a pane by id, or cycle to the next pane. |
| `vesta.cmd(verb, ...args)` | Low-level: run any control verb, returns a table. |

### UI

| Call | Description |
|------|-------------|
| `vesta.notify(msg [, opts])` | In-app toast + entry in the bell list. `opts = { title, desktop }`: a desktop (Notification Center) banner fires when Vesta is backgrounded; `desktop = true` forces one even when focused. Desktop banners need the bundled `Vesta.app`. |
| `vesta.status(text)` | Set the chrome status text. |
| `vesta.prompt(message [, default], fn)` | Free-text input; `fn(text)`. |
| `vesta.confirm(message, fn)` | Yes/No; `fn(true\|false)`. |
| `vesta.pick(items, fn)` | Single-select; `fn(label)`. Items are strings or `{ label, desc }`. |
| `vesta.pickmulti(items, fn)` | Multi-select (Tab marks); `fn(table_of_labels)`. |
| `vesta.menu(items)` | Action list; each item `{ text, desc, action = fn }` runs its own `action`. |
| `vesta.panel(lines, opts)` | Create/update a floating panel → returns its `id`. |
| `vesta.close(id)` | Close a panel. |

**Picker sizing.** `pick`/`pickmulti`/`menu` take an optional final `opts` table. By
default the panel hugs its content (width to the widest row, height to the row count) and
scrolls past a generous max. Override per call: `{ width = 600 }` (fixed width),
`{ height = 460 }` (force a tall panel — the old always-large look), `{ maxrows = 8 }` or
`{ maxheight = 300 }` (start scrolling earlier). e.g.
`vesta.pick(items, fn, { maxrows = 6 })`.

**Panels.** `lines` is an array; each line is one of:
- a string, or `{ text = , color = "#rrggbb" }` — a label,
- `{ text = , color = , click = fn }` — a clickable list row,
- `{ input = true, placeholder = , action = fn }` — an editable field;
  `action(text)` fires on Enter,
- `{ svg = "<svg…>", h = 240 }` or `{ image = "/path.png", h = 240 }` — render an
  image (inline SVG markup is rasterized; `h` is an optional display height),
- any line may also set `prefix = "│ ● "` + `prefixColor = "#rrggbb"` — a colored
  leading run before `text` (e.g. a graph gutter with a white subject). Rows are
  packed tight so a `│`/`●` prefix column connects into a continuous line.

`opts = { title, corner = "topright"|"topleft"|"bottomright"|"bottomleft",
bg = "#rrggbb", width, height, id, window = "active"|"all" }`. `height = N` makes
the panel's content scroll inside a fixed height. Pass a previous `id` to update a
panel in place. `window = "all"` renders it in every window; the default follows
the active window.

Panels are **floating cards the user can rearrange**: drag the title bar to move
(snaps to a 20px grid + the four corners), click anywhere on a card to bring it to
front, and click the `–` to edge-minimize it (docks to the nearest edge leaving a
grab tab; click to restore). Each panel's position + minimized state persist per
**title** across launches, so give panels you want remembered a stable `title`.

### Events

Register with `vesta.on(name, fn)`. Handlers receive the relevant `paneID`
(except `config-reloaded`).

| Event | When |
|-------|------|
| `config-reloaded` | After init/plugins (re)load. |
| `dir-changed` | The focused pane's working dir changed. |
| `command-finished` | A foreground program returned to the shell. |
| `session-opened` | A new session was created. |
| `focus-changed` | The active session changed. |
| `session-closed` | The user closed a session. |
| `session-exited` | A shell exited on its own. |
| `pane-output` | Raw output bytes from any live pane: `fn(paneID, chunk)`. |

`pane-output` fires for **every** live pane and hands you raw bytes (binary-safe;
use `chunk:find(needle, 1, true)`). It's best-effort and coalesced under load, and
only works in persist mode (the default) where a daemon owns the PTY.

## Safety

Plugins can't crash Vesta:
- Every callback is error-isolated; an error shows a toast.
- A plugin whose callback errors 5 times in a row is **auto-disabled** (re-enable
  with `vesta plugins enable <name>`).
- A callback stuck in an infinite loop is **aborted** by an instruction-budget
  guard rather than freezing the UI.

Scrollback is persisted to disk by the daemon, so a pane's history survives a
daemon restart or reboot — nothing to do from a plugin.

See `examples/starter/init.lua` for all of the above in one runnable file.
