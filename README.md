# quire

A minimal daily todo list app for macOS that uses vim, markdown format, Canvas integration and automatically carries forward incomplete tasks from yesterday.

## What it does

- **Daily outline pages** — one markdown file per day (`YYYY-MM-DD.md`), stored wherever you choose (iCloud, Dropbox, Git, or just `~/Documents/Quire`).
- **Checkbox tasks** — `[ ]` / `[x]` / `[?]` (todo / done / waiting), cycled by clicking.
- **Carry-forward** — incomplete tasks from the previous day appear automatically on today's page.
- **Canvas LMS sync** — pulls upcoming assignments from your institution's Canvas instance and inserts them under a `## Canvas` heading (optional; credentials stored in the macOS Keychain).
- **Task timers** — click the ▶ pill on any checkbox line to start a per-task stopwatch. History is persisted to SQLite.
- **Vim mode** — opt-in modal editing (normal / insert / visual / v-line) toggled via `⌃⌥V`.
- **Headings & bold** — `## Heading`, `**bold**` rendered inline with markers hidden.

## Requirements

- macOS 14 Sonoma or later
- Xcode 16 / Swift 6 toolchain

## Build & run

```bash
git clone https://github.com/YOUR_USERNAME/quire.git
cd quire
swift run
```

Or open the folder in Xcode (`File → Open…`, select the directory) and press ▶.

## Storage

| Data | Location |
|---|---|
| Daily `.md` files | `~/Documents/Quire/` (configurable in Settings → General) |
| SQLite (timers, Canvas dedup) | `~/Library/Application Support/Quire/quire.sqlite` |
| Canvas credentials | macOS Keychain (service `app.quire.canvas`) |

## Outline format

Each line follows `<tabs>- [optional checkbox] body`:

```
- ## My heading
- [ ] a task to do
	- [x] a completed sub-task
	- [?] waiting on someone
- a plain bullet
- **bold text** inline
```

Indentation is tabs. Pressing **Enter** on a blank bullet outdents (or strips the bullet at level 0). **Tab** / **Shift+Tab** indent and outdent.

## Canvas integration (optional)

1. Open **Settings → Canvas**.
2. Enter your school's Canvas host (e.g. `yourschool.instructure.com`).
3. Paste a personal access token (generated at *Account → Settings → New Access Token*).
4. Click **Save & Sync**.

Quire syncs every 15 minutes and deduplicates on the assignment ID, so running the sync repeatedly is safe.

## Vim mode

Toggle with `⌃⌥V` or via the **Vim** menu.

| Mode | Enter with |
|---|---|
| INSERT | `i` `I` `a` `A` `o` `O` |
| NORMAL | `Esc` |
| VISUAL | `v` |
| V-LINE | `V` |

Motions: `h j k l w b 0 ^ $ gg G` · Edits: `x dd yy p P u` · Visual ops: `d y c`

## License

MIT — see [LICENSE](LICENSE).
