# dodo

A simple terminal outliner app for lists and todos. 200KB native app.

## Features

This is a very simple tracking app:

- press ENTER to create a new item
- press SPACE to mark it as done
- other shortcuts displayed at the bottom

<img width="681" height="336" alt="Screenshot 2026-05-28 at 16 30 17" src="https://github.com/user-attachments/assets/9f7112a1-63a2-4eff-b37a-3cdfb38b5134" />

## Data storage

Lists are saved to a single tab-delimited `lists.txt`.

On the **first launch**, if iCloud Drive is enabled on the Mac, dodo asks
whether to store your lists there — putting them in iCloud syncs them across
your Macs for free. 

```
# iCloud (if you opt in) — synced across your Macs:
~/Library/Mobile Documents/com~apple~CloudDocs/dodo/lists.txt

# local (the default when iCloud is unavailable):
$XDG_DATA_HOME/dodo/lists.txt      # if XDG_DATA_HOME is set
~/.local/share/dodo/lists.txt      # otherwise
```

Settings are stored at `$XDG_CONFIG_HOME/dodo/config` or `~/.config/dodo/config`.

## Themes

10 built-in themes (todo: custom theming).

<img width="320" alt="image" src="https://github.com/user-attachments/assets/155d1ceb-69e0-485c-927f-82f4d16fcc84" />

<img width="320" alt="image" src="https://github.com/user-attachments/assets/d49672b7-8307-4805-9ba2-ef6e41a12097" />

<img width="320" alt="image" src="https://github.com/user-attachments/assets/e1f1a01c-286a-4207-9d95-e01199135d51" />

## Development

TDB

```sh
c3c run dodo          # build + run
# or
c3c build dodo && ./out/dodo
```

Requires `c3c` 0.8.0.

## Inspired by

- https://checkvist.com/
- https://github.com/charmbracelet/bubbletea
