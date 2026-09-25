# Controller setup and tuning — change notes

Build: `BioBuzz3D.exe`, 97,317,472 bytes,
SHA-256 `FA52DD8596FD4DA74BA8EE658444717261831EFF19CD732DCFDAE0AED4F3B8EC`,
MD5 `e6bb40a8255c651e0875790d4c31a130`.

**Regression:** 24 harness runs, zero failures. Captures clean at 1280×720,
1600×900 and 1920×1080 plus the first-run pass. Note that the Controls
screenshots show a **keyboard** seat, because no controller exists in the
build environment — the pad-specific rows are what a connected controller
would populate.

An input pass. **Nothing about the robot changed**: drivetrain physics, speed
and turn limits, scoring, the AI and autonomous execution are all untouched.
Everything here happens between your thumb and the command.

---

## Read this first, if you read nothing else

**No physical controller was connected to any of this.** Every result below
came from driving the real processing, profile and assignment code with values
supplied by a test. That proves the maths and the bookkeeping. It proves
nothing about how a real pad feels, what a real stick rests at, or whether an
Xbox and a PlayStation pad report the same axes. The manual checklist at the
end is the part that needs a pad in your hands, and until someone works
through it, controller support is **unverified against hardware**.

---

## 1. Seats you can understand

`Settings → Controls → Seats` lists the seats the current roster actually
needs — Robot 1 Driver, Robot 1 Operator, and so on — and for each one:

- **the device and whether it is connected right now**, not just what it was
  assigned to;
- **the profile** it is using;
- **Identify** — press it, then press a button on the controller you mean, and
  that pad takes the seat;
- when there is nothing to give it, a plain sentence saying the robot will not
  move and what to do about it.

**One person per robot still shares one controller between driving and
mechanisms.** That is deliberate and the screen says so, with a pointer to
People per robot on Play if you want them split.

**One device cannot be assigned to two people by accident.** Picking a pad
another seat already holds is refused with a message naming that seat.

**Identical controllers are not guessed at.** Two of the same pad report the
same GUID and the same name, and their id numbers are whatever Godot handed
out this session. When two indistinguishable pads are connected, the seat says
so and asks you to use Identify rather than pretending it can tell them apart.

**If a controller in use disconnects mid-run, the run stops.** The pause menu
names the seat that lost it. **Reconnecting does not resume** — you pick the
pad back up and resume yourself, which is also what stops a plugged-in pad
resuming a match nobody is holding.

## 2. A live input preview

On the Feel and Buttons tabs: both sticks as raw numbers and as the processed
command, trigger bars, every button currently down, and the device and profile
in use. Stick drift shows up as a non-zero raw reading with the pad on the
table; a deadzone shows up as raw moving while the processed output stays at
zero.

It reads the hardware directly, so it **consumes no press and sends nothing to
the robot**, and the settings screen keeps running while the game is paused —
verified: with a match halted, the preview ran 30 frames while the ball, the
robot and every command stayed at 0.0000.

## 3. Tuning

Per profile: movement deadzone, turning deadzone, movement response, turning
response, three inversion switches, and the precision-mode speed. Each has a
one-line explanation. **Reset this tuning** resets exactly these and leaves
buttons and every other setting alone.

### The deadzone is now continuous

The old rule was a threshold: below 0.18 the axis read zero, and at 0.181 it
read 0.181 — so the robot went from nothing to nearly a fifth of full speed
across one hair of travel, and **there was no way to ask for 5%**.

Now: zero inside the deadzone, zero *at* its edge, rising smoothly from there,
and exactly 1.0 at full deflection.

```
t   = (magnitude - deadzone) / (1 - deadzone)
out = t ^ curve
```

A curve above 1 gives a gentler centre for fine corrections; below 1, a
sharper one. **Neither changes the maximum** — `t` is 1 at full stick, so the
output is 1 whatever the exponent. That is the sentence the screen uses too.

### The driving stick is one stick

Translation is processed as a 2D vector with a **radial** deadzone. Two
independent axes would give a square deadzone — a diagonal nudge of
(0.15, 0.15) reads as nothing on both axes even though the thumb has moved
0.21 — and would let a full diagonal ask for 1.41× full speed. Direction is
preserved and magnitude is clamped; a 360° sweep confirms no direction can ask
for more than 1.0. Turning is processed separately.

### `turn_sens` is retired

**It was capping your robot.** The old code was `turn = clamp(turn * sens)`,
which scales the *command*: at a sensitivity of 0.4, a driver holding the
stick fully over was asking for 40% turn and could not ask for more.

It is migrated **once** into the stock profile's turn response curve —
`curve = 1 / turn_sens`, clamped to 0.5–3.0 — and then never read again, so the
old multiply and the new curve can never both apply. A flag records that the
migration happened so it cannot run twice.

**The unavoidable behaviour change:** if you had turn sensitivity below 1.0,
full stick now reaches the robot's full turn rate. The gentle centre you were
buying is preserved; the ceiling nobody agreed to is not.

Tuning applies to human input only. The AI and recorded autonomous routines
move through `Robot.set_drive()`, which is downstream of all of it — verified
by replaying a routine with the deadzone at maximum and confirming the command
comes back unchanged.

## 4. Remapping

Buttons, triggers and stick directions, grouped as Driving, Mechanisms and
Session. During a rebind:

- **the button that opened the dialog must be released first**, or the very
  press that opened it gets captured;
- **Esc always cancels**, whichever capture is running;
- a conflict offers **Replace** or **Cancel**, naming what currently uses that
  input and what will be left unbound;
- **Start before a match and Pause during one are allowed to share**, because
  that is one button doing one obvious thing;
- afterwards the device is **gated** — nothing is accepted until everything
  returns to neutral, so the button you are still holding does not act the
  instant you leave the screen.

The same gate applies after loading a profile, after a reconnect, and after a
saved situation is restored.

**Precision mode and recalibration have no stock pad button.** Every face,
shoulder and d-pad button on a standard controller is already used by the
existing layout, and silently taking one would break someone's muscle memory.
They are listed in amber as "Not bound — click to set" and are fully bindable;
you choose what to give up. The keyboard bindings for both (`Ctrl` and `R`)
are unchanged.

**Control hints follow the bindings.** The pause-menu Controls card and the
objective HUD read from the live map, so a rebind shows up in the hints.

## 5. Profiles

New, Duplicate, Rename, Delete, and a per-seat selector. A profile stores
**bindings and tuning** and belongs to a person, not to a controller — seats
point at profiles, and neither the device id nor the seat is stored inside one.

They live in `user://control_profiles.json`, separate from `settings.cfg`, so
damaging one cannot take your keyboard bindings or any other preference with
it. Every value is validated on load: an out-of-range deadzone is clamped, a
non-numeric value falls back to the default, an impossible button is dropped,
and an action this build does not have is ignored. A file that is not valid
JSON at all yields a working standard profile and a warning.

The **Standard gamepad** profile cannot be renamed or deleted, so there is
always something to fall back to.

## 6. Testing it

From Controls with no match running: **Test drive** — free practice on a
staged field with no clock and no objective. Nothing there is recorded: free
practice never fires the match-finished path, no attempt is armed and no
scenario is loaded, so no match record, no objective attempt and no leaderboard
entry can be written. Leaving it returns you to Controls, not to Play.

With a match paused behind the screen, Test drive is replaced by **Apply and
resume**, which returns to the same paused match with the new settings. It
never starts a second session over the top of one you are in the middle of.

---

## What was verified automatically

`tools/debug_input.tscn` — **90 checks, plus 6 after a real restart**, in two
processes:

| Area | Checks |
|---|---|
| Deadzone continuity | zero at centre, zero inside, zero *at* the edge, near-zero just outside (not a jump to the raw value), full output at full deflection for every deadzone and curve |
| Smoothness | 1000 points of stick travel: output never decreases and never steps more than 1% |
| Curves | a gentler curve asks for less at half stick, a sharper one for more, and neither changes the maximum |
| The stick as a vector | a full diagonal is bounded at 1.0 not 1.41, direction is preserved, a 360° sweep never exceeds 1.0, a diagonal nudge is judged on the whole stick |
| Two controllers | independent profiles, changing one does not move the other, an unassigned device falls back to stock |
| Assignment | three seats get three devices, pads before keyboard, two seats pinned to one pad cannot both have it, a pin to an absent pad falls back rather than killing the seat, solo mode shares deliberately |
| Migration | the 1/sens mapping at three points, the flag that stops it running twice, full stick reaching full turn where the old multiply capped it at 0.4 |
| Neutral gating | a gated device reports no stick, no turn, no button and no fresh press, while diagnostics can still read the hardware |
| Disconnect | an absent device asks for nothing, holds no trigger, and a reconnect starts gated rather than firing |
| Human-only tuning | a recorded routine replays unchanged with the deadzone at maximum |
| Keyboard | nine bindings confirmed unchanged, rebinding still present |
| Unbound actions | precision and recalibrate report no stock pad button, and bind correctly when given one |
| Persistence | a profile with custom tuning and a remapped button reads back after a real process restart; the stock profile always exists and cannot be deleted |
| Damaged data | unparseable JSON still yields a usable profile; clamped, dropped and defaulted values on a mangled one |

`tools/debug_pause.tscn` — **72 checks**, including the new one: with a match
halted, the Controls preview ran 30 frames while the ball, the robot and every
command stayed at 0.0000, and the robot itself could not process.

---

## What needs a real controller — manual checklist

**None of this has been done.** Fifteen minutes with a pad.

**Connect and assign**
1. Plug in a controller with the game running. Settings → Controls → Seats
   shows it and says connected.
2. Press **Identify** on Robot 1 Driver, then a button on that pad. It takes
   the seat and the footer says so.
3. With two pads plugged in, assign each to a different seat. Try to assign
   one pad to both — it should refuse and name the seat that already has it.
4. With **two identical** pads, check the seat warns that it cannot tell them
   apart and asks you to Identify.

**Preview**
5. Put the pad on the table. Raw stick readings should be near zero; anything
   above ~0.05 is stick drift and is what the deadzone is for.
6. Move each stick slowly. Raw moves immediately; the processed output stays
   at zero until you leave the deadzone, then rises smoothly.
7. Pull each trigger halfway. The bars should read about 0.5.
8. Press every button in turn and confirm the name shown matches the button
   you pressed — this is where an unusual pad's mapping will show up.

**Tuning**
9. Raise the movement deadzone until the drift reading no longer produces
   output. Check full stick still reads 1.00 of full.
10. Set movement response to about 2.0. Half stick should ask for noticeably
    less; **full stick must still read 1.00**.
11. Toggle each inversion and confirm it flips the axis you expect.
12. Press **Reset this tuning** and confirm your buttons and other settings
    are untouched.

**Remapping**
13. Rebind precision mode to a button of your choice. Confirm the dialog waits
    for you to release the button you clicked with.
14. Try to bind it to something already in use — confirm the conflict offers
    Replace and Cancel and names what would be left unbound.
15. Press Esc during a capture and confirm it cancels.
16. **Hold the trigger you just bound and leave the screen.** The robot must
    not fire until you release and press again.

**Driving**
17. **Test drive.** Drive, strafe, turn, hold precision mode, shoot. Then
    check Progress and the leaderboard — nothing from this session should
    appear anywhere.
18. Return to Controls and confirm you land back on the Controls page.

**Disconnect**
19. Start a match, then unplug the controller. The match must pause and name
    the seat.
20. Plug it back in. It must **not** resume on its own; resume yourself and
    confirm the robot answers and is not stuck moving.

**Two players**
21. With two pads and Driver + operator, confirm each person's controls only
    affect their own job, and that one pad cannot drive the other's robot.

**Restart**
22. Close the game and reopen it. Profiles, tuning, bindings and seat
    assignments should all be as you left them.
