# BIOBUZZ 3D — honest assessment

Rewritten after an independent review on Windows, 20 September 2026, which
reproduced three defects this document had missed and disproved one it
asserted, and updated again after that reviewer's follow-up found two more.
Where this document and those reviews disagreed, the reviews were right — five
times out of five.

Two words are used strictly:

- **Tested** means a headless harness under `tools/` drives the real game code
  and asserts on the result. That proves *the code does what the code intends*.
- **Untested** means nobody and nothing has checked it. Where something is
  untested, that is said, not softened.

**No automated check in this document is evidence that driving feels
realistic.** A harness can measure 67.3 in/s and zero heading drift. Whether
that feels like Team 506's robot is a question only someone who has driven
that robot can answer, and nobody has. **There is no player feedback anywhere
in this document**, because there has still been no human driving session.

---

## Correction: the "broken diagonals" claim was wrong

The previous version of this file listed, as the headline defect, that diagonal
driving produced 27 in/s with 7° of yaw where it should have been ~48 in/s.
**That measurement was invalid and the diagnosis is withdrawn.**

The old `debug_drive.gd` drove its diagonal case from (−62, −20) toward the
centre of the field and struck `Field/HiveFrame` at t = 0.772 s — inside its own
0.9 s measurement window. It was measuring a collision and reporting it as
drivetrain performance. The harness had no assertions, so it printed the number
and exited zero, and this document repeated it for a whole release.

On a bare floor that now verifies its own clearance, the same commands give:

| case | speed | heading drift |
|---|---|---|
| forward | 67.3 in/s | +0.03° |
| reverse | 67.3 in/s | −0.35° |
| strafe right / left | 67.3 in/s | −0.25° / +0.21° |
| all four diagonals | 67.3 in/s | < 0.15° |
| spin right / left | −466.5 / +466.5 °/s | — |

The real finding is different, and is a **simplification rather than a bug**:
the drivetrain commands a body velocity directly and models **no per-wheel
speed cap**, so a diagonal runs as fast as a straight line. A real mecanum
cannot do that. With standard inverse kinematics and the stick to a corner,
two wheels are asked for twice what the other two are (FL = FR = 2, FR = BL = 0),
so normalising by the fastest wheel leaves a chassis speed of 1/√2 ≈ **0.707**
of top speed — 48.1 in/s on this robot. That is where the old "~48" came from.

`tools/debug_drive.gd` now **reports** that ratio and deliberately **does not
assert it**: it is a textbook prediction, not a measurement of Team 506's
robot, and turning a derivation into an acceptance threshold is how the wrong
number got in here in the first place. Implementing wheel-speed normalisation
is a separate change with its own measurements.

---

## The table

| Area | Directly tested | Still simplified or uncertain | Needs measurements from the physical robot? |
|---|---|---|---|
| **Driving** | `debug_drive`, 37 assertions on a bare floor that **fails if anything touches the robot**: forward, reverse and both strafes all 67.3 in/s within 3% of the rated 68; all four diagonals agree within 1.5 in/s; every pure translation holds heading within 1.5°; both spins reach 466.5 °/s symmetrically and travel < 2 in; the robot stays upright throughout. A separate obstacle case confirms the HIVE frame **stops** the robot without it climbing (0.00 in rise) or passing through. `debug_ride`: rides 0.77 in low under load with four wheels loaded. `stress_test`: worst residual jitter 0.05 in/s on a full field. | **No per-wheel speed cap** (above). No motor curve, current limit, voltage sag under stall, or carpet model; battery fades the drivetrain through a simple scale. Acceleration and braking come from a traction clamp, not torque. | **Yes.** Top speed, turn rate, acceleration, and coast distance are all measurable on a real field in an afternoon, and none have been. The numbers above are the model describing itself. |
| **Intake** | `debug_intake_bounds`, `debug_roster`: balls enter through the mouth, stop at the 4-element cap, NECTAR is rejected by a POLLEN-only intake, both mouths feed on a dual intake, and a ball is never owned by two robots or by a freed one. An intake can no longer swallow a ball while a menu is up (`debug_pause`). | A **capture volume**, not rollers. A ball in the mouth is moved into the hopper rather than dragged in, so there is no fumble, no half-in ball, no jam, and little difference between hitting a ball fast and creeping onto it. | **Yes, if it matters to you.** How reliably the real intake takes a ball at speed is the thing the sim cannot invent. |
| **Shooting** | `debug_shooting`: 19 of 20 taken shots entered the CELL from five positions between 42 and 56 in. `debug_moving_shot` fires while driving; `debug_turret` covers recalibration after a desync; `debug_power` the power/hood range. `debug_pause` confirms a shot in flight is still credited after a long pause. | The aim solver is a **drag-aware ballistic solution with no error term**: given a reachable target it picks a power and hood that work. No spin-up lag, no flywheel droop between shots, no hood backlash, no spread. 95% is "the solver is correct", not "you will make 95%". Edge-of-range and rotating shots are weakest. | **Yes.** Real exit speed, spread at a fixed distance and cycle-to-cycle consistency would replace an idealised model. |
| **Scoring** | `smoke_match`, `debug_hive`, `debug_rules`, `debug_report`, `calibrate`: tipping matches Field Setup Guide S12.3 (8 POLLEN at 0 NECTAR, 3 at 3); the score is harvested from the field **at rest** 2.8 s after the buzzer; G304/G407/G408/G410/G417/G418 fire; final and provisional scoring differ in the right direction. | Tipping is **emergent from ball mass on a hinged body** — the right model — but FIRST does not publish element masses, so the masses in `bb.gd` are fitted to reproduce the published table. Referee-judgement fouls (pinning, hoarding, interference) are not modelled. | **Partly, and cheaply.** Weighing one POLLEN and one NECTAR replaces the single fitted number the whole tip model rests on. Five minutes, highest value on this list. |
| **Objectives** | `debug_objectives`, 102 assertions plus 7 after a real restart. Baselines exclude everything already on the field. A foul on the completing step fails. Completion exactly at the deadline counts; a tick past it does not, **at three different step widths**, because the clock is the 180 Hz physics tick rather than the rendered frame. A points total eligible before the deadline may finish settling after it; one that becomes eligible after it may not; one whose points have left the field by the buzzer **fails on the final score**. Loading, a ball re-entering a CELL and a robot re-entering an area each count once. An attempt finishes exactly once. | Four goal kinds, deliberately not a scripting language: nothing conditional can be expressed. Points come from the live scoreboard, which is provisional mid-match; the settling rule handles that, but a goal met and unmet inside the settling window reads as unmet. Balls already airborne when a situation was saved **do** count for points and **never** for shots — real, documented, and warned about in the editor. | No. |
| **Retries** | `debug_workflow`, `debug_situations`: after a retry every ball is back within **0.0000 in** and the robot within **0.0000 in**; the source snapshot is unchanged across attempts; the clock restarts at zero and excludes paused and menu time; an early retry is recorded as **abandoned** and abandoned attempts count against the success rate. | Identical *starting conditions*, not identical *outcomes* — Jolt is not deterministic across runs, so two attempts with identical inputs diverge. Stated as such everywhere; it does mean a retry cannot A/B two driving lines precisely. | No. |
| **Pause** | `debug_pause`, **65 assertions** across the pause menu, Settings navigation and a three-second pause: ball, robot and CELL all move 0.0000; every clock, statistic and score unchanged; a manual-aim hold does not expire behind the menu; a shot in flight is still credited afterwards; **autonomous recording captures no samples and playback does not advance the playhead**, with pending drive command, intake and aim flags held and resume continuing from the same point; resuming restores the exact velocity. A **tree walk** fails if any node outside the declared always-running set can still process while halted. | The default is now exclusion: everything under the world root pauses unless it is named as always-running. That is the second attempt — the first was an allowlist of simulation nodes and it missed `auto_player`. The tree walk exists so the next omission is a test failure rather than a review finding; it found one (restored elements) within a run of being written. | No. |
| **Controller handling** | Only code paths: `debug_roster` checks seats are handed out pads-first then keyboard, a pinned seat gets its device, a pin to a missing controller falls back, and the AI never takes a device from a person. `debug_menus` checks the assignment screen writes through. | **No gamepad has ever been connected to this build.** Deadzones, trigger curves, stick drift, whether an Xbox and a PS pad read alike, whether two pads stay on the right robots after one is unplugged — all **untested against hardware**. The keyboard is the only input that has moved a robot in a test. Still the largest untested area. | No, but it needs a **real controller**. First thing to try. |
| **Performance** | Two samples from the reviewer's desktop (Ryzen 7 5800X, RTX 2080 Ti, 1600×900, four robots, three AI drivers, 56 elements, VSync off, 20 s after warm-up): **295.6** then **257.3** avg FPS, p99 frame time 5.46 then 7.33 ms, physics holding 180.03 and 180.04 steps/s across both. `stress_test` separately confirms the solver stays stable on a full field. | **Those are two single samples, not an A/B**, and the reviewer said so: the difference between them establishes nothing about whether any change cost performance. Neither says anything about team laptops, input latency, long sessions or worst-case contact piles. This pass changed process modes again and has not been benchmarked at all. | No, but it needs **your team's actual laptops**, and a controlled repeat rather than single runs, before any hardware requirement is published. |

---

## What the check marks are worth

Every "tested" cell is a harness asserting on the game's own systems — the same
`Scoring`, the same `MatchStats`, the same physics bodies the player drives. No
test mocks out the thing it is testing.

The reviews are the reason to be careful about what that buys. Of six
substantive findings across two rounds, four were in code this document already
described as tested, one was a number this document asserted that turned out to
be a collision, and one was a harness reporting its own broken fixture as a
product defect. The lessons recorded in `DEVLOG.md` are the ones worth
repeating here:

- **A diagnostic without assertions is not a test.**
- **A measurement that cannot prove its own conditions is not a measurement.**
- **A list of things to hold down will be one short of the tree.** Prefer a
  default that stops everything and names the exceptions.
- **A test that cannot fail is worse than no test.** The tree-walk guard added
  this pass passed against the build it was written to catch, until it was
  fixed — and then found a leak nobody had reported.

The honest summary:

- **The rules are probably right.** Scoring, fouls, tipping and objectives have
  been checked against the manual line by line, and the objective timing has
  now been checked by someone adversarial.
- **The behaviour is probably self-consistent.** Nothing drifts, leaks, double
  counts, finishes twice, or keeps running behind a menu.
- **The feel is still unknown.** Nobody has driven it with a controller, nobody
  has measured the real robot, and nobody has said whether it is close. Those
  three gaps are why this build exists, and none of them closed this pass.
