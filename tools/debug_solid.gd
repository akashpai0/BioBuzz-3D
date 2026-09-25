extends Node
##
## NOTHING MAY PHASE THROUGH ANYTHING.
##
## Drives a robot hard into every solid thing on the field and measures how far
## it gets INSIDE. A robot resting against a wall overlaps it by a fraction of
## an inch because that is how a solver works; a robot that is six inches into
## it, or out the other side, is a collision bug.
##
## `stress_test` already rams the structures, but it only ever had ONE robot —
## so robot-versus-robot, which is the case a driver hits every single match,
## was never tested at all.
##
var main: Node3D
var fails := 0

## More than this far inside something solid is a phase-through.
const MAX_PEN := 3.0     # in

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	main.menu.close()
	await get_tree().create_timer(1.5).timeout
	main._on_menu_start(BB.Mode.FREE_PRACTICE, BB.Alliance.RED, 1,
		{"robots": 2, "per_robot": 1, "opponents": 1})
	await get_tree().create_timer(2.2).timeout
	print("\n--- IS ANYTHING SOLID ---")

	_report_layers()
	_visual_vs_collision()
	await _vs_robot()
	await _vs_hive_leg()
	await _vs_corner()
	await _vs_flower()
	await _vs_wall()
	await _lap()

	print("  %s  (%d failures)" % [
		"EVERYTHING IS SOLID" if fails == 0 else "THINGS PHASE THROUGH", fails])
	get_tree().quit(1 if fails > 0 else 0)

func _ok(label: String, got, want) -> void:
	var good: bool = got == want
	if not good:
		fails += 1
	print("  %s %-48s got %s   want %s" % ["PASS" if good else "FAIL", label, str(got), str(want)])

## Jolt needs collision relationships to be MUTUAL. Printing the actual layer
## and mask bits makes a one-sided pair obvious instead of mysterious.
func _report_layers() -> void:
	var r: Robot = main.robots[0]
	var o: Robot = main.robots[2] if main.robots.size() > 2 else main.robots[1]
	print("  robot layer=%d mask=%d   opponent layer=%d mask=%d" % [
		r.collision_layer, r.collision_mask, o.collision_layer, o.collision_mask])
	_ok("robots are on the WORLD layer",
		(r.collision_layer & (1 << (BB.LAYER_WORLD - 1))) != 0, true)
	_ok("robots MASK the WORLD layer (mutual, or Jolt ignores it)",
		(r.collision_mask & (1 << (BB.LAYER_WORLD - 1))) != 0, true)
	var frame: StaticBody3D = main.field.frame_body
	print("  hive frame layer=%d mask=%d" % [frame.collision_layer, frame.collision_mask])
	_ok("the HIVE frame is on a layer robots mask",
		(frame.collision_layer & r.collision_mask) != 0, true)

## What you SEE has to match what COLLIDES.
##
## A mesh that reaches further than the collision box is indistinguishable, on
## screen, from phasing through something: the robot stops correctly but its
## intake is visibly buried in the wall or in the other robot. Both robots do
## it at once when they meet, so the overlap looks twice as bad.
func _visual_vs_collision() -> void:
	var r: Robot = main.robots[0]
	var half := BB.ROBOT_CUBE * 0.5
	var worst_x := 0.0
	var worst_z := 0.0
	var worst_name := ""
	for child in r.get_children():
		if not (child is MeshInstance3D):
			continue
		var mi: MeshInstance3D = child
		# the turret sits ABOVE the wall line and is allowed to overhang
		if mi.position.y / BB.IN > BB.WHEEL_R + BB.ROBOT_BODY_H:
			continue
		var box: AABB = mi.get_aabb()
		box = mi.transform * box
		var ox: float = maxf(absf(box.position.x), absf(box.end.x)) / BB.IN - half
		var oz: float = maxf(absf(box.position.z), absf(box.end.z)) / BB.IN - half
		if maxf(ox, oz) > maxf(worst_x, worst_z):
			worst_name = mi.name
		worst_x = maxf(worst_x, ox)
		worst_z = maxf(worst_z, oz)
	print("      worst mesh overhang: %.2f in across, %.2f in fore/aft" % [
		worst_x, worst_z])
	_ok("no part is drawn outside the collision box",
		maxf(worst_x, worst_z) < 0.35, true)

func _park(r: Robot, x: float, y: float, yaw: float) -> void:
	r.auto_drive = true
	r.set_drive(0, 0, 0)
	r.teleport(Transform3D(Basis(Vector3.UP, yaw), BB.fp(x, y, 0.0)))

## Two robots driven nose to nose. They must not end up inside each other.
func _vs_robot() -> void:
	var a: Robot = main.robots[0]
	var b: Robot = main.robots[1]
	_park(a, -30.0, -50.0, -PI * 0.5)
	_park(b, 6.0, -50.0, PI * 0.5)
	await get_tree().physics_frame
	for i in 240:
		a.set_drive(0, 0, 1)
		b.set_drive(0, 0, 1)
		await get_tree().physics_frame
	a.set_drive(0, 0, 0)
	b.set_drive(0, 0, 0)
	var gap := Vector2(a.fx() - b.fx(), a.fy() - b.fy()).length()
	# two 18 in robots nose to nose sit about 18 in apart, centre to centre
	_ok("two robots cannot drive into each other", gap > BB.ROBOT_CUBE - MAX_PEN, true)
	print("      centre-to-centre gap %.1f in (18 is touching)" % gap)

## Straight at a HIVE leg at full speed.
func _vs_hive_leg() -> void:
	var a: Robot = main.robots[0]
	_park(a, BB.HIVE_FRAME_X - 30.0, BB.HIVE_FRAME_FOOT, -PI * 0.5)
	await get_tree().physics_frame
	for i in 200:
		a.set_drive(0, 0, 1)
		await get_tree().physics_frame
	a.set_drive(0, 0, 0)
	var dx := absf(a.fx() - BB.HIVE_FRAME_X)
	_ok("a HIVE leg stops the robot", a.fx() < BB.HIVE_FRAME_X - 6.0, true)
	print("      stopped %.1f in short of the leg plane (x %.1f)" % [dx, a.fx()])

## Into the inside of a corner, where two walls meet — the case in the report.
func _vs_corner() -> void:
	var a: Robot = main.robots[0]
	var lim := BB.FIELD_HALF
	_park(a, -lim + 40.0, -lim + 40.0, 0.0)
	await get_tree().physics_frame
	for i in 260:
		# drive diagonally into the corner and keep pushing
		a.set_drive(-1.0, 0.0, -1.0)
		await get_tree().physics_frame
	a.set_drive(0, 0, 0)
	await get_tree().create_timer(0.4).timeout
	var out_x := -lim - a.fx()
	var out_y := -lim - a.fy()
	_ok("the corner holds the robot in",
		absf(a.fx()) < lim and absf(a.fy()) < lim, true)
	print("      corner rest at (%.1f, %.1f), walls at +-%.0f" % [a.fx(), a.fy(), lim])

## Into a FLOWER, which has its own robot-only guard hull.
func _vs_flower() -> void:
	var a: Robot = main.robots[0]
	var f: Flower = main.field.flowers[0]
	var flat := Vector3(f.global_position.x, 0.0, f.global_position.z)
	var out_dir := flat.normalized()
	var start := flat - out_dir * 34.0 * BB.IN
	a.auto_drive = true
	a.teleport(Transform3D(Basis.looking_at(flat - start, Vector3.UP), start))
	await get_tree().physics_frame
	for i in 200:
		a.set_drive(0, 0, 1)
		await get_tree().physics_frame
	a.set_drive(0, 0, 0)
	var d := Vector2(a.fx() - f.global_position.x / BB.IN,
		a.fy() + f.global_position.z / BB.IN).length()
	_ok("a FLOWER stops the robot", d > 9.0, true)
	print("      stopped %.1f in from the flower axis" % d)

## A full lap of the field, pressed against the wall the whole way, through
## every corner and past every FLOWER. This is the general version of "there is
## something wrong with this corner": it does not need to be told which one.
func _lap() -> void:
	var a: Robot = main.robots[0]
	var lim := BB.FIELD_HALF
	_park(a, -lim + 20.0, -lim + 20.0, -PI * 0.5)
	await get_tree().physics_frame
	var escaped := false
	var worst := 0.0
	var legs := [
		[Vector3(0, 0, 1), Vector3(-1, 0, 0)],    # along +x, leaning -y
		[Vector3(0, 0, 1), Vector3(-1, 0, 0)],
	]
	# four sides: drive forward while strafing into the wall, turning at each
	# corner by re-parking with the next heading
	var headings := [-PI * 0.5, 0.0, PI * 0.5, PI]
	var corners := [
		Vector2(-lim + 20.0, -lim + 20.0), Vector2(lim - 20.0, -lim + 20.0),
		Vector2(lim - 20.0, lim - 20.0), Vector2(-lim + 20.0, lim - 20.0),
	]
	for side in 4:
		_park(a, corners[side].x, corners[side].y, headings[side])
		await get_tree().physics_frame
		for i in 320:
			a.set_drive(-0.6, 0.0, 0.8)     # forward, leaning into the wall
			await get_tree().physics_frame
			var ox: float = absf(a.fx()) - lim
			var oy: float = absf(a.fy()) - lim
			worst = maxf(worst, maxf(ox, oy))
			if ox > MAX_PEN or oy > MAX_PEN:
				escaped = true
	a.set_drive(0, 0, 0)
	_ok("a lap of the wall never leaves the field", escaped, false)
	print("      worst excursion past the wall line %.2f in" % worst)

## Flat into a wall at full speed, repeatedly.
func _vs_wall() -> void:
	var a: Robot = main.robots[0]
	_park(a, 0.0, 0.0, -PI * 0.5)
	await get_tree().physics_frame
	var worst := 0.0
	for pass_i in 3:
		_park(a, BB.FIELD_HALF - 50.0, -40.0, -PI * 0.5)
		await get_tree().physics_frame
		for i in 200:
			a.set_drive(0, 0, 1)
			await get_tree().physics_frame
		worst = maxf(worst, a.fx() - (BB.FIELD_HALF - Robot.HALF))
	a.set_drive(0, 0, 0)
	_ok("a wall stops the robot every time", worst < MAX_PEN, true)
	print("      worst wall penetration %.2f in" % worst)
