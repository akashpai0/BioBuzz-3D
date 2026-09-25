# 2026-09-24e — smoother and sharper (mainly the browser version)

- **Smooth motion:** robots, balls and the HIVE are drawn between physics steps
  (physics interpolation). Visual only — the simulation is identical. Fixes the
  judder when the frame rate isn't a multiple of 180 (most browsers, 144 Hz
  screens).
- **Graphics → Quality: Low / Medium / High / Max**, plus Resolution (75–200 %),
  Anti-aliasing and Shadows (Off/Low/High/Ultra). Max renders at 2× and shrinks
  down (supersampling). High is the default.
- **Crisper shadows:** the sun's shadow now covers 12 m instead of 100 m.
- Changed: `project.godot`, `scripts/bb.gd`, `camera_rig.gd`, `main.gd`,
  `robot.gd`, `robot_preview.gd`, `opponent_overlay.gd`, `settings.gd`,
  `settings_menu.gd`; new `tools/shot_quality.*`, `tools/perf_frame.*`.
- No change to online rooms (GAME_VERSION unchanged).

# Changed files — player-hosted online rooms (Epic Online Services)

Against the dedicated-server online build of 22 September 2026
(exe SHA-256 `c5ab5d4a…edad2760`, 97,846,768 bytes).

This build: `BioBuzz3D.exe` — size and SHA-256 in the delivery note
(`DELIVERY.txt`).

**Status:** implemented; tested locally (separate programs, one machine) and in
simulation; **EOS never run for real and no internet test yet** — see
`ONLINE.md` → Status and "Internet test (do this first)".

## Architecture change

The room no longer runs on a rented server. **The host player's game is the
room**: its own world is the authoritative simulation, and it serves the other
players. Internet discovery and connectivity come from **Epic Online Services**
(free) through the EOSG plugin; a same-network path covers one site and the
tests. The room service (broker), room processes and server deployment files are
gone.

## New

| File | What |
|---|---|
| `scripts/net/net_invite.gd` | invites: `BBZ1-E.<lobby>.<host id>.<secret>` / `BBZ1-L.<addr:port>.<secret>`; 26-char secure secret; parsing with plain-language errors |
| `scripts/net/net_eos.gd` | EOS via EOSG, looked up at run time only: anonymous persistent Device-ID login, the room's lobby directory entry, lookup by id, P2P links, relay control, NAT type; keeps EOSG ticking while the world is paused |
| `eos_credentials.example.cfg` | template for the five IDs from the developer portal |
| `tools/debug_net_link.gd` | transport + fragmentation at the EOS packet limit |
| `tools/debug_net_eos_sim.gd`, `tools/eos_sim_guest.gd`, `tools/fake_eos/` | the internet path's logic against EOSG stand-ins, two programs (simulated) |

## Rewritten / changed

| File | Change |
|---|---|
| `scripts/net/net_link.gd` | any MultiplayerPeer (ENet or EOSGMultiplayerPeer) or an in-process pair; 1164-byte datagrams with fragmentation; route (direct / relayed / same network / hosting) |
| `scripts/net/net_room.gd` | runs inside the host's game; several links; admission by invite secret (constant-time), refused connections dropped; `closed` signal instead of quitting; silent-peer timeout; lobby status updates; **Low upload** (30 snapshots/s) |
| `scripts/net/net_session.gd` | connects through a link factory (reconnect = call it again); queues messages until admitted; loss measured from snapshot gaps; route |
| `scripts/net/net_client.gd` | **Host room** / **Join** by invite; host sees the live world (no puppet); host leaving ends the session; EOS node |
| `scripts/net/online_screen.gd` | Host (Over the internet / Same network only) · Join by pasting an invite · EOS status and NAT type · relay test setting |
| `scripts/net/lobby_screen.gd`, `net_hud.gd` | Copy invite, host wording, per-player route (direct / via Epic relay), Low upload, End session |
| `scripts/net/net_role.gd`, `net_proto.gd` | protocol 2; broker messages removed; `SET_RATE` |
| `scripts/boot.gd` | the game only (plus `--host-test` for the harnesses) |
| `scripts/main.gd` | room routing by `net_room` instead of "is server"; Test drive blocked while in a room |
| `export_presets.cfg` | include `eos_credentials.cfg` in exports |
| `tools/debug_net*.gd`, `perf_net.gd`, `demo_online.gd`, `net_bot*.gd` | ported to hosted rooms and invites |
| `ONLINE.md`, `README.md`, `DEVLOG.md` | rewritten for player-hosted rooms |

## Removed

`scripts/net/net_broker.gd`, `deploy/` (Dockerfile, run script, systemd unit).

## Test results

See `ONLINE.md` → Test record, and `DELIVERY.txt` for the offline suite.

---

# 23 September 2026 (later) — UI repairs merged, EOS plugin built in

Build: `BIOBUZZ3D-ui-fixes\BioBuzz3D.exe` — sizes and SHA-256 in `DELIVERY.txt`.

## Merged from "BioBuzz UI and scenario-editor repairs"

| File | Change |
|---|---|
| `scripts/ui.gd` | focus outline drawn inside the control (hollow, inset 3 px) so scroll panels no longer clip it; `weight()` emboldens the glyphs instead of painting an outline |
| `scripts/scenario_editor.gd` | field clicks/drags/ghost converted from panel-local to viewport coordinates; camera fits the field between the panels (width and height, correct centring, refits on resize); tooltip on Test scenario |
| `scripts/main.gd` | Esc (or the pause action) during a scenario test returns to the unchanged draft — before the match, while running, and after it finishes |
| `scripts/robot_preview.gd` | the preview renders at its displayed pixel density |
| `project.godot` | `window/dpi/allow_hidpi=true`, `rendering/scaling_3d/scale=1.0` (existing `canvas_items`/`expand` kept) |
| `tools/debug_ui_repairs.*` | new regression test (53 checks per resolution) |

The supplied `ui.gd` differed from ours only by these fixes plus an older
comment; ours (the `Gui` autoload note) was kept. Nothing else in the supplied
files was newer than our source.

## Also in this build

- **EOSG 2.3.1 plugin is now part of the project** (`addons/`, autoloads,
  plugin enabled) and the export carries its DLLs:
  `libeosg.windows.template_release.x86_64.dll`, `EOSSDK-Win64-Shipping.dll`,
  `xaudio2_9redist.dll`. `eos_credentials.cfg` (Julian's product) is exported.
- Tests fixed to be honest now that the plugin is present:
  `debug_net_2proc` (the "Epic unavailable says why" check no longer assumes a
  plugin-less build), `fake_eos` (steps the real EOSG autoloads aside),
  `debug_net_client` (waits for the replay chunk/notice instead of fixed delays;
  in a clean profile the old version failed on pre-merge code too — it had been
  passing only because of replays left over from earlier runs).

## 24 September 2026 — STL import

| File | Change |
|---|---|
| `scripts/cad_import.gd` | STL faces were drawn inside-out (STL is counter-clockwise, Godot's front face is clockwise) — fixed; normals worked out from the corners (exporters often write zeros); ASCII STL with tabs parsed; a cut-short binary file refused with a sentence; too-big files explain how to export lighter (Fusion/SolidWorks/Onshape settings); loaded models cached, so rebuilding the robot does not re-read the file; `fit_to_robot` takes an up axis |
| `scripts/robot_shop.gd`, `robot_body.gd`, `robot_menu.gd` | new **Which way is up** (Z / Y / X; STL defaults to Z, glTF to Y) — CAD STL no longer lies on its side; a refused import shows its reason in red under **Import model** |
| `tools/debug_cad_stl.*`, `tools/shot_cad_garage.*` | STL import test (pass a real file with `-- path`), Garage capture after an import |

## 24 September 2026 — the team's CAD is the robot

| File | Change |
|---|---|
| `scripts/robot_body.gd` | with a CAD model loaded, **only the CAD is drawn** — no frame, bumpers, rollers, wheels or turret; `load_cad()` |
| `scripts/robot.gd`, `scripts/main.gd` | our alliance's robots use the CAD and hide the stock wheel/launcher meshes (they still work: that is the physics); opponents keep the stock robot so the alliances are easy to tell apart |
| `scripts/cad_import.gd` | any rotation (`rot_basis`: tip X, roll Z, turn Y); placement measured from the model's convex hull so a turned model sits exactly on the floor and inside the 18 in footprint |
| `scripts/robot_shop.gd` | `model_rot` (degrees, 3 axes) replaces yaw + up axis; older saves are converted |
| `scripts/robot_menu.gd` | **Line it up**: Tip / Turn / Roll sliders with ±90° buttons and Reset; the preview shows guides while on Appearance |
| `scripts/robot_preview.gd` | guides: the 18 in cube, a yellow FRONT · INTAKE arrow and edge, BACK (or BACK · INTAKE with two intakes), LAUNCHER · turret, top middle |
| `tools/debug_cad_robot.*` | test + captures (replaces `shot_cad_garage`) |

## 24 September 2026 — team credit

`scripts/menu.gd`, `assets/pandara_panda.png`: the team panda + **BUILT BY 506 PANDARA · pandara.org ↗** (506 in the panda's purple) at the top right of
the Play page, above the controller status; click (or focus + Enter) opens
https://pandara.org. The Online card now says "send an invite" instead of "share a code".

