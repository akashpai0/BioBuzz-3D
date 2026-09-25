# BIOBUZZ 3D

A rebuild of [DSIM](https://www.playdsim.com/biobuzz)'s BIOBUZZ mode in **Godot 4.5**,
in 3D, with real rigid-body physics instead of a 2D approximation.

FTC 2026–27 **BIOBUZZ presented by RTX**. Field dimensions, staging, scoring and the
rules the sim can enforce all come from the Competition Manual V1 — every constant in
`scripts/bb.gd` carries its section or figure number.

> **Reviewing this build?** Start with **`REVIEW-BUILD.md`** (in `docs/`) — how to launch it,
> the controls, a 20-step manual checklist and the known limitations — and then
> **`ASSESSMENT.md`**, which says plainly what has actually been tested and what
> is still a guess. A ready-to-run Windows binary ships beside them.

## Open it

See the repository [`README.md`](../README.md) and [`DEVELOPING.md`](DEVELOPING.md):
Godot 4.5, open `project.godot`, install the Epic plugin binaries once, F5.
The field, both HIVES, the four FLOWERS and the robot are generated from code
at startup — there is no imported art apart from the team panda and a small
symbol font.

## Modes

The title screen offers three, because sitting through a dead 30 seconds every
time you want to practise driving is no way to spend an evening:

- **FULL MATCH** — AUTO 0:30, transition 0:08, TELEOP 2:00, scored for real.
- **TELEOP ONLY** — straight to the buzzer, two minutes of driving.
- **FREE PRACTICE** — no clock, no lockouts, nothing ends.

In a full match you can also cut AUTO short at any time with `K` (or the
controller's D-pad).

### Replays

Every run is recorded automatically. **Watch replay** on any result screen,
or **Progress → Replays** for the whole collection (no limit on how many are
kept; nothing is deleted unless you delete it). In the viewer, scrub to just
before a mistake and press **Practise from here** to save that moment as a
situation and drive it again. Full details and measured costs: `REPLAYS.md`.

### Online practice (private rooms)

**Play → Online practice.** One player **hosts from inside the game** — their
game runs the practice for everyone — and copies an **invite** to the team;
friends paste it into **Join**. Take seats (a whole robot, or split into driver +
operator — up to 4 robots and 8 people, AI on any robot you like), ready up and
practise; the host can pause and retry for everyone. Online runs land in your
own replay collection. No server to rent: over the internet the game uses
**Epic Online Services** (free) for finding the room and connecting peer to peer,
which needs a one-time setup in this project — see `ONLINE.md`. Until that is
done, only same-network rooms work; offline play never needs any of it.

### Match setup

Three switches under the mode picker, all defaulting to the quiet case:

- **DRIVERS 1 / 2** — two people, two robots on your alliance, one controller
  each. Both of you stand at the same driver station, so there is no split
  screen: one camera at eye height is what your alliance actually sees. `TAB`
  walks the chase camera between the robots. Player two needs a controller of
  their own — with only one pad, player two's robot sits still rather than
  mirroring player one's keyboard.
- **OPPONENT NONE / ONE ROBOT** — a simple bot for the other alliance. It
  collects, shoots, and occasionally comes and leans on you. It is deliberately
  not a good driver; the point is that the field is contested.
- **FIELD PERFECT / RANDOMISED** — perfect is the default, because a real field
  is reset to the manual before every match. Randomised nudges the loose staged
  elements a few inches and your start pose a couple of degrees, which is what a
  hurried reset actually looks like.

### Settings

`SETTINGS` on the title screen, or `ESC` mid-match. Four pages — audio levels,
field of view and turn sensitivity, window and quality, and full keyboard
rebinding. Everything applies the moment you change it and is saved straight
away; there is no OK button to forget to press. There is also a colourblind
alliance palette (Okabe-Ito vermillion and blue) that swaps every robot, tape
strip and HUD chip at once.

Turn sensitivity changes how far the stick has to move, not the robot's top
turn rate — that stays at the 460°/s everyone gets.

### Sound

There is not a single audio file in this project. Every sound is generated from
code at startup, the same way the field and the robot are. That also makes them
parametric rather than triggered: the flywheel is an oscillator driven by the
launcher's real spin-up, the intake drops in pitch and gains level as the hopper
fills, and a ball impact reads the ball's own deceleration — so a tap and a
launched ball arriving are the same sound at opposite ends of its range.

### The robot feels like a robot

Commands arrive 70 ms late and the motors ramp rather than snap. You start every
match at the full 68 in/s and 460°/s on a fresh pack, and finish it about ten
percent down — enough to feel in the last thirty seconds, not enough to fight.
The HUD draws the pack as a bar, and flooring it visibly sags the voltage without
costing you top speed, which is how a real battery behaves.

### The human player is a person

G426 lets your human player feed NECTAR in; it never said the ball appears out
of thin air. Elements owed to you now arrive a second or two later, one at a
time, set down in the LOADING ZONE. A ball that leaves the field is out of play
until somebody walks it back around the guardrail — two to four seconds. Worth
knowing before you plan a cycle around a feed.

## Controls

Plays on a **controller or the keyboard** — the title screen shows whichever one
is plugged in. Xbox layout; a DualSense maps to the same buttons.

| action | controller | keyboard |
|---|---|---|
| drive / strafe | left stick | `W A S D` |
| rotate | right stick X | `Q` `E` |
| fire (hold to empty the hopper, ~0.4 s for four) | `RT` or `A` | `SPACE` |
| spit one out | `LT` or `B` | `Z` |
| launcher power | `LB` / `RB` | `[` `]` |
| auto-aim on/off | `R3` | `C` |
| turret / hood by hand | D-pad | arrow keys |
| stop the intake (hold) | `L3` | `X` |
| field-centric | `X` | `F` |
| camera | `Y` | `TAB` |
| start | `START` | `ENTER` |
| reset the field | `BACK` | `BACKSPACE` |
| skip AUTO | D-pad | `K` |
| precision mode | — | `CTRL` |

With **2 DRIVERS**, every one of these is read per device: player two on a pad
cannot drive player one's robot, and a keyboard driver is not shoved around by
whatever a plugged-in controller is resting on.

**The intake runs constantly.** Drive over POLLEN and it collects, up to the
four elements G407 allows. **Auto-aim is on by default**: the turret tracks your
alliance's raised CELL and solves the arc for it, and the HUD tells you when you
are on the wrong side of the field to have a shot at all.

## What "real physics" actually buys you

This is the part that could not be done in the 2D original.

**The CELL is a box you shoot into the mouth of.** It is open at its outer end
only — 20 in wide by 14 tall, tilted 30° — so a shot has to arrive from outboard
of the cell, travelling toward the pivot, on a path flat enough to clear the
lip. That mouth is picked out in yellow on the field because finding it is half
the job. Red's raised CELL faces south and blue's faces north, so the side of
the field you are standing on decides whether you have a shot; auto-aim works
this out and says so.

**A CELL lets go at 0.44 lb.** Eight POLLEN, or six NECTAR, or any mix that
reaches it — the HUD shows the raised cell's load as a bar against that number,
so you can see how many more you need. Below it the seesaw does not budge; above
it the catch releases and the swing goes over under its own weight.

**The old note below describes the tip mechanism, which is still real physics —
only the release threshold is a number.** The seesaw is a `RigidBody3D` on a hinge, balanced
exactly on its pivot axis, held over-centre by a constant detent torque. The only
thing that can turn it is the weight of the POLLEN and NECTAR lying in the raised
CELL. Tipping it is a real torque problem: *where* your shots land in the tray
changes the lever arm, so eight balls piled against the inner wall behave differently
from eight spread down the cell. The detent was solved headless against FIRST's own
calibration rows — see `DEVLOG.md` §3 and `tools/calibrate.gd`.

**The spill is not scripted either.** Each CELL is modelled the way the real one is
built: floor, two sides, an inner end wall, and an **open outer end**. When a cell
swings down, its outer end becomes the low end and the load rolls out onto the tiles
by itself (G409).

**The FLOWER sorts by size, not by a rule check.** It is built the way the real
one is: three rings joined by four HIPS pipes, and those pipes ARE the tube wall.
Their spacing is set from the real bore, which means a 3.6 in NECTAR drops past
them but a 2.8 in POLLEN cannot squeeze out sideways between two of them. The
lower ring is a real annulus with a 2.79 in hole, so a POLLEN settles into it and
is cradled; the retrieval opening is a real 3.55 in gap, which a POLLEN fits
through and a NECTAR does not. G418 is enforced by geometry, not by a rule check.

**The elements are pickleballs and they stay where you leave them.** Perforated
plastic, drawn with the hole pattern, and damped so a ball that has stopped stays
stopped instead of creeping across the tiles for the rest of the match. Push one
and it moves. They bounce off the mat the way a real ball does — the springiness
lives in the tiles rather than in the balls, so a shot that lands on the load
already sitting in a CELL does not ping straight back out of the mouth.

**A ball that leaves the field comes back.** It is set down in the nearest
loading zone — the human player area — rather than hanging in the air at the
edge, and it costs a MINOR foul. (G405 makes *deliberate* ejection a MAJOR but
exempts balls lost on scoring attempts; since the sim cannot tell the two apart
it charges the lesser one.)

**The intake takes POLLEN only, and runs constantly.** Drive over a ball and it
collects, and it rides visibly inside the chassis frame. A NECTAR will not go in
at all, and nothing gets stranded under the robot — the intake reaches back
under the whole chassis, and anything it cannot collect is pushed back out.

**G407 is enforced, and the intake respects it.** *"No more than 4 at a time."*
The intake physically will not take a fifth ball. But CONTROL is not only what
is inside the robot: the manual counts herding balls along with you, while
calling inadvertent contact with one in your path "bulldozing" and explicitly
not a violation. So a loose ball only counts once it has actually travelled
*with* the robot for more than a moment — drive around with a full hopper
pushing two more along and you are controlling six. First offence is a VERBAL
WARNING; a repeat, or six at once, is STRATEGIC and hands the other alliance a
MAJOR FOUL worth 20. The HUD shows the count, says how many are being dragged,
and counts down the grace period.

**Shots work on the move.** The launcher knows the ball inherits the robot's
velocity and aims off it, so a shot taken while strafing at full speed lands
where a standing shot would. Measured: 20 of 20 while driving.

**The driver camera is at eye height** — 64.5 in, a 5 ft 9 in driver — so you
are looking slightly down across the field the way you would at an event.

**The turret looks after itself.** A nudge of the D-pad or the arrow keys steers
it by hand for a couple of seconds and then auto-aim takes back over — it does
not silently switch off and leave you missing. A watchdog checks every frame
that the turret is in a state it could legitimately be in and resets it if not,
logging why. `R` (or re-engaging auto-aim with `C` / `R3`) recalibrates on
demand, which also clears every cached aim solution.

**Sign in once, and there is a leaderboard.** The first time you open the game
it asks what to call you; the name is kept on your computer. Finished matches go
on the board automatically, split into two tables — one-intake runs and
two-intake runs are different contests — keeping your best per variant.

*Sharing has no server behind it,* so boards do not sync on their own. Instead,
**COPY MY SCORES** puts your whole board on the clipboard as a share code you can
send to anyone else with the game, and **PASTE SHARED SCORES** merges theirs into
yours. The higher score wins per name and variant.

**Pick your robot.** One intake or two, chosen by clicking a little 3D model on
the title screen. They drive identically — the difference is a collector at each
end instead of one at the front. The models are built by the same code as the
real robot, so what you pick is what you drive.

**Blue plays from the blue end.** Choosing blue moves the driver camera to the
other side of the field, flips the field-centric stick mapping, and starts you
at the blue wall. Blue's raised CELL faces north where red's faces south, so the
side you have to shoot from flips with it.

**Driver feel is fixed** at 68 in/s and 460 deg/s.

**The drivetrain can lose traction.** Each of the four mecanum wheels is a raycast
suspension producing its own normal force, and each may only push along its own 45°
roller direction, clamped at `mu * N`. Weight transfer, lifting a wheel on a bump,
spinning out on a POLLEN under one corner and tipping over are all consequences, not
special cases. Live wheel loads and total slip are on the HUD.

## Match flow

AUTO 0:30 (no driver input, G401) → TRANSITION 0:08 (no powered movement, G403) →
TELEOP 2:00. FLOWERS unlock for NECTAR at 1:00 remaining (G410 — putting one in
early is a MAJOR foul, and the HUD logs it). "Train whistle" at 0:20. At the buzzer
the field is allowed to **settle for 2.8 s before it is scored**, because §10.5 A–G
scores the field at rest, not the field at 0:00.

What is sitting in a CELL does **not** score during the match — per §10.5.C it
is assessed only once everything has come to rest at the end, so the HUD shows
`IN CELL --` until then. During play a HIVE is worth 20 per TIP and nothing else.

Scoring is Table 10-2 in full: LEAVE 3, PARK 5, HIVE TIP 20, elements remaining in a
raised CELL 2, elements in a FLOWER you own 2, bottom-NECTAR bonus 5, GARDEN 1, plus
the SWARM / POLLINATOR ranking points.

## Layout

```
project.godot          engine config (Jolt, 120 Hz physics)
scenes/main.tscn       four lines; everything else is built in code
scripts/bb.gd          every constant, with its manual citation
scripts/field.gd       tiles, walls, tape, HIVE frame, FLOWERS
scripts/hive.gd        the bi-stable seesaw
scripts/flower.gd      tube, rings, scoring volume, ownership
scripts/robot.gd       mecanum drivetrain, intake, hopper, launcher
scripts/match.gd       clock, phases, human NECTAR entry, fouls
scripts/scoring.gd     Table 10-2
scripts/hud.gd         driver-station overlay
scripts/main.gd        world assembly, staging and auto-targeting
scripts/ui.gd          the shared visual language every menu is built from
scripts/menu.gd        PLAY: mode, match setup, live robot, Start
scripts/robot_menu.gd  GARAGE: hardware, appearance (CAD), autonomous
scripts/progress_screen.gd PROGRESS: match history, trends, local leaderboard
scripts/settings_menu.gd SETTINGS: audio, camera, graphics, controls + devices
scripts/robot_preview.gd the lit 3D robot shown on Play and in the Garage
scripts/snapshot.gd    saved practice situations: the capture/restore format
scripts/scenario_library.gd  the situation files on disk, written atomically
scripts/scenario_screen.gd   the situation library page
scripts/scenario_draft.gd    the editable draft: mutations, undo, validation
scripts/scenario_editor.gd   the visual scenario creator
scripts/objective.gd   practice objectives: definition, wording, validation
scripts/attempt.gd     one go at an objective: lifecycle, baseline, timing
scripts/attempt_log.gd local attempt history, comparison groups, best times
scripts/objective_hud.gd  the compact practice HUD
scripts/attempt_results.gd  how the attempt went
scripts/starter_drills.gd   the four drills, written like any other scenario
scripts/driver_input.gd per-device control reads, so two drivers do not cross
scripts/ai_driver.gd   the optional opponent
scripts/leaderboard.gd local best-per-variant board and share codes
scripts/signin.gd      the one-time name prompt
tools/calibrate.gd     headless solver for the HIVE detent torque
tools/stress_test.gd   anti-glitch: rams every structure, then checks invariants
tools/shot_ui.gd       renders screenshots under a virtual display
tools/debug_hive.gd    one-shot seesaw diagnostic
tools/debug_coop.gd    two drivers, an opponent and a randomised field
tools/debug_human.gd   the human player's reaction time and feeding rate
tools/shot_all.gd      captures every menu page and fails if a control is
                       unreachable; run it at 1280x720, 1600x900 and 1920x1080
tools/debug_menus.gd   the menu wiring as behaviour: pause keeps the match,
                       pinned controllers stick, Garage changes reach the robot
tools/debug_situations.gd  saved situations across a real restart. Two runs:
                       `tools/debug_situations.tscn -- write` then `-- read`
tools/debug_editor.gd  the scenario creator: authoring, test/return, undo,
                       editing a moving snapshot, and every validation case
tools/debug_objectives.gd  objectives, attempts and bests. Two runs:
                       `tools/debug_objectives.tscn -- write` then `-- read`
DEVLOG.md              build log / handoff notes
```

## Tuning

Everything worth changing is an `@export` on the robot (top speed, wheel force,
traction µ, suspension, launch speed, hood) or a constant in `bb.gd`. If a Team
Update moves a field dimension, change the one line in `bb.gd` and the field follows.

If someone weighs a real set of POLLEN and NECTAR, put the true masses in `bb.gd` and
re-run `godot --headless --path . tools/calibrate.tscn` to re-solve the detent. That
is the only number in the project that is fitted rather than cited.

## Provenance

Dimensions were read from the FTC Competition Manual V1 as distilled in the DSIM
repository's `docs/biobuzz-reference.md`. **No DSIM code was copied** — DSIM is a 2D
TypeScript/canvas project and this is an independent GDScript implementation. FIRST,
FTC and BIOBUZZ are trademarks of their respective owners; this is an unofficial
practice tool.
