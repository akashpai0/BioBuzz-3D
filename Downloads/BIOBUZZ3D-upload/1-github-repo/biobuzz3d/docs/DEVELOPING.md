# Developing BIOBUZZ 3D

## Setup (once per computer)

1. **Godot 4.5.stable**, standard build (not .NET): <https://godotengine.org/download/archive/4.5-stable/>.
   Newer 4.x opens it too, but builds and tests are made with 4.5 — keep the
   team on one version.
2. **Export templates 4.5**: Editor → Manage Export Templates → Download and Install.
3. Clone the repo, open `project.godot` from the Godot project manager.
4. **Epic plugin binaries**: follow `addons/epic-online-services-godot/bin/README.md`.
5. **Epic credentials** (only for internet rooms): copy
   `eos_credentials.example.cfg` → `eos_credentials.cfg` and fill in the IDs
   from the Epic Developer Portal (ask the team lead for them). It is in
   `.gitignore` — never commit it. `docs/ONLINE.md` explains the portal setup.

Press **F5**. No errors should be printed on start.

## Rules of the codebase (read before changing things)

- **Constants live in `scripts/bb.gd`**, each with its manual section. Change the
  number there, nowhere else.
- **Everything visual is built from code** (no `.tscn` art). The robot's look is
  `scripts/robot_body.gd`; the team CAD path is `scripts/cad_import.gd`.
- **The shared UI kit is the `Gui` autoload** (`scripts/ui.gd`). Not `UI` — that
  name clashes with the Epic plugin's `EOS.UI` class and breaks the plugin.
- **Online**: `scripts/net/`. The host's game is the authoritative room
  (`net_room.gd`); every player, including the host, talks to it through
  `net_session.gd`. `net_eos.gd` is the only file that touches the Epic plugin,
  and it works when the plugin is missing (it says why internet play is off).
- **Browser build**: `OS.has_feature("web")` turns off online rooms and CAD import
  with a sentence to the player. Don't add features that need the file system
  or raw networking without a web fallback.
- Physics runs at **180 Hz** on purpose (see the comment in `project.godot`).
- Keep `docs/DEVLOG.md` up to date: add a STATUS block at the top of
  "STATUS / RESUME HERE" for every session — what changed, what was verified,
  what is open.

## Tests

`tools/` holds headless test harnesses (`debug_*.tscn`). Each prints `[ok]` /
`[FAIL]` lines and exits non-zero on failure.

```
tools/run_tests.sh          # quick set, ~10 min
tools/run_tests.sh full     # everything, ~45 min
```

Logs land in `build/test-logs/`. The runner gives every test its own throwaway
profile folder, because tests create and delete replays, scenarios and settings.
If you run a single test by hand, do the same:

```
XDG_DATA_HOME=/tmp/t godot --headless --path . tools/debug_menus.tscn
```

(on Windows in Git Bash also set `APPDATA=/tmp/t`). Tests that draw the UI
(`shot_all`, `debug_ui_repairs`, `debug_cad_robot`) need a display; on a Linux
server wrap them in `xvfb-run`.

Useful ones:

| Test | Covers |
|---|---|
| `_chk` | every script compiles |
| `debug_menus`, `shot_all` | every screen opens and fits (captures to `_shots/`) |
| `debug_editor` | scenario editor |
| `debug_replay -- write` then `-- read` | replays survive a restart |
| `debug_net_2proc` | a real host + a separate joining program over the LAN path |
| `debug_net_eos_sim` | the internet path against simulated Epic services |
| `debug_ui_repairs -- W H` | focus rings, editor mouse mapping, Esc from a test |
| `debug_cad_robot -- <file.stl>` | team CAD import, rotation, CAD-only robot |

## Builds

| Target | How | Output |
|---|---|---|
| Windows | Project → Export → **Windows Desktop** → Export Project | `build/windows/` — `BioBuzz3D.exe` + 3 DLLs (ship all four) |
| Browser | `tools/build/export_web.sh` (Linux/macOS/Git Bash, `godot` on PATH) | `build/web/` — upload the folder's contents |
| Linux | Project → Export → Linux | `build/linux/` |
| macOS | Project → Export → macOS (universal, ad-hoc signed) | `build/macos/BioBuzz3D.zip` — no internet rooms (the plugin has no macOS binaries here) |

The browser export needs the **no-threads** web template (it is part of the
normal 4.5 export templates). It is exported without threads on purpose, so it
runs on any host (GitHub Pages, itch.io, pandara.org) without special headers.

Exporting on Windows also lets Godot set the exe icon and version info
(Editor Settings → Export → Windows → `rcedit`); builds made on Linux keep
Godot's default icon.

## Known open items

See the top STATUS blocks in `docs/DEVLOG.md`. At the time of writing:

- Two-computer **internet** test not done yet (Epic login + room creation were
  verified on one PC; a second connection has not joined).
- `debug_net_client`: one check fails intermittently (host killed right after
  Lobby → Start; the guest's copy of that new run is sometimes missing).
- Browser version: performance on low-end laptops/Chromebooks not measured.
