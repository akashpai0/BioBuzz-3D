extends Node
## DRIVETRAIN MEASUREMENT, ON A FLOOR THAT IS ACTUALLY CLEAR.
##
## ── WHY THIS FILE WAS REWRITTEN ────────────────────────────────────────────
## The previous version drove its diagonal case from (-62, -20) toward the
## middle of the field and hit `Field/HiveFrame` at t = 0.772 s, inside its
## own 0.9 s measurement window. It then printed 27 in/s and -6.7 deg of
## heading change and called that the drivetrain's diagonal performance. It
## was a collision. The project's own assessment repeated the number as a
## defect for a whole release. An independent review caught it.
##
## Two rules came out of that, and this file is built on them:
##
##   1. A CAPABILITY MEASUREMENT PROVES ITS OWN CLEANLINESS. Every run below
##      happens on a bare floor with nothing else in the world, and every run
##      watches for contact and FAILS if anything touches the robot. A number
##      that cannot say what it touched is not a measurement.
##   2. OBSTACLE BEHAVIOUR IS A DIFFERENT TEST. It is at the bottom of this
##      file, it uses the real field, and it asserts the opposite thing: that
##      the robot is stopped by the structure rather than climbing it or
##      passing through it.
##
## ── THE MODEL THESE ASSERTIONS ARE AGAINST ────────────────────────────────
## `Robot._physics_process` commands a BODY VELOCITY directly:
##
##     v_body = (cmd.x * strafe_factor, 0, -cmd.z) * max_speed_in_s * power
##
## and the four raycast suspensions then chase that velocity. There is no
## per-wheel speed decomposition, so there is no per-wheel speed CAP. What
## follows from that, and what this file therefore asserts, is:
##
##   * forward, strafe and any diagonal all reach the same top speed
##   * all four diagonals behave identically
##   * a pure translation produces no yaw, and a pure yaw produces no travel
##   * both spin directions have the same magnitude
##
## ── THE OPEN MODELLING QUESTION, WITH ITS ARITHMETIC ──────────────────────
## A real mecanum drivetrain CANNOT translate diagonally as fast as it drives
## straight. With the standard inverse kinematics and the stick to a corner
## (vx = vy = 1):
##
##     FL = vy + vx = 2     FR = vy - vx = 0
##     BL = vy - vx = 0     BR = vy + vx = 2
##
## two wheels are asked for twice the speed the other two are, so normalising
## by the fastest wheel halves the command, leaving vx = vy = 0.5 and a
## chassis speed of sqrt(0.5^2 + 0.5^2) = 0.7071 of top speed. At the
## 68 in/s this robot is built for that is 48.1 in/s.
##
## THAT NUMBER IS NOT ASSERTED HERE, deliberately. It is what the textbook
## kinematics predict, not something measured off Team 506's robot, and
## turning a derivation into an acceptance threshold is how the last wrong
## number got into the documentation. `DIAGONAL_RATIO` below records the
## prediction, the harness REPORTS how far the current model is from it, and
## the decision to implement wheel-speed normalisation is a separate change
## with its own measurements. See ASSESSMENT.md.

var fails := 0
var robot: Robot
var _contacts: Array[String] = []

## Predicted diagonal-to-straight speed ratio under normalised mecanum
## kinematics. REPORTED, NOT ASSERTED — see the header.
const DIAGONAL_RATIO := 0.7071

const SETTLE_S := 0.45
const RUN_S := 1.2

func _ready() -> void:
	_build_floor()
	robot = Robot.make(BB.Alliance.RED)
	robot.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(robot)
	robot.auto_drive = true
	robot.field_centric = false
	robot.contact_monitor = true
	robot.max_contacts_reported = 8
	robot.body_entered.connect(func(b: Node) -> void:
		if b != _floor:
			_contacts.append(String(b.name)))
	await get_tree().create_timer(1.5).timeout

	print("\n--- DRIVETRAIN, CLEAR FLOOR ---")
	var straight := await _translation()
	await _diagonals(straight)
	await _rotation()
	await _obstacles()

	print("  %s  (%d failure%s)" % [
		"DRIVETRAIN MEASURED CLEANLY" if fails == 0 else "DRIVETRAIN TEST BROKEN",
		fails, "" if fails == 1 else "s"])
	get_tree().quit(1 if fails > 0 else 0)

var _floor: StaticBody3D

## A bare tile floor and nothing else. No walls, no HIVE, no FLOWERS, no balls.
func _build_floor() -> void:
	_floor = StaticBody3D.new()
	_floor.name = "TestFloor"
	var shape := BoxShape3D.new()
	shape.size = Vector3(24.0, 0.2, 24.0)
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position.y = -0.1
	_floor.add_child(col)
	var mat := PhysicsMaterial.new()
	mat.friction = 0.95
	mat.bounce = BB.TILE_BOUNCE
	_floor.physics_material_override = mat
	_floor.set_collision_layer_value(BB.LAYER_WORLD, true)
	add_child(_floor)

# ================================================================ measuring ==

## One case. Returns {speed, drift, spin, slip, upright, moved, clean}.
func _run(label: String, drive: Vector3, run_s := RUN_S) -> Dictionary:
	robot.set_drive(0, 0, 0)
	robot.reset_to(Transform3D(Basis.IDENTITY, Vector3.ZERO))
	await get_tree().create_timer(SETTLE_S).timeout
	_contacts.clear()
	var p0: Vector3 = robot.global_position
	var yaw0: float = robot.global_rotation.y
	robot.set_drive(drive.x, drive.y, drive.z)
	var t := 0.0
	while t < run_s:
		t += await _tick()
	var out := {
		"moved": (robot.global_position - p0).length() / BB.IN,
		"speed": robot.speed_in_s(),
		"drift": rad_to_deg(angle_difference(yaw0, robot.global_rotation.y)),
		"spin": rad_to_deg(robot.angular_velocity.y),
		"slip": robot.total_slip(),
		"upright": robot.global_transform.basis.y.dot(Vector3.UP),
		"clean": _contacts.is_empty(),
		"hit": ", ".join(_contacts),
	}
	robot.set_drive(0, 0, 0)
	print(("  %-16s %6.1f in   speed %5.1f in/s   drift %6.2f deg   "
		+ "spin %7.1f deg/s   slip %5.1f N   upright %.3f   %s") % [
		label, out["moved"], out["speed"], out["drift"], out["spin"],
		out["slip"], out["upright"],
		"clear" if out["clean"] else ("TOUCHED " + String(out["hit"]))])
	return out

func _tick() -> float:
	await get_tree().physics_frame
	return 1.0 / float(Engine.physics_ticks_per_second)

## Every capability number in this file is void if something was in the way.
func _clean(label: String, r: Dictionary) -> void:
	_ok("%s: nothing was in the way" % label, r["clean"], true)
	_ok("  it stayed on its wheels", r["upright"] > 0.999, true)

# =================================================================== cases ===

## Straight down the two axes. Returns the forward speed, which every other
## translation is compared against.
func _translation() -> float:
	var fwd := await _run("forward", Vector3(0, 0, 1))
	_clean("forward", fwd)
	var back := await _run("reverse", Vector3(0, 0, -1))
	_clean("reverse", back)
	var right := await _run("strafe right", Vector3(1, 0, 0))
	_clean("strafe right", right)
	var left := await _run("strafe left", Vector3(-1, 0, 0))
	_clean("strafe left", left)

	var top: float = float(fwd["speed"])
	_ok("forward reaches the drivetrain's rated top speed",
		absf(top - robot.max_speed_in_s) < robot.max_speed_in_s * 0.03, true)
	_ok("  reverse matches forward",
		absf(float(back["speed"]) - top) < 1.0, true)
	_ok("  strafing right matches forward (no per-wheel cap is modelled)",
		absf(float(right["speed"]) - top) < 1.0, true)
	_ok("  strafing left matches strafing right",
		absf(float(left["speed"]) - float(right["speed"])) < 1.0, true)
	for pair in [["forward", fwd], ["reverse", back],
			["strafe right", right], ["strafe left", left]]:
		_ok("  %s holds its heading" % String(pair[0]),
			absf(float((pair[1] as Dictionary)["drift"])) < 1.0, true)
	return top

## ALL FOUR, because a drivetrain that is right in one quadrant and wrong in
## another is exactly the bug the old single-diagonal case could not see.
func _diagonals(top: float) -> void:
	var q := 0.7071
	var runs: Array = []
	for spec in [["fwd-right", Vector3(q, 0, q)], ["fwd-left", Vector3(-q, 0, q)],
			["back-right", Vector3(q, 0, -q)], ["back-left", Vector3(-q, 0, -q)]]:
		runs.append(await _run("diag %s" % String(spec[0]), spec[1] as Vector3))
		_clean("diag %s" % String(spec[0]), runs[-1])

	var speeds: Array[float] = []
	for r in runs:
		speeds.append(float((r as Dictionary)["speed"]))
		_ok("  a diagonal holds its heading",
			absf(float((r as Dictionary)["drift"])) < 1.5, true)
	var lo := speeds[0]
	var hi := speeds[0]
	for v in speeds:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	_ok("all four diagonals agree with each other", hi - lo < 1.5, true)

	# REPORTED, NOT ASSERTED. See the file header for why.
	var ratio := (lo + hi) * 0.5 / maxf(top, 0.001)
	print(("\n  MODEL NOTE: diagonal / straight = %.3f. Normalised mecanum "
		+ "kinematics\n              predict %.3f (%.1f in/s at this robot's "
		+ "%.0f in/s top speed).\n              The drivetrain commands a body "
		+ "velocity and models no per-wheel\n              speed cap, so the "
		+ "two do not agree. That is a MODELLING DECISION\n              still "
		+ "open, not a test failure — see ASSESSMENT.md.\n") % [
		ratio, DIAGONAL_RATIO, DIAGONAL_RATIO * robot.max_speed_in_s,
		robot.max_speed_in_s])

## Both directions, because a yaw that is fast one way and slow the other is
## a sign bug the single-direction case could not see either.
func _rotation() -> void:
	var cw := await _run("spin right", Vector3(0, 1, 0))
	_clean("spin right", cw)
	var ccw := await _run("spin left", Vector3(0, -1, 0))
	_clean("spin left", ccw)
	_ok("spinning right reaches the rated turn rate",
		absf(absf(float(cw["spin"])) - robot.yaw_rate_max)
			< robot.yaw_rate_max * 0.05, true)
	_ok("  spinning left matches it",
		absf(absf(float(ccw["spin"])) - absf(float(cw["spin"]))) < 12.0, true)
	_ok("  and they turn opposite ways",
		signf(float(cw["spin"])) != signf(float(ccw["spin"])), true)
	_ok("  a spin on the spot does not travel",
		float(cw["moved"]) < 2.0 and float(ccw["moved"]) < 2.0, true)

## THE SEPARATE TEST. On the real field, driving into the structure must stop
## the robot — not phase through it, not climb it, not flip it. This is the
## case the old diagonal run was accidentally measuring.
func _obstacles() -> void:
	print("\n--- DRIVING INTO THE FIELD STRUCTURE (real field) ---")
	robot.queue_free()
	_floor.queue_free()
	await get_tree().process_frame
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(2.0).timeout
	main.menu.close()
	main.mm.mode = BB.Mode.FREE_PRACTICE
	var r: Robot = main.robot
	r.auto_drive = true
	r.field_centric = false
	# the lane the old harness used, driven deliberately into the HIVE legs
	r.set_drive(0, 0, 0)
	r.reset_to(Transform3D(Basis.IDENTITY, BB.fp(-62.0, -20.0, 0.0)))
	await get_tree().create_timer(0.5).timeout
	var q := 0.7071
	r.set_drive(q, 0, q)
	var t := 0.0
	var worst_rise := 0.0
	while t < 2.5:
		t += await _tick()
		worst_rise = maxf(worst_rise, r.global_position.y / BB.IN)
	r.set_drive(0, 0, 0)
	var p := BB.to_field(r.global_position)
	print("  ended at (%.1f, %.1f)  rise %.2f in  upright %.3f" % [
		p.x, p.y, worst_rise, r.global_transform.basis.y.dot(Vector3.UP)])
	_ok("the HIVE structure stops the robot rather than letting it through",
		p.length() < 40.0, true)
	_ok("  it does not climb the structure", worst_rise < 2.0, true)
	_ok("  and it stays upright",
		r.global_transform.basis.y.dot(Vector3.UP) > 0.98, true)

func _ok(what: String, got: Variant, want: Variant) -> void:
	var pass_: bool = str(got) == str(want)
	if not pass_:
		fails += 1
	print("  %s %-56s got %s   want %s" % [
		"PASS" if pass_ else "FAIL", what, str(got), str(want)])
