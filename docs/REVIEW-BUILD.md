# BIOBUZZ 3D — review build

A driver-practice simulator for the FTC 2026-27 BIOBUZZ game, built in Godot
4.5 with real rigid-body physics. This build exists to be **driven by people
who did not write it**, on their own machines, with their own controllers.

Read `ASSESSMENT.md` before you form an opinion about realism: it says plainly
what has been checked and what is still a guess. `CHANGES.md` lists every file
touched in this pass and why. This release exists to close the findings of an
independent review; its section at the end of this file is the short version.

---

## Exactly what was tested

| | |
|---|---|
| Engine | **Godot 4.5.stable.official.876b29033** |
| Renderer | Forward+ (Vulkan), `gl_compatibility` only on the web target |
| Physics | Jolt, 180 Hz tick, continuous collision detection on |
| Project | `BioBuzz3D/` as shipped in this package — no VCS, so the project folder **is** the revision |
| Rules revision | `BB.RULES_REV = 1` (stamped into every saved practice record) |
| Windows binary | `BioBuzz3D.exe`, exported from that project with the "Windows Desktop" preset, `embed_pck=true`. Its SHA-256 is in `CHANGES.md`. |
| Supersedes | the build reviewed 20 Sep 2026 (project `E6F61705…3780C`, exe `3170865F…83D836`) |
| Verified on | Linux x86_64, headless and under software OpenGL. **The .exe itself has not been run on Windows by me** — see Known limitations. |

The game data is about 0.5 MB; the rest of the .exe is the Godot runtime.
Everything — field, robot, audio, UI — is generated in GDScript at load. There
are no binary assets in the project at all.

---

## Launching it

### Windows

1. Copy **`BioBuzz3D.exe`** anywhere. It is one self-contained file; there is
   nothing to install and nothing beside it to keep.
2. Double-click it.
3. SmartScreen will say "Windows protected your PC", because the binary is
   unsigned. **More info → Run anyway.** There is no code-signing certificate
   for this, and there will not be one.
4. First launch asks for a username. That name is only used to label your own
   scores on this machine.

**If it will not start at all**, the machine most likely has no working Vulkan
driver. Make a shortcut, or run from a terminal, with the compatibility
renderer:

```
BioBuzz3D.exe --rendering-method gl_compatibility
```

That renderer is slower and drops some lighting, but it runs on almost
anything. If that also fails, update the graphics driver and try again.

**Where your data goes.** Saved situations, practice history, settings, the
leaderboard and recorded autos live in
`%APPDATA%\Godot\app_userdata\BIOBUZZ 3D\`. Deleting that folder resets the
game to a first launch. Nothing is uploaded anywhere.

### Running from source instead

Open the `BioBuzz3D` folder in Godot 4.5 and press F5. Same game; useful if you
want to read the code or change a constant in `scripts/bb.gd`.

---

## Controls

The full list is in **Settings → Controls**, and a summary is on the pause menu
(press **Esc**).

| | Keyboard | Controller |
|---|---|---|
| Drive / strafe | `W` `A` `S` `D` | left stick |
| Turn | `Q` / `E` | right stick |
| Shoot (hold to empty) | `Space` | right trigger / A |
| Spit one out | `Z` | B / left trigger |
| Auto-aim | `C` | right stick click |
| Recalibrate turret | `R` | *not bound — set it in Controls* |
| Precision mode (hold) | `Ctrl` | *not bound — set it in Controls* |
| Camera | `Tab` | Y |
| Menu / pause | `Esc` | Start |
| Save this moment | `F5` | — |
| Retry the situation | `F6` | — |

**Settings → Controls** now has four tabs — Seats, Feel, Buttons, Profiles —
for assigning controllers, seeing live what one is sending, tuning deadzones
and response curves, remapping buttons and saving named profiles. There is a
**Test drive** button there that launches a practice field which records
nothing. `CONTROLLERS.md` explains all of it, and carries the manual checklist
for the parts that need a pad in your hands.

**No physical controller has ever been connected to this project.** The
processing maths and the bookkeeping are tested; the feel is not.

## What to try first

Press **Open library** on the Play screen. Four drills ship with the game:

- **Collect and shoot** — 8 successful shots, no clock.
- **Twenty points, forty-five seconds** — a points goal against a deadline.
- **Recover from the corner** — drive to a marked area within 15 s.
- **Final twenty seconds** — 15 points in 20 s *without a foul*.

Every attempt is timed, recorded and compared against your own best. `F6`
restarts the drill from exactly the same field.

---

## Manual test checklist

Twenty minutes, in order. Anything that does not behave as described is worth
reporting, with what you were doing when it happened.

**Launch and setup**
1. The game starts and asks for a name once, not every time.
2. The Play screen names the drills on the shelf without scrolling.
3. Settings → Controls lists your controller by name when one is plugged in.

**Driving**
4. Start Free practice. The robot drives forward, back and strafes at roughly
   the same speed, and does not drift while going straight.
5. Drive a diagonal. It should feel as fast as driving straight and should
   not yaw. (That it is *as fast* is the known simplification above — a real
   mecanum would be slower diagonally.)
6. Hold `Ctrl` (precision mode). The robot slows and stays controllable.
7. Drive into a wall, a HIVE leg and the other robot. Nothing passes through
   anything, and the robot does not climb, levitate or get stuck.

**Intake and shooting**
8. Drive over loose POLLEN. It goes in, and the hopper stops at four.
9. Hold shoot. All four leave in roughly half a second.
10. From about 45 in, shots go into the CELL. Close up, the HUD says "too
    close" rather than letting you fire into the roof.
11. Press `R` mid-match. The turret recalibrates and says so in the event log.

**Scoring**
12. Feed one CELL until it tips. It tips at 8 POLLEN with no NECTAR in it.
13. At the buzzer the score settles for about 3 s before the final number.

**Drills**
14. Open the library, play **Final twenty seconds**. The card in the corner
    shows the goal, the clock and both constraints.
15. Let the clock run out. The result screen says it failed, says why, and
    offers Retry and Back to library in the footer.
16. Press Retry. The field is back exactly where it was and the attempt is
    numbered 2.
17. **Pause test.** Shoot a ball and press `Esc` while it is still in the air.
    The ball should hang exactly where it was — nothing on the field may move,
    drift or settle while the menu is up. Resume: it carries on from the same
    point at the same speed.
18. Do the same but leave via the **nav bar** (click Garage, or Settings)
    rather than `Esc`. It must behave identically; this route used to leave the
    match running behind the page.
19. Open a menu mid-drill. The clock stops, and the time on the result
    afterwards excludes the time you spent in the menu.
20. Deliberately take a foul (hold five balls) on a no-foul drill. The attempt
    fails on the foul, even if you complete the goal on the same instant.
21. On a points drill, reach the goal and then **knock the scoring elements
    back out** before the buzzer. The attempt must fail: the final score is
    what counts, not the highest number the scoreboard ever showed.

**Editor**
22. Library → Edit on any drill. Move a ball, press Test, drive, then Return to
    editor. Your change is still there and still unsaved.
23. Save. Close the game, reopen it. The drill, your change and your practice
    history are all still there.

---

## Known limitations

**Defects**

- **No per-wheel speed cap is modelled**, so a diagonal runs as fast as a
  straight line (67.3 in/s either way). A real mecanum cannot do that —
  normalised kinematics predict about 48 in/s on the diagonal. This replaces
  the previous release's claim that "diagonal driving is wrong, 27 in/s with 7°
  of yaw"; **that measurement was a collision with the HIVE frame inside its
  own test window and the diagnosis is withdrawn.**
- Shots taken while the robot is rotating are less reliable than shots taken
  square, and shots at the far edge of range are the weakest case.
- Closing the game while a drill is running records that attempt as abandoned
  only if you leave through a menu; a hard kill loses it.
- Performance has **not** been re-measured since this pass changed process
  modes across the scene tree. `tools/perf_sample.tscn` is the reviewer's own
  benchmark, kept verbatim, so the same measurement can be repeated.

**Deliberately not modelled**

- No motor curve, current limit, voltage sag under stall, or carpet friction.
  Battery level does fade the drivetrain, but through a simple scale.
- The intake is a capture volume, not rollers: balls cannot jam, fumble or sit
  half in.
- The launcher has no spin-up lag, flywheel droop or shot spread.
- Referee-judgement fouls (pinning, hoarding, interference) are not modelled.
  G304, G407, G408, G410, G417 and G418 are.
- Retries restore identical **starting conditions**, not identical outcomes.
  Jolt is not deterministic, so two identical runs will diverge.

**Untested**

- **No gamepad has ever been connected to this build.** Every controller
  behaviour is unverified against hardware. Try this first.
- **No frame rate has been measured on real hardware.** 180 Hz physics with CCD
  on ~60 bodies is expensive; a weak laptop may struggle. Report what you see.
- The .exe has not been run on Windows. The identical Linux export of the same
  project boots clean, which is evidence, not proof.
- Element masses are fitted to reproduce the manual's tip table, not weighed.
  Weighing one POLLEN and one NECTAR would replace the single tuned number the
  whole tipping model rests on.

**Out of scope for this pass** (asked for, deliberately not added): replay
timeline and free camera, first-run tutorial, online sharing, global
leaderboard.

---

## What changed in this pass, and how it was checked

An independent review on 20 September 2026 reproduced three defects and
disproved one claim this project had made. All four are addressed; nothing else
was added. `CHANGES.md` has the file-by-file detail.

| Finding | Fix | Evidence |
|---|---|---|
| Pause left the world running — a ball travelled 19.47 in during a one-second pause while the attempt clock stood still | Pausing halts the scene tree, and every menu route goes through it. Gameplay timers moved off the wall clock onto a simulation clock that stops with it | `debug_pause`: **16 failures before, 0 after**, across two menu routes. Also caught a route the review had not: the nav bar did not pause the match at all |
| Final scoring confirmed an eight-point goal with only six final points | Final confirmation uses the actual final score, never latched provisional progress | `debug_objectives`: the reviewer's exact case now reads final delta 6, does not succeed, and records 6 |
| The deadline included a whole rendered frame past it (9.95 → 10.05 against a 10 s limit) | The attempt runs on the 180 Hz physics tick; a tick counts only if the clock at its **end** is at or before the limit | Verified at step widths of 1/180 s, 0.05 s and 0.25 s: identical outcome, so the boundary no longer depends on frame rate |
| The drivetrain diagnostic's diagonal case was measuring a collision | Harness rewritten on a bare floor that fails if anything touches the robot; all four diagonals, both spins, 37 assertions; obstacle behaviour is a separate test | On a verified-clear floor all four diagonals give 67.3 in/s with < 0.15° drift. The old diagnosis is **withdrawn** |
| The objective card overlapped the scoreboard at 1280×720; the screenshot harness passed screens that were hidden behind the first-run dialog | The card measures the scoreboard's real height; every capture now runs an occlusion check and declares its profile state | `shot_all` clean at three resolutions plus a `-- fresh` pass that self-tests the occlusion check |

Both review probes are now regression tests. Run against a copy of the project
with the fixes reverted, they report **16** and **9** failures respectively.

**Regression:** 23 harness runs after the changes, all zero failures —
`smoke_match`, `stress_test` (worst jitter 0.00 in/s), `debug_drive`,
`debug_shooting` (19 of 20 taken shots entered the CELL), `debug_ride`,
`debug_hive`, `debug_rules`, `debug_roster`, `debug_opponent`, `debug_coop`,
`debug_report`, `debug_human`, `debug_turret`, `debug_power`, `debug_blue`,
`debug_leaderboard`, `debug_audio`, `debug_editor`, `debug_menus`,
`debug_pause`, plus `debug_situations`, `debug_objectives` and
`debug_workflow` in both of their phases.

---

## Previous pass

