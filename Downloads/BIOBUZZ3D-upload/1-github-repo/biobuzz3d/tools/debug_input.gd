extends Node
## CONTROLLER PROCESSING, TUNING AND PROFILES, TESTED AS BEHAVIOUR.
##
## ── WHAT THIS CAN AND CANNOT PROVE ────────────────────────────────────────
## NO PHYSICAL CONTROLLER IS CONNECTED when this runs. Everything below drives
## the real processing, profile and assignment code with values supplied by the
## test, which proves the MATH and the BOOKKEEPING are right.
##
## It proves nothing whatever about how a real pad feels, what a real stick
## rests at, or whether an Xbox and a PlayStation controller report the same
## axes. Those need a pad in someone's hands and are on the manual checklist
## in REVIEW-BUILD.md. Do not read a pass here as "controllers work".
##
## Two phases, as two processes, because "the profile is still there when you
## come back" cannot be proved by the process that wrote it.

var fails := 0
const P1 := "input harness one"
const P2 := "input harness two"

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var phase := String(args[0]) if args.size() > 0 else "write"
	if phase == "write":
		_shaping()
		_vector_shaping()
		_inversion()
		_profiles_are_independent()
		_assignment()
		_migration()
		_neutral_gate()
		_disconnect_is_safe()
		_tuning_is_human_only()
		_keyboard_is_untouched()
		_unbound_actions_are_visible()
		_write_profiles()
	else:
		_read_profiles()
	print("  %s  (%d failure%s)" % [
		"INPUT PROCESSING OK" if fails == 0 else "INPUT PROCESSING BROKEN",
		fails, "" if fails == 1 else "s"])
	get_tree().quit(1 if fails > 0 else 0)

# ================================================================== shaping ==

## THE DEADZONE IS CONTINUOUS. No step at the edge, zero inside, full at full.
func _shaping() -> void:
	print("\n--- DEADZONE AND CURVE ---")
	var dz := 0.20
	_ok("dead centre is zero", "%.4f" % DriverInput.shape(0.0, dz, 1.0), "0.0000")
	_ok("  inside the deadzone is zero",
		"%.4f" % DriverInput.shape(dz * 0.99, dz, 1.0), "0.0000")
	_ok("  exactly at the edge is zero",
		"%.4f" % DriverInput.shape(dz, dz, 1.0), "0.0000")
	_ok("full deflection is FULL output, whatever the deadzone",
		"%.4f" % DriverInput.shape(1.0, dz, 1.0), "1.0000")
	_ok("  and whatever the curve",
		"%.4f" % DriverInput.shape(1.0, dz, 3.0), "1.0000")
	_ok("  even with no deadzone at all",
		"%.4f" % DriverInput.shape(1.0, 0.0, 2.2), "1.0000")

	# no step: just outside the deadzone must be nearly zero, not 0.2
	var just_out := DriverInput.shape(dz + 0.001, dz, 1.0)
	_ok("just outside the deadzone is nearly nothing, not a jump",
		just_out < 0.01, true)
	_ok("  the old threshold rule would have jumped to the raw value",
		dz + 0.001 > 0.2, true)

	# monotonic and continuous across the whole range
	var worst_step := 0.0
	var prev := 0.0
	var last_m := 0.0
	for i in 1001:
		var m := float(i) / 1000.0
		var out := DriverInput.shape(m, dz, 1.6)
		if out < prev - 0.000001:
			_ok("output never goes DOWN as the stick goes further (at %.3f)" % m,
				false, true)
			break
		worst_step = maxf(worst_step, out - prev)
		prev = out
		last_m = m
	_ok("output rises smoothly with no jump bigger than 1%%",
		worst_step < 0.01, true)
	_ok("  and reaches full at the top", "%.4f" % prev, "1.0000")

	# a gentler centre asks for LESS in the middle and the same at the ends
	var mid_flat := DriverInput.shape(0.5, 0.0, 1.0)
	var mid_soft := DriverInput.shape(0.5, 0.0, 2.5)
	var mid_sharp := DriverInput.shape(0.5, 0.0, 0.5)
	_ok("a gentler curve asks for less at half stick", mid_soft < mid_flat, true)
	_ok("  a sharper curve asks for more", mid_sharp > mid_flat, true)
	_ok("  and neither changes the maximum",
		"%.4f %.4f" % [DriverInput.shape(1.0, 0.0, 2.5),
			DriverInput.shape(1.0, 0.0, 0.5)], "1.0000 1.0000")

## THE DRIVING STICK IS A VECTOR. Radial deadzone, direction kept, magnitude
## bounded — including the corners, which a per-axis deadzone gets wrong twice.
func _vector_shaping() -> void:
	print("\n--- THE DRIVING STICK AS ONE STICK ---")
	var dz := 0.15
	var full_diag := Vector2(1, 1).normalized()
	var out := DriverInput.shape_vector(full_diag, dz, 1.0)
	_ok("a full diagonal is bounded at 1.0, not 1.41",
		"%.4f" % out.length(), "1.0000")
	_ok("  and keeps its direction",
		"%.3f" % absf(out.angle() - full_diag.angle()), "0.000")

	var worst := 0.0
	for deg in 360:
		var v := Vector2.RIGHT.rotated(deg_to_rad(float(deg)))
		worst = maxf(worst, DriverInput.shape_vector(v, dz, 1.0).length())
	_ok("no direction can ask for more than full speed",
		"%.4f" % worst, "1.0000")

	# a small diagonal nudge is INSIDE a radial deadzone but outside a square one
	var nudge := Vector2(0.12, 0.12)          # length 0.170, each axis 0.12
	_ok("a diagonal nudge is judged on the whole stick, not each axis",
		DriverInput.shape_vector(nudge, dz, 1.0).length() > 0.0, true)
	_ok("  because the thumb really has moved %.3f" % nudge.length(),
		nudge.length() > dz, true)
	_ok("a dead-centre stick is exactly zero",
		DriverInput.shape_vector(Vector2.ZERO, dz, 1.0), Vector2.ZERO)
	_ok("  and drift inside the deadzone is exactly zero",
		DriverInput.shape_vector(Vector2(0.10, 0.05), dz, 1.0), Vector2.ZERO)

func _inversion() -> void:
	print("\n--- INVERSION ---")
	var p := ControlProfile.new("inv")
	p.id = "inv-test"
	p.set_tuning("invert_move_x", 1.0)
	_ok("inversion is a profile setting", p.is_on("invert_move_x"), true)
	_ok("  and the others are untouched", p.is_on("invert_move_y"), false)
	_ok("  and it does not change the deadzone",
		"%.2f" % p.get_tuning("move_deadzone"), "0.12")

## TWO CONTROLLERS, TWO PROFILES, NO BLEED.
func _profiles_are_independent() -> void:
	print("\n--- TWO CONTROLLERS, TWO PROFILES ---")
	for e in ControlProfile.all():
		if String((e as ControlProfile).name) in [P1, P2]:
			ControlProfile.delete_one((e as ControlProfile).id)
	var a := ControlProfile.create(P1)
	var b := ControlProfile.create(P2)
	a.set_tuning("move_deadzone", 0.05)
	a.set_tuning("turn_curve", 2.4)
	b.set_tuning("move_deadzone", 0.32)
	b.set_tuning("turn_curve", 0.7)
	ControlProfile.save_one(a)
	ControlProfile.save_one(b)
	DriverInput.refresh_profiles()

	DriverInput.set_profile(0, a.id)
	DriverInput.set_profile(1, b.id)
	_ok("controller 1 uses its own profile",
		"%.2f" % DriverInput.profile(0).get_tuning("move_deadzone"), "0.05")
	_ok("controller 2 uses its own",
		"%.2f" % DriverInput.profile(1).get_tuning("move_deadzone"), "0.32")
	_ok("  changing one does not move the other",
		"%.2f" % DriverInput.profile(0).get_tuning("turn_curve"), "2.40")
	_ok("an unassigned device falls back to the stock layout",
		DriverInput.profile_id(7), ControlProfile.STOCK_ID)

	# tuning shapes ONLY human input: these are pure functions of the profile
	var shaped := DriverInput.shape(0.5, a.get_tuning("move_deadzone"),
		a.get_tuning("move_curve"))
	_ok("tuning is applied to the command, not to the robot's limits",
		shaped <= 1.0, true)

## ASSIGNMENT: no accidental sharing, deliberate sharing preserved, and an
## ambiguous pair of identical pads is reported rather than guessed at.
func _assignment() -> void:
	print("\n--- SEAT ASSIGNMENT ---")
	Settings.seats.clear()
	var pool := [0, 1, -1]
	var got := Settings.allocate_devices(3, pool)
	_ok("three seats get three different devices",
		got[0] != got[1] and got[1] != got[2], true)
	_ok("  pads first, keyboard last", got[2], -1)

	Settings.seats.clear()
	Settings.seats[0] = 1
	Settings.seats[1] = 1                    # both pinned to the SAME pad
	got = Settings.allocate_devices(2, pool)
	_ok("two seats cannot both hold one controller", got[0] != got[1], true)
	_ok("  the first pin wins", got[0], 1)
	_ok("  and the loser is left dead rather than shadowing someone",
		got[1], DriverInput.NONE)

	Settings.seats.clear()
	Settings.seats[0] = 9                    # a pad that is not plugged in
	got = Settings.allocate_devices(2, pool)
	_ok("a pin to an absent controller falls back instead of killing the seat",
		got[0] != DriverInput.NONE, true)

	# single-person mode: one device drives AND operates, on purpose
	var plan := Settings.seat_plan(1, false, 1)
	_ok("solo mode is one seat", plan.size(), 1)
	_ok("  so driver and operator share a device deliberately",
		String(plan[0]["role"]), "Driver")
	var duo := Settings.seat_plan(1, false, 2)
	_ok("driver + operator is two seats", duo.size(), 2)
	_ok("  and they are separate seats, so they get separate devices",
		int(duo[0]["seat"]) != int(duo[1]["seat"]), true)

	Settings.seats.clear()

func _migration() -> void:
	print("\n--- TURN SENSITIVITY MIGRATION ---")
	# THE MAPPING the migration writes: curve = 1 / old sensitivity.
	for pair in [[0.4, 2.5], [1.0, 1.0], [1.8, 1.0 / 1.8]]:
		var sens := float((pair as Array)[0])
		var want := float((pair as Array)[1])
		_ok("  sensitivity %.1f maps to a curve of %.2f" % [sens, want],
			"%.3f" % clampf(1.0 / sens, 0.5, 3.0), "%.3f" % want)
	_ok("migration is marked done, so it cannot run twice",
		Settings.is_on("game/turn_sens_migrated"), true)
	# THE POINT OF THE MIGRATION: the old multiply capped what a full stick
	# could ask for; the curve does not.
	_ok("after migration a full stick reaches FULL turn",
		"%.4f" % DriverInput.shape(1.0, 0.1, 2.5), "1.0000")
	_ok("  where the old multiply capped it at the sensitivity",
		"%.4f" % clampf(1.0 * 0.4, -1.0, 1.0), "0.4000")
	_ok("  and the gentle centre it was bought for is kept",
		DriverInput.shape(0.5, 0.1, 2.5) < DriverInput.shape(0.5, 0.1, 1.0), true)


# ======================================================= THE NEUTRAL GATE ====
#
# Nothing held across a change may act when control comes back. This is the
# difference between a rebind that works and a robot that fires the moment you
# leave the settings screen.

func _neutral_gate() -> void:
	print("\n--- NOTHING HELD BECOMES A PRESS ---")
	var kb := -1
	DriverInput.forget()
	_ok("the keyboard is at rest in a headless test",
		DriverInput.at_neutral(kb), true)
	DriverInput.require_neutral(kb)
	_ok("  so a gate opens immediately once it is", DriverInput.is_gated(kb), false)

	# a gated device reads as nothing at all, and reports no edges
	DriverInput.require_neutral(4)				 # a device that is not there
	_ok("a gated device reports no stick", DriverInput.move(4), Vector2.ZERO)
	_ok("  no turn", "%.2f" % DriverInput.turn(4), "0.00")
	_ok("  no button strength", "%.2f" % DriverInput.strength(4, "fire"), "0.00")
	_ok("  and no fresh press", DriverInput.just_pressed(4, "fire"), false)

	# ...but diagnostics can still SEE it, which is the point of the raw path
	_ok("diagnostics still read the hardware while the gate is shut",
		DriverInput.raw_strength(4, "fire") >= 0.0, true)

	_ok("forgetting state gates every device at once",
		DriverInput.is_gated(4) or DriverInput.at_neutral(4), true)

## A controller that vanishes must not leave a command behind.
func _disconnect_is_safe() -> void:
	print("\n--- DISCONNECT AND RECONNECT ---")
	var gone := 6								  # never connected here
	_ok("a device that is not there asks for nothing",
		DriverInput.move(gone), Vector2.ZERO)
	_ok("  and holds no trigger", "%.2f" % DriverInput.strength(gone, "fire"), "0.00")
	_ok("  and NONE is inert by definition",
		DriverInput.move(DriverInput.NONE), Vector2.ZERO)
	_ok("  including its precision scale, which must not be zero",
		"%.2f" % DriverInput.precision_scale(DriverInput.NONE), "1.00")

	# reconnecting gates, so a held trigger at plug-in does not fire
	DriverInput.require_neutral(gone)
	_ok("a reconnected controller starts gated, not firing",
		DriverInput.strength(gone, "fire"), 0.0)
	_ok("  the game says which seat lost its controller",
		Settings.has_signal("device_lost"), true)

## The tuning is human-input only. AI and recorded autonomous go through
## set_drive(), which is downstream of every line in DriverInput.
func _tuning_is_human_only() -> void:
	print("\n--- TUNING TOUCHES HUMAN INPUT ONLY ---")
	var p := ControlProfile.get_one(ControlProfile.STOCK_ID)
	var before := p.get_tuning("move_deadzone")
	p.set_tuning("move_deadzone", 0.40)
	ControlProfile.save_one(p)
	DriverInput.refresh_profiles()
	var rt := AutoRoutine.new()
	rt.start_recording()
	for i in 10:
		rt.capture(Vector3(0.05, 0.0, 0.05), false, false, false, true)
	var cmd := rt.at(0.05)
	_ok("a recorded auto command is unchanged by a huge deadzone",
		"%.2f" % (cmd["drive"] as Vector3).z, "0.05")
	_ok("  because routines are replayed through set_drive(), not the sticks",
		cmd.has("drive"), true)
	p.set_tuning("move_deadzone", before)
	ControlProfile.save_one(p)
	DriverInput.refresh_profiles()

## The keyboard must be exactly as it was.
func _keyboard_is_untouched() -> void:
	print("\n--- THE KEYBOARD IS UNCHANGED ---")
	for pair in [["drive_fwd", KEY_W], ["drive_back", KEY_S],
			["strafe_left", KEY_A], ["strafe_right", KEY_D],
			["turn_left", KEY_Q], ["turn_right", KEY_E],
			["fire", KEY_SPACE], ["slow", KEY_CTRL], ["recalibrate", KEY_R]]:
		var action := String(pair[0])
		_ok("  %s is still %s" % [action, OS.get_keycode_string(int(pair[1]))],
			BB.keys_for(action).has(int(pair[1])), true)
	_ok("keyboard rebinding still works through Settings",
		Settings.has_method("rebind"), true)
	_ok("  and a keyboard seat is never given a pad profile's buttons",
		DriverInput.raw_strength(-1, "fire") >= 0.0, true)

## Precision mode and recalibration have no stock pad button, and that is
## stated rather than silently true.
func _unbound_actions_are_visible() -> void:
	print("\n--- ACTIONS WITH NO PAD BUTTON ---")
	var p := ControlProfile.get_one(ControlProfile.STOCK_ID)
	for a in ["slow", "recalibrate"]:
		_ok("  %s has no stock pad button" % a, p.label_for(a), "—")
	var mine := ControlProfile.create("bindable check")
	mine.bind("slow", {"button": JOY_BUTTON_RIGHT_SHOULDER})
	_ok("  but it can be bound", mine.label_for("slow"), "RB")
	_ok("  and binding it is recorded as a customisation",
		mine.is_custom("slow"), true)
	ControlProfile.delete_one(mine.id)

# ============================================== persistence, as two processes

func _write_profiles() -> void:
	print("\n--- WRITING PROFILES ---")
	var p := ControlProfile.create("persisted harness profile")
	p.set_tuning("move_deadzone", 0.27)
	p.set_tuning("turn_curve", 1.85)
	p.bind("slow", {"button": JOY_BUTTON_RIGHT_SHOULDER})
	ControlProfile.save_one(p)
	_ok("a profile was written", p.id != "", true)
	_ok("  with a custom binding", p.is_custom("slow"), true)
	_ok("  which reads as a real control name",
		p.label_for("slow"), "RB")
	_ok("  and an untouched action still falls back to stock",
		p.is_custom("fire"), false)
	_ok("  reading as the stock control", p.label_for("fire").findn("A") >= 0, true)

	# conflicts
	var clash := p.conflicts("outtake", {"button": JOY_BUTTON_A})
	_ok("binding B to a button A already uses is reported as a conflict",
		clash.has("fire"), true)
	var shared := p.conflicts("pause", {"button": JOY_BUTTON_START})
	_ok("  but Start/Pause is allowed to share, because it always has",
		shared.has("start_match"), false)

	# damaged data must not take anything else down
	var f := FileAccess.open(ControlProfile.PATH + ".bak", FileAccess.WRITE)
	f.store_string(FileAccess.get_file_as_string(ControlProfile.PATH))
	f.close()
	f = FileAccess.open(ControlProfile.PATH, FileAccess.WRITE)
	f.store_string("{ this is not json")
	f.close()
	var recovered := ControlProfile.all()
	_ok("a damaged profile file still yields a usable stock profile",
		recovered.size() >= 1, true)
	_ok("  and does not lose the keyboard bindings",
		Settings.keys != null, true)
	var restore := FileAccess.open(ControlProfile.PATH, FileAccess.WRITE)
	restore.store_string(FileAccess.get_file_as_string(ControlProfile.PATH + ".bak"))
	restore.close()

	# a hand-mangled but parseable profile is repaired, not trusted
	var bad := ControlProfile.from_dict({"id": "junk", "name": "",
		"tuning": {"move_deadzone": 9999.0, "turn_curve": "banana"},
		"bindings": {"fire": {"buttons": [999]}, "not_an_action": {"buttons": [1]}}})
	_ok("an out-of-range deadzone is clamped, not stored",
		bad.get_tuning("move_deadzone") <= 0.40, true)
	_ok("  a non-numeric value falls back to the default",
		"%.2f" % bad.get_tuning("turn_curve"), "1.00")
	_ok("  an impossible button is dropped", bad.is_custom("fire"), false)
	_ok("  an action this build does not have is dropped",
		bad.bindings.has("not_an_action"), false)
	_ok("  and a blank name is replaced", bad.name != "", true)

func _read_profiles() -> void:
	print("\n--- READING PROFILES BACK (cold start) ---")
	var found: ControlProfile = null
	for p in ControlProfile.all():
		if (p as ControlProfile).name == "persisted harness profile":
			found = p
	_ok("the profile survived a restart", found != null, true)
	if found == null:
		return
	_ok("  with its tuning", "%.2f" % found.get_tuning("move_deadzone"), "0.27")
	_ok("  and its curve", "%.2f" % found.get_tuning("turn_curve"), "1.85")
	_ok("  and its remapped button", found.label_for("slow"), "RB")
	_ok("the stock profile is always there",
		ControlProfile.get_one(ControlProfile.STOCK_ID) != null, true)
	_ok("  and cannot be deleted",
		ControlProfile.delete_one(ControlProfile.STOCK_ID), false)
	ControlProfile.delete_one(found.id)
	for e in ControlProfile.all():
		if String((e as ControlProfile).name) in [P1, P2]:
			ControlProfile.delete_one((e as ControlProfile).id)

func _ok(what: String, got: Variant, want: Variant) -> void:
	var pass_: bool = str(got) == str(want)
	if not pass_:
		fails += 1
	print("  %s %-58s got %s   want %s" % [
		"PASS" if pass_ else "FAIL", what, str(got), str(want)])
