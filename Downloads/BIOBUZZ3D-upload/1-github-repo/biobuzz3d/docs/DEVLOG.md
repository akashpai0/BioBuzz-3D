# BIOBUZZ 3D — DEVLOG / HANDOFF

Dense build log. Format is for machine resumption: any model (Claude, GPT, Astra 6,
whatever) should be able to read this file alone and continue the project cold.
Terse on purpose. Update the STATUS block at the bottom on every work session.

```yaml
project:    BIOBUZZ 3D
goal:       remake playdsim.com/biobuzz (2D FTC driver sim) in Godot 4.5 with real rigid-body physics
engine:     Godot 4.5 stable, Forward+, Jolt Physics, 120 Hz physics tick
dims:       3D. mecanum drivetrain. single red robot, solo practice.
source_of_truth:
  - FTC BIOBUZZ Competition Manual V1 (2026-09-12, 173 pp)
  - distilled in DSIM repo: github.com/genius0412/dsim -> docs/biobuzz-reference.md
  - Event Field Setup Guide S12 (Hive Calibration) for the tip table
license_note: DSIM was READ for dimensions only. No DSIM code copied. Original implementation.
```

## 1. Coordinate frame (do not change, everything depends on it)

| manual | Godot |
|---|---|
| x (audience right) | +X |
| y (away from audience) | **-Z** |
| height above tiles | +Y |
| unit | inches; `BB.IN = 0.0254` -> metres |

Helper `BB.fp(x_in, y_in, z_in) -> Vector3` does the conversion. **Never write raw
metres in gameplay code** — write manual inches and pass them through `fp` / `BB.m`.
RED = x < 0 (audience left, G304.A). BLUE = x > 0.

## 2. Design decisions (and why)

| # | decision | rationale |
|---|---|---|
| D1 | Full 3D, not 2D | user choice. Also required: you cannot shoot a ball 65 in up into a HIVE cell in a top-down sim. |
| D2 | Everything built procedurally in GDScript, no binary assets | `.tscn`/`.glb` files are unreviewable and merge-hostile; a code-built field is diffable and parametric. Only `scenes/main.tscn` exists, and it is 4 lines. |
| D3 | Constants live ONLY in `scripts/bb.gd` | single edit point when Team Update changes a number. |
| D4 | HIVE tip is EMERGENT, not a lookup table | DSIM uses the manual's tip TABLE because it is 2D and has no ball masses. Here the swing is a hinged RigidBody3D balanced on its pivot; ball weight is the only torque. See S3. |
| D5 | CELL outer end is left OPEN | makes the "contents spill onto the tiles when a cell goes down" (G409) fall out of gravity instead of a script. Physically matches the real chute. |
| D6 | FLOWER lower ring modelled as an annulus with a 2.79 in hole | a 2.8 in POLLEN then *cradles* in the hole and will not roll out of the 3.55 in retrieval opening on its own — which is exactly the real behaviour, for free. |
| D7 | Mecanum via 4 raycast suspensions + per-wheel traction clamp | gives real weight transfer, wheel lift, tipping and traction loss. A "set velocity directly" mecanum would defeat the point of the rebuild. |
| D8 | Input map built in code (`bb.gd::_ready`) | keeps `project.godot` human-readable; Godot's serialised InputEvent blobs are unmaintainable. |
| D9 | Score harvested `SETTLE_S = 2.8 s` after the buzzer | manual S10.5 A-G: the state that scores is the field AT REST, not at 0:00. |
| D10 | Detent uses a SNAP-THROUGH profile, not a constant torque | a constant detent made the seesaw *creep* for ~9 s at threshold. Full strength over the outer half of travel (so a sub-threshold load does not sag at all), falling as sin() to zero at centre (the unstable point of any over-centre mechanism). A load that beats the detent now commits and goes over. It is also the more physical model. |
| D11 | Suspension is soft (~0.4-0.7 in sag), not rigid | an FTC robot has no suspension, but a perfectly rigid 4-wheel chassis is statically indeterminate: wheels lift, and the robot spun out on every diagonal. Real travel keeps all four loaded while still feeling rigid. |
| D12 | Elements use `DAMP_MODE_REPLACE` | with the default COMBINE, the project's default damping is ADDED to the body's, so the launcher's solver modelled 0.12 while physics applied 0.22 and every shot fell short. |

## 3. HIVE tip calibration — THE one tuned number

Manual gives a TABLE (nectar in cell -> pollen needed to tip), explicitly *not* a mass model:

| nectar | pollen to tip | source |
|---|---|---|
| 0 | **8** | Field Setup Guide S12.3 |
| 1 | 7 | owner measurement |
| 2 | 6 | owner measurement |
| 3 | **3** | Field Setup Guide S12.3 |
| 4 | 1 | owner measurement |
| 5 | 0 | owner measurement |

We reproduce it with three numbers instead: `POLLEN_MASS = 0.058 kg`,
`NECTAR_MASS = 0.105 kg`, `HIVE_HOLD_TORQUE` (N*m detent resisting the swing).
Mass ratio 1.81 was solved from the two *manual-sourced* rows (8p == 3p+3n).
`HIVE_HOLD_TORQUE` is calibrated headless — see `tools/calibrate.gd`.

**SOLVED VALUES (session 2, closed CELL): `POLLEN_MASS = 0.058`,
`NECTAR_MASS = 0.170`, `HIVE_HOLD_TORQUE = 0.78`.** 4/4 on the manual-sourced
gate rows. `tools/calibrate.gd` can now sweep NECTAR mass as well as torque
(`GameElement.nectar_mass_override`), which is how 0.170 was found.

Note the nectar mass nearly doubled from session 1. That is not a fudge: in the
closed CELL the 3.6 in NECTAR settle hard against the inner end wall at a SHORT
lever arm while the smaller POLLEN stack behind them further out, so nectar pull
less than their mass suggests. The geometry is right, so the fitted number moved
to match it.

Four of six exact, including BOTH rows that come from FIRST's own Field Setup Guide.
The two misses are the rows the reference says are unreachable:
no single mass ratio satisfies `2n+6p` and `3n+3p` at once — 2 nectar wants a nectar
worth <1.25 pollen, 3 nectar wants >1.5. Proven by hand, then confirmed by sweep.
**This is a known, accepted residual, not a bug. Do not "fix" it by hard-coding the
table** — that would throw away the thing the rebuild is for.

Why 0.96 and not 1.04-1.08 (which also pass the four gate rows): the gate runs drop
the load straight down into the tray, while a real match LAUNCHES it in, and shots
settle slightly closer to the pivot, i.e. at a shorter lever arm. 0.96 passes the
gate AND tips from three launched POLLEN in `tools/smoke_match.gd`. If you retune,
check BOTH harnesses — the gate alone will let you ship a hive that cannot be tipped
by actually playing.

## 3a. Bugs found by the harnesses (all fixed — do not reintroduce)

| what looked wrong | actual cause |
|---|---|
| nothing ever tipped, at any detent value | the CELL `Area3D` sat at the swing origin; only its *shape* carried the offset, so the calibrator was dropping the load at the pivot instead of into the tray. The area now carries the offset, and `cell.global_transform` is a usable "inside this tray" frame. |
| aim-assisted shots bounced off the HIVE | two separate faults: the solver used the muzzle position from BEFORE it moved the hood (so it solved a problem it then changed), and it returned the LOW arc. A flat shot cannot enter a CELL — the walls stand ~63 in up, so it clips the rim from outside. The scan now runs downward from 84 deg to take the lob, and the aim point is `Hive.aim_point()`, the centre of the OPENING, not of the tray. |
| every shot fell short of the solver's prediction | damping mode, see D12. |
| robot drove backwards; diagonals spun out | the mixer read `_drive.z` as forward while `_drive.z` held *minus* forward. Forward and strafe are now verified to 58-59 in/s with 0.0 deg of heading drift in `tools/debug_drive.gd`. The spin-out was D11. |
| drivetrain test showed wheels lifting at t=0 | test artifact: it commanded motion during the spawn bounce. The harness now settles the robot for 0.45 s first. |

## 3b. Session 2 — geometry correction, UI, controller, anti-glitch

Two things in the V1 build were WRONG against the manual and are now fixed. Both
change gameplay substantially; do not revert them.

| was | is | source |
|---|---|---|
| CELL modelled as an open-topped tray | CELL is a closed box, **open at its OUTER END ONLY** — a 20 x 14 mouth perpendicular to the bar. Raised, it faces up-and-outboard; a shot must come from outboard travelling toward the pivot. Lowered, the same mouth dumps the load. | reference S2.2, owner ruling 2026-09-12 |
| both HIVES staged the same way | staged pose is per alliance: **red's raised CELL is SOUTH, blue's is NORTH** (`BB.STAGED_TILT`) | S10.3.1, Fig 10-2 |

Consequences worth knowing before touching the launcher:
* The mouth is a tilted window, so a near-vertical lob clips its lip. The solver
  now returns BOTH arcs (`solve_hood_all`) and picks by **arrival elevation**
  (`arrival_elev`) against a preference the target supplies — `Hive.preferred_arrival()`
  is about -42 deg. A FLOWER wants the steep arc, a CELL wants the flat one. One
  launcher, two very different scoring routes.
* Which side of the field you are on now decides whether a shot exists at all.
  `Hive.has_line_from()` answers that and the HUD surfaces it.

Also added this session: title screen with mode + alliance select (`menu.gd`,
`hex_panel.gd`), TELEOP-ONLY and FREE-PRACTICE modes plus skip-AUTO, full
controller mapping, constant intake, auto-targeting on by default, pickleball
elements that stay put, flowers rebuilt as 3 rings + 4 pipes, robot given
bumpers / wheels / an intake roller, and `tools/stress_test.gd`.

### Bugs found by the harnesses this session

| what looked wrong | actual cause |
|---|---|
| balls crept down a FLOWER at a constant few in/s and never landed | the new "don't roll" brake scaled the WHOLE velocity vector every tick and so fought gravity to an equilibrium. It now brakes the HORIZONTAL component only. |
| every shot bounced off the HIVE | not a bug — the robot was on the closed side of the cell. The test was firing from the start wall; red's mouth faces south. The test now drives to the open side, which is what a driver must do. |
| no shots fired in the test at all | `reset_to()` empties the hopper by design (it is a field reset). Added `teleport()` for repositioning with the load intact. |
| 3n+3p would not tip at any torque that 8p tipped | the closed CELL changed the lever arms: big NECTAR jam against the inner end wall at a SHORT arm while POLLEN stack further out. Re-solved NECTAR mass against it — see S3. |
| clock pinned to the left edge instead of centred | setting `position` after `set_anchors_preset` does not survive; the HUD now sets explicit offsets. Caught only because the UI was actually rendered and looked at. |
| chase camera filled half the screen with the outside of a wall | it sat outside the perimeter when the robot was parked against one. Now clamped inside. |

## 3c. Session 3 — the tip is a MASS, and five bug fixes

### The tip rule changed, on the team's own figures

A CELL lets go at **0.44 lb** of load: 8 POLLEN, or 6 NECTAR, or any mix. That
fixes `POLLEN_MASS = 0.44/8 lb`, `NECTAR_MASS = 0.44/6 lb`, `TIP_MASS = 0.44 lb`.

`hive.gd` now GATES ON THAT MASS: the detent holds the seesaw solid below the
threshold and releases completely above it. The swing itself is still real
physics — only the release is a threshold, which is how an over-centre catch
behaves. The earlier emergent-torque design made tipping depend on WHERE in the
cell the load happened to settle, which is wrong against a hive calibrated to a
number, and it is why hives were tipping when they should not have.

`tools/calibrate.gd` now checks the mass rule instead of solving a torque:
8/8 rows correct (7p no / 8p yes, 5n no / 6n yes, 3n+3p no / 3n+4p yes,
4n+2p no / 4n+3p yes). **Do not reintroduce a fitted torque.**

### Bugs, and what they actually were

| symptom | cause |
|---|---|
| **robot levitates off its wheels, drivetrain stops working** | the suspension raycasts had no collision mask, so they hit POLLEN. Driving over a ball read as a huge spring compression and launched the robot. Elements now live on `BB.LAYER_ELEMENT` and the rays mask `LAYER_WORLD` only. |
| **nothing could tip the hive at all, at any load** | JOLT WANTS THE COLLISION MASK RELATIONSHIP TO BE MUTUAL. With elements on their own layer, the balls rested in the CELL but never pressed on it, because the swing's mask did not include the element layer. Every static field body and the swing now mask `LAYER_ELEMENT` explicitly. This one cost the most time — remember it. |
| every Area3D stopped detecting elements | same root cause: cell volumes, flower scoring volumes and the intake all mask `LAYER_ELEMENT` now. Symptom was scoring silently reading zero. |
| 8 POLLEN sat exactly on the threshold and did nothing | 8 x (0.44/8) is EXACTLY 0.44 by construction, so `>=` landed on the wrong side of float rounding. `BB.TIP_EPS` (a twentieth of a POLLEN) absorbs it. |
| shots bounced back OUT of the CELL | restitution was raised for the mat feel, and a ball pinging off the load already in the cell escapes through the mouth — the only opening. Fixed by putting the bounce in the TILES (`BB.TILE_BOUNCE = 0.55`, Jolt combines restitution as the max) and keeping ball-on-ball calm at 0.30, plus absorbent materials on the CELL and FLOWER so they swallow a shot. |
| the launcher missed from close range | not an aiming bug. A CELL is a CLOSED BOX: close in, the only arcs that reach it are steep enough to land on the ROOF. `Robot.shot_clearance()` now walks the candidate trajectory, finds where it crosses the plane of the mouth and checks it fits the 20 x 14 window with room for the ball. The solver searches SPEED as well as angle and takes the arc with the most clearance; if nothing fits it refuses to lock and the HUD says "TOO CLOSE - back up". 95% of shots it agrees to take go in. |

The aim search is throttled (`_aim_next_full`, 0.2 s) and caches both hits and
misses. It is expensive; do not call it unthrottled every frame.

### Also this session
Turning is its own tunable (`Robot.yaw_rate_max`, 400 deg/s) via exact mecanum
inverse kinematics instead of a normalised mixer. The intake takes POLLEN only
and runs constantly, and collected balls ride visibly inside an open chassis
frame. The HUD shows the raised cell's load as a fraction of 0.44 lb.

## 3d. Session 4 — G407, the intake, and a flat title screen

* **Title screen** is now a flat opaque colour. The honeycomb and the live arena
  behind it were noise; `hex_panel.gd` is deleted.
* **G407 implemented from the manual text** (S11.4.3, p108): *"No more than 4 at
  a time. A ROBOT may not simultaneously CONTROL more than 4 SCORING ELEMENTS.
  Violation: VERBAL WARNING. MAJOR FOUL and YELLOW CARD per MATCH, if
  STRATEGIC."*  To make the rule reachable at all, the robot can now physically
  hold six (`BB.HOPPER_MAX`) while four remains the legal line
  (`BB.HOPPER_CAP`). Escalation follows the manual's own guidance: five for
  longer than MOMENTARY (~3 s, S10.6) is an instance and the first instance is a
  VERBAL WARNING; a repeat, or ever holding six, is STRATEGIC and costs a MAJOR
  FOUL of 20 to the opponent. Momentarily touching five and giving one back is
  explicitly not a violation, which is why the grace timer exists.
* **Nothing wedges under the robot any more.** The intake volume used to be a
  small box in front of the bumper, so a ball shoved under the chassis sat there
  unreachable. It now spans from in front of the bumper back under the whole
  chassis: anything under there is either collected, or — when the robot is
  already full or the intake is off — pushed back out the front.

`tools/debug_rules.gd` covers all of it: collects past four, warns, escalates,
and leaves nothing stuck underneath.

## 3e. Session 5 — CONTROL is carrying plus dragging

The intake now hard-stops at `BB.HOPPER_CAP` (4): a fifth ball cannot be taken
in. G407 is still reachable, because **CONTROL is not only what is in the
hopper**. `Robot._track_herding()` counts a loose element as CONTROLLED once it
has travelled WITH the robot — same heading, both actually moving — for longer
than `BB.HERD_TIME` (1.1 s). That is the manual's own distinction: "bulldozing",
inadvertent contact with a ball in the robot's path, is explicitly not CONTROL,
while corralling is. A brief clip while crossing the field does not count;
driving around with a full hopper pushing two more does.

`Robot.controlled_count()` = hopper + `herded_count()`, and that is what
`MatchManager.check_control()` now judges.

Other changes: holding fire empties the hopper (`BB.FIRE_INTERVAL` 0.13 s, four
balls out in ~0.41 s measured); drive 60 -> 68 in/s and yaw 400 -> 460 deg/s,
both now **sliders on the title screen** (`Menu.drive_speed` / `Menu.turn_rate`,
applied through `main._apply_settings()` on start, on pause-menu close, and live
while dragging).

## 3f. Session 6 — lead, eye height, the flower crevice, and a scoring audit

**Scoring audited against the manual itself** (S10.5, pp86-91), not the distilled
notes. Everything already matched and nothing was changed:

| line | manual | ours |
|---|---|---|
| HIVE TIP | 20, AUTO and TELEOP, *per tip*, assessed throughout | same; `smoke_match.gd` now asserts `tips * 20` |
| remaining in CELL | 2 each, "earn points for that ALLIANCE" — the CELL's colour | credited to the hive's alliance |
| FLOWER owner | alliance of the TOP-most NECTAR of its colour; owner scores every element in it "regardless of which ALLIANCE placed" | same |
| Bottom NECTAR Bonus | 5, alliance of the BOTTOM-most scoring NECTAR | same, per flower |
| GARDEN | 1 each, to the garden's colour "regardless of which ALLIANCE placed" | same |
| LEAVE / PARK | 3 / 5+5, park = "at least partially in the LOADING ZONE" | same |
| RP | SWARM 16 pts, POLLINATOR 1 = 4 TIPS, POLLINATOR 2 = 7 TIPS | same |

One thing the audit exposed: a TIP only scores while a MATCH is running
(`on_tip` returns early in PRE/DONE, which is correct). `smoke_match.gd` had
been enabling the robot by hand without calling `start()`, so its tip credit was
silently dropped — a test bug, but it is exactly what a player would see if they
tipped a hive without starting a match.

**Lead compensation.** `fire()` adds the robot's velocity to the ball, which is
right, and it is why shots taken while driving used to drift. `Robot._apply_lead()`
now points the turret along (the solved arc's world velocity MINUS the robot's),
so once the robot's motion is added back the ball leaves along exactly the arc
that was solved. `tools/debug_moving_shot.gd`: **20 of 20 while moving**, at up
to 67 in/s, strafing both ways, driving in, backing off and diagonally.

**Driver camera** sits at `BB.DRIVER_EYE` (64.5 in) — a 5 ft 9 in driver's eye
height — so the view looks slightly DOWN across the field, as it does at an
event.

**The flower crevice.** A round FLOWER standing against a flat perimeter wall
makes a narrowing V on each side, and a ball that rolls in gets pinched and held
by friction halfway up, touching nothing else. That was the "balls stuck in the
walls" report. Fixed with `_wall_fillet()`, solid material filling both Vs,
capped at 65 degrees so the fillet never becomes a shelf itself. Two earlier
attempts are worth not repeating: a 40-45 degree cap is close enough to the
friction angle (~32-36 degrees) that balls sit on it, and narrowing the fillet
to save visual weight reopens the crevice. `tools/debug_flower_stick.gd` rains
elements around all four flowers and checks for exactly this.

## 3g. Session 7 — why the turret "broke mid run"

Two real defects, both of which present as the launcher going dead partway
through a match. Neither was a physics problem.

**1. A manual nudge switched auto-aim OFF permanently.** `_read_input()` set
`auto_aim = false` whenever the turret keys or D-pad were touched. On a
controller the D-pad is easy to brush, and once it fired there was no feedback
and no obvious way back — every shot after that went wherever the turret happened
to be pointing. Manual input now SUSPENDS auto-aim for `BB.MANUAL_AIM_HOLD`
(2.5 s) and it re-engages by itself; the HUD says which state it is in.

**2. The turret was aimed by assigning `turret.global_rotation.y`.**
Assigning one component of a global Euler decomposes the whole basis and
rebuilds it from those angles — so any roll or pitch the ROBOT had (driving over
a ball, being shoved, up on two wheels) was folded back into the turret's own
orientation, a bit more every frame. Near steep pitch the decomposition can flip
it outright. `_point_turret()` now converts the desired world bearing into the
ROBOT's frame and sets `turret.rotation.y`, which is both immune to the robot's
attitude and what a chassis-mounted turret physically does.

**And the watchdog that was asked for.** `_check_turret()` runs every frame and
validates: transforms finite, both bases still rotations (determinant 1), hood
angle within 0-90, flywheel within range. Any failure calls `recalibrate()`,
which restores a known-good turret, clears every cached aim solution and emits
`recalibrated(reason)` — `main.gd` puts it in the event log so it is visible
rather than mysterious. `R` recalibrates on demand, and re-engaging auto-aim
(`C` / `R3`) recalibrates first so it always starts from a clean state.

`tools/debug_turret.gd` proves all of it: scores 4/4, then spins and shoves the
robot while aiming, then corrupts the turret outright (basis scaled x3, hood
NAN, flywheel 99999), and checks the watchdog catches it and that it scores 4/4
again afterwards. Worst basis determinant across the whole abuse run: 1.000.

## 3h. Session 8 — CELL scoring timing, blue side, robot variants

**CELL contents no longer score during play.** Manual S10.5.C: what is sitting
in a CELL is assessed *after* everything has come to rest at the conclusion of
the MATCH. `Scoring.breakdown()` takes a `final` flag and only adds the 2-per-
element CELL points when it is set — `MatchManager._finish()` passes true, the
HUD passes true only in SETTLE/DONE and shows `IN CELL --` before that. So
during a match a HIVE is worth 20 per TIP and nothing else, which is what the
rules actually say.

**Driver feel is fixed**, not a slider: `Menu.DRIVE_SPEED` 68 in/s and
`Menu.TURN_RATE` 460 deg/s. The DRIVING section is gone from the title screen.

**Blue plays from the other end.** Blue is not a recolour — three things flip:
* `CameraRig.alliance` puts the DRIVER view at x = +124 instead of -124;
* field-centric input multiplies both axes by the alliance sign, so "forward"
  on the stick pushes blue away from the blue wall;
* the G304 start pose is point-symmetric (blue at the +x wall, facing -x).
Blue's raised CELL is the NORTH one (`BB.STAGED_TILT`), so the side you must
shoot from flips too — `tools/debug_blue.gd` checks all of it.

**Robot variants.** One intake or two, chosen from a clickable little 3D model
on the title screen. The models are live `SubViewport`s built by
`scripts/robot_body.gd` — **the same builder the real robot uses**, so the thing
you pick is the thing you drive. `intakes` is purely cosmetic (a roller at each
end instead of one): the intake volume already reaches under the whole chassis,
so both collect identically, which is what was asked for.

Two UI notes worth keeping: a card showing a 3D model marks selection with a
BORDER only (`outline_only` meta) — filling it with the accent colour drowns the
model — and the previews rebuild on an alliance change so the model wears the
right colour.

## 3i. Session 9 — dual intake, out-of-field returns, sign-in and leaderboard

**A two-intake robot really does collect from both ends.** Its intake volume now
extends `BB.INTAKE_REACH` past BOTH bumpers and pulls toward whichever end the
ball is nearest; a one-intake robot reaches past the front only and explicitly
skips anything behind its rear bumper. Both still stop at four. Measured: two
intakes collect 4 while reversing into a pile, one intake collects 0.

**Elements that leave the FIELD come back through a LOADING ZONE.** Previously
`_keep_in_bounds()` clamped position while PRESERVING height, so a ball that
sailed over the wall hung in mid-air at the edge. It is now set down in the
nearer alliance's loading zone — the human player area — and costs a MINOR foul.

G405 makes *deliberate* ejection a MAJOR, but explicitly exempts elements that
leave "during scoring attempts". A sim cannot tell a deliberate ejection from an
overcooked shot, so it charges the lesser MINOR: enough to discourage firing
balls out of the arena, not enough to decide a match on one bad launch.

**The threshold has to be PAST the wall.** First attempt used
`FIELD_HALF - 1.0`, which is *inside* the field — and the GARDEN strips run from
y = 70 to 72, so correctly staged garden POLLEN were treated as escapees and
"returned" to a loading zone, quietly zeroing both alliances' garden points. It
is `FIELD_HALF + 2.5` now. `smoke_match.gd` caught it.

**Sign-in and leaderboard** (`scripts/leaderboard.gd`, `scripts/signin.gd`).
A name is asked for once on first run and kept in `user://profile.cfg`. Scores
are kept per ROBOT VARIANT — a one-intake run and a two-intake run are different
contests, so the board shows two tables — and only a player's best run per
variant is stored. A finished FULL MATCH or TELEOP run records automatically;
free practice never ends so it never records.

**There is no server.** Scores cannot sync by themselves. What exists instead is
a share code: the whole board as one base64 line, copied to the clipboard, which
anyone else with the game can paste to merge (higher score wins per name and
variant). Honest about it on the screen itself rather than implying online play.

Board rows are real Label columns, not padded text — the UI font is proportional,
so `%-18s` lines nothing up.

## 3j. Session 10 - two drivers, an opponent, a human player, and a layout that fits

**The title screen had outgrown a fixed column.** At Julian's 1908x960 the START
button was clipped off the bottom. Two changes, both structural rather than
cosmetic:

1. `menu.gd::build()` is now three bands - a header, a `ScrollContainer` body,
   and a footer holding START. START lives OUTSIDE the scroll area, so it can
   never be the thing that goes off-screen. The body is two columns (mode /
   alliance / match setup on the left, the robot picker on the right) with the
   control map full-width beneath, which cut ~130 px of height.
2. `project.godot` now sets `window/stretch/aspect="expand"`. The default is
   `keep`, which letterboxes the UI into a fixed 1600x900 canvas - so a 1908x960
   screen gets black bars and the layout never sees the extra room. With `expand`
   the menu is handed the real window shape, and 1600x900 of logical space is the
   guaranteed WORST case: wider or taller only ever gives it more.

`tools/shot_fit.gd` is the new guard. It renders the title screen AND the
leaderboard, walks every visible Button, and fails if any rectangle is not fully
inside the canvas. Run it once per resolution (window resizing from inside a
virtual display is not reliable): verified at 1280x720, 1600x900, 1908x960 and
2560x1440.

**Two drivers, two robots** (`scripts/driver_input.gd`, `main.gd::_build_robots`).
`Input.get_action_strength()` answers "is anyone pressing this", which is exactly
wrong with two people at one computer. Every control is read through
`DriverInput.strength(device, action)`, which resolves the same `BB.ACTIONS`
bindings against ONE device. Devices are handed out pads-first, keyboard-last, so
one pad goes to player one. A driver with nothing left gets `DriverInput.NONE`
(-2), which reads as zero - two robots answering one W key is worse than one
robot parked. The AI opponent is pinned to NONE for the same reason.

Both drivers stand at the SAME driver station, so there is no split screen and
none is wanted: one camera at 5'9" is what the real alliance sees. TAB cycles the
three views and, on the way past CHASE, moves to the next robot.

**G407 is per ROBOT, not per field.** `MatchManager._control` keys a
`{over, instances, flagged, warning}` record by robot. One driver dragging a
fifth ball must not clear the other driver's timer, and each accumulates their
own escalation history. Robot 1's record is mirrored into the flat
`control_*` fields the HUD already read. LEAVE and AUTO PARK became per-robot
counts crediting the alliance, so two robots that both leave are worth two
LEAVEs (S10.5).

**The human player is a person** (`match.gd::_pump_humans`). G426 entitles the
human player to enter NECTAR; it never said the ball teleports in. Elements owed
now go into a per-alliance queue with a reaction time
(`BB.HUMAN_REACT_MIN/MAX`, 0.9-2.4 s) and are fed one at a time
(`BB.HUMAN_PLACE_GAP`, G427), set down in the LOADING ZONE touching the tiles at
zero velocity. An element that leaves the FIELD is now taken OUT OF PLAY at the
moment it goes over the wall (`held_by = self`, parked off-field) and walked back
around the guardrail in 2.2-4.5 s, instead of reappearing on the same frame.
`GameElement.exited_field` carries the element now so the manager can hold it.

**Robot feel** (already in from the previous pass, verified here): 70 ms control
latency via a command log, a 6 units/s motor ramp, and a battery that sags with
wheel force and drains over a match (13.0 V nominal, 10.8 V floor). `power_factor()`
scales every wheel command; the HUD draws the pack as a bar, because a driver who
can see the brownout coming drives differently.

**Opponent** (`scripts/ai_driver.gd`, toggled in the menu). COLLECT / SHOOT /
DEFEND / UNSTICK, re-decided 4x a second, parking `SHOOT_STANDOFF` = 46 in off the
CELL mouth normal. Deliberately mediocre: it hesitates, over-drives its target,
and gives up on a ball someone else grabbed. The point is that the field is
contested, not that it wins.

**Randomised field, opt-in.** Julian's own framing - "most of the time it will be
a perfect starting field" - so PERFECT is the default. RANDOMISED nudges loose
staged elements by up to `BB.SCATTER_POS_IN` (3.5 in) and the robot starts by
`SCATTER_ROBOT_IN` / `SCATTER_ROBOT_DEG` (2.5 in, 4 deg), never INTO the wall.
Preloads, CELL nectar and the human players' supply are placed by hand either
way, because they are.

**Bug caught by the new harness.** `_build_robots` spawned every robot at the
origin and left `stage()` to place them. Three 30 lb bodies interpenetrating for
one physics frame is a loaded spring, and Jolt fired them across the field.
They are teleported to their start pose at construction now.

Staging arithmetic generalised: 16 of the 40 POLLEN are ROBOT preloads at 4
apiece, and whatever no robot is present to carry goes to that alliance's LOADING
ZONE. Still 40 and 16 with one, two or three robots on the field - asserted.

## 3k. Session 11 - how long a tip takes, and why NECTAR is quicker

Target from the owner, measured on a real hive: a full POLLEN load takes about
4 s to go over, a full NECTAR load is quicker, and more weight in the cell is
quicker again.

**The duration knob is the damper, and nothing else.** Once the catch lets go,
`hold_torque` is zero and the only thing turning the swing is the load's weight
on its arm. The load is fixed at 0.44 lb by the manual. So the swing time is set
entirely by `BB.HIVE_ANGULAR_DAMP`, solved by `tools/tip_time.tscn` at **0.50**
(was 1.15, which gave 5.6 s).

**Why NECTAR could not be faster, and the fix.** `NECTAR_MASS` used to be
`TIP_LB / 6`, the tidy choice - which makes six NECTAR weigh EXACTLY what eight
POLLEN weigh, so the two loads produced identical torque and tipped at identical
speed. The rule is only that six tips and five does not, and that fixes a RANGE:
0.0333 to 0.0396 kg. `NECTAR_MASS` is now **0.0385**, near the top of it. Six
NECTAR overshoot the catch by ~16% where eight POLLEN land exactly on it, so an
all-NECTAR load really does go over quicker - for the same reason any heavier
load does.

The ceiling is five NECTAR still holding: 5 x 0.0385 = 0.1925 kg against a
0.1983 kg catch. The mixed rows moved with it, and `tools/calibrate.gd`'s gate
table was updated from `4n+2p held / 4n+3p tip` to `4n+1p held / 4n+2p tip` -
a step TOWARD the manual's table, which says 4 NECTAR + 1 POLLEN goes over.
Still 8/8.

**Margin had to be wide enough to beat the noise.** At 0.0371 kg the NECTAR
edge was ~3%, which is SMALLER than the run-to-run spread caused by where the
balls happen to settle in the cell - so "NECTAR is faster" held on average and
was visibly false on individual tips. 0.0385 puts it at ~16%, and the measured
ranges no longer overlap.

Measured, mean of three different drops each, damper 0.50:

| load | mean | range |
|---|---|---|
| 8 POLLEN | 4.08 s | 3.98 - 4.23 |
| 6 NECTAR | 3.83 s | 3.69 - 3.93 |
| 10 POLLEN | 3.56 s | |
| 12 POLLEN | 2.98 s | |
| 8 NECTAR | 3.03 s | |

The asked-for NECTAR figure was 3.6 s. 3.83 is as close as the rules allow: the
mass needed for 3.6 s is ~0.0399 kg, at which FIVE NECTAR would tip the hive and
break the owner's own measured rule. Flagged rather than faked.

**Three harness bugs found on the way, all of which had been producing
confident wrong answers:**

1. The load was laid out on a fixed 3-wide grid, so eight balls filled three
   rows and six filled two - the NECTAR load started biased toward the pivot and
   "measured" slower for reasons that had nothing to do with NECTAR.
2. Balls were dropped from up to 11 in above the cell centre. The cell is 14 in
   tall, so half the load landed on the ROOF, never registered, and the gate
   never opened - reported as "NEVER TIPPED" for every damper value.
3. Timing started when the last ball landed, i.e. it was timing the bounce.
   `Hive.gate_locked` is a test-only hook that holds the catch shut while a load
   settles, so the clock starts on a known frame with the load at rest.

`tools/tip_time.tscn` is now an assertion, not a sweep: it checks the POLLEN
load lands near 4 s, that NECTAR beats it, and that 10 beats 8, 12 beats 10 and
8 NECTAR beats 6. Widen `DAMPS` to re-solve the damper.

## 3l. Session 12 - drive feel, a see-through perimeter, sound, and settings

**The drivetrain had never once reached spec, and nothing errored.** The battery
model keyed `power_factor()` to the SAGGING terminal voltage. Full throttle drew
104 N of commanded wheel force, `BATTERY_SAG_PER_N = 0.020` turned that into a
2.1 V drop on the FIRST FRAME, and the robot ran at 57% power forever: measured
38.6 in/s against a 68 in/s spec and 307 deg/s against 460.

The fix is to separate two things that were conflated. Sag is what happens when
you floor it and it recovers when you let off - that belongs on the HUD bar and
must NOT cut top speed, or a fresh pack never performs. DISCHARGE is the pack
actually emptying over a match, and that is what should cost you. So
`power_factor()` now reads OPEN-CIRCUIT voltage (`BATTERY_POWER_LOSS_PER_V`,
floor `BATTERY_POWER_MIN`), `BATTERY_SAG_PER_N` drops to 0.004 and only moves
the display, and `reset_battery()` runs on every re-stage.

Measured by `tools/debug_power.tscn`:

| | speed | spin | power |
|---|---|---|---|
| fresh pack | 67.9 in/s | 465 deg/s | 1.000 |
| after 150 s of hard driving | 61.1 in/s | 420 deg/s | 0.900 |

Ten percent down by the end - felt in the last thirty seconds, not fought.

**The perimeter is now a real field perimeter.** Black extruded rail along the
bottom (1.75 in), clear polycarbonate panel, black rail along the top (1.5 in),
via `BB.glass()` and `Field._wall_band()`. Collision is untouched - still one
solid 12 in box per side - so nothing about how a ball or a robot meets the wall
changed. The panel has culling disabled (a single-thickness pane seen from
outside would vanish) and casts no shadow (a translucent caster lays a dark band
across the tiles that reads as a wall lying on the floor).

This matters more than it sounds: the DRIVER camera sits OUTSIDE the field at
eye height, so before this you were looking at the back of an opaque wall.

**Sound, with no audio files** (`scripts/audio.gd`, autoloaded as `SFX`). Same
reasoning as the meshes: a .wav is an unreviewable binary. Every sound is
generated into an `AudioStreamWAV` at startup - filtered noise for the crowd,
summed harmonics plus commutator hash for motors, exponentially decaying bursts
for impacts, detuned squares for the horn. ~25 ms of startup, ~1.5 MB of RAM.

The payoff is that the sounds are PARAMETRIC rather than triggered. The flywheel
is an oscillator whose pitch follows the launcher's actual spin-up; the intake
drops in pitch and gains level as the hopper fills, because loaded rollers do;
ball impacts read the ball's own deceleration and pitch accordingly, so a tap
and a launched ball arriving are the same sample at different ends of its range.
Only the robot the camera is watching is audible (`Robot.audible`), or a
three-robot field is three drivetrains deep in mud.

`tools/debug_audio.tscn` checks what goes wrong silently with generated audio:
all-zero buffers, clipping, DC offset, and loop seams (first and last sample far
apart = an audible tick every cycle). 15/15.

**Settings** (`scripts/settings.gd` autoloaded as `Settings`, UI in
`scripts/settings_menu.gd`). Four pages - audio, game, video, controls -
persisted to `user://settings.cfg`. There is no OK/Cancel: every widget applies
on change and saves immediately, because a settings screen you have to confirm
is one you cannot hear yourself adjusting.

`Settings.SPEC` is the single source of truth - a key maps to
`[default, min, max]` and the screen builds itself from it, so adding a setting
is mostly adding a line there. `apply_all()` is idempotent and knows how to push
every value at the live game, which is why nothing else in the project has to
remember to re-read a preference.

Key rebinding needed a mutable layer over the `const ACTIONS` table:
`BB.key_override`, `BB.keys_for()` and `BB.rebuild_input_map()`. Everything that
reads the keyboard - `DriverInput` and Godot's own `InputMap` - goes through
`keys_for()`, so the two can never disagree about what a key does. Controller
bindings stay fixed; remapping a gamepad mostly produces controllers nobody else
can pick up and use. Rebinding refuses a key already in use rather than silently
creating a double-bound key the player cannot see.

Colourblind alliance colours are Okabe-Ito vermillion and blue, swapped in at
`BB.alliance_colour()` so every mesh, tape strip and HUD chip follows at once.

Turn sensitivity scales the stick CURVE, not the rate: the command is clamped
to 1.0 after scaling, so everyone's maximum is still the same 460 deg/s and a
high setting buys response, not a faster robot.

`tools/shot_fit.gd` now renders and bounds-checks all four settings pages as
well as the title screen. Clean at 1280x720 and 1908x960.

## 3m. Session 13 - the match report, per-driver stats, the robot shop, recorded autos

**Scoring reports counts AND points, and the end-of-match items now land at the
end.** `Scoring.breakdown()` returns `<key>_n` beside every `<key>`, so a report
line can show "3 elements, 6 pts" instead of a bare 6. `Scoring.REPORT` is the
printed row order and `Scoring.END_ONLY` lists what is only assessed once the
field is at rest — CELL contents, FLOWER contents, the bottom-NECTAR bonus and
END OF MATCH PARK. Those read "--" during play rather than a number about to
change. The results screen walks `REPORT`, so adding a scoring element means
editing one table, not the UI.

FLOWER scoring moved to end-only with the rest. S10.5 scores the field at rest
and a ball still rattling down a flower tube at the buzzer has not scored yet.

**`scripts/stats.gd` - what actually happened, per robot.** The score says who
won and is useless for practice: 40 points off 9 shots and 40 off 31 are
completely different matches. Collected passively from signals the match already
emits; deleting the node would leave play identical. A shot counts as MADE when
the element it launched reaches a CELL within `MADE_WINDOW` (6 s) — long enough
for any real arc, short enough that a ball nudged in by hand three cycles later
is not quietly credited.

Fifteen rows: shots taken/made/accuracy, average shot distance, elements
collected, tips fed, scoring cycles with average and best, distance driven, top
speed, time moving, time on a full hopper, time empty, and seconds spent over
the G407 limit.

**`scripts/results_screen.gd`** - two pages, SCORE and STATS, in the shape of a
real FTC match report. The table is held to 1020 px and centred: full-width on a
wide monitor puts RED at one edge and BLUE at the other and no one can read a
line across it.

**The ROBOT screen** (`robot_shop.gd` + `robot_menu.gd`), four pages:

- SPECS turns real hardware into drivetrain numbers. Motor (7 in the catalogue
  with published free RPM and stall torque), external ratio, wheel diameter,
  weight, track, wheelbase, launcher speed. Free speed is
  `rpm / ratio / 60 * pi * dia`; wheel force is stall torque through the
  reduction over the wheel radius, derated to 0.45 because nothing runs at
  stall; yaw rate comes from the wheel-rectangle half-diagonal, so a long robot
  turns slower at the same speed. STOCK ROBOT stays the default — it is what
  the leaderboard is measured on.
- MODEL imports a team's CAD. `cad_import.gd` handles GLB/glTF through
  `GLTFDocument` and parses STL by hand (binary and ASCII), because Godot has no
  runtime STL loader and STL is what everyone exports first. Models are scaled
  into the 18 in cube and stood on the tiles whatever units they were drawn in.
  **Collision stays the 18 in cube.** A hull built from arbitrary imported
  geometry gives you a robot that catches on its own intake and sinks through
  the floor, and every legal robot starts inside that cube anyway. Wheels,
  turret and alliance bumpers are still drawn on top because they move.
- AUTO lists saved routines and picks the active one.
- HISTORY is every finished match logged to `user://robot_history.json`, with a
  five-match trend against everything before it. Cycle time is flagged the other
  way round from the rest — lower is better.

**Recorded autos** (`auto_routine.gd`, `auto_player.gd`). Drive it, press P,
drive again to stop, and it replays as your AUTONOMOUS. What is stored is INPUT
sampled at 30 Hz, not positions, for two reasons: a stored path is the ANSWER,
and a robot that teleports through a ball in its way is a cartoon; and Jolt is
not deterministic, so the same inputs land a few inches apart — exactly like a
real encoder auto on a different battery. A routine that only works when nothing
goes slightly wrong is telling you something true. Recording is free-practice
only, since a routine cut out of a two-minute run would not line up with
anything.

**The randomised-field option is gone**, along with `_scatter()` and the
SCATTER_* constants.

**Harness notes.** `tools/debug_report.tscn` (30 checks) covers all three: that
the breakdown's TOTAL equals the sum of its own printed lines, that every row in
`REPORT` has data behind it, that END_ONLY rows really are zero mid-match, that
made shots never exceed taken, and that a recorded routine saves, loads, lists,
replays the robot somewhere and releases it at the end.

`debug_coop`'s "staging is identical run to run" assertion was deleted rather
than repaired. It existed to test randomisation, which no longer exists, and
every attempt to salvage it measured something else: exact resting positions
differ because balls are still rolling down flower tubes seconds after staging,
and loose-element counts differ because a loading-zone ball can roll an inch out
of its rect. The staging totals are already asserted properly in the same file.

## 3n. Session 14 - tight turning, a working opponent, guided auto recording

**Turning is closed-loop now.** An FTC robot with a heading PID stops on a
bearing; one steering on wheel traction alone coasts past it. Measured, without
a controller, a full-speed release carried the chassis **31 degrees** past the
point the stick was let go. With one it is **2 degrees**.

The implementation matters more than the numbers. `Robot._heading_target()`
corrects THE RATE THE WHEELS ARE ASKED FOR; it does not apply a torque of its
own. Three earlier attempts did apply their own torque, and all three left two
rate loops arguing at 180 Hz with the chassis buzzing at a steady +/- 9 deg/s.
One loop, driven through the wheels, is better behaved AND more honest: the
correction is limited by traction, exactly like the real thing.

Things that went wrong on the way, all of them recorded because they will look
tempting again:
- a **sign error** in the heading term does not wobble, it spins the robot to
  400 deg/s and never stops;
- a **derivative term** on the measured yaw rate looks right on paper and is
  wrong here: a chassis on four raycast suspensions produces a noisy rate at
  180 Hz and D multiplies that noise back into the command. A deadband
  (`YAW_HOLD_DEAD`) kills the same ring without the noise gain;
- the first authority cap was **2.6 rad/s^2**, about twenty times too small to
  stop the chassis at all, and `teleport()` did not clear the latched heading,
  so the controller steered back toward a bearing from before the robot moved.

Measured: 2.0 deg overshoot from a full-speed release, 2.2 from a gentle one,
heading held within 2.4 deg, 0.07 deg of drift over a straight run, 0.74 across
a strafe. `tools/debug_yaw.tscn`.

**The opponent actually plays now.** Rewritten to the brief: nearest POLLEN,
reasonable pace, four, score, repeat. Two bugs kept it standing still, and
both were invisible without a test:

1. `main._process` skipped AI robots when running auto-targeting, so
   `aim_locked` was never true and the bot drove to its firing point and stood
   there forever.
2. `SHOOT_STANDOFF` was measured along the CELL mouth's own normal, which
   points up and outboard — so 46 inches along it put the robot only ~38 inches
   out horizontally under a target 56 inches up. The solver correctly refused
   that near-vertical shot. The standoff is measured FLAT now.

`tools/debug_opponent.tscn` runs it for 70 seconds and checks it collects,
fills to four and no further, takes shots, scores, keeps moving, and drives at
a sane pace rather than flat out. Measured: 9 shots, 1 tip, 127 ft driven, top
speed 36.8 in/s.

**Guided auto recording.** ROBOT -> AUTO -> RECORD A NEW AUTO stages the field,
counts down from three, records exactly `BB.AUTO_S`, then OFFERS to save it
under a name. Nothing is written until the driver chooses, because most first
takes are bad and a folder of auto-3, auto-4, auto-5 helps nobody. The HUD
clock shows the recording countdown while it runs.

**The FLOWER "stuck ball" turned out not to be a bug.** Reported symptom: two
balls come out, two stay. Three probes, all negative — dropped balls stack
cleanly (1.40 in, then every 2.80, exactly one diameter), nothing wedges when
balls are FIRED at the structure from eight bearings at three heights, and an
empty robot clears a loaded flower 4/4 in five seconds. What does reproduce is
the hopper cap: a robot arriving with two already aboard takes two and leaves
the rest, and those are retrievable on a second trip.

Two harness bugs were found in the course of proving that, and both had been
producing confident wrong answers: the first probe drove the robot AWAY from
the flower (the nose is local -Z, and the yaw was computed by hand instead of
with `Basis.looking_at`), and `_clear()` emptied the hopper ARRAY while leaving
the balls frozen to the robot with `held_by` still set — orphans invisible to
every count in the game. `tools/debug_flower_retrieve.tscn` now guards the
whole cycle.

`debug_flower_stick` gained the INCOMING pass: balls fired horizontally at each
flower rather than only rained on it from above.

## 3o. Session 15 - matching a real robot, and an editable collision shape

**Five stopwatch numbers, and the sim reproduces them.** ROBOT -> SPECS now
offers three drivetrain sources: STOCK (what the leaderboard is measured on),
FROM HARDWARE (motor catalogue figures), and FROM MEASUREMENTS. The last is the
useful one: top speed forward, top speed sideways, standstill-to-top-speed,
stopping distance and turn rate, all of which a team can get in one practice
session with a stopwatch and a tape measure.

No solver. Each measurement maps to exactly one parameter by the physics that
produced it — speeds are caps, 0-to-full gives acceleration through F = m*a,
stopping distance gives deceleration through v^2 = 2*a*d — which is why a
five-number wizard is enough. Defaults are a middling FTC mecanum robot, so it
is usable before anyone has measured anything.

**Two corrections, both measured rather than guessed** (`BB.ACCEL_TRIM`,
`BB.BRAKE_TRIM`):

- A mecanum wheel pushes along its ROLLER axis at 45 degrees, so only ~0.7 of
  each wheel's force goes where you asked, and the commanded contact velocity
  is projected the same way. Naive F = m*a under-delivers by more than half:
  6.3 N per wheel produced 0.73 m/s^2 where the arithmetic promised 1.74.
- Braking needs the opposite correction, because the wheels are not doing all
  of it. Rolling resistance, body damping and the heading hold all help.

**Stopping distance needed its own law.** Weakening the brakes could not produce
a long coast: incidental drag put a floor of about 15 inches under it however
little force the wheels used. So while coasting, `Robot.brake_decel` commands
the deceleration directly and the incidental rolling-resistance term stands
down. Any measured distance is now reachable.

Measured against an entered 48 / 33 in/s, 0.70 s, 20 in, 240 deg/s robot:
47.6, 32.6, 0.71 s, 17.3 in, 241.6 deg/s. Tolerances in
`tools/debug_calibrate.tscn` are 6-15%.

**Collision is an editable shape list now**, not a fixed cube. `RobotShop.shapes`
is one box per part in inches, robot-local; empty means the stock 18 inch
chassis, so an unedited robot behaves exactly as before. ROBOT -> SHAPE adds,
removes and sizes parts, and warns when the result would not pass an 18 inch
inspection. This is what HITS things — the CAD remains only the picture.

**Four harness faults found, all of which had produced confident wrong
answers.** Worth recording because every one of them looked like a code bug:

1. The calibration harness faced the robot at a wall 11 inches away and
   measured a "top speed" of 23 in/s. It now starts at the far red end at
   y = -55, with 118 inches of clear runway.
2. It then measured stopping distance from wherever the speed run finished —
   nose against the far wall — and dutifully reported a 2 inch stop that was
   really a collision.
3. It printed a property that had just been renamed, which killed `_ready`,
   left `robot` null and hung the harness forever with no output. Harnesses now
   fail loudly if setup never completes rather than spinning.
4. `debug_yaw` measured sway against the heading the stick was RELEASED at
   rather than the heading the robot came to REST at. Those are 30 degrees
   apart after a full-speed stop, so a hold that was in fact steady to 0.4
   degrees was reported as 31 degrees of sway.

**And one real cross-test bug: harnesses were contaminating each other.**
`RobotShop` persists to `user://robot.cfg`, so `debug_calibrate` leaving
MEASURED behind silently changed the drivetrain every later harness tested.
`debug_calibrate` now restores stock when it finishes, and `debug_yaw` and
`debug_power` pin the stock drivetrain on the way in.

`MatchStats.track()` also reconnected its signals on every re-stage — the
`per.has(r)` guard does not help when `per` has just been cleared — so Godot
errored once per signal per stage forever.

## 3p. Session 16 - the roster, split controls, and a controls card

**The opponent no longer wanders into the HIVE.** The two leg planes at
|x| = 24.5 are joined by a base bar lying on the tile seam — an inch tall, and
invisible to a whisker cast at chest height, so the bot rode up on it and
ground along. Rather than teach it to climb a kerb it now treats the structure
as a keep-out box (`HIVE_KEEP_X/Y`): it routes around via one corner waypoint,
and ignores any ball parked inside the footprint, because the HIVE is directly
overhead and nothing in there is collectable anyway. Measured: 29 shots, 3
tips, 0.1 s jammed.

**The setup screen now describes a real alliance.** YOUR ALLIANCE picks one or
two robots; a sub-option under it says whether the second is another person or
an AI teammate; PER ROBOT chooses one person doing everything or a driver and
an operator; OPPONENTS is none, one or two AI bots. Sub-options are indented
and quieter so they read as belonging to the line above rather than as another
top-level choice.

`Robot.op_device` splits a robot between two people: drive, strafe, turn,
precision, field-centric and camera stay with the driver; intake, turret, hood,
launcher power, fire, eject, auto-aim and recalibrate move to the operator.
Left equal to `device` — the default — one person has the whole robot.

**A lambda ate the seat counter.** Devices were handed out through
`var take := func() -> int: ... seat += 1`, and GDScript closures capture
locals BY VALUE, so the outer `seat` never advanced and every seat silently got
the same controller. Two robots moving as one, no error, no clue. It is a plain
`_take_seat()` method now, and `debug_roster` checks that no two seats ever
share a device — the first version of that check was too lenient and passed
the bug.

**Intake option.** POLLEN ONLY or POLLEN + NECTAR, changing nothing else about
either element. A real 3.6 in NECTAR does not fit a POLLEN intake, which is why
the default is off, but plenty of robots are built for both.

**Removed:** the SHAPE page (editable collision boxes) and the FROM HARDWARE
drivetrain source. Hardware asked teams for gear ratios in order to PREDICT
numbers they could simply go and measure, and the measured path is both easier
and more accurate; the enum value is kept so older saved files still load and
is folded into STOCK.

**`scripts/controls_screen.gd`** answers the two questions that come up the
moment more than one person plays: which controller am I, and what does my half
do. Generated from the live roster and from `BB.ACTIONS`, so it cannot drift
the way a printed control card does, and it warns in orange when a seat has run
out of devices.

**`debug_yaw` was flaky, and the flakiness was the harness.** It exited its
measurement the moment the yaw rate dipped below a threshold — but steering
BACK to the release heading means reversing, and the rate passes through zero
as it does, so the test caught that instant and recorded the robot as stopped
30 degrees from where it actually settles. Alternating 2 deg / 31 deg results
between runs were the tell. Settling is now measured as being ON the bearing
for 0.2 s, which is what the word means. Repeatable at 0.3 deg overshoot from
a full-speed release.

## 3q. Session 17 - "I can phase through things"

Reported: the robot passes through the other robot, through the HIVE structure
and through things near one corner. Screenshots showed a robot apparently half
outside the perimeter with parts on both sides of it.

**Collision was fine. The DRAWING was not.**

`tools/debug_solid.tscn` rams a robot into another robot, a HIVE leg, a corner,
a FLOWER and a wall, laps the entire perimeter pressed against it, and measures
how far inside anything it gets. Every one of those passed on the first run:
worst wall penetration 0.11 in, two robots stop 17.9 in apart centre to centre,
the lap never leaves the field by any amount at all. Layers and masks are
mutual, which is the thing Jolt punishes.

What was wrong is that the robot was DRAWN outside its own collision box:

| part | overhang |
|---|---|
| intake roller | **2.70 in** fore/aft |
| bumpers | 0.80 in all round |

The bumpers were centred ON the 18 in edge rather than inside it, and the
roller sat 1.2 in beyond that with a 1.5 in radius on top. So the robot stopped
in exactly the right place and then LOOKED buried in whatever it had stopped
against — and when two robots meet, both overhangs add up to more than five
inches of interpenetrated geometry. That reads as phasing through.

It was also simply wrong: R102 says a robot starts inside an 18 in cube, so
nothing should poke out of one. Bumpers are flush inside the footprint now and
the rollers are tucked in by their own radius. Overhang measured at 0.00 in
both ways, and `debug_solid` asserts it stays there.

**The editable collision shape is gone for good.** It was removed from the UI
last session but `Robot._build()` still read `RobotShop.shapes`, so a stale
entry left in `user://robot.cfg` by someone who had experimented with the page
could silently give a robot the wrong collision — or none. Collision is a fixed
chassis box again, and the shape list is deleted rather than orphaned.

**Lesson for the next one of these.** "It phases through things" is a collision
report, and the collision was not the problem. The test that found it was the
one comparing what is DRAWN against what COLLIDES — not any of the five that
drove a robot into things at speed.

## 3r. Session 18 - the review pass: outcomes corrected, the workflow walked

Four things were asked for and nothing else was added.

### Objective outcomes: progress and constraints are judged TOGETHER

The old `_evaluate()` ran in a fixed order and gave every tie to the player.
The owner overruled it: a run that picks up a foul on the same step it finishes
did not meet a "without a foul" objective, and calling it a success is the game
flattering the driver. The whole step is now measured first and then judged:

```
1. measure progress - but ONLY while still inside the deadline.
   Once the deadline has passed, progress is LATCHED (`_latched`).
2. a broken constraint FAILS, even on the step that would have completed it.
3. otherwise, reaching the goal SUCCEEDS - including exactly ON the deadline.
4. otherwise, a passed deadline FAILS on time.
```

The deadline itself is spelled out rather than implied:

- The step that CROSSES the deadline is still inside it (`was_before =
  (elapsed - delta) < limit`), so completion exactly at the limit counts.
- Everything after it is latched out. Tips, shots and reach dwell all stop
  accruing; only the already-measured `progress` survives.
- THE ONE THING THAT MAY CROSS THE DEADLINE IS CONFIRMATION. `_eligible_since`
  records when the provisional points total first reached the goal. A total
  eligible BEFORE the deadline may finish settling after it — that is the game
  confirming a result the player had already earned. A total that only becomes
  eligible after the deadline may not. Falling back below the goal while
  settling clears `_eligible_since` and the attempt fails on time. A foul
  during settling still fails it, because step 2 runs first.

### Balls already in the air at the saved starting instant

Defined, documented in the objective help, and warned about in the editor. The
two goal kinds differ, and the difference is structural rather than special-
cased:

| kind | behaviour | why |
|---|---|---|
| SHOTS | never counted | a made shot needs a `MatchStats._pending` entry created by `Robot.launched`. Restoring a snapshot re-stages the robots and clears `per`, so a ball restored mid-air has no launch behind it. No code needed. |
| POINTS | DO count | the scoreboard is the match's own and it genuinely rises. The game will not keep a second scoreboard to subtract it back out (D3-adjacent: one scoring implementation, always). |

`Objective.in_flight(spec)` is **velocity only** — height was tried and was
wrong, because balls sit at rest inside FLOWERS and raised CELLs all match
long and every ordinary situation warned. `Attempt.airborne_at_start` records
the count and the results screen says so.

### Workflow: walked as a new player, four problems, all fixed

`tools/debug_workflow.tscn` is new: two processes, 61 checks then 5 after a
cold start, walking launch -> Play -> pick a drill -> understand it -> fail ->
read the result -> retry -> pause -> edit -> test -> return -> save -> quit ->
come back.

| found | fix |
|---|---|
| **THE PAUSE MENU DID NOT ALWAYS PAUSE.** Only the Esc/Start path in `_unhandled_input` called `mm.pause()`. `goto("Play")` while a match was in progress opened the pause menu over robots that were still driving and an objective clock that was still running. | `_open_pause_menu()` calls `mm.pause()` itself. It is idempotent, so the paths that already paused are unaffected. |
| The drills were BELOW THE FOLD at 1600x900, under Match setup, labelled only with a count. A new player launching a thing called DRIVER PRACTICE could not tell drills existed. | The card moved directly under the mode cards, renamed "Practice drills", primary Open library button, and it NAMES what is on the shelf. |
| Nothing in-game said which keys drive. The binding list was three clicks away in Settings -> Controls. | A Controls card on the pause menu: one line read from `BB.keys_for` (so rebinds show) plus a `UI.disclosure` with the full list, reusing `SettingsMenu.DRIVING/MECHANISMS/SESSION`. |
| The result screen's only footer action was Retry; "Back to library" was below the fold past the numbers. | `UI.shell()` gained `foot_alt`, a SECONDARY footer button hidden by default. `AttemptResults` shows it as Back to library / Return to editor. |

Retry fidelity re-verified in the same walk: every ball back within **0.0000
in**, the robot within **0.0000 in**, the source snapshot untouched, the clock
back at zero and paused time excluded. NOTE for whoever writes the next
harness: measure the field IMMEDIATELY after `retry_situation()` returns.
Waiting even 0.4 s lets the human-player NECTAR queue and ordinary physics move
things, and the drift you then measure is not the restore's.

### Packaged

`ASSESSMENT.md` (honest table: what was tested, what is still a guess, what
needs a physical robot) and `REVIEW-BUILD.md` (launch, controls, a 20-step
manual checklist, known limitations, what changed and how it was checked), plus
a Windows .exe exported from this exact project.

## 3s. Session 19 - the independent review, and what it cost to be wrong

An outside reviewer ran the shipped build on Windows, reran every supplied
harness, wrote probes of their own, and found three defects plus one false
claim. All four are fixed. Their probes are now regressions. READ THIS SECTION
BEFORE WRITING ANOTHER HARNESS.

### The lesson, first

Three of the four findings were in code this project already described as
TESTED. The fourth was a number the project ASSERTED that turned out to be a
collision. Both failure modes have the same root:

  A DIAGNOSTIC WITHOUT ASSERTIONS IS NOT A TEST.
  A MEASUREMENT THAT CANNOT PROVE ITS OWN CONDITIONS IS NOT A MEASUREMENT.

`debug_drive.gd` printed numbers and exited 0 forever. Its diagonal case drove
into `Field/HiveFrame` at t=0.772 s, inside its own 0.9 s window, and reported
27 in/s and -6.7 deg of yaw as drivetrain performance. ASSESSMENT.md then
carried "diagonals are broken" as the headline defect for a whole release.
On a clear floor the same commands give 67.3 in/s and <0.15 deg. Withdrawn.

### 1. PAUSE DID NOT STOP THE WORLD  (the serious one)

Reviewer's probe: an airborne ball moved 19.47 in during a 1 s pause while the
attempt clock stood still and hopper-full time grew by 1.0015 s. Reproducing it
here found worse - 115 in of ball travel, 46 in of robot travel - and a route
the reviewer had not taken: `goto()` from the nav bar did not pause AT ALL, so
walking to Settings mid-match left the match clock itself running.

Root cause: `MatchManager.pause()` set a boolean and switched robot input off.
Everything that did not check that boolean carried on - rigid bodies, the hive
swing, `MatchStats._process`, `Robot._physics_process`, and every timer built
on `Time.get_ticks_msec()`.

THE FIX IS ARCHITECTURAL, ON PURPOSE. `BB.halt()` sets `SceneTree.paused`, so
the default for anything new is to STOP; the handful of nodes that must keep
running say so with PROCESS_MODE_ALWAYS. A flag-plus-checks pause is what
failed, and repeating it with more checks would fail the same way later.

NON-OBVIOUS ENGINE BEHAVIOUR, measured with tools/probe_pm (since deleted):

    SceneTree.paused = true stops the PHYSICS SERVER outright - bodies do not
    integrate regardless of their process_mode - but _process and
    _physics_process STILL FIRE on PROCESS_MODE_ALWAYS nodes.

So making `main` ALWAYS (needed, or Esc could never un-pause what Esc paused)
made every child that INHERITS run while halted. Bodies froze, MatchStats kept
counting. `field`, `mm`, `stats` and every spawned robot and element are now
explicitly PAUSABLE.

Also new: `BB.sim_time` / `BB.sim_now()`, advanced in _physics_process only
while neither halted nor restoring. `MatchStats._now()` and `Robot._now()` both
use it, so a shot's MADE_WINDOW, the manual-aim hold and the control-latency
queue can no longer expire behind a menu. FREEZING BODIES ALONE IS NOT ENOUGH -
the reviewer said so explicitly and they were right.

`BB.set_restoring()` lifts the halt for the duration of a snapshot restore,
which needs live physics frames to settle bodies into their saved poses.

### 2. FINAL SCORING CONFIRMED POINTS THAT HAD GONE

    latched=8  live_delta=0  final_delta=6  ->  succeeded

`attempt.gd` had `reached = (progress if _latched else delta_points) >= goal`.
Latched progress is a record of what the PROVISIONAL scoreboard once showed. It
is not evidence the points are still on the field. The match scores the field
at rest; so does this now. Pre-deadline eligibility is untouched, because an
attempt that never became eligible has already failed on time before the buzzer.

### 3. THE DEADLINE INCLUDED THE FRAME THAT RAN PAST IT

    previous=9.95  now=10.05  limit=10  ->  succeeded

`Attempt` ran on `_process`. The boundary test asked whether the step STARTED
before the limit, so a whole rendered frame crossed it - and the grace period
was therefore a function of frame rate: ~50 ms at 20 fps, ~3 ms at 300.

Now on `_physics_process` (fixed 180 Hz) with the rule stated in one line:

    A TICK COUNTS IF THE SIMULATION CLOCK AT THE END OF IT IS AT OR BEFORE THE
    LIMIT.      inside := (not timed) or elapsed <= limit + TICK_EPS

TICK_EPS is 1 us of float slack so a limit landing exactly on a tick boundary
still counts as "at the limit". It is NOT a grace period. Verified at step
widths of 1/180, 0.05 and 0.25 s: identical outcome.

### 4. HUD OVERLAP AND A CAPTURE HARNESS THAT LIED

`objective_hud` used a fixed `offset_top = 150`, assuming the scoreboard's
DECLARED minimum height (176 px). A PanelContainer sizes to its contents, so
the real height varies with the text in it and at 1280x720 the cards touched.
`Hud.left_panel_bottom()` now reports the measured edge and `_place()` sits
under it.

Worse: the reviewer ran `shot_all` against a CLEAN PROFILE and got a folder of
screenshots that were all the first-run name dialog with the intended screen
behind it - and the harness reported PASS for every one, because every widget
it measured was on the canvas. IT WAS CHECKING BOUNDS AND CALLING THAT A
SCREENSHOT. `shot_all` now declares its profile state (`-- fresh` captures the
first-run dialog deliberately), runs an OCCLUSION check on every capture, and
self-tests that check by confirming a screen behind the dialog IS reported as
covered.

### What to do next

  - implement per-wheel speed normalisation, or decide not to, WITH
    measurements. The prediction (0.707x, 48.1 in/s) is derived in the header
    of debug_drive.gd and deliberately not asserted.
  - re-run tools/perf_sample.tscn (the reviewer's own harness, kept verbatim)
    on real hardware: this pass changed process modes across the whole tree.
  - a physical controller, and a driver.

## 3t. Session 20 - the follow-up review: the list was one short again

The same reviewer re-ran session 19's build. The three fixed defects stayed
fixed (102+7 objectives, 40 drive assertions, 30 pause assertions after they
gave the harness a populated scenario). Two things came back.

### 1. AUTOPLAYER RECORDED AND PLAYED BACK THROUGH THE PAUSE

    AUTO_PAUSE recording: halted=true new_frames=30  simulation_seconds=0.0
    AUTO_PAUSE playback:  halted=true playback_seconds=1.0 auto_process_mode=0

Their diagnosis was exact. `main` is PROCESS_MODE_ALWAYS (it has to keep taking
input, or Esc could never un-pause what Esc paused). `auto_player` inherited
that and was NOT in session 19's explicit list of simulation nodes to hold down
(`field`, `mm`, `stats`).

THE FIX IS NOT "ADD AUTO_PLAYER TO THE LIST". That list was one short in
session 19 and would be one short again. THE DEFAULT IS NOW INVERTED:

    main.always_running() -> the world root, rig, hud, and each menu layer
    main._mark_process_modes() -> those ALWAYS, EVERYTHING ELSE under the root
                                  PAUSABLE, by exclusion
    main._adopt(node) -> the ONE door for anything added after startup
                         (robots, elements, AI brains, the Attempt)

Adding a subsystem now pauses by default. Getting it wrong takes a deliberate
opt-in. Also: `_guided_record`'s count-in and its `recording_left` countdown use
`create_timer(t, false)` now - a SceneTreeTimer is process_always=TRUE by
default, so both were running out behind the menu.

### 2. THE GUARD THAT COULDN'T FAIL, AND WHAT IT THEN FOUND

Added `debug_pause._nothing_else_is_running()`: walk the live tree while halted
and fail if any node outside `always_running()` can still process. The generic
form of the defect, so the next omission is a test failure.

THE FIRST VERSION OF IT PASSED AGAINST THE BROKEN BUILD. It started the walk at
`main`, matched it as always-running, and returned - never scanning one child.
A test that cannot fail is the exact failure mode this whole review sequence is
about, and it happened INSIDE the fix for it. Start the walk at the root's
CHILDREN.

Corrected, it caught AutoPlayer on the old code and then immediately found a
leak neither review had: `Snapshot.restore()` added restored elements with
`main.add_child(e)`, bypassing `_adopt`, so every ball in a loaded situation
kept `_settle()`-ing and bounds-checking behind the pause menu. Routed through
`_adopt`.

### 3. THE FIXTURE DEFECT

`debug_pause` loaded `ScenarioLibrary.list_all()[0]`. In a fresh profile that
was "Recover from the corner" - an empty-field drill - so `_stir()` found no
ball and the run died dereferencing null, REPORTING THAT AS A PAUSE FAILURE.

`_setup()` now AUTHORS its fixture: a staged field through the editor, a SHOTS
objective with an unreachable target so the attempt stays live, saved, loaded
by the id that saving RETURNED, deleted in `_teardown()`. Shelf order and
starter-drill names are irrelevant to it. `_bail()` prints what was missing,
tears down and quits(1) instead of continuing with nulls. Verified by pointing
the fixture at an empty field on purpose: exit 1, clean message, no errors.

RULE FOR EVERY FUTURE HARNESS: never index into user data. Author the fixture,
reference it by the id you got back, delete it after.

### 4. CLEANUP

`Attempt.Objective_area()` set `global_position` on a node that had not entered
the tree yet (an engine error). It sets a LOCAL position now; new
`Attempt.place_area()` puts an ATTACHED marker in world space, and both the
attempt and the editor call it after `add_child`.

## 3u. Session 21 - controller setup, tuning and profiles

An INPUT pass. Drivetrain physics, speed and turn limits, scoring, AI and
autonomous execution are untouched. Everything added sits between the thumb
and the command.

### New files

  scripts/control_profile.gd  ControlProfile: a named set of bindings +
                              tuning, in user://control_profiles.json. Kept
                              deliberately apart from the DEVICE (an id that
                              changes every session), the SEAT (a job) and the
                              ROBOT (whose limits are not negotiable).
                              Every value validated on load.
  tools/debug_input.gd        90 checks + 6 after a real restart, two phases.

### The deadzone was a THRESHOLD, which is the wrong shape

Old: `if raw > 0.18: v = raw`. So the axis went from 0 to 0.181 across a hair
of stick travel and there was NO WAY TO ASK FOR 5%. Replaced with continuous
rescaling:

    t   = (magnitude - deadzone) / (1 - deadzone)     zero at the edge
    out = t ^ curve                                    1.0 at full, always

The curve exponent changes how far the thumb travels for a given command and
CANNOT change the maximum, because t == 1 at full deflection whatever the
exponent. That sentence is on screen too, because it is the thing players
always assume is untrue.

### The driving stick is ONE stick

Per-axis deadzones are wrong twice: a diagonal nudge of (0.15, 0.15) reads as
nothing on both axes though the thumb moved 0.21, and a full diagonal asks for
1.41x full speed. shape_vector() shapes the MAGNITUDE radially and keeps the
direction. A 360-degree sweep in the harness asserts nothing exceeds 1.0.

### turn_sens WAS CAPPING THE ROBOT

`turn = clamp(turn * sens)` scales the COMMAND. At sens 0.4 a full stick asked
for 40% turn and could not ask for more. That is not a sensitivity, it is a
speed limit nobody agreed to.

Settings.migrate_turn_sens() runs ONCE: stock profile's turn_curve = 1/sens
clamped to [0.5, 3.0], then a flag. Nothing reads turn_sens for gameplay
afterwards, so the old multiply and the new curve CANNOT BOTH APPLY.
Behaviour change to own: anyone below 1.0 gets their full turn rate back.

### The neutral gate

After a rebind, a profile load, a reconnect or a restored situation, the game's
idea of "was this down last frame" belongs to a different world. DriverInput
GATES the device: every read returns zero and no edge fires until the hardware
is seen at rest, then it opens by itself. No press consumed, none invented.
raw_strength()/raw_move() bypass it so DIAGNOSTICS can still see a held
trigger while the gate refuses to act on it.

### Seats, and two pads that are the same pad

Device ids are not stable and two identical controllers share a GUID. So:
seats store a PROFILE id (stable) and a device PIN (advisory), and
DriverInput.is_ambiguous() reports when more than one connected pad is
indistinguishable, at which point the screen asks for Identify instead of
guessing. Assigning a pad another seat holds is REFUSED by name.

Settings.device_lost -> main._on_device_lost: a pad vanishing mid-run pauses
and names the seat. Reconnect deliberately does NOT resume.

### UI

Controls is four sub-tabs (Seats / Feel / Buttons / Profiles). One column was
43 controls below the fold, which is a scroll, not a setup flow. The live
preview sits on Feel and Buttons, reads the RAW path, and works while the
world is halted because the settings screen is PROCESS_MODE_ALWAYS - verified
in debug_pause that 30 preview frames move nothing on the field.

NOTE: `slow` and `recalibrate` have NO stock pad button. Every face, shoulder
and d-pad button is already taken. Rather than silently steal one they are
shown in amber as "Not bound - click to set". Do not "fix" this by assigning
one; it would break somebody's muscle memory.

## 3v. Session 22 - configurable practice opponents

Four behaviors in the EXISTING AIDriver: COLLECT (the original opponent,
unchanged), STATIONARY, ROUTE, DEFEND. See OPPONENTS.md for the player-facing
account. This section is for whoever edits the code next.

### Where things live

  scripts/opponent_config.gd  OpponentConfig: behaviors, FIELDS (default, min,
                              max, label, help, unit), KEYS per behavior,
                              PRESETS, sanitize(), check(), canon(),
                              from_brain() = THE COMPATIBILITY PATH.
  scripts/ai_driver.gd        the brain. `config` + per-behavior runtime state,
                              all timers as REMAINING time, `status` set by
                              whichever branch ran this tick.
  scripts/opponent_overlay.gd routes/areas/status drawn on the field; editor
                              uses for_config(), practice uses for_brain().
  scripts/scenario_draft.gd   opponent(id) READS (never converts a legacy
                              brain); set_opponent() is the only write, and
                              clears saved runtime state on any edit.
  tools/debug_opponents.gd    66 + 3 checks, two phases.
  tools/demo_opponents.gd     renders the four drills to _shots/demo_*/.

### Decisions worth keeping

  - STANDARD COLLECT == THE OLD OPPONENT. CRUISE became `pace` (0.55),
    the 0.25 s think interval became `reaction`. APPROACH keeps its
    0.34/0.55 proportion. Do not "retune" Standard.
  - A brain dict with no "behavior" key is LEGACY. from_brain() reads it as
    Collect/Standard. The signature adds "opponents_cfg" ONLY when a
    non-legacy brain exists, so every pre-existing scenario hashes identically
    and keeps its practice history. Verified in the harness.
  - Presets are NAMES FOR VISIBLE VALUES. preset_name() is COMPUTED, never
    stored, so a label cannot claim a preset whose numbers were edited. Area
    geometry and target are deliberately NOT preset fields.
  - Defend and Stationary call _steer_to(..., avoid=false). A defender that
    sidesteps the robot it is blocking is not defending; a parked robot that
    sidles away from an approaching one is not parked.
  - Defender goals are CLAMPED INSIDE THE CIRCLE. It cannot plan a point
    outside its area, so it cannot chase. Physical shoves are the only way
    out; tested tolerance is radius + 12 in (measured worst 23 of 30).
  - The defender SAMPLES the target's position every `reaction` seconds.
    That is its only knowledge of the target. No prediction, by design.
  - _renumber() remaps defender `target` indices when robots are added or
    removed. A removed target becomes -1 and check() reports it.
  - Opponent overlays in practice are NOT built while BB.frozen(): brains
    exist before their saved config is applied during a restore.

### Gotchas found this session

  - A RECORDER TIMED BY COUNTING AWAITED FRAMES LIES under software GL: one
    screenshot lets several physics steps run. The first demo run let every
    attempt time out and filmed the results screen. Time on BB.sim_now().
  - ...and a recorder waiting on BB.sim_now() DEADLOCKS when the attempt
    succeeds, because the results screen halts the world. End on BB.halted.
  - `pkill -f <pattern>` matches the shell running it. Use ps + awk.
  - settings_menu._tick_preview cast freed labels for one frame after a
    Controls tab switch (a latent bug from session 21). Now checks every
    entry with is_instance_valid first.
  - A top-level "saved" timestamp is stamped by every to_snapshot() call, so
    compare drafts with it removed.

## 3w. Session 23 - replays, "Practise from here", an unlimited local collection

Every run is recorded as authoritative STATE (never inputs), watched in a
read-only viewer, and any recorded checkpoint can become a saved situation.
Player-facing account + measured costs: REPLAYS.md. This is for the next editor.

### Where things live

  scripts/replay_format.gd    ReplayFormat: the .bbreplay byte layout, chunk
                              write/scan/read, peek_header(). Append-only.
                              scan() reads chunk HEADERS only.
  scripts/replay_store.gd     ReplayStore: folder (user://replays by default,
                              user://replay_settings.json), sidecar <id>.json
                              (title/favourite/tags/summary), index.json CACHE,
                              list() / delete() / set_folder() / move_all().
  scripts/replay_recorder.gd  ReplayRecorder (PAUSABLE child of main): 30 Hz
                              samples in 1 s blocks, a Snapshot checkpoint
                              every 1 s, events, FINAL chunk. Bounded memory.
  scripts/replay_reader.gd    ReplayReader: lazy block decode + 12-block LRU.
  scripts/replay_viewer.gd    ReplayViewer (ALWAYS CanvasLayer 31): poses the
                              REAL field from samples while BB.viewing.
  scripts/replay_timeline.gd  the scrub bar.
  scripts/replay_branch.gd    checkpoint -> situation (Free practice, no
                              objective, `origin` block). refusal(), summary().
  scripts/replay_library.gd   Progress -> Replays page (built into Progress).
  tools/debug_replay.gd       163 + 12 checks, two phases (write / read).
  tools/perf_replay.gd        -- match | long [min] | library  (measurements)
  tools/demo_replay.gd        films the workflow + stills to _shots/.

### Hooks added to existing code (all additive)

  BB.viewing / set_viewing(): frozen() includes it, refresh_halt() halts on it.
  MatchManager: signals `started` (end of start()) and `aborted` (abort() when
    a run WAS in progress).  MatchStats: signal `shot_made(r, e)` at the one
    place a made shot is credited.  Snapshot.capture(main, rng_seed := -1).
  CameraRig.Mode.OVERVIEW (appended; cycle() unaffected).  SFX.stop_all_loops(),
    SFX.plays counter.  Hud.notice().  results / attempt_results: Watch replay,
    show_note(), reopen().  main: recorder + viewer, watch_replay(),
    _on_viewer_closed(), _leave_replay_world() (re-stages; a replay's poses are
    a picture, not a run), _no_record_next for test drive + guided auto.

### Decisions worth keeping

  - LIFECYCLE: begin() only ARMS. The file is created on the first live tick
    (in progress, not paused, not frozen). ARMED -> finish() writes nothing.
    Ends: mm.aborted (retry/end/reset/replace), mm.finished (deferred one
    frame so Attempt can hand over its outcome first), Attempt finished
    (main._on_attempt_finished -> note_attempt), WM_CLOSE_REQUEST.
  - Situation runs arm in _restore_and_play AFTER _start_attempt (they resume,
    they do not start()). Matches arm on mm.started.
  - ELEMENT TABLE ORDER == Snapshot.capture order, taken on the same tick as
    checkpoint 0, so sample element k == checkpoint-0 element e(k+1). The
    viewer maps via the `sid` meta restore sets. No element spawns mid-run in
    this game; if that ever changes, the recorder needs a table-change chunk.
  - Viewer staging: Snapshot.restore(cp0, for_editing=true), then editing off,
    viewing on (halt). Hidden (human/out) balls are STILL PLACED at their
    recorded spot so the picture is a pure function of t (a test caught
    history-dependence here).
  - Interpolation is display-only and never crosses an owner change or a jump
    > 0.5 m (robot) / 0.6 m (ball). Numbers = floor sample.
  - Checkpoint CAPTURE on the sample tick, ENCODE+WRITE 3 ticks later
    (CHECKPOINT_WRITE_LAG): keeps the worst tick ~2 ms instead of ~3.7 ms.
  - ReplayStore.new_id uses a PRIVATE RNG. Snapshot.restore seed()s the global
    one, so randi() ids repeated across retries, AND drawing from it changed
    the game's human-placement randomness. Same reason the recorder passes its
    own rng_seed to capture().
  - Sidecar fast path trusts status=complete + rec_bytes == size, but still
    peeks the 16-byte signature (catches replaced / newer files).
  - The viewer's panels only re-set text when it changes; recolouring 90+
    event buttons every frame cost 1.5 ms (now 0.05 ms).
  - Branch = Free practice + no objective + `origin`. Historical scoreboard
    kept; Attempt baselines make any new objective start at 0 (tested).
  - SETTLE/DONE/PRE checkpoints are refused for branching, with a reason.

### Gotchas found this session

  - Object already has _set(); a static helper named _set() is a parse error
    ("signature doesn't match the parent"). Named _put_text().
  - stats._on_tip: get_meta(key, null) STILL errors on a missing key (null is
    "no default"). A hive tipped with no feeder spammed errors. has_meta() now.
  - `ps | grep pattern | kill` in the SAME command line kills the shell (the
    line contains the pattern). Kill in a separate command.
  - FileAccess.get_size(path) / get_modified_time(path) are static in 4.5.
  - --fixed-fps 180 runs physics as fast as the CPU allows, one tick per
    frame: that is how the 20-minute session was measured in 9 minutes.

## 3x. Session 24 - private online practice rooms

Player/operator guide, hosting, measured limits, test record: ONLINE.md.
STATUS: implemented + tested locally. NOT deployed, NOT tested over the
internet (no server exists; play.pandara.org not created). Keep saying so.

### Architecture (process-per-room)

  boot.tscn (run/main_scene) -> NetRole.parse(user args after `--`):
    client (default)  -> main.tscn, offline game unchanged
    --broker          -> NetBroker: room service. Codes, rate limits, tickets,
                         spawns rooms (OS.create_process same exe --headless
                         -- --room <port> <secret> <broker_port>), reaps them.
                         No simulation.
    --room            -> main.tscn headless + NetRoomServer: THE simulation.
  Ports: broker UDP 7350, rooms 7400-7415. Players connect OUTWARD only.
  ENet 4 channels: 0 control rel, 1 input unrel, 2 state unrel, 3 bulk rel.

### Where things live

  scripts/net/net_role.gd      NetRole: mode, args, compat() key, constants
  scripts/net/net_link.gd      NetLink: ENet host + byte counters + SIMULATED
                               latency/jitter/loss (both directions, this end)
  scripts/net/net_proto.gd     NetProto: ids, 25-byte input, snapshot codec
                               (quantized row), role action lists
  scripts/net/net_scenario.gd  NetScenario: wire form + untrusted validation
  scripts/net/net_broker.gd    NetBroker
  scripts/net/net_room.gd      NetRoomServer (states lobby/loading/countdown/
                               running/paused/results; seats; timing rules)
  scripts/net/net_session.gd   NetSession: protocol client (no world)
  scripts/net/net_client.gd    NetClient: game side; puppet world, input send,
                               interpolation clock, replay writer
  scripts/net/online_screen.gd / lobby_screen.gd / net_hud.gd   UI
  scripts/net/net_replay_writer.gd  streamed chunks -> local .bbreplay
  scripts/world_pose.gd        shared posing (viewer + puppet)
  scripts/boot.gd              front door
  deploy/                      Dockerfile, run-server.sh, biobuzz.service
  tools/net_bot.gd (NetBot), net_bot_proc.tscn (bot as separate process)
  tools/debug_net_smoke / debug_net_client / debug_net_2proc / debug_net
  tools/perf_net.gd (-- quick | -- baseline | -- remote host:port)
  tools/demo_online.gd (rendered film + stills, real time)

### Hooks in existing code (additive)

  BB.puppet/set_puppet (frozen + halted). DriverInput VIRTUAL devices
  (1000 + 2r driver, +1 operator): set_virtual/add_virtual_presses/clear_*;
  is_gated false for virtual (room keeps its own neutral gate).
  ReplayRecorder.fill_row static; sink Callable streaming; header_extra;
  flag bit 4 paused. ReplayFormat encode_chunk/check_chunk/write_encoded.
  ReplayStore "partial" health from coverage_note. ReplayLibrary "Online
  practice" filter. main: ai_mask roster, foes via _adopt, server guards,
  net/net_room vars, online guards in goto/unhandled_input/device_lost.
  Snapshot setup.ai_mask. ScenarioDraft.to_snapshot sets ai_mask. menu:
  Online practice card -> signal open_online.

### Decisions worth keeping

  - Owner != server. Owner = player with room-management commands. The
    room process is the only authority. No client prediction at all.
  - Inputs: 60/s, seq + run id. Room drops old seq, old run, >90/s, wrong
    seat parts (counted as `masked`). Presses = u8 running counters.
  - STALE_INPUT_MS 250 -> seat neutral. Reconnect: token, same seat, must
    send neutral before inputs count again (needs_neutral).
  - Retry: one finalize, restore checkpoint (incl. AI wait_left), new run
    id, wait RESTORE_ACK from every seated player, countdown. Snapshots are
    NOT sent while _busy (restoring) — sending mid-restore wedged loading.
  - Pause of whole room = SceneTree halt in the room process; the room node
    and link are PROCESS_MODE_ALWAYS.
  - Owner leaving closes the room (no hand-over). Owner disconnect = grace.
  - Rate limits per IP: 40 joins/min, 6 creates/min, 8 WRONG codes/min,
    20 wrong/10 min -> 10 min block. (Was 10 joins/min total: a school
    behind one NAT would have been refused. Changed this session.)
  - `--load-report` is a FLAG (was parsed as taking a value and swallowed
    the next option).
  - Room waits 1 s, halts, THEN listens/connects to broker.

### Gotchas found this session

  - pkill -f "-- --room" parses the pattern as options. Use
    OS.execute("pkill", ["-f", "--", "--room 17..."]).
  - New class_name scripts need `godot --headless --editor --quit` once.
  - Input.parse_input_event with the SAME InputEventKey object twice is
    ignored the second time: make a new event per press/release.
  - /proc files read empty through FileAccess (size 0). Use OS.execute cat.
  - Many "[FAIL]"s under CPU load were test races (waiting on one bot then
    checking three). Wait on every party you assert about.
  - Headless tests on this 2-core box: 8 bots + room + broker share CPU;
    loopback ping reads ~20 ms from scheduling alone.

## 3y. Session 25 - player-hosted rooms, Epic Online Services, no servers

Replaces 3x's dedicated server (broker + room processes + deploy/). The
HOST PLAYER'S GAME runs the room. ONLINE.md has the player guide, the EOS
setup steps, and the simulated / local / internet test split.
STATUS: implemented + tested locally + EOS path tested against a SIMULATED
backend only. EOS never run for real (no plugin binaries / credentials /
network to Epic here). No internet test yet.

### Architecture

  host's game:  main (live world) + NetClient + NetRoomServer (child of
                NetClient, PROCESS_MODE_ALWAYS). links[0] = LOOP pair to the
                host's own NetSession; links[1] = EOS server peer or ENet.
  guest's game: main as PUPPET + NetClient + NetSession over EOS client peer
                (or ENet LAN).
  discovery:    EOS lobby = directory entry only (PublicAdvertised, bucket
                "biobuzz3d", max 8 members, attributes bb_compat/bb_version/
                bb_room/bb_locked/bb_players). Guests SEARCH BY ID, never join
                it; joining it grants nothing. Lookup ERROR (null) -> try the
                invite's host PUID directly; EMPTY result -> "room ended".
  invite:       BBZ1-E.<lobby id>.<host PUID>.<secret>   (NetInvite)
                BBZ1-L.<addr>:<port>.<secret>             (same network)
  admission:    ENTER {secret} checked constant-time by NetRoomServer; the
                LOOP link's first entrant is the owner. Wrong secret -> DENY +
                drop after 400 ms. Reconnect = seat token as before.
  login:        Connect interface, Device ID credential, persistent (NOT
                EOSG's login_anonymous_async, which deletes the device id and
                gives a new PUID every launch).
  transport:    NetLink over any MultiplayerPeer (ENet / EOSGMultiplayerPeer)
                or LOOP. 1-byte header (channel | FRAG) + fragmentation at
                MAX_DATAGRAM 1164 = EOS_P2P_MAX_PACKET_SIZE 1170 - EOSG 6.
                Same limit on ENet so tests exercise it.
  no host migration: host leaves -> room._close -> CLOSED to all -> lobby
                destroyed; host gone past grace -> guests' reconnect window
                ends -> "Lost the connection to the host". Replays kept.

### Where things live (new / changed this session)

  scripts/net/net_link.gd     rewritten (MultiplayerPeer + LOOP + fragments)
  scripts/net/net_invite.gd   NEW  token make / parse / secret / LAN addrs
  scripts/net/net_eos.gd      NEW  EOSG via run-time lookups only
  scripts/net/net_room.gd     host-in-game: links[], secret admission,
                              _close emits `closed` (no quit), SILENT_MS,
                              status_changed -> lobby attrs, SET_RATE
  scripts/net/net_session.gd  rewritten: link factory, queue until WELCOME,
                              loss from snapshot gaps, route
  scripts/net/net_client.gd   host_room / join_room / host_headless, host
                              view (no puppet), EOS node, teardown restores
  scripts/net/online_screen.gd  Host (internet | same network) / Join (paste)
  scripts/boot.gd             game only; --host-test for the harnesses
  REMOVED: net_broker.gd, deploy/
  tools/fake_eos/             simulated EOSG (same API) for debug_net_eos_sim
  tools/debug_net_link.gd     transport + fragmentation
  tools/debug_net_2proc.gd    THE PROTOTYPE: game hosts, separate program joins
  tools/debug_net_eos_sim.gd + eos_sim_guest.gd   simulated EOS, 2 programs
  eos_credentials.example.cfg template; export_presets include_filter adds
                              eos_credentials.cfg

### Decisions worth keeping

  - Scripts never name EOSG classes (ClassDB.instantiate, get_node(/root/H*),
    GDScript constant maps for EOS.* option classes/enums). A build without
    the addon parses, runs, plays offline and plays same-network.
  - EOSG's autoloads are PAUSABLE by default; the room halts the tree. NetEOS
    sets EOSGRuntime/HPlatform/HAuth/HLobbies/HP2P to PROCESS_MODE_ALWAYS or
    EOS would stop ticking the moment the host paused.
  - Host plays through the LOOP link like a guest (same validation, same
    inputs path, MENU neutral). Its world is live, so NetClient skips puppet
    build/pose when hosting and just aims the camera.
  - Host personal menu = MENU message only; never mm.pause / BB halt. Test
    drive is blocked while in a room (it would have started an offline match).
  - Standard setups start opponents as AI (3x change) — still true.
  - Low upload: SET_RATE {low} host-only, snap_every 3 -> 6; guests' draw
    delay = 2 x snap_every + 2 x jitter; loss meter uses snap_every.
  - Messages a session sends before WELCOME are queued (a host's first click
    raced its own ENTER and was dropped as "unknown peer").

### Gotchas found this session

  - ENetMultiplayerPeer client after disconnect is inactive: mp.poll() on it
    errors every frame. Check get_connection_status() first.
  - A burst of 180 unreliable datagrams on ENet loopback loses ~40 % with no
    simulation at all — unreliable means unreliable; don't test for 100 %.
  - `await obj.call("async_method")` works; static funcs on GDScript inner
    classes are callable via (script as GDScript).call(); enums arrive as
    Dictionaries in get_script_constant_map().
  - GitHub API / release downloads and api.epicgames.dev are blocked from this
    workspace; `git clone` of public repos works (read EOSG source that way).
  - Holding a key from before a run starts is deliberately ignored until it is
    released (require_neutral). Tests must press after "running".

## 4. File map

```
project.godot            engine config, autoload BB, Jolt, 120 Hz
scenes/main.tscn         4 lines: Node3D + main.gd. Everything else is code.
scripts/bb.gd            ALL constants + manual citations + fp()/mat() helpers + InputMap
scripts/element.gd       GameElement: POLLEN / NECTAR RigidBody3D
scripts/hive.gd          Hive: hinged bi-stable seesaw, emits tipped(alliance)
scripts/flower.gd        Flower: tube + rings + scoring Area3D        [pending]
scripts/field.gd         walls, tiles, tape, HIVE frame, zones        [pending]
scripts/robot.gd         mecanum chassis, intake, hopper, launcher    [pending]
scripts/match.gd         phase clock, human nectar entry, fouls       [pending]
scripts/scoring.gd       Table 10-2 implementation                    [pending]
scripts/hud.gd           clock, score breakdown, mechanism readout    [pending]
scripts/camera_rig.gd    chase / overhead / driver-station            [pending]
scripts/main.gd          assembles the world, staging, reset, ROSTER   [pending]
scripts/driver_input.gd  per-device control reads, so two drivers do not cross
scripts/ai_driver.gd     the optional opponent: collect / shoot / defend / unstick
scripts/menu.gd          title screen: mode, alliance, setup options, robot picker
scripts/leaderboard.gd   local best-per-variant board + base64 share codes
scripts/signin.gd        one-time name prompt on first run
tools/calibrate.gd       headless tip-threshold solver + full-table sweep
tools/smoke_match.gd     end-to-end: staging check, then aim/fire/tip/score
tools/debug_drive.gd     drivetrain benchmark (fwd / strafe / diagonal / spin)
tools/debug_hive.gd      one-shot seesaw diagnostic
tools/debug_shot.gd      tick-by-tick trajectory + contact trace for one shot
tools/debug_coop.gd      2 drivers + AI opponent + randomised field: roster, seats, counts
tools/debug_human.gd     human player reaction time, one-at-a-time feeding, placement
tools/shot_fit.gd        renders the title screen and fails if any Button is off-canvas
tools/tip_time.gd        asserts how long a TIP takes, and that heavier loads are quicker
tools/debug_power.gd     start-at-spec and the ~10% fade across a match
tools/debug_audio.gd     generated audio: silence, clipping, DC offset, loop seams
scripts/audio.gd         every sound, synthesised at startup. No audio files.
scripts/settings.gd      the settings store, persistence and apply
scripts/settings_menu.gd the settings screen
scripts/stats.gd         per-robot match statistics, collected passively
scripts/results_screen.gd the match report: SCORE and STATS pages
scripts/robot_shop.gd    hardware specs -> drivetrain, CAD path, match history
scripts/robot_menu.gd    the ROBOT screen: specs, model, auto, history
scripts/cad_import.gd    GLB/glTF via GLTFDocument, STL parsed by hand
scripts/auto_routine.gd  a recorded autonomous: input frames at 30 Hz
scripts/auto_player.gd   records and replays one against a robot
tools/debug_report.gd    breakdown arithmetic, stats counting, the auto recorder
tools/debug_yaw.gd       overshoot, sway and drift - is the turning tight?
tools/debug_opponent.gd  the AI over a full teleop: collect, fill, score, repeat
tools/debug_flower_retrieve.gd  a FLOWER must give balls back
tools/debug_calibrate.gd the sim has to reproduce the numbers a team measured
tools/debug_roster.gd    every roster combination, and who holds which controller
tools/debug_solid.gd     nothing phases through anything, and nothing is drawn
                         outside its own collision box
scripts/controls_screen.gd  who has what, generated from the live roster
scripts/replay_*.gd      replays: format, store, recorder, reader, viewer,
                         timeline, branch, library page (see 3w)
tools/debug_replay.gd    replay + practise-from-here harness (write / read)
tools/perf_replay.gd     recording cost, growth, memory, seek, library size
scripts/net/*.gd         online rooms, player-hosted (see 3y; 3x is history)
scripts/boot.gd          front door (game; --host-test for harnesses)
tools/*net*.gd           online harnesses, load test, rendered demo
tools/fake_eos/          simulated EOSG for the EOS-path logic test
ONLINE.md                online rooms: players, EOS setup, limits, test record
README.md                player-facing: install, controls, what the physics buys
```

Each `tools/*.gd` has a matching 6-line `.tscn`. Run any of them with
`godot --headless --path . tools/<name>.tscn`.

## 5. Verification

Godot 4.5 headless binary is available in the build container and IS used to check
the project — `godot --headless --path . --quit` for parse/import, plus the
calibration harness for physics. Nothing is shipped unparsed.

---

## STATUS / RESUME HERE

```yaml
session: 2026-09-24e
status:  SMOOTHER + SHARPER (browser feedback: "jittery, less sharp").
         Physics interpolation ON (project.godot physics_interpolation=true,
         jitter_fix=0): bodies are DRAWN between their last two 180 Hz ticks.
         Visual only, simulation untouched. BB.refresh_interpolation() turns it
         off while BB.frozen() (replay viewing, net puppet, editor, restore) and
         resets on every switch; BB.snap_visuals() after teleport/reset_to;
         main.stage() resets the whole tree. Camera rig + robot preview +
         opponent overlay are INTERPOLATION_MODE_OFF (moved in _process); the
         rig follows get_global_transform_interpolated().
         Graphics: Quality preset Low/Medium/High(default)/Max + Resolution
         (75/100/150/200 %, bilinear), Anti-aliasing, Shadows Off/Low/High/Ultra
         (Settings.preset_values / apply_graphics; any edit -> "Custom").
         Max = 200 % supersample + MSAA 8x (4x in browser) + 8192 soft-ultra
         shadows (4096 soft-high in browser). Anisotropic 16x (4x on Low).
         Sun shadow range 100 m -> 12 m (field is 3.7 m): far crisper shadows.
         F3 readout moved to top centre (was over the red score panel) and
         now shows the preset + render scale.
verified: _chk; run_tests.sh quick 16/16; tools/shot_quality.tscn renders
         all four presets (inspected: Max edges clean, Medium shadows smooth
         after 2048->4096 + soft-low). smoke_match's tip check is flaky with
         interpolation ON or OFF (4/6 vs 4/5 passes) — pre-existing chaos in
         the shot, not caused by this.
         Threaded browser build measured (headless Chromium, perf_frame): no
         physics gain (4-6 ms per tick either way), so the browser stays
         no-threads (no COOP/COEP headers needed).
not_1to1: browser uses WebGL 2 (Compatibility renderer), desktop Vulkan
         (Forward+): same game and physics, slightly different lighting.
open:    real-GPU check of Max in a browser; the items below.
```

```yaml
session: 2026-09-24d
status:  GITHUB REPO + BROWSER VERSION.
         Repo layout: project at root, docs/ (all .md notes, .gdignore'd),
         .gitignore (never: eos_credentials.cfg, EOSG bin/, build/, _shots/),
         .github/workflows/web.yml (browser build -> GitHub Pages; untested
         until the first push), tools/run_tests.sh (isolated profiles),
         tools/build/export_web.sh (strips EOSG, no-threads web export).
         Browser: OS.has_feature("web") -> online rooms + CAD import off with
         a sentence; DejaVu symbol subset as font fallback (arrows etc. were
         missing in the browser); replay viewer "⏮/⏭" -> "◀/▶".
         F3 anywhere: fps / frame-time readout (for checking slow laptops).
verified: fresh clone -> export_web.sh OK; clone + EOSG bins ->
         tools/run_tests.sh quick 16/16; browser build loads, signs in, runs a
         match in headless Chromium (software GL, so no speed number).
open:    browser speed on a real Chromebook/low-end laptop (use F3);
         two-computer internet test; debug_net_client intermittent check.
```

```yaml
session: 2026-09-24c
status:  FINAL FOLDER Downloads\BIOBUZZ3D-final-2026-09-24\ = exe (SHA 2b10b383…,
         md5 a1adad52…) + 3 EOS DLLs + README + DELIVERY + CHANGES + project zip.
         Adds team credit (panda icon, 506 in #b86ff7, opens pandara.org) and
         the Online card text fix. Old BIOBUZZ3D-ui-fixes\BioBuzz3D.exe could not
         be replaced (Windows still had it open); the .new copy sits beside it.
```

```yaml
session: 2026-09-24b
status:  TEAM CAD REPLACES THE ROBOT LOOK (ours only; opponents stock).
         Garage "Line it up": 3-axis rotation + ±90 + reset; preview guides
         (18 in cube, FRONT·INTAKE arrow, BACK, LAUNCHER). Placement from the
         convex hull (exact floor contact at any angle). model_rot replaces
         model_yaw/model_up (migrated on load).
verified: debug_cad_robot OK + regression batch (see DELIVERY.txt)
build:   Downloads\BIOBUZZ3D-ui-fixes\BioBuzz3D.exe (SHA f0cef7c4…)
notes:   collision stays the 18 in cube; the CAD is visual only. Held
         elements (hopper) still drawn where the stock hopper is.
```

```yaml
session: 2026-09-24
status:  STL import fixed. Julian's "Intake + Transfer.stl" was 512 MB /
         10.2 M triangles (refused by the 48 MB / 400k limit, message was in
         the small print). Made him a 261k-tri copy with vertex clustering
         (numpy, on his machine): Downloads\Intake + Transfer (for BIOBUZZ).stl
fixed:   inside-out STL winding; Z-up STL lying down (new up-axis option);
         ASCII tabs; zero normals; cache; clear red refusal with export advice
verified: debug_cad_stl OK, menus/roster/editor/drive/smoke/ui_repairs/shot_all
build:   Downloads\BIOBUZZ3D-ui-fixes\BioBuzz3D.exe replaced (SHA 3286485d…)
```

```yaml
session: 2026-09-23c
status:  UI REPAIRS MERGED (from Julian's Codex handoff) + EOSG PLUGIN IN THE
         PROJECT. REAL EOS WORKS ON JULIAN'S PC: anonymous login + lobby +
         invite + end session, NAT moderate. No two-computer internet test yet.
builds:  Downloads\BIOBUZZ3D-ui-fixes\BioBuzz3D.exe SHA bfebcb08… — see DELIVERY.txt (exe + 3 DLLs)
did:
  - merged ui.gd (inset hollow focus, embolden weight), scenario_editor.gd
    (viewport coords for field input, fit camera between panels),
    main.gd (Esc returns from scenario test in any phase), robot_preview.gd
    (render at display density); project: allow_hidpi, scaling_3d/scale=1.0
  - addons/epic-online-services-godot (2.3.1 prebuilt: windows + linux bins),
    autoloads + editor_plugins, eos_credentials.cfg (Julian's product)
  - tests: debug_ui_repairs (new), 2proc EOS check, fake_eos replaces real
    autoloads, debug_net_client waits on events
verified: see DELIVERY.txt (all runs with XDG_DATA_HOME isolation)
open:
  - debug_net_client "host killed right after Lobby->Start: new run kept"
    intermittent; pre-existing (fails on pre-merge code in a clean profile).
    Guest never received a chunk for the new run within 17 s. Investigate
    host recorder begin/sink after LOBBY->START.
  - Online card text still says "share a code" (should say invite)
  - macOS: plugin zip has no macOS binaries -> mac builds are LAN/offline only
next: two-computer internet test (ONLINE.md), then the open items above
```

```yaml
session: 2026-09-23
status:  PLAYER-HOSTED ROOMS (no server) — implemented + tested locally and
         against a SIMULATED EOS. Real EOS never run; NO INTERNET TEST YET.
         Supersedes 2026-09-22b (broker/room servers/deploy removed).
engine:  Godot 4.5.stable.official.876b29033, Jolt, 180 Hz
builds:  exe    fb895476…968bc9fb (97,877,784 B)
         x86_64 1e5d2540…4fc98dc5 (71,542,824 B)
         both WITHOUT the EOSG plugin (not downloadable here) -> internet
         hosting says "needs EOSG"; same-network rooms work
did:
  - host's game = authoritative room (NetRoomServer child of NetClient),
    host plays over an in-process LOOP link; guests over EOSGMultiplayerPeer
    (EOS P2P, relay fallback) or ENet (same network)
  - discovery = EOS lobby directory entry looked up by id from the invite;
    admission = 26-char invite secret checked by the host (constant time)
  - invite BBZ1-E.<lobby>.<host puid>.<secret> / BBZ1-L.<addr:port>.<secret>
  - NetEOS: run-time-only EOSG access (build works without the plugin),
    persistent anonymous Device-ID login, relay mode, NAT type, EOSG
    autoloads forced PROCESS_MODE_ALWAYS (world pause must not stop EOS)
  - NetLink: 1164-byte datagram cap + fragmentation on every backend
  - host leaving / host gone past 60 s grace -> session ends, replays kept
  - Low upload (snap every 6 ticks) host toggle
  - REAL EOSG 2.3.1 FOUND A CONFLICT: eos.gd has inner `class UI`, which
    collides with our autoload `UI` ("Class UI hides an autoload singleton")
    -> every EOSG autoload failed to compile. Autoload renamed UI -> Gui
    (1505 refs). Verified with the real plugin (Linux .so from Julian's
    prebuilt zip) on 4.5: tools/eos_real_probe (tools/eos_real_probe.tscn; needs the plugin)
    48 API checks ok, dummy creds fail cleanly ("Failed to create EOS
    Platform"), 2proc 29/29 and menus with the plugin enabled.
  - Julian's editor is Godot 4.7.2 (project converted to "4.7" on open)
  - this pass: default room name follows player name; host sees
    "You ended the session." in its own words (lobby AND HUD buttons)
verified (all local, Linux, one machine):
  - debug_net_link 18, debug_net_smoke 9, debug_net_client 28,
    debug_net 75 + 6, debug_net_2proc 28 (5 consecutive runs) then 29,
    debug_net_eos_sim 16 (simulated EOS, two programs)
  - perf_net: host headless ≈ 68 % of one 2.1 GHz core full room, ~200 MB,
    ≈ 60 KB/s upload per guest (≈ 479 KB/s full room); idle 8 %
  - offline suite 36/36 exit 0, debug_replay write+read, menus after edit
  - exported Linux binary boots --host-test and writes an invite
  - demo_online film + 16 stills rendered (software GL)
NOT verified:
  - real EOS SDK / EOSG plugin never loaded (api.epicgames.dev + GitHub
    release downloads blocked from this workspace)
  - any internet connection, direct or relayed; Windows<->Windows
  - shot_all not rerun this pass
tokens:  ≈ 420 k across the last context window of this pass (earlier
         window not measured); handoff = this block + 3y + ONLINE.md
next:
  1. Julian: Epic portal setup + plugin + eos_credentials.cfg (ONLINE.md)
  2. internet test: Never relay / Always relay / Automatic (ONLINE.md)
  3. fix whatever real EOSG differs on (NetEOS is the only file touching it)
  4. later: host migration (deliberately not done)
```

```yaml
session: 2026-09-22b
status:  PRIVATE ONLINE PRACTICE ROOMS — implemented + tested locally.
         NOT DEPLOYED. NOT TESTED OVER THE INTERNET. play.pandara.org does
         not exist; the client's default server points at it.
engine:  Godot 4.5.stable.official.876b29033, Jolt, 180 Hz
builds:  exe  c5ab5d4a…edad2760 (97,846,768 B)
         x86_64 a15d548d…a065f (71,511,808 B) = server (+ Linux client)
did:
  - scripts/net/* (see 3x), boot.tscn front door, deploy/*, ONLINE.md
  - UI: Play card, Online screen (errors at the top), lobby (everyone's ping),
    HUD (ping/loss, away, in menu, let go), results / retry / pause cards
  - fixes this pass: --load-report was eating the next option; masked-input
    counter had driver/operator swapped (counter only); join rate limit
    would have blocked a school behind one NAT (now 40 joins/min, 8 WRONG
    codes/min); standard setups now start opponents as AI (was all human,
    which blocked Start with empty robots); release builds reported 0 MB
verified:
  - debug_net 69 + 6, debug_net_client 28, debug_net_smoke 8,
    debug_net_2proc 4 (editor AND exported release binary, 4 processes)
  - perf_net: 8 players full 2v2 split; room ≈ 80 % of a 2.8 GHz vCPU,
    190 MB; 470 KB/s out; idle lobby room 9 % / 190 MB; responsiveness
    table under simulated RTT 0–200 ms / loss 0–10 % in ONLINE.md
  - exported server via deploy/run-server.sh + 8 remote-mode bots (loopback)
  - offline: 36 runs (debug_opponent flaked once in batch, passed twice
    after), debug_replay 163 + 12, shot_all 3 resolutions
  - demo_online: rendered film (real time, ~4 fps software render) + 15 stills
NOT verified / limits:
  - no deployment; no two-connection internet test (ONLINE.md Outstanding)
  - Dockerfile never built (Docker Hub blocked here)
  - Windows client never run against a server (Linux<->Linux only)
  - no client prediction by design: input-to-screen ≈ offline + 80 ms on
    loopback, + ~185 ms at 100 ms RTT
  - ENet traffic unencrypted; no accounts; codes are the only secret
  - owner leaving closes the room (no hand-over)
tokens:  ≈ 280 k in the final context window of this pass (the earlier
         window was not measured); handoff = this block + 3x + ONLINE.md
next:
  1. rent a small x86-64 VPS (2 vCPU / 2 GB), deploy (ONLINE.md), DNS A
     record play.pandara.org, open UDP 7350 + 7400-7415
  2. two-connection test from ONLINE.md Outstanding; perf_net -- remote
  3. only then call it "deployed and tested over the internet"
```

```yaml
session: 2026-09-22a
status:  REPLAYS + "PRACTISE FROM HERE" + UNLIMITED LOCAL COLLECTION.
         Every run recorded as state; read-only viewer; any whole-second
         checkpoint becomes a Free-practice situation; Progress -> Replays.
engine:  Godot 4.5.stable.official.876b29033, Forward+, Jolt, 180 Hz, CCD on
did:
  - replay_format/store/recorder/reader/viewer/timeline/branch/library (new)
  - hooks: BB.viewing, mm.started/aborted, stats.shot_made, capture seed,
    CameraRig.OVERVIEW, SFX.stop_all_loops, Hud.notice, Watch replay buttons
  - fixes found on the way: stats._on_tip missing-meta error; typed-Nil in
    stats for untracked robots; Snapshot.capture freed-owner guard
  - REPLAYS.md (player guide + format + measured costs + limits)
verified:
  - debug_replay 163 write + 12 cold-start checks, 0 failures
  - 36 existing harness runs on final code; debug_opponents write failed
    once on a 1 s WALL-CLOCK wait (starved ticks), fixed to sim time, both
    phases then pass. shot_all 3 resolutions, 0 failures.
  - perf_replay: 46 us/tick recorder share (4 robots), worst tick ~2.1 ms;
    1.04-1.09 MB/min (4 robots), 0.57 MB/min over 20 min (2 robots);
    memory +0.01 MB from minute 5 to 20; 2000-replay library, 0 decodes
  - rendered workflow film + 13 stills (demo_replay)
NOT verified / limits:
  - branching snaps to 1 s checkpoints; no sub-second branching
  - viewer draws CURRENT Garage model (recorded profile name shown)
  - wheel spin / rollers not recorded (pose, turret, hood, hopper are)
  - performance only on the 2-core Xeon container, headless; not on a GPU PC
  - two game instances share the folder SETTING file (each caches it at
    start; last writer wins for the next launch)
  - still no physical controller has ever been connected

session: 2026-09-21c
status:  CONFIGURABLE PRACTICE OPPONENTS. Stationary / Follow a route /
         Defend an area / Collect and score, in the Scenario Creator, saved
         and retried mid-behavior, four new starter drills.
engine:  Godot 4.5.stable.official.876b29033, Forward+, Jolt, 180 Hz, CCD on
did:
  - OpponentConfig (new), OpponentOverlay (new); AIDriver extended.
  - Scenario Creator: Opponent behavior section with per-setting validation,
    waypoint and area placement, numeric editing, Test scenario.
  - Snapshots store config + runtime state; retry restores it.
  - Practice signature includes opponent config (only when configured).
  - Settings -> Camera & display -> Opponent overlay (default off).
  - 4 starter drills: around a parked robot, crossing traffic, guarded
    target, competing for pollen.
verified:
  - debug_opponents 66 checks + 3 cold-start, all on the real field
  - four rendered gameplay clips; three drills completed by a scripted driver
NOT verified / limits:
  - defender NOT checked against pinning/contact rules (not modelled)
  - defender positioning is goalkeeping; it does not predict
  - Collect targets POLLEN only and scores only by shooting
  - routes are straight legs + HIVE routing, not path-planned
  - no human has driven against any of these
  - still no physical controller has ever been connected

session: 2026-09-21b
status:  CONTROLLER SETUP, TUNING AND PROFILES. Input only - no drivetrain,
         scoring, AI or autonomous changes.
engine:  Godot 4.5.stable.official.876b29033, Forward+, Jolt, 180 Hz, CCD on
did:
  - ControlProfile (new): named bindings + tuning, own JSON file, validated.
  - DriverInput rewritten: continuous radial deadzone on the driving stick as
    a VECTOR, separate turn axis, response curves, inversion, precision scale,
    neutral gating, ambiguity detection.
  - turn_sens migrated once into a turn curve and then never read again.
  - Settings: seat_profiles, device_lost signal, note_live_seats/push_profiles.
  - main: disconnect pauses and names the seat; Test drive from Controls.
  - settings_menu: Controls rebuilt as Seats/Feel/Buttons/Profiles with a live
    input preview, Identify, conflict Replace/Cancel, profile management.
verified:
  - 24 harness runs, 0 failures
  - debug_input 90 checks + 6 cold-start
  - debug_pause 72 checks (was 65): diagnostics live while the world is frozen
  - captures at 1280x720 / 1600x900 / 1920x1080
NOT verified:
  - NO PHYSICAL CONTROLLER HAS EVER BEEN CONNECTED TO THIS PROJECT.
    Everything above is the maths and the bookkeeping. Deadzone feel, stick
    drift, trigger curves, whether an Xbox and a PS pad read alike, and
    hot-unplug are ALL unverified. CONTROLLERS.md has the manual checklist.
known_defects_not_fixed:
  - no per-wheel speed cap modelled (diagonal == straight, 67.3 in/s)
  - performance not re-measured

session: 2026-09-21a
status:  FOLLOW-UP REVIEW FIXES. Autonomous recording/playback now pause with
         the world; the pause harness builds its own fixture and fails clean.
         No features added, no gameplay or drivetrain physics changed.
engine:  Godot 4.5.stable.official.876b29033, Forward+, Jolt, 180 Hz, CCD on
did:
  - PROCESS-MODE DEFAULT INVERTED. main.always_running() names what keeps
    running; _mark_process_modes() stops EVERYTHING ELSE under the root;
    _adopt() is the one door for runtime-created simulation nodes.
  - auto_player._physics_process also returns on BB.halted.
  - _guided_record count-in and recording_left use create_timer(t, false).
  - Snapshot.restore() adopts restored elements (FOUND BY THE NEW GUARD).
  - debug_pause authors its own fixture and _bail()s with exit 1 on bad setup.
  - Attempt.place_area(): no global transform on a detached node.
verified:
  - 23 harness runs, 0 failures
  - debug_pause 65 assertions (was 30); 10 failures on reverted wiring -> 0
  - the bail path: empty-field fixture -> exit 1, clean message, no nulls
  - only engine errors in the whole suite are the DELIBERATE malformed-JSON
    snapshot tests in debug_situations
known_defects_not_fixed:
  - NO PER-WHEEL SPEED CAP modelled (diagonal == straight, 67.3 in/s).
    Normalised mecanum predicts 0.707x. Next physics task, WITH measurements.
  - no gamepad has ever been connected to any build of this project
  - performance not re-measured here; reviewer's sample moved 295.6 -> 257.3
    FPS between runs, which is two single samples and establishes nothing.
    tools/perf_sample.tscn is theirs, kept verbatim, for a controlled A/B.
next_milestone (reviewer's, in order):
  1. real controller session
  2. 2-3 teammates on the starter drills, uncoached
  3. measure one real robot; calibrate a profile; THEN decide physics changes

session: 2026-09-20i
status:  INDEPENDENT REVIEW FIXES. Three reproduced defects fixed, one false
         diagnosis withdrawn, review probes converted to regressions.
         No features added.
engine:  Godot 4.5.stable.official.876b29033, Forward+, Jolt, 180 Hz, CCD on
did:
  - PAUSE NOW HALTS THE SCENE TREE (BB.halt/menu_halt/refresh_halt). Every
    menu route pauses, including goto() from the nav bar, which did not.
  - BB.sim_time / sim_now(): gameplay timers are off the wall clock, so a
    shot window or an aim hold cannot expire behind a menu.
  - Attempt runs on _physics_process; deadline rule is now
    "a tick counts if the clock at its END is at or before the limit".
  - final scoring uses the FINAL score, never latched provisional progress.
  - debug_drive.gd rewritten: bare floor, contact-monitored, fails if anything
    touches the robot; all four diagonals, both spins, 37 assertions.
    Obstacle behaviour is a SEPARATE test.
  - objective_hud measures the scoreboard instead of assuming its height.
  - shot_all declares profile state and occlusion-checks every capture.
  - NEW tools/debug_pause.tscn (30 checks), tools/perf_sample.tscn (reviewer's).
verified:
  - 23 harness runs, 0 failures, after the changes
  - debug_pause     16 failures before the fix -> 0 after
  - debug_objectives 9 failures on a reverted copy -> 0 here (102 + 7 checks)
  - shot_all at 1280x720 / 1600x900 / 1920x1080, plus a -- fresh pass
known_defects_not_fixed:
  - NO PER-WHEEL SPEED CAP is modelled, so a diagonal runs as fast as a
    straight line. Normalised mecanum predicts 0.707x (48.1 in/s at 68).
    Reported by debug_drive, deliberately NOT asserted. Next physics task.
  - no gamepad has ever been connected to any build of this project
  - performance not re-measured after the process-mode changes
retracted:
  - "diagonal driving is wrong, 27 in/s with 7 deg of yaw" - that was a
    collision with HiveFrame inside the measurement window. See 3s.

session: 2026-09-20h
status:  REVIEW BUILD SHIPPED. Objective outcomes corrected, the practice
         workflow walked and fixed, an honest assessment written, a Windows
         binary exported. No features added beyond the four workflow fixes.
engine:  Godot 4.5.stable.official.876b29033, Forward+, Jolt, 180 Hz, CCD on
did:
  - Attempt._evaluate() rewritten: progress and constraints are measured
    together and one result is committed. A foul on the completing step now
    FAILS. Deadline: the crossing step counts, everything after is LATCHED,
    and only CONFIRMATION of an already-eligible points total may cross it.
    New state: _eligible_since, _latched, airborne_at_start.
  - Objective.in_flight()/count_in_flight()/FLIGHT_RULE_SHOTS/FLIGHT_RULE_POINTS.
    Quoted in metric_note(), in Snapshot.check_draft()'s editor warning, and on
    the results screen. Velocity-only test; height was wrong (FLOWERS).
  - main._open_pause_menu() now pauses. REAL BUG: only the Esc path did, so
    every other route to the pause menu left the match live behind it.
  - menu.gd: practice card moved above Match setup, renamed "Practice drills",
    names the shelf. New Controls card on the pause menu (_refresh_controls).
  - ui.gd shell() gained foot_alt; attempt_results uses it for the way out.
  - tools/debug_workflow.tscn - NEW, two processes, 66 checks total.
verified:
  - debug_objectives   86 checks + 7 cold-start   0 failures
  - debug_workflow     61 checks + 5 cold-start   0 failures
  - 19 other harnesses re-run end to end          0 failures
    (smoke_match, stress_test jitter 0.05 in/s, debug_drive, debug_shooting
     19/20 = 95%, debug_ride, debug_hive, debug_rules, debug_roster,
     debug_opponent, debug_coop, debug_report, debug_human, debug_turret,
     debug_power, debug_blue, debug_leaderboard, debug_audio, debug_editor,
     debug_menus, debug_situations x2)
  - shot_all at 1280x720, 1600x900, 1920x1080: EVERY SCREEN FITS, focus chain
    21 stops, Start reachable
  - the EXPORTED Linux build boots clean under xvfb (proxy for the .exe, which
    has not been run on Windows here)
known_defects_not_fixed:
  - DIAGONAL DRIVING IS WRONG: 27.2 in/s with -6.7 deg yaw and 21.6 N slip
    where it should be ~48 in/s with none. Straight and strafe are correct.
    This is the top of the next session's list.
  - no gamepad has ever been connected to any build of this project
  - no frame rate measured on real hardware
open_questions:
  - element masses are FITTED to reproduce the S12.3 tip table, not weighed.
    Weighing one POLLEN and one NECTAR replaces the one tuned number the whole
    tipping model rests on.

session: 2026-09-20g
status:  PRACTICE OBJECTIVES, ATTEMPT RESULTS AND PERSONAL BESTS.
         Built on the existing snapshot, library, editor and test/return work;
         ordinary matches are untouched.
added:
  - scripts/objective.gd (Objective). ONE goal plus at most two constraints —
    deliberately not a scripting language. Kinds: POINTS, TIPS, SHOTS, REACH.
    Constraints: a time limit, and no new foul. describe() writes the sentence
    ("Make 8 successful shots within 30 seconds without a foul, as robot 1").
    TARGETS ARE LIMITED TO WHAT CAN HONESTLY BE MEASURED: points and tips are
    alliance-level (a tip is caused by the mass in a CELL and the game cannot
    say whose ball did it, so crediting the last launcher would be a guess);
    shots can be per robot because the launcher IS attributed; reach is one
    robot. targets_for() enforces it and the validator explains it.
  - scripts/attempt.gd (Attempt). Ready -> Running -> Succeeded / Failed /
    Abandoned. The clock only advances while the match is genuinely being
    played — not paused, not frozen, not in a menu or the editor. EVERY
    MEASUREMENT IS A DELTA FROM A BASELINE taken at begin(), so a situation
    that already has 100 points, three old tips and a ball sitting in a CELL
    starts every objective at zero. finish() is guarded: repeated events,
    reopening results and restoring snapshots cannot finish it twice.
  - scripts/attempt_log.gd (AttemptLog). user://attempts.json, atomic writes,
    SEPARATE from the match history and the leaderboard. signature() hashes
    everything that changes the difficulty — objective, starting field, roster,
    profile, clock, BB.RULES_REV — and deliberately NOT the name or the
    description, so renaming keeps the history. best() is the fastest
    SUCCESSFUL attempt only. Success rate is successes over EVERY attempt,
    abandoned ones included, so restarting a bad run cannot look perfect.
    compare_line() is built only from recorded numbers.
  - scripts/objective_hud.gd: the compact practice card — objective, progress,
    clock, constraints, attempt number, device-appropriate retry/menu hints.
    Separate from the match scoreboard. Status always carries a MARK as well
    as a colour.
  - scripts/attempt_results.gd: verdict, objective and progress, time against
    your best, successful shots / total, final points, new fouls, and the
    group's attempt / completion / success-rate counts. Retry, Edit scenario,
    Back to library, and Return to editor when it was a draft test.
  - scripts/starter_drills.gd: four drills written through the ordinary
    library with ordinary editor operations, so they duplicate and edit like
    anything else. Collect and shoot; twenty points in forty-five seconds;
    recover from the corner to a target area; the final twenty seconds with
    one AI opponent. No defender or stationary profile is advertised, because
    neither exists.
  - BB.RULES_REV, recorded on every attempt.
  - tools/debug_objectives.tscn, two processes: 42 checks then 7 after a cold
    start.
decisions_worth_keeping:
  - [SUPERSEDED BY SESSION 2026-09-20h - DO NOT REINSTATE] SIMULTANEITY IS
    RESOLVED IN A FIXED ORDER: progress, then success, then the no-foul
    constraint, then the time limit. An objective reached on the same
    simulation step as a foul or as the clock expiring is a SUCCESS.
    -> Owner overruled this. A foul on the completing step now FAILS. See
       section 3r.
  - POINTS ARE PROVISIONAL WHILE THE MATCH RUNS. The live scoreboard can go
    DOWN — a ball rolls out of a GARDEN — so a points goal has to hold for
    BB.SETTLE_S before it counts, and the HUD says "provisional, settling"
    while it does. If the match ends first, the FINAL breakdown decides.
  - "Successful shot" is the existing verified metric: a ball you launched
    that entered a CELL within MatchStats.MADE_WINDOW. It is labelled that
    way everywhere and never confused with points at the end of the match.
  - a reach area is the robot's ground-plane centre inside the circle for
    0.75 s, stated in the editor, and explicitly NOT official PARK scoring.
  - there is no independent starting-score field. Historical events (tips,
    fouls) are editable as data; everything else is derived from the field, so
    there is no second number to contradict it.
gotchas_found:
  - RESET_TO ON A GHOST TAKES THE ENGINE DOWN. Robot.reset_to() called
    e.release() on freed hopper entries: not a script error, a hard abort with
    a C++ backtrace. stage() now clears hoppers BEFORE freeing the balls, and
    reset_to() checks validity. Found by the new startup path that stages the
    field once to build the drills.
  - the properties column is 380 px wide and a label plus a three-button
    segmented row is wider than that, so it overflowed the panel. _row() now
    measures the control and stacks it under its label when it is too wide.
  - the attempt results screen was under the editor (layer 31 vs 32). It is
    34 now: an attempt can finish while the creator is open.
verified (49 checks across two processes, tools/debug_objectives.tscn):
  - three old tips count for nothing and the goal is the NEW two; loading
    emits no progress and no elapsed time; a ball already in a CELL is not a
    new made shot; pausing does not consume objective time and the clock runs
    again on resume.
  - [SUPERSEDED] success wins a tie with a foul AND a timeout on the same
    step. The assertion is INVERTED as of 2026-09-20h. The "finishes exactly
    once, later events cannot write a second record" half still holds.
  - a points goal does not succeed the instant it is crossed, says so while it
    settles, then counts; a goal only the FINAL score reaches is decided at
    match end on the final breakdown, and the record carries final points.
  - retry starts exactly one new attempt and records the old one as ABANDONED,
    not as a success; a faster failed or abandoned attempt never takes the
    record; abandoned attempts stay in the count so the rate cannot read 100%.
  - renaming keeps the comparison group; the clock, the robot's position, the
    objective and the battery each split it.
  - a scenario with no objective is free practice, still validates, and
    describes itself honestly.
  - the four drills are on the shelf with real objectives, measured for the
    alliance where attribution requires it.
  - after a real restart: history reads back, the group and the personal best
    survive, the rules revision travels with them, nothing reached the match
    history or the leaderboard, and editor tests are flagged apart.
  - shot_all: 29 screens bounds-checked at 1280x720, 1600x900 and 1920x1080,
    0 failures at all three, including the practice HUD over a live match, the
    editor's Objective section and the attempt results screen.
  - gameplay untouched: smoke_match, debug_roster, stress_test, debug_solid,
    debug_menus, debug_editor, debug_coop, debug_report, debug_opponent,
    debug_yaw, debug_power, debug_rules and the situations test all 0.
limitations_stated:
  - tip objectives are alliance-level only, by design, because per-robot
    attribution is not reliable.
  - objective progress for POINTS is provisional while driving; the HUD says
    so rather than pretending otherwise.
  - the practice HUD and results screen are controller-navigable; PLACING and
    DRAGGING in the editor remain mouse and keyboard.
  - no coach: the comparison line is one factual sentence from recorded data.
  - still not built: replay + free camera (9), first-run tutorial (11).

```yaml
session: 2026-09-20f
status:  IN-GAME VISUAL SCENARIO CREATOR. ARRANGE -> TEST -> BACK -> SAVE.
         Built ON the existing saved-situation system: same versioned format,
         same capture, same restore, same library, same atomic writes.
added:
  - scripts/scenario_draft.gd (ScenarioDraft). THE MODEL. Wraps a snapshot and
    owns every mutation: add/remove/duplicate elements and robots, move,
    rotate, hopper in/out, per-object properties, scenario-wide settings.
    UNDO IS A STACK OF WHOLE SNAPSHOTS (cap 60) — a situation is ~12 KB and a
    full copy cannot half-apply the way a hand-written inverse can.
    Positions are FIELD INCHES throughout; metres only at the snapshot edge.
    Starts: staged() (a real match start), empty_field() (walls, HIVEs,
    FLOWERs and one player robot kept, every loose ball gone), from_snapshot().
  - scripts/scenario_editor.gd (ScenarioEditor). THE SCREEN. Edits the REAL
    field with the game paused rather than a diagram of it. Field centre,
    palette left, properties right, name/view/undo/redo top, validation +
    Save / Test / Back bottom, collapsible controls panel. Top-down and angled
    views, wheel zoom, right/middle-drag pan, 2 in grid snap, selection ring,
    placement ghost, numeric position and heading entry.
  - Snapshot.check_draft(): the validator, ERROR vs WARNING. Errors (block
    save and test): duplicate ids, a hopper pointing at a ball that is not
    there, one ball in two hoppers, a carried ball that does not say so,
    NECTAR in a POLLEN-only intake, no robot to drive, roster over the limit,
    a battery or intake count the game cannot build, a negative or impossible
    clock, a pending feed referring to a missing ball. Warnings (never block):
    a ball outside the walls, below the tiles, a phase that disagrees with the
    mode. Every problem carries the id of the object it belongs to, and the
    properties panel prints it beside that object.
  - Snapshot.restore(..., for_editing) leaves the whole field FROZEN where it
    was placed and hands nothing back: velocities stay in the DRAFT untouched.
  - BB.editing + BB.frozen(): one test every reactive system asks. All the
    guards that used to read `restoring` now read `frozen()`.
  - tools/debug_editor.tscn: 41 checks over the whole acceptance list.
changed:
  - the library gained Create a scenario (standard staged field / empty
    practice field), and per row Edit and Duplicate & edit.
  - the pause menu and the results screen offer Return to editor while a draft
    is under test.
  - main.goto("Play") now sets menu.match_running from mm.in_progress(), so
    Play's face always follows the actual match state.
test_and_return:
  - Test validates, takes an IMMUTABLE COPY of the draft, and runs it as an
    ordinary situation attempt. Retry restores the TEST's own starting state.
    Return to editor brings the draft back byte-for-byte; the harness compares
    JSON before and after and it is identical. Testing never writes the saved
    file and never replaces the draft with the played-out field. Test attempts
    stay out of the leaderboard and the match history, like every other
    situation attempt.
gotchas_found:
  - THE EDITOR POSES THE MATCH MANAGER. Restoring a draft sets mm.phase and
    the clock so the field reads right — and leaving the editor without
    aborting convinced Play a match was running, so it opened the pause menu
    over a field with nothing on it. Caught by the focus-chain check in
    shot_all, which walked 200 stops of pause-menu buttons and never reached
    Start.
  - the see-through hole that forwards clicks to the field has to be added
    BEFORE the panels, or it sits on top of them and eats their clicks.
  - the 3D camera fills the whole viewport but the panels cover its edges, so
    centring on the field centres it behind the palette. _fit_view() works out
    the distance that puts all 144 inches inside the visible strip and slides
    the focus by however much the two panels are out of balance.
  - UI.help() was removed in the menu redesign; the editor still called it.
    Replaced with UI.disclosure(), which returns [button, box].
verified (41/41, tools/debug_editor.tscn):
  - the editor opens on a staged field with the world frozen; a ball can be
    placed (at rest) and removed; the robot moves and turns to a typed
    heading; the hopper holds what was put in it and a carried ball is not
    also loose; NECTAR is refused by a pollen-only intake until the intake is
    changed; the battery sets; an opponent can be added and the roster shape
    follows; 20 seconds on the clock is what comes back; undo and redo work
    across placement, deletion and property changes; the scenario saves and
    reads back clean with the roster it was saved with.
  - test -> drive somewhere else -> Retry restores the test's own pose ->
    Return to editor with the draft IDENTICAL and no match history written.
  - opening a saved MOVING situation keeps its airborne ball moving, does not
    advance the clock, and moving a DIFFERENT ball leaves it alone; moving the
    flyer itself stops it, which is the stop-motion default.
  - every validation case above, and nonsense data refused politely.
  - shot_all: 26 screens bounds-checked at 1280x720, 1600x900 and 1920x1080,
    0 failures at all three, including the editor, the selected-robot
    properties, a selected ball, the controls panel, the test pause menu and
    the returned editor. Focus chain 21 stops, Start reachable.
  - gameplay untouched: smoke_match, debug_roster, stress_test, debug_solid,
    debug_menus, debug_coop, debug_report, debug_opponent and the two-process
    situations test all 0 failures.
limitations_stated:
  - PRECISE FIELD MANIPULATION IS MOUSE AND KEYBOARD. Every panel, button and
    field is reachable with a controller or Tab, and every position and
    heading can be typed as a number, but there is no controller gizmo for
    dragging objects yet.
  - walls, HIVEs and FLOWERs stay where the manual puts them by design. The
    HIVE panel exposes its latch state and tip count; setting the tilt
    visually is not in this pass.
  - opponents use the existing AI driver. There is no "Stationary" behaviour
    yet and no picker pretending there is.
  - historical score (tips, fouls) is editable as data; everything else on the
    scoreboard is derived from what is on the field, so there is no second
    number to contradict it.
  - no replay timeline, no sharing service, no objective system, no AI rewrite
    — out of scope for this pass by request.

```yaml
session: 2026-09-20e
status:  SAVED PRACTICE SITUATIONS + INSTANT RETRY. THE WHOLE LOOP WORKS.
loop:    play -> F5 (or the pause menu) -> name it -> library -> "Play from
         here" -> F6 retries the ORIGINAL instant, as many times as you like.
added:
  - scripts/snapshot.gd (class Snapshot). THE FORMAT. version 1, format tag
    "biobuzz.situation". Captures: match phase, clock, settle timer, endgame /
    flower-unlock latches, the event log, the full scoreboard, fouls, per-robot
    G407 bookkeeping, the human players' queue and pool; every robot's pose,
    velocity, turret yaw, hood, launcher speed, battery (loaded AND open
    circuit), field-centric / auto-aim / intake flags, turret faults, fire
    cooldown, manual-aim time REMAINING, and hopper contents by id; every
    element's kind, alliance, transform, both velocities, holder and launcher;
    every hive's swing transform, both velocities, latch sign, armed flag, tip
    count and gate; the AI's mode, target, and all four of its timers; the auto
    routine and how far through it was.
    RULES THE FORMAT FOLLOWS (the field editor will read this later):
      * stable ids — elements e0001.., robots by roster index. Hopper contents,
        AI targets and the human queue are stored as ids and resolved after the
        objects exist.
      * TIME REMAINING, never a deadline. manual_until is stored as "how much
        longer", because the absolute value is measured from process start.
      * transforms are flat float arrays: readable, diffable, hand-editable.
      * INPUT DEVICES ARE NOT STORED. The roster SHAPE is; seats are handed out
        by the normal allocation from whatever is plugged in now, so a file
        saved on a two-pad machine cannot silently give robot 2 a pad that is
        not there.
      * rng: Godot does not expose the global generator's state, so the file
        carries a SEED that restore re-applies. Every retry of one situation
        therefore draws the same human placements as the last retry.
  - scripts/scenario_library.gd: one JSON file per situation under
    user://situations/. Writes are atomic (tmp -> parse-check -> swap), so an
    interrupted save leaves the previous file intact. Unreadable files are
    LISTED with their problem rather than hidden.
  - scripts/scenario_screen.gd: the library, in the shared theme. Name,
    description, phase, time left, robots, alliance, element count, saved date;
    Play from here / Rename (inline) / Duplicate / Delete (confirmed); honest
    empty state that explains what a situation is and how to make one.
  - Play has three faces now: SETUP, PAUSED (the pause menu: save, retry, end,
    library) and NAMING (name + description, Save as new / Overwrite / Cancel).
  - save_situation (F5) and retry_scenario (F6), both rebindable in
    Settings > Controls > Session. `pause` also picked up JOY_BUTTON_START so a
    controller can reach the pause menu at all — the controller route to save
    and retry is that menu, since every pad button was already taken.
  - MatchManager.save_state/apply_state, Scoring.save_state/apply_state,
    Robot.save_state/apply_state/clear_inputs/adopt/release_from_restore,
    Hive.save_state/apply_state/release_from_restore,
    AIDriver.save_state/apply_state, DriverInput.forget().
  - BB.restoring: the one flag the reactive systems check. Guarded: element
    physics (settle / wall check / impact sound), hive physics and cell entry,
    robot physics (the intake would grab whatever was placed next to it),
    stats, the AI, the auto player and main's auto-targeting.
  - tools/debug_situations.tscn: TWO PROCESSES on purpose — `-- write` builds
    an awkward field and saves it, `-- read` is a cold start that finds the
    file and restores it. 27 checks.
changed:
  - Settings.allocate_devices() replaces device_for_seat(): the WHOLE roster is
    allocated at once, in two passes (pins first, in seat order; then
    everything else). A pin to an unplugged pad falls back; a pin to a pad an
    earlier seat already has leaves that seat DEAD and says so, rather than
    silently giving two people one controller.
  - situation attempts never reach the leaderboard or the match history.
  - goto("Play") with a match paused shows the PAUSE MENU rather than resuming
    behind the player's back.
gotchas_found:
  - FREEZE THE WORLD OR THE RESTORE IS A LIE. BB.restoring stops SCRIPTS, not
    the physics server. Two settling frames of gravity moved the robot 2.4 in
    off its saved pose, landed the airborne ball and killed the hive's swing.
    Fix: every body is placed FROZEN and the motion is handed back in one pass
    on the frame play resumes. Drift went from 0.06 m to 0.0000.
  - mm.abort() clears `paused`, so pausing BEFORE calling it does nothing and
    _pump_humans ran during the load, placing freed balls.
  - ARRAYS ARE REFERENCES. MatchManager.forget_robots() called robots.clear()
    on an array that is the SAME OBJECT as main.robots, so the loop that frees
    the old robots then had nothing to iterate: every restart left the previous
    robots on the field, still driving and still intaking, fighting the new
    ones for the same ball. Caught by debug_roster's intake checks, NOT by
    anything in the situations tests.
  - an element owned by a freed robot is a ghost: `held_by is Robot` on a freed
    instance is an error that took the whole capture down. Robots now drop what
    they are carrying when the roster is rebuilt, and capture treats a ghost
    owner as nobody.
verified:
  - debug_situations 27/27 across a real process restart: the file survives;
    element count, roster, a PARTIALLY loaded hopper (2 of 4), robot pose and
    velocity, an airborne ball's velocity and a mid-swing hive all come back
    with 0.0000 error; the human player's feed keeps the delay it had LEFT;
    scoreboard, fouls and clock restore; loading raises no foul; no driver
    command survives the load; THREE retries leave the element count, the robot
    count, the starting score, the pose and the hopper unchanged; a finished
    attempt does not touch the match history; two seats cannot share one
    keyboard; a damaged file is reported and the rest of the shelf still lists;
    a newer format version is refused with a sentence.
  - shot_all: 21 screens bounds-checked at 1280x720, 1600x900 and 1920x1080 —
    0 failures at all three, including the library empty and stocked, the pause
    menu and the naming card. Focus chain 21 stops, Start reachable.
  - gameplay untouched: smoke_match 17/17, debug_roster, stress_test,
    debug_solid, debug_coop, debug_menus, debug_report, debug_opponent,
    debug_yaw, debug_power, debug_calibrate, debug_rules, debug_blue,
    debug_turret, debug_intake_bounds, debug_leaderboard — all 0 failures.
cannot_yet_restore_exactly:
  - CONTACT STATE. Jolt's accumulated contact manifolds are not in the file, so
    a ball balanced on a cell lip may fall the other way. The promise is the
    same STARTING CONDITIONS, not the same outcome.
  - the global RNG's internal state (Godot does not expose it) — a re-applied
    seed instead, which makes retries of one situation consistent with each
    other but not with the original run past the save point.
  - a recording in progress is not captured; saving during one keeps the
    routine but not the partial take.
  - MatchStats start at zero for each attempt, by choice: an attempt's numbers
    are the attempt's, not a continuation of the match it was cut from.
next:
  - never built: replay + free camera (9), first-run tutorial (11).
  - the situation format is ready for the visual field editor; it is NOT built.

```yaml
session: 2026-09-20d
status:  FULL MENU PASS DONE. PLAY, GARAGE, PROGRESS, SETTINGS BUILT TO THE
         SUPPLIED DESIGN REFERENCE AND WIRED TO THE REAL GAME SYSTEMS.
reference: biobuzz-design-reference/ (10 PNGs + REFERENCE-WEBSITE.html).
  exact tokens taken from the concept CSS and scaled 736px -> 1600x900:
    #101211 page, #191C19 panel, #222722 hover, #EEF1E9 ink, #AAB4A5 muted,
    #333B32 line, #FFD139 accent on #171B14 text. 12px panel / 8px control
    corners -> 14 / 10 here. body 14px -> 18px, h2 29 -> 38, h3 17 -> 22.
    grid minmax(0,1.35fr)/minmax(260px,1fr) kept: setup 57%, preview 43%.
  NOT copied: the 736px export wrapper, the outer margin, the CSS-art robot,
    the sample scores, "Layout concept - game actions are previews", the
    hardcoded "Controller connected", and the "Organize remaining bindings"
    developer note.
rewritten:
  - scripts/ui.gd          the design system. palette/scale/type + factories:
                           shell() (top nav, heading, scrolling body, footer),
                           panel/card/scroll_card, row/rows, options,
                           mode_card, fact, metric, status, key_chip, slider,
                           slider_row, dropdown, line_edit, table_head/row,
                           two_columns, make_scroll, sentence(), join_list().
                           8 button looks, each with normal/hover/pressed/
                           SELECTED/disabled/FOCUS. focus is an accent ring
                           drawn OUTSIDE the control (expand_margin 3); NAV and
                           OPTION selection is an accent underline, never a
                           yellow slab.
  - scripts/menu.gd        PLAY. modes + match setup left, live robot right,
                           footer holds the session line and Start. Start text
                           follows the mode ("Start practice" in free play).
  - scripts/robot_menu.gd  GARAGE. Hardware / Appearance / Autonomous beside a
                           persistent preview. real profiles, real CAD import,
                           real routine library (use / test / delete, with a
                           confirm), rename, calibration wizard behind
                           "Calibrate my robot".
  - scripts/settings_menu.gd SETTINGS. category list + bounded panel: Audio,
                           Camera & display, Graphics, Controls. Controls IS
                           the device-assignment flow now.
  - scripts/results_screen.gd, scripts/signin.gd, scripts/hud.gd retheme.
added:
  - scripts/progress_screen.gd  PROGRESS. three real metrics, recent matches
                           from RobotShop.history(), detail block with trends,
                           local leaderboard + share codes, clear-with-confirm.
  - scripts/robot_preview.gd    RobotPreview: lit SubViewport with its own
                           World3D, fading grid floor, soft contact shadow,
                           drag-to-orbit, auto-spin. Built by RobotBody, so an
                           imported CAD model and the alliance colour show up.
                           No physics body, no gameplay state.
  - Settings.seats + device_for_seat()/set_seat_device()/seat_plan(): a seat
                           can be pinned to a controller and it persists. a pin
                           to a device that is no longer plugged in falls back
                           instead of going dead.
  - MatchManager.pause()/resume()/in_progress(): ESC mid-match now PAUSES.
  - BB.DRIVE_SPEED_IN_S / TURN_RATE_DEG_S, RobotShop.top_speed_in_s() /
    turn_deg_s() / profile_name(): no screen hardcodes 68 and 460 any more —
    a MEASURED profile shows 48 in/s and 240 deg/s in the same strip.
  - main.goto(page, tab): ONE router for every nav pill, footer and deep link.
removed:
  - scripts/controls_screen.gd — folded into Settings > Controls, which is the
    same content with real per-seat device dropdowns. "Assign controllers" on
    Play deep-links straight to it.
gotchas_found:
  - GOING TO THE GARAGE MID-MATCH FREED THE ROBOT. goto() rebuilt the roster on
    leaving the Garage; with a match paused behind the menus that frees the
    robot the match, camera and stats all hold -> "previously freed instance"
    on every frame. Rebuild only when no match is in progress; mid-match the
    Garage's changes wait for the next start, which its footer already says.
    Found by tools/debug_menus, not by looking at screenshots.
  - a lambda whose `match` branch ends in `)` does not parse; use a method.
  - UI.body() autowraps, so a label in an HBox next to a spacer gets zero width
    and renders one letter per line. row labels need AUTOWRAP_OFF.
  - a ScrollContainer sizes its child to the child's MINIMUM height, so a
    column leaves a void unless every link in the chain has SIZE_EXPAND_FILL.
  - the scrollbar sits ON the content unless you leave it a gutter: scroll_card
    and shell() both add a 14px right margin inside the scroll.
verified:
  - tools/shot_all.tscn: 17 captures (Play x4 incl. the busy roster, Garage x5,
    Progress x2, Settings x4, results, sign-in), bounds-checked at 1280x720,
    1600x900 AND 1920x1080 -> EVERY SCREEN FITS, 0 failures at all three.
    NOTE: stretch is canvas_items+expand on a 1600x900 base, so all three
    window sizes lay out on the SAME 1600x900 canvas; the window only changes
    the pixel scale. Anything taller than the fold is inside a scroll region
    and the harness counts those separately rather than calling them clipped.
  - focus chain on Play: 20 stops, Start reachable without a mouse.
  - tools/debug_menus.tscn 15/15: pause keeps the match (clock, score, robots)
    across Settings and the Garage; a pinned seat gets its device; a pin to a
    missing controller falls back; the Garage's intake and collects reach the
    built robot; a slider is on disk immediately.
  - gameplay untouched: smoke_match 17/17, debug_roster, debug_solid,
    stress_test, debug_report, debug_opponent, debug_coop, debug_yaw,
    debug_power, debug_calibrate all 0 failures.
remaining_limitations:
  - the preview orbits with the mouse; there is no controller binding for it.
  - controller bindings are still fixed (by choice); only keyboard rebinds.
  - the leaderboard is local, shared by copy-paste code. no server.
next:
  - never built from the original list: replay + free camera (9), first-run
    tutorial (11).

```yaml
session: 2026-09-20c
status:  SHARED THEME + NEW PLAY SCREEN DONE. GARAGE/PROGRESS/SETTINGS NOT YET.
added:
  - scripts/ui.gd, autoloaded as UI: the one visual language. palette, scale,
    type ramp, and factories (card/vbox/hbox/divider/eyebrow/title/heading/body,
    button+select+tint, segmented, stat, status, help). every button carries
    normal/hover/pressed/SELECTED/disabled/FOCUS. focus is an accent ring drawn
    OUTSIDE the fill (expand_margin 3) so it never reads as "selected"; selected
    is a tight accent border plus accent label text.
  - tools/shot_play.tscn: renders Play in three states (default, busy roster,
    both help disclosures open), bounds-checks each, and walks the focus chain.
  - tools/shot_garage.tscn: renders Garage SPECS, bounds-checks it, and asserts
    the intake buttons write back to the Play screen.
changed:
  - scripts/menu.gd rewritten as the PLAY page. public API untouched (signals
    started/settings_changed/open_settings/open_robot/open_controls; vars mode,
    alliance, robot_intakes, takes_nectar, robots, mate_is_ai, per_robot,
    opponents; consts DRIVE_SPEED/TURN_RATE; build/open/close/is_open/
    seats_needed; _root and _open_board kept for tools/shot_fit.gd).
    layout: persistent header (Play/Garage/Progress/Settings) - scrollable two
    columns (left: mode + match setup; right: live robot preview + summary +
    controls) - persistent bottom bar (readiness dot + session summary + the
    yellow Start match). Start is OUTSIDE the scroll on purpose.
  - robot config moved OFF Play: intakes and pollen/nectar now live in the
    Garage SPECS page (robot_menu._page_layout + _pick_row), which reads and
    writes RobotMenu.play (set by main.gd before build). Play shows them
    read-only with two routes into the Garage, so nothing became unreachable.
  - the two walls of control text are behind UI.help() disclosures now.
  - main.gd: robot_menu.play = menu; closing the Garage rebuilds with
    menu.robot_intakes rather than robot.intakes, so an intake change applies.
gotchas_found:
  - a lambda with a `match` whose last branch ends in `)` does not parse:
    "Expected expression for match pattern". split it into a named method.
  - UI.body() autowraps by default. in an HBox next to a spacer_h() that means
    the label is handed zero width and renders ONE LETTER PER LINE. any label
    sitting in a row needs AUTOWRAP_OFF. cost one render to spot.
  - a ScrollContainer sizes its child to the child's MINIMUM height, so the
    right column left a 130 px void under the robot. cols/right/card/preview
    all need SIZE_EXPAND_FILL for the preview to grow into it.
verified:
  - tools/shot_fit.tscn at 1280x720, 1600x900 AND 1920x1080: EVERYTHING FITS
    (0 failures) at all three, including settings pages 0-3 and the controls
    screen. NOTE: stretch is canvas_items+expand on a 1600x900 base, so all
    three window sizes produce the SAME 1600x900 logical canvas - the window
    size only changes the pixel scale.
  - shot_play: help-open state still fully on screen; focus chain is 24 stops,
    mode -> setup -> right column -> START -> nav, START REACHABLE yes.
  - shot_garage: every control on screen, ONE INTAKE writes back to Play.
  - smoke_match 17/17 on the second run. FIRST run failed the tip (cell=6, one
    shot missed the mouth) - the tip threshold is genuinely marginal at 3 nectar
    + 3 pollen, so this harness is FLAKY at the boundary, not regressed. re-run
    before believing a tip failure.
next:
  - Garage, Progress and Settings pages in the same language (waiting on
    Julian's go-ahead after seeing the Play screenshots)
  - still never built: replay + free camera (9), first-run tutorial (11)

```yaml
session: 2026-09-20b
status:  THE PHASE-THROUGH WAS A DRAWING BUG. FIXED.
found:
  - collision was correct throughout: walls, corners, HIVE legs, FLOWERS and
    robot-versus-robot all stop the robot properly (worst penetration 0.11 in)
  - the robot was DRAWN up to 2.70 in outside its own collision box, so it
    stopped correctly and looked buried; two robots meeting overlapped by more
    than five inches of geometry
changed:
  - bumpers flush inside the 18 in footprint, rollers tucked in by their radius
  - collision back to a fixed chassis box; RobotShop.shapes deleted, so a stale
    saved entry can no longer break a robot's collision
added:
  - tools/debug_solid.tscn: rams everything, laps the perimeter, and asserts no
    mesh is drawn outside the collision box
verified (21 harnesses, all green):
  - debug_solid 10/10  debug_roster 38/38  smoke_match 17/17  stress_test 13/13
  - debug_opponent 9/9  debug_coop 12/12  debug_report 30/30  debug_yaw 7/7
  - debug_calibrate 6/6  debug_power 6/6  debug_rules 8/8  debug_human 6/6
  - debug_blue 6/6  debug_turret 7/7  debug_audio 19/19  tip_time 5/5
  - debug_flower_retrieve 4/4  debug_flower_stick 0 wedged
  - debug_intake_bounds 6/6  debug_leaderboard 11/11

session: 2026-09-20
status:  ROSTER, SPLIT CONTROLS AND THE CONTROLS CARD DONE.
added:
  - AI keep-out box around the HIVE structure; it routes round rather than
    riding up on the 1 in base bar
  - YOUR ALLIANCE 1/2, ROBOT 2 person-or-AI, PER ROBOT 1/2, OPPONENTS 0/1/2
  - Robot.op_device: driver and operator on separate controllers
  - Robot.takes_nectar: POLLEN ONLY or POLLEN + NECTAR
  - scripts/controls_screen.gd, reachable from CONTROLS on the title screen
removed:
  - the SHAPE page and the FROM HARDWARE drivetrain source
fixed:
  - seat allocation used a lambda counter; GDScript captures locals by value,
    so every seat got the same device
  - debug_yaw's settle test exited on the rate passing through zero mid-rewind
verified (20 harnesses, all green):
  - debug_roster 38/38  debug_opponent 9/9  debug_yaw 7/7 (0.3 deg, repeatable)
  - debug_calibrate 6/6  smoke_match 17/17  debug_report 30/30
  - stress_test 13/13  debug_coop 12/12  debug_human 6/6  debug_blue 6/6
  - debug_rules 8/8  debug_turret 7/7  debug_audio 19/19  tip_time 5/5
  - debug_power 6/6  debug_flower_retrieve 4/4  debug_flower_stick 0 wedged
  - shot_fit: title, 4 settings pages and the controls screen all fit

session: 2026-09-19f
status:  CALIBRATION AND EDITABLE COLLISION SHAPES DONE.
added:
  - RobotShop.Source: STOCK / HARDWARE / MEASURED
  - five measured inputs + a wizard page that shows what the sim does with them
  - Robot.strafe_factor and Robot.brake_decel
  - BB.ACCEL_TRIM (mecanum 45 deg roller projection) and BB.BRAKE_TRIM
  - RobotShop.shapes: editable collision boxes, with an 18 in inspection warning
  - ROBOT > SHAPE page
verified (18 harnesses, all green):
  - debug_calibrate 6/6 - entered 48/33/0.70/20/240, got 47.6/32.6/0.71/17.3/241.6
  - debug_yaw 7/7  debug_opponent 9/9  smoke_match 17/17  debug_report 30/30
  - stress_test 13/13  debug_coop 12/12  debug_flower_retrieve 4/4
  - debug_rules 8/8  debug_human 6/6  debug_blue 6/6  debug_turret 7/7
  - debug_audio 19/19  tip_time 5/5  debug_power 6/6
  - shot_report: all 5 ROBOT pages and both results pages fit at 1908x960
next (owner's order): drivetrain types (tank / swerve), then articulated
  mechanisms, then the in-game editor

session: 2026-09-19e
status:  OPPONENT NO LONGER GETS STUCK.
changed:
  - AIDriver gained five obstacle whiskers (rays, not a list of known
    obstacles, so walls / flowers / robots are all avoided for free)
  - AVOID_AT threshold: reacting to anything inside the whisker length meant
    reacting to the perimeter wall across most of the field, and the bot
    sidled about collecting two balls in seventy seconds
  - STUCK DETECTION IS NOW PROGRESS, NOT SPEED. Wedged on the HIVE's base bar
    the bot grinds along at 4-5 in/s commanding strafe and turn at once - fast
    enough that a speed-based detector never fires, so it sat there for the
    rest of the match. Distance to the current goal is the honest measure.
  - unstick backs out AND slides to the clearer side, with the side fixed for
    the whole manoeuvre
measured (70 s run): 27 shots, 3 tips, 139 ft driven, 0.0 s jammed
  (before: 9 shots, 1 tip, 3.5 s jammed on a leg)
harness notes:
  - "idle" and "jammed" both had to exclude SHOOT mode; standing still at the
    firing spot is the bot doing its job, not a stall
verified: debug_opponent 9/9, debug_coop 12/12, smoke_match 17/17,
  debug_yaw 7/7, stress_test 13/13

session: 2026-09-19d
status:  TURNING, OPPONENT AND GUIDED AUTO RECORDING DONE.
changed:
  - closed-loop heading hold through the WHEEL rate command (not a torque):
    full-speed release overshoot 31 deg -> 2 deg
  - ai_driver.gd rewritten simple: nearest pollen, fill to 4, score, repeat
  - AI robots are now included in auto-targeting (they never fired before)
  - SHOOT_STANDOFF measured flat, not along the tilted mouth normal
  - ROBOT > AUTO > RECORD: countdown, 30 s, then offer to save
  - debug_flower_stick extended with horizontally FIRED balls
verified (16 harnesses, all green):
  - debug_yaw 7/7   debug_opponent 8/8   debug_flower_retrieve 4/4
  - debug_flower_stick 0 wedged (rain AND incoming)
  - smoke_match 17/17  stress_test 13/13  debug_report 30/30
  - debug_rules 8/8  debug_coop 12/12  debug_human 6/6  debug_blue 6/6
  - debug_power 6/6  tip_time 5/5  debug_audio 19/19  debug_turret 7/7
not_done_this_pass:
  - async multiplayer and the online leaderboard (owner deferred them)
findings:
  - the FLOWER does not trap balls; the reported symptom is the 4-ball cap

session: 2026-09-19c
status:  SCORING REPORT, STATS, ROBOT SHOP AND RECORDED AUTOS DONE.
added:
  - itemised breakdown with counts AND points; FLOWER and END PARK now
    assessed at the end with CELL contents (Scoring.REPORT / END_ONLY)
  - scripts/stats.gd: 15 per-robot stats, collected passively
  - results_screen.gd: SCORE + STATS pages in real match-report shape
  - robot_shop.gd / robot_menu.gd: hardware specs, CAD import, match history
  - cad_import.gd: GLB/glTF + a hand-written STL parser (binary and ASCII)
  - auto_routine.gd / auto_player.gd: record an auto by driving it, replay it
  - removed the randomised-field option and all scatter code
verified:
  - debug_report 30/30   smoke_match 17/17   stress_test 13/13
  - debug_rules 8/8  debug_audio 19/19  tip_time 5/5  debug_power 6/6
  - debug_coop 12/12  debug_human 6/6  debug_blue 6/6  debug_turret 7/7
  - debug_intake_bounds 6/6  debug_leaderboard 11/11
  - shot_report: results x2 and robot x4 pages all fit at 1908x960
known_gaps:
  - CAD import is VISUAL only; collision stays the 18 in cube
  - auto replay is not bit-identical between runs, by design (Jolt is not
    deterministic) - this is documented on the AUTO page, not hidden

session: 2026-09-19b
status:  DRIVE FEEL, PERIMETER, SOUND AND SETTINGS DONE.
changed:
  - power_factor keyed to open-circuit not sagging voltage: the robot finally
    reaches its own spec (was running at 57% from the first frame)
  - perimeter drawn as black rail / clear polycarbonate / black rail
  - scripts/audio.gd: 15 procedurally generated sounds, no audio files
  - scripts/settings.gd + settings_menu.gd: 4 pages, live-applied, persisted
  - BB.key_override / keys_for() / rebuild_input_map() for key rebinding
  - BB.colorblind alliance palette (Okabe-Ito)
verified:
  - debug_power 6/6 (67.9 in/s and 465 deg/s fresh, 61.1 and 420 worn, 9.9% fade)
  - debug_audio 19/19   tip_time 5/5   smoke_match 17/17  stress_test 13/13
  - debug_rules 8/8  debug_coop 13/13  debug_human 6/6  debug_blue 6/6
  - debug_turret 7/7  debug_intake_bounds 6/6
  - shot_fit: title screen + all 4 settings pages clean at 1280x720 and 1908x960
next:
  - the agreed list continues at 7 (post-match stats), then 9, 11, 12, 13, 3, 6

session: 2026-09-19
status:  TIP TIMING RETUNED AND VERIFIED.
changed:
  - BB.HIVE_ANGULAR_DAMP 1.15 -> 0.50 (8 POLLEN now tips in ~4.0 s, was 5.6)
  - BB.NECTAR_MASS TIP_LB/6 -> 0.0385 kg, so a full NECTAR load is ~16% heavier
    than a full POLLEN load and genuinely tips faster
  - calibrate gate row 4n+2p held -> 4n+1p held / 4n+2p tip (closer to the manual)
  - Hive.gate_locked test hook
verified:
  - tip_time.gd 5/5   calibrate.gd 8/8 mass gate
  - smoke_match 17/17  stress_test 13/13  debug_rules 8/8  debug_blue 6/6
  - debug_human 6/6    debug_coop 13/13   debug_intake_bounds 6/6  debug_turret 7/7
open:
  - asked-for NECTAR time was 3.6 s; 3.83 s is the floor that keeps five NECTAR
    from tipping. Needs the owner's call to go further.

session: 2026-09-16
status:  FEATURE COMPLETE AND VERIFIED.
added:
  - title screen rebuilt: header / scrolling body / pinned footer, two columns
  - project stretch aspect EXPAND (was letterboxing into 1600x900)
  - 2-player local co-op, per-device input, DriverInput.NONE for a driverless seat
  - optional AI opponent, toggled in the menu
  - human player reaction time and one-at-a-time feeding (G426 / G427)
  - out-of-field elements taken out of play and walked back, not teleported
  - randomised starts / element scatter, OPT-IN (perfect is the default)
  - G407 per robot; LEAVE and PARK counted per robot, credited per alliance
  - HUD: second driver strip, battery bar and power factor
verified:
  - clean load, 0 errors and 0 warnings
  - smoke_match.gd 17/17        stress_test.gd 13/13 (jitter 0.00 in/s)
  - debug_rules.gd 8/8          debug_turret.gd 7/7     debug_blue.gd 6/6
  - debug_shooting.gd 19/20     debug_moving_shot.gd 20/20
  - debug_flower_stick.gd 0 wedged   debug_intake_bounds.gd 6/6
  - debug_leaderboard.gd 11/11  calibrate.gd 8/8 on the 0.44 lb mass rule
  - debug_coop.gd 13/13         debug_human.gd 6/6
  - shot_fit.gd PASS at 1280x720, 1600x900, 1908x960, 2560x1440
known_gaps:
  - leaderboard is LOCAL. Sharing is by copy/paste share code, not a server.
  - one opponent, not two. A full 2v2 needs a second AI and G402/G411 pinning
    and hoarding rules, which are not modelled.
  - AUTO is still a dead 30 s for the player robot; the AI drives in it.

session: 2026-09-15h
status:  FEATURE COMPLETE AND VERIFIED.
verified:
  - clean load, 0 errors and 0 warnings
  - smoke_match.gd 17/17        debug_intake_bounds.gd 6/6
  - debug_leaderboard.gd 11/11  debug_blue.gd 6/6   debug_turret.gd 7/7
  - debug_rules.gd 8/8          stress_test.gd 13/13 (jitter 0.04 in/s)
  - debug_shooting.gd 19/20     debug_flower_stick.gd 0 wedged
known_gaps:
  - leaderboard is LOCAL. Sharing is by copy/paste share code, not a server.
    A real global board needs a host; nothing in the client pretends otherwise.

session: 2026-09-15g
status:  FEATURE COMPLETE AND VERIFIED.
verified:
  - clean load, 0 errors and 0 warnings
  - smoke_match.gd 17/17 (incl. CELL scores nothing mid-match, 6 once final)
  - debug_blue.gd 6/6     debug_turret.gd 7/7     debug_rules.gd 8/8
  - debug_shooting.gd 19/20 standing   debug_moving_shot.gd 20/20 moving
  - stress_test.gd 13/13 (jitter 0.04 in/s)   debug_flower_stick.gd 0 wedged
  - debug_drive.gd 67.3 in/s, spin 466 deg/s, drift 0.0 deg

session: 2026-09-15f
status:  FEATURE COMPLETE AND VERIFIED.
verified:
  - clean load, 0 errors and 0 warnings
  - smoke_match.gd 15/15      debug_rules.gd 8/8
  - debug_turret.gd 7/7 (recovers from a deliberately corrupted turret)
  - debug_shooting.gd 19/20 standing   debug_moving_shot.gd 20/20 moving
  - stress_test.gd 13/13 (jitter 0.01 in/s)
  - debug_flower_stick.gd 0 wedged     debug_ride.gd pass

session: 2026-09-15e
status:  FEATURE COMPLETE AND VERIFIED.
verified:
  - clean load, 0 errors and 0 warnings
  - smoke_match.gd 15/15 (includes: every TIP is worth 20)
  - stress_test.gd 13/13 (jitter 0.04 in/s)   debug_rules.gd 8/8
  - debug_shooting.gd 19/20 standing (95%)
  - debug_moving_shot.gd 20/20 while moving at up to 67 in/s
  - debug_flower_stick.gd 0 wedged in the flower walls (run twice)

session: 2026-09-15d
status:  FEATURE COMPLETE AND VERIFIED.
verified:
  - clean load, 0 errors and 0 warnings
  - smoke_match.gd 13/13   stress_test.gd 13/13 (jitter 0.05 in/s)
  - debug_rules.gd 8/8 (cap holds at 4, dragging trips G407, dump 0.41 s)
  - debug_shooting.gd 19/20 taken shots entered the CELL (95%)
  - debug_drive.gd 67.3 in/s, spin 466 deg/s, drift 0.0 deg
  - debug_ride.gd pass

session: 2026-09-15c
status:  FEATURE COMPLETE AND VERIFIED.
verified:
  - clean load, 0 errors and 0 warnings
  - smoke_match.gd 13/13   stress_test.gd 13/13 (jitter 0.05 in/s)
  - debug_rules.gd 5/5     debug_ride.gd pass
  - debug_shooting.gd 20/20 taken shots entered the CELL (100%)

session: 2026-09-15b
status:  FEATURE COMPLETE AND VERIFIED. Runs clean in Godot 4.5.
verified:
  - clean load, 0 errors and 0 warnings
  - smoke_match.gd 13/13
  - calibrate.gd 8/8 on the 0.44 lb mass rule
  - stress_test.gd 13/13, worst residual jitter 0.77 in/s
  - debug_ride.gd max chassis rise 0.06 in over 26 loose POLLEN (was levitating)
  - debug_shooting.gd 90-95% of taken shots enter the CELL
  - debug_drive.gd fwd/strafe 59.3 in/s, spin 391 deg/s, drift < 0.1 deg

session: 2026-09-15
status:  superseded by 15b above.
verified_this_session:
  - clean load, 0 errors and 0 warnings
  - smoke_match.gd 14/14 (staging -> auto-target -> mouth entry -> tip -> score)
  - stress_test.gd 11/11, worst residual jitter 0.27 in/s
  - debug_drive.gd fwd 59.3 / strafe 59.3 / diagonal 41.7 in/s, drift < 0.1 deg
  - UI rendered under xvfb and inspected: tools/shot_ui.tscn writes _shots/*.png
    (xvfb-run -a -s "-screen 0 1600x900x24" godot --path . --rendering-driver
     opengl3 --resolution 1600x900 tools/shot_ui.tscn)

session: 2026-09-14
status:  v1. Superseded by session 2 above.
done:
  - field, walls, tape, zones, HIVE structure, 4 FLOWERS  (field.gd, flower.gd)
  - bi-stable HIVE seesaw with emergent, calibrated tipping  (hive.gd)
  - mecanum drivetrain, intake, 4-element hopper, turret launcher  (robot.gd)
  - drag-aware ballistic aim assist with flywheel spin-up  (robot.gd)
  - match clock, phases, G410 foul, human NECTAR entry  (match.gd)
  - Table 10-2 scoring + ranking points  (scoring.gd)
  - HUD, three cameras, staging and reset  (hud.gd, camera_rig.gd, main.gd)
  - 5 headless harnesses under tools/
verified:
  - project loads with ZERO errors and zero warnings
  - smoke_match.gd: 12/12 checks pass (staging to tip to score)
  - debug_drive.gd: fwd 58.6 / strafe 59.1 / diagonal 41.2 in/s, heading drift <0.2 deg
  - calibrate.gd: 4/4 manual-sourced HIVE rows
not_done_deliberately:
  - single RED robot only; no opponent AI and no multiplayer
  - AUTO is a dead 30 s (no autonomous routines) - robot.set_drive() and
    robot.aim_at() are the hooks to write one against
  - G402 / G411 / G421 (pinning, hoarding, auto interference) need a second robot
    to mean anything, so only G304, G407, G408, G410, G417 and G418 are modelled
open_questions:
  - element mass is not published by FIRST. If a real set is weighed, put the true
    values in bb.gd and re-run BOTH tools/calibrate.tscn and tools/smoke_match.tscn.
  - HIVE swing takes ~1.5-2.3 s limit to limit; DSIM animates 4.0 s. Raise
    Hive.swing.angular_damp if the slower swing matters.
```
