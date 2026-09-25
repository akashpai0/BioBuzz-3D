# Replays and "Practise from here"

Every run you play is recorded. Watch it back, find the moment it went wrong,
and turn a moment just before it into a saved situation you can drive again —
straight away, and as many times as you like.

    Play  →  Watch replay  →  find the mistake  →  pick an earlier moment
          →  Practise from here  →  Start practising  →  Retry

## Where to find it

- **Results screens.** Match results and practice-attempt results both have
  **Watch replay**. Back returns you to the same result card, and Retry still
  works from there.
- **Progress → Replays.** The whole collection, with a **Latest replay**
  shortcut at the top.

Watching only happens when no run is going. If a run is paused behind the
menus, the Replays page says so and asks you to resume it or end it from the
pause menu first. The game never throws a paused run away to show a replay.

## What gets recorded

Every full match, teleop run, free practice session, saved-situation attempt
and editor test is recorded automatically. Nothing to turn on. Test drives
from Controls and guided autonomous recording are not recorded.

- A new file starts on the first moment the run is actually played. Opening
  a menu, loading a situation or entering the editor never creates an empty
  replay, and never replaces an older one.
- **Retry** saves the attempt you just gave up on as its own replay, marked
  **Abandoned**, before the new attempt starts.
- Ending a run from the pause menu, starting another, or closing the game
  window mid-run saves what was played, marked **Abandoned** (or **Ended**
  for free practice, which has no finish line).
- Outcomes: *Finished* (a match that ran to the end, with its final score),
  *Objective completed*, *Objective failed*, *Abandoned*, *Ended*,
  *Incomplete* (recording stopped early, see below).

### What is in a recording

**Recorded state, not your inputs.** A replay is never made by feeding your
controller back into the physics. It holds what was on the field:

| Kind | How often | What |
|---|---|---|
| Samples | 30 per second (every 6th physics tick) | robot poses, turret and hood angles, hopper counts, enabled, battery; both HIVE swings; every ball's pose and who holds it; match phase, clock, scoreboard, foul points; each opponent's status line whenever it changes |
| Checkpoints | once per second | a complete saved-situation snapshot: poses and velocities, mechanisms, hoppers, battery, clock, scoreboard, hives mid-swing, human-player queue, autonomous playback, and each AI opponent's settings **and** what it was in the middle of (route position, target, time left on a wait) |
| Events | as they happen | shot launched, successful shot, HIVE tipped, foul / warning, phase change, objective completed / failed — each with a stable id |

Time is counted in physics ticks (1/180 s), so recorded times are exact to
the tick and pauses are skipped entirely. Samples land every 33.3 ms,
checkpoints every 1.000 s.

"Successful shot" means what it already meant in the match stats: a ball you
launched reached a CELL within 6 s. It is not a promise the points survived
to the final score. The scoreboard shown is the in-game scoreboard; CELL and
FLOWER points only appear on it at the buzzer, exactly as in a match.

## The viewer

The field fills the screen. Along the bottom: the timeline (click or drag
anywhere), elapsed replay time, the recorded match clock, previous / next
checkpoint, play / pause, speeds 0.25× 0.5× 1× 2×, the camera, the event list,
**Practise from here** and **Back**. Every key is printed on screen.

| | Keyboard | Controller |
|---|---|---|
| Play / pause | Space | X |
| Step 1 s / 5 s | ← → / Shift ← → | hold a trigger to scrub |
| One sample | , . | |
| Previous / next checkpoint | [ ] | LB / RB |
| Speed | 1 2 3 4 | |
| Camera | C | Y |
| Events | E | View / Back |
| Practise from here | P | focus the button, A |
| Back | Esc | B |

Controller: the D-pad moves between buttons and A presses the focused one.
None of this is a driving binding — no run is going while you watch.

**What is recorded and what is yours.** The clock, scoreboard, hoppers,
batteries and opponent status are the recording. The camera, speed and event
panel are your viewing settings and change nothing. Robots are drawn with
your *current* Garage model; the recorded robot profile name is shown.

**Watching is read-only.** While the viewer is up the game world is frozen
and stopped: physics does not step, no robot reads a controller, no opponent
decides anything, and nothing scores, fouls, picks up, tips, makes a sound or
creates an attempt. Poses are smoothed between samples for display, but never
across a ball changing owner or a jump too big to be motion; every number is
the last recorded value.

**Events.** Select one to jump to it, or **−3 s** to see the lead-up.

## Practise from here

1. Pause at the moment you want (or just press the button — it pauses).
2. The playhead moves to the nearest **complete checkpoint** and says so,
   with both times, if you were between two. The game will not simulate
   forward to invent the exact in-between moment.
3. You see what that moment holds: clock, recorded score, each robot's
   hopper, battery and speed, each opponent's behavior and what it was doing,
   any balls already in the air (with the rule for how objectives treat them),
   and any autonomous routine in progress.
4. Name it and **Save situation**. It goes into your ordinary situation
   library. Then **Start practising**, **Edit scenario**, or keep watching.

The new situation:

- starts from everything the checkpoint recorded — including opponents
  mid-route or mid-wait, which carry on from there rather than starting over;
- is **Free practice** with **no objective**. The original run may have been
  one point from its goal; that is not inherited. Add an objective in the
  editor if you want one — it counts from zero, even though the historical
  scoreboard is kept as the starting state;
- gives controllers out through today's seat allocation, never an old
  controller id;
- **Retry** always returns to that saved moment.

Saving or practising from a replay never changes the replay or its result,
and deleting a replay later never deletes situations saved from it.

What it does **not** promise: identical physics afterwards. The restored
contact set is not the one the original run had built up, so a ball balanced
on a rim may fall the other way. Everything you can see and act on starts
the same; what happens next is a real simulation.

## The replay collection

**There is no limit on how many replays are kept.** Disk space is the only
limit, and nothing is ever deleted unless you delete it. Progress → Replays
lists every one, newest first, with date and time, editable title, length,
mode, situation, outcome, recorded score and file size.

- **Search** titles, situations, modes, outcomes and tags (`#tag` works).
- **Sort** by newest, oldest, longest, highest score, title, file size.
- **Filter** by mode and outcome, or favourites only.
- Per replay: ★ favourite, **Watch**, **Practise…**, **Rename**, **Tags**,
  **Show file** (opens your file manager on it), **Delete**.
- Tick several and **Delete selected** — the confirmation states how many
  replays, how many files and how much space, and that situations saved from
  them are not affected.
- Titles can repeat. Each replay has its own unique file name, so renaming
  never overwrites anything.

The list is built from small per-replay detail files and a cache — never by
opening the recordings — and shows 25 at a time.

### Where the files are

The folder is shown on the Replays page with **Open replay folder**. By
default it is the game's own data folder:

- Windows: `%APPDATA%\Godot\app_userdata\BIOBUZZ 3D\replays`
- Linux: `~/.local/share/godot/app_userdata/BIOBUZZ 3D/replays`

Each replay is two files: `r-<date>-<time>-<n>.bbreplay` (the recording) and
`r-….json` (its title, favourite, tags and summary). `index.json` is only a
cache and can be deleted; it is rebuilt from the files.

**Change folder…** asks what you mean:

- **Switch** — new replays go to the new folder; the ones already recorded
  stay where they are and show again if you switch back;
- **Move and switch** — each replay is copied, checked, and only then removed
  from the old folder. Any that fail stay where they were, and you are told.

The folder cannot be changed while a run is being recorded.

### Long free practice

A free practice session records for as long as it runs — no rolling window,
nothing at the start dropped. Data is written to disk once a second, so the
game's memory use does not grow with the length of the session, and the
viewer reads only the part of the file it is showing, so seeking anywhere in
a long session is as quick as in a short one. One session is one file.

### When something goes wrong

- **The disk fills up or refuses a write.** Recording stops; the run carries
  on. The HUD says so and says how much was saved ("saved up to 0:03.0"). The
  replay is listed as **Incomplete** and plays up to that point. It is never
  shown as a finished recording.
- **The game is closed or crashes mid-run.** Everything written up to the last
  second is kept. After a crash, the replay is listed as *Recovered —
  playable up to m:ss*.
- **A file is damaged or from a newer version of the game.** It is listed with
  what is wrong ("not a BIOBUZZ replay", "recorded by a newer version",
  "recording file is missing"); healthy replays are unaffected. A recording
  with one damaged block still opens, and the damaged section says so.
- **Low disk space** (under 200 MB) is warned about; recording continues.

## Measured costs

Measured in this project's build container — **Intel Xeon @ 2.80 GHz, 2
logical cores, Linux, Godot 4.5-stable, headless, no GPU** — running as fast
as the CPU allows (`--fixed-fps 180`). Single runs; not a gaming PC.

**Teleop match, 4 robots (you, AI partner, 2 Collect opponents), 56 balls, 60 s:**

| | |
|---|---|
| Recorder's share of each physics tick | 46 µs average (whole tick ≈ 2.4–3.1 ms) |
| Ticks with no sample (5 of every 6) | ~1 µs |
| Sample ticks | 192 µs avg, 373 µs p99 |
| Once a second: block write + sample + checkpoint capture | 1.3 ms avg, 2.0 ms worst |
| Once a second, 3 ticks later: checkpoint encode + write | 1.3 ms avg, 2.1 ms worst |
| One checkpoint | capture 0.60 ms + JSON 0.85–0.91 ms + zstd 0.14 ms → 3 KB (16 KB raw) |
| File growth | **1.04–1.09 MB per minute** (samples ≈ 850 KB, checkpoints ≈ 230 KB, events ≈ 4 KB) |

**Free practice, you + 1 Collect opponent, 56 balls, 20 simulated minutes,
driver moving throughout:**

| | |
|---|---|
| File | 11.4 MB for 20 minutes = **0.57 MB per minute** (0.84 MB/min in the first two busy minutes) |
| Game memory (static allocations) | +0.67 MB in the first minute, then **+0.01 MB from minute 5 to minute 20** |
| Recorder buffer | never more than 30 samples (one block) |
| Opening the 20-minute file | 17.8 ms (2 451 chunk headers, 92 events) |
| Random seek, cold | 3.7–5.0 ms average, 5.3–8.8 ms worst (200 seeks) |
| Playback step within cached data | 0.19 ms (posing the field 0.06 ms, panels 0.05 ms) |

As a rough guide from those two rates: a 2:30 match with four robots is about
2.7 MB; an hour of busy free practice is roughly 35–65 MB.

**Library of 2 000 replays:** listed with no cache in 476 ms, with a fresh
cache in 165 ms; the Replays page opened in 362 ms; search over all 2 000 in
under 10 ms; **no recording was opened to list them**.

These numbers do not include a GPU-rendered game, where frame time is set by
rendering; the recorder's cost is CPU work on the physics tick either way.

## Format (for tools)

`.bbreplay`: 16-byte header (`BBREPLAY`, u32 version, u32 reserved), then
chunks of `u32 'BBCK', u8 type, 3 reserved, f64 t0, f64 t1, u32 raw length,
u32 compressed length, u32 checksum` + a zstd payload. Types: 1 header
(JSON), 2 samples (Godot `var_to_bytes([meta, PackedFloat32Array])`),
3 checkpoint (JSON, a `biobuzz.situation` snapshot plus `replay_t`), 4 events
(JSON), 5 final (JSON). Append-only; readers index chunk headers without
decoding payloads and stop cleanly at the first incomplete or damaged chunk.
Version 1. A newer version is refused with a message, never guessed at.

## Limitations

- Robots are drawn with your current Garage model, not the one used then
  (the profile name is recorded and shown).
- Wheel spin, intake rollers and other purely decorative motion are not
  recorded; drivetrain pose, turret, hood and hopper contents are.
- Practise from here snaps to whole-second checkpoints.
- Situations from a replay are Free practice. Change the mode in the editor
  if you want the recorded clock to run.
- One recording per run; there is no video export, sharing or cloud copy.
- Very long sessions list at most 600 events in the side panel (launches are
  left out first); all of them stay marked on the timeline.
- **No physical controller has been connected to this project.** The viewer's
  controller buttons are tested with synthetic input events only.
