# dodo

A Checkvist-style outliner in your terminal — nested, checkable todo lists.
Built in [C3](https://c3-lang.org) on the **milktea** TUI framework (the
`bubble-tree` repo next door).

## Build & run

The build pulls the framework straight from `../bubble-tree`, so keep the two
directories side by side.

```sh
c3c run dodo          # build + run
# or
c3c build dodo && ./out/dodo
```

Requires `c3c` 0.8.0.

## Keys

**Lists screen**

| Key | Action |
|-----|--------|
| `↑`/`↓` or `k`/`j` | move |
| `enter` | open the list |
| `n` | new list (then type its name) |
| `r` | rename the selected list |
| `d` | delete the selected list |
| `q` / `esc` / `ctrl+c` | quit (saves) |

**Items screen**

| Key | Action |
|-----|--------|
| `↑`/`↓` or `k`/`j` | move |
| `space` | toggle complete |
| `tab` | indent (nest under the item above) |
| `shift+tab` | outdent |
| `enter` | new item below, start typing it |
| `e` | edit the current item |
| `d` | delete the current item |
| `esc` / `←` | back to the lists screen |
| `q` / `ctrl+c` | quit (saves) |

While editing an item, `enter` commits it and immediately opens a fresh sibling
(rapid entry), `backspace` on an empty item deletes it, and `tab`/`shift+tab`
re-nest without leaving edit mode.

## Where your data lives

Lists are saved to a single tab-delimited `lists.txt`, automatically on quit
(and on `ctrl+s`), and loaded on startup.

On the **first launch**, if iCloud Drive is enabled on the Mac, dodo asks
whether to store your lists there — putting them in iCloud syncs them across
your Macs for free. Your answer is remembered, so you're only asked once.

```
# iCloud (if you opt in) — synced across your Macs:
~/Library/Mobile Documents/com~apple~CloudDocs/dodo/lists.txt

# local (the default when iCloud is unavailable):
$XDG_DATA_HOME/dodo/lists.txt      # if XDG_DATA_HOME is set
~/.local/share/dodo/lists.txt      # otherwise
```

The storage choice is a local, per-machine preference kept in the standard
config dir: `$XDG_CONFIG_HOME/dodo/config` (or `~/.config/dodo/config`).

## Layout

- `src/store.c3` — data model (`Item`, `TodoList`) and load/save.
- `src/main.c3` — the milktea model: input handling and rendering.
