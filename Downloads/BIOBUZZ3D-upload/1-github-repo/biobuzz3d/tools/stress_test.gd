extends Node
##
## ANTI-GLITCH TEST.
##
## Deliberately abuses the sim for half a minute — full-speed rams into the HIVE
## frame, the FLOWERS and the walls, max-power shots fired point blank at
## structures, the robot parked on top of a pile of balls — and then checks the
## invariants that "nothing phases through anything" actually reduces to:
##
##   1. every element is still in the world, and there are still exactly 56
##   2. nothing is under the tiles or outside the perimeter
##   3. nothing is left jittering, which is what a trapped/penetrating body does
##   4. the robot is inside the field, upright, and not underground
##   5. no element is inside a closed CELL that it never had a mouth-path into
##

var main: Node3D
var robot: Robot
var t := 0.0
var phase := 0
var fails := 0
var worst_jitter := 0.0
var rammed := 0

const TARGETS := [
	Vector2(-24.5, 0.0),      # straight into a HIVE frame leg
	Vector2(-69.0, -24.0),    # into FLOWER F1
	Vector2(-72.0, 0.0),      # into the west wall, flat out
	Vector2(-24.0, 69.0),     # into FLOWER F2
	Vector2(0.0, 0.0),        # under the hive, through the base bars
	Vector2(-66.5, 36.0),     # into the LOADING ZONE pollen pile
]

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	main.menu.close()
	main.mm.mode = BB.Mode.FREE_PRACTICE
	await get_tree().create_timer(1.8).timeout
	robot = main.robot
	main.mm.start()
	robot.auto_drive = true
	robot.field_centric = false
	robot.launch_speed_in_s = BB.LAUNCH_SPEED_MAX
	print("\n--- STRESS ---")

func _ok(label: String, got, want) -> void:
	var good: bool = got == want
	if not good:
		fails += 1
	print("  %s %-46s got %s   want %s" % ["PASS" if good else "FAIL", label, str(got), str(want)])

func _physics_process(d: float) -> void:
	if robot == null:
		return
	t += d

	# --- ram a structure, reposition, ram the next one
	if phase < TARGETS.size():
		var target: Vector2 = TARGETS[phase]
		if fmod(t, 4.0) < d:
			# line up 40 in away and drive flat out at it
			var from := target + (target.normalized() if target.length() > 1.0 else Vector2(0, 1)) * 40.0
			from.x = clampf(from.x, -62.0, 62.0)
			from.y = clampf(from.y, -62.0, 62.0)
			var yaw := atan2(target.x - from.x, -(target.y - from.y))
			robot.teleport(Transform3D(Basis(Vector3.UP, yaw + PI), BB.fp(from.x, from.y, 0.5)))
			rammed += 1
			phase = int(t / 4.0)
		robot.set_drive(0.0, 0.0, 1.0)
		# fire into whatever is in front, at maximum power
		if robot.can_fire():
			robot.launch_speed_in_s = BB.LAUNCH_SPEED_MAX
			robot.hood_deg = 18.0
			robot.hood.rotation.x = deg_to_rad(robot.hood_deg)
			robot.fire()

	if t > 26.0 and t < 30.0:
		robot.set_drive(0.0, 1.0, 0.0)       # spin in place on top of everything

	if t > 30.0:
		robot.set_drive(0.0, 0.0, 0.0)

	# --- watch for jitter only AFTER a real settling window. Sampling straight
	# after the spin just measures balls that are still honestly rolling.
	if t > 34.0:
		for e in get_tree().get_nodes_in_group("element"):
			var el: GameElement = e
			if el.held_by == null:
				worst_jitter = maxf(worst_jitter, el.linear_velocity.length() / BB.IN)

	if t > 37.0:
		_report()

func _report() -> void:
	var els := get_tree().get_nodes_in_group("element")
	_ok("elements still in the world", els.size(), 56)
	# the intake is always on and the robot has just driven over everything,
	# so this is a real test that it refuses NECTAR
	var bad := 0
	for e in robot.hopper:
		if (e as GameElement).kind != BB.Kind.POLLEN:
			bad += 1
	_ok("no NECTAR in the hopper (intake takes POLLEN only)", bad, 0)
	_ok("hopper within what the robot can physically hold", robot.hopper.size() <= BB.HOPPER_MAX, true)
	_ok("structures rammed", rammed >= 5, true)

	var under := 0
	var outside := 0
	var sky := 0
	for e in els:
		var el: GameElement = e
		if el.held_by != null:
			continue
		if el.fz() < -1.0:
			under += 1
		if absf(el.fx()) > BB.FIELD_HALF + 2.0 or absf(el.fy()) > BB.FIELD_HALF + 2.0:
			outside += 1
		if el.fz() > 80.0:
			sky += 1
	_ok("elements under the tiles", under, 0)
	_ok("elements outside the perimeter", outside, 0)
	_ok("elements stuck above the field", sky, 0)
	_ok("worst residual jitter under 4 in/s", worst_jitter < 4.0, true)

	_ok("robot inside the perimeter",
		absf(robot.fx()) < BB.FIELD_HALF and absf(robot.fy()) < BB.FIELD_HALF, true)
	_ok("robot above the tiles", robot.global_position.y > BB.m(-1.0), true)
	_ok("robot upright", robot.global_transform.basis.y.dot(Vector3.UP) > 0.5, true)

	# a closed CELL must only ever hold what came in through its mouth
	for a in main.field.hives:
		var h: Hive = main.field.hives[a]
		_ok("%s down-cell is empty (it dumped its load)" % BB.alliance_name(a),
			_down_cell_count(h) == 0, true)

	print("\n%s  (%d failures)  worst jitter %.2f in/s" % [
		"NOTHING GLITCHED" if fails == 0 else "GLITCHES FOUND", fails, worst_jitter])
	get_tree().quit(1 if fails > 0 else 0)

func _down_cell_count(h: Hive) -> int:
	var down: Area3D = h.cell_b if h.up_cell() == h.cell_a else h.cell_a
	var n := 0
	for b in down.get_overlapping_bodies():
		if b is GameElement and not (b as GameElement).held_by:
			n += 1
	return n
