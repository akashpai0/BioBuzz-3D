# Practice opponents — change notes

Build: `BioBuzz3D.exe`, 97,402,520 bytes,
SHA-256 `97444FB372660D6E00E1AE6598D2996E5698EFB97437149E7E55EB8D9BA18B30`,
MD5 `7232f2ffeb934aafe7eca760478ab15c`.

**Regression:** 25 harness runs. 24 passed first time; `debug_pause` failed one
check — "resuming keeps the ball's velocity" — which turned out to be a
timing-luck assertion from an earlier pass (it read the velocity a frame
*before* pausing, with a tolerance smaller than one physics tick of gravity).
It was replaced with an exact check of the actual invariant, and `debug_pause`
then passed **73/73**. Screen captures clean at 1280×720, 1600×900 and
1920×1080.

Four configurable opponent behaviors for rehearsing traffic, defense and
scoring under repeatable conditions when another driver isn't available.
Built into the existing opponent AI, Scenario Creator, snapshots and practice
attempts. Controller setup, scoring and pause are unchanged.

---

## What was inspected first, and what was reused

The existing `AIDriver` was already a working collect-and-score opponent: nearest
loose POLLEN, collect four, drive to a spot the CELL is open from, fire — with
obstacle whiskers, HIVE routing, progress-based stuck detection, and snapshot
save/restore of its runtime state. It ran on physics `delta` and was already
adopted as a pausable node.

So nothing was rebuilt. **That logic is now the *Collect and score* behavior,
unchanged**; its two hard-wired numbers became its settings, and at the
Standard preset they are exactly what they always were (55% cruise command, one
decision every 0.25 s). The three new behaviors share its steering, whiskers and
HIVE routing. Snapshots already had a per-robot `brain` block; configuration and
runtime state now live there.

## The four behaviors

| Behavior | What it does | Intake | Status it reports |
|---|---|---|---|
| **Stationary** | Holds its starting pose with ordinary drivetrain control. Push it and it moves — then, after its reaction delay, drives itself back. Optionally turns back to its heading. | off | Holding position · Holding position (pushed N in) · Returning to position |
| **Follow a route** | Drives up to 12 waypoints in order — Loop, Back and forth, or Stop at end — with a wait at each. Normal driving and collisions, with whisker avoidance and HIVE routing. | off | Travelling to waypoint N · Waiting: N.N s · Blocked — recovering · Blocked — waiting N.N s · Route complete |
| **Defend an area** | Stays in a circle; while the chosen robot's centre is within the radius + 12 in, it goes to the point `standoff` inches from that robot on the side toward the middle of the area. Otherwise it goes back to the middle. **Every goal is clamped inside the circle**, so it never pursues across the field. | off | Defending Robot N · Returning to area · Holding area |
| **Collect and score** | The original opponent. Nearest compatible element, collect up to the hopper cap, shoot it at its own CELL with the ordinary launcher and aim. Optional collection area. | on | Collecting · Travelling to shooting spot · Aiming · Shooting · Waiting: no compatible elements · Blocked — backing off |

Every behavior shows **Disabled by the match** when the match has switched
robots off (the G403 transition, for instance).

**Blocked**, for routes: no progress toward the waypoint for 1.4 s triggers a
1.1 s back-and-slide, at most twice, then a 2 s wait before trying again. It
never moves the robot except by driving it.

**The defense area is measured on the defender's ground-plane centre.** An 18 in
robot can overhang the circle by up to 9 in, and contact can shove it further
for a moment. The tested tolerance is 12 in beyond the radius.

**The defender is not rule-checked.** This game does not model pinning,
trapping or other defensive-contact rules, so the editor says so in amber
beside the setting rather than implying it is a legal defender. It does respect
the restrictions the game does enforce — every robot, this one included, is
switched off in the transition period.

**Collect and score targets POLLEN only.** That is what every intake accepts and
what this behavior knows how to score, so compatibility is always satisfied.
It never goes for NECTAR, even on an intake that could take it. Its alliance has
one CELL, so there is no scoring target to choose — and so none is offered.

## Settings, not a difficulty number

Every setting shown is one the chosen behavior actually uses:

| Setting | Stationary | Route | Defend | Collect |
|---|:-:|:-:|:-:|:-:|
| Driving pace — share of this robot's own full-stick command | ✓ | ✓ | ✓ | ✓ |
| Reaction delay — time before acting on a change | ✓ |  | ✓ | ✓ |
| Keep heading | ✓ |  |  |  |
| Arrival tolerance, route end mode, waypoints + waits |  | ✓ |  |  |
| Target robot, area centre, radius, standoff |  |  | ✓ |  |
| Collection area centre and radius |  |  |  | ✓ |

The held heading for Stationary is the robot's **own placed heading**, edited in
*Where* or with Q/E — one number, not a second one that could disagree with it.
Route has no reaction delay because nothing in it reacts to anything.

**Presets are names for visible values.** Gentle, Standard and Challenging set
pace and reaction (and tolerance or standoff where those apply). Change any of
those values and the label becomes **Custom**. Area size and target are
geometry, not difficulty, so changing them leaves the label alone.

**What difficulty is never allowed to be:** nothing here touches grip, motor
power, top speed, battery, launcher accuracy, hopper capacity, cooldowns, or
what the opponent can see. Pace caps the command it sends; reaction delays when
it acts. The defender only knows where your robot is by sampling its position,
every *reaction delay* seconds.

## Scenario Creator

Selecting an AI robot adds an **Opponent behavior** section directly under
*Driven by*, in the existing right-hand properties column: behavior selector
and explanation, preset, the relevant settings each with a one-line
explanation, validation messages placed beside the setting they are about, and
**Test scenario** through the existing test-and-return flow.

- **Routes:** *Add waypoints on the field* then click, in order; each waypoint
  has numeric X, Y and wait fields, up/down reordering and delete. Esc or *Done*
  stops adding.
- **Areas:** *Place on the field*, or type the centre.
- While editing, **every** AI robot's route or area is drawn — numbered
  waypoints, direction arrows, the loop-back leg, wait labels, the dashed first
  leg from where the robot starts, and area rings.
- In practice, the same drawing plus a live status line above each opponent is
  available through **Settings → Camera & display → Opponent overlay**. It is
  off by default, so the normal view stays uncluttered.

Validation catches: a route with fewer than two waypoints, a waypoint inside the
HIVE footprint, a defender with no target or a same-alliance target, and a
defense area overlapping the HIVE (where it cannot stand).

Roster limits are unchanged, and opponents never occupy a controller seat.

## Saving and retrying

A snapshot stores the configuration **and** the runtime state needed to resume:
current waypoint and direction, remaining wait, recovery count and remaining
recovery or blocked-wait time, stationary home and heading, remaining reaction
delay, the defender's last observed target position and time until it looks
again, and the status. Every timer is stored as time **remaining**, never as a
deadline, and advances only on the physics tick, so a pause freezes all of them.

The new behaviors draw no random numbers. The snapshot records `rng: null`, so a
later version that adds controlled randomness can tell the two kinds of file
apart. This promises repeatable **starting** conditions, not identical physical
outcomes — Jolt is not deterministic across runs.

**Retry restores the opponent as saved**, not in a default state: a route saved
2.744 s into a wait resumes with 2.744 s remaining.

**Old scenario files** go through an explicit compatibility path: a brain block
with no `behavior` key is the pre-existing collect opponent and is read as
*Collect and score* at the *Standard* preset. Merely viewing such a robot in the
editor does not convert it — only an edit does — so an untouched old scenario
cannot change on save. Missing targets, non-numeric values, out-of-field or
malformed waypoints and unknown behaviors are all repaired or reported, never a
crash.

**Practice records:** opponent configuration and the initial waypoint and wait
are part of the comparison group, so a personal best earned against a Gentle
defender does not carry over to a Challenging one. That key is added **only when
a configured opponent is present**, so every scenario saved before this feature
hashes exactly as it did and keeps its history.

## Starter scenarios

Four new ones, written through the ordinary library alongside the existing four
and created only if missing:

| Drill | Opponent | Objective |
|---|---|---|
| **Around a parked robot** | Stationary, Standard, in the straight line | Reach the far target in 9 s |
| **Crossing traffic** | Route, Standard, a four-point loop across your lane | Reach the far side in 10 s |
| **Guarded target** | Defend, Standard, 24 in area around the target, defending Robot 1 | Reach the target in 14 s |
| **Competing for pollen** | Collect and score, Standard | Score 20 more points in 45 s |

All four are ordinary situations — editable, duplicable, deletable.

---

## Verification

### Automated — `tools/debug_opponents.tscn`, 66 checks + 3 after a real restart

Every case is authored through the Scenario Creator draft, run through the
ordinary Test path, and judged on where the real robot actually went.

| Claim | Evidence |
|---|---|
| Stationary holds, does not collect, is pushable, returns | still within 1 in over 2 s; intake off, empty hopper; an impulse moved it **4.4 in**; drove back to **2.1 in**; never frozen |
| Routes honor order and waits | visited `[0, 1, 2]`; measured wait **1.51 s** for a 1.5 s setting |
| Traversal modes | Loop `[0,1,2,0,1]`; Back and forth `[0,1,2,1,0]`; Stop at end stops, says *Route complete*, and stays within 0.5 in once braked |
| Pace limits movement | 30% → **20.1 in/s**; 80% → **53.7 in/s**; never above a full stick |
| Blocked robots do not teleport | a wall across the field: recovery, then *Blocked — waiting*; never crossed it; largest single-tick move **0.29 in** |
| Defense stays in its area | driven at from four directions: furthest **23.0 in** from centre of a 30 in area; stood between Robot 1 and the middle; returned when Robot 1 left |
| Collection respects compatibility and capacity | never above the hopper cap; never targeted NECTAR on an intake that takes it; **10 shots** through the ordinary launcher; waits when nothing is compatible, notices a ball appearing |
| Pause freezes decisions, waits, movement | mid-wait: **4.250 s → 4.250 s** across 1.5 s paused; position and status unchanged; resumes from the same point; mid-drive via Settings: no movement |
| Save/load and retry mid-wait | saved **2.744 s**, reloaded **2.744 s**, same waypoint and settings; after it had moved on, retry restored the same |
| Across a real restart | cold start resumes the saved remaining wait |
| Test → retry → return | draft content unchanged |
| Records split by opponent settings | preset change, setting change → new group; returning to the same values → same group; editing a preset value → *Custom* |
| Old scenarios | comparison hash identical with and without a legacy brain; loads as Collect at Standard; malformed data sanitized; missing target reported beside its setting |
| No human input, no seats | opponent device and operator device both NONE; a 0.40 deadzone and inverted Y on the human profile did not affect it; seat plan unchanged |

### Rendered gameplay — four clips, 1280×720

Each of the four starter drills played through the library with the overlay on
and Robot 1 driven along a scripted line that interacts with the opponent:

- **Stationary** — pushed ~10 in, *Returning to position*, back within tolerance;
  Robot 1 goes round and **reaches the target**.
- **Route** — loops across the lane; Robot 1 waits, crosses, cuts in front of it
  and triggers a real **Blocked — recovering**; Robot 1 reaches the far side.
- **Defend** — *Holding area* until Robot 1 approaches, then *Defending Robot 1*,
  holding Robot 1 at x ≈ 20–34 for ~7 s before it forces through; stays inside
  its area throughout.
- **Collect** — collects, travels to its shooting spot, aims and shoots
  repeatedly on a staged field.

Rendering here is software OpenGL, so the clips show **behavior, not frame
rate**.

## Honest limitations

- **The defender is not checked against pinning or defensive-contact rules**,
  because the game does not model them.
- **The defender's positioning is simple goalkeeping.** It stands between your
  robot and the middle of its area. It does not predict where you are going,
  so a driver who approaches from an angle can get past it, as the demo shows.
- **Collect and score only ever goes for POLLEN**, and only scores by shooting.
  It will not play NECTAR or FLOWERS.
- **Routes are not path-planned.** Legs are straight lines with HIVE routing and
  whisker avoidance. A waypoint behind a structure other than the HIVE may be
  unreachable, and the robot will report Blocked rather than find a way round.
- **Stationary resists pushing only as hard as its pace allows**, through the
  ordinary drivetrain. At Gentle it is easy to shove aside; that is the setting
  doing what it says, not a wall that gives way.
- **Opponent robots use the stock drivetrain**, which still models no per-wheel
  speed cap (see ASSESSMENT.md).
- **Opponent robots have not been compared with a human-driven robot or a real
  team's behavior.** These are repeatable practice conditions, not a model of
  how a particular team drives.
