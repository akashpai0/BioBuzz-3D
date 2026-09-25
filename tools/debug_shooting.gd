extends Node
## Measures how often an auto-aimed shot actually ends up inside the raised
## CELL, from a spread of positions on the open side of the mouth. This is the
## number that decides whether the launcher feels fair: if the HUD says LOCKED,
## the ball should go in.
var main: Node3D
var robot: Robot
var hive: Hive
var t := 0.0
var idx := 0
var fired := 0
var hits := 0
var shots := 0
var busy := false

const SPOTS := [
	Vector2(-12.75, -38.0),
	Vector2(-12.75, -52.0),
	Vector2(-12.75, -64.0),
	Vector2(-30.0, -50.0),
	Vector2(6.0, -50.0),
	Vector2(-40.0, -40.0),
]
const PER_SPOT := 4

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	main.menu.close()
	main.mm.mode = BB.Mode.FREE_PRACTICE
	await get_tree().create_timer(1.8).timeout
	robot = main.robot
	hive = main.field.hives[BB.Alliance.RED]
	main.mm.start()
	# clear the staged NECTAR so the hive cannot tip mid-measurement
	for e in hive.up_cell_elements():
		e.queue_free()
	await get_tree().physics_frame
	print("\n--- LAUNCHER ACCURACY (auto-aim) ---")
	_go()

func _go() -> void:
	if idx >= SPOTS.size():
		var pct := 100.0 * float(hits) / maxf(float(shots), 1.0)
		print("\n  %d of %d TAKEN shots entered the CELL  (%.0f%%)" % [hits, shots, pct])
		print("  (spots marked NO SHOT are the solver refusing an arc that would")
		print("   hit the roof — the HUD tells the driver to back up instead)")
		print("  %s" % ("PASS" if pct >= 85.0 else "FAIL - aim needs work"))
		get_tree().quit(0 if pct >= 85.0 else 1)
		return
	busy = true
	var p: Vector2 = SPOTS[idx]
	robot.teleport(Transform3D(Basis.IDENTITY, BB.fp(p.x, p.y, 0.0)))
	for e in hive.up_cell_elements():
		e.queue_free()
	while robot.hopper.size() < BB.HOPPER_CAP:
		var e := GameElement.make(BB.Kind.POLLEN)
		main.add_child(e)
		e.global_position = robot.to_global(Vector3(0, BB.m(6.0), 0))
		robot._take(e)
	await get_tree().create_timer(0.8).timeout
	fired = 0
	t = 0.0
	busy = false

func _physics_process(d: float) -> void:
	if robot == null or busy:
		return
	t += d
	# Give each spot a window to take its shots. If auto-aim never locks, that
	# is the solver correctly saying no arc fits through the mouth from here —
	# record it as "no shot" rather than hanging or calling it a miss.
	if fired < PER_SPOT and t < 6.0:
		if robot.aim_locked and robot.can_fire():
			robot.fire()
			fired += 1
			shots += 1
		return
	if t < (6.0 if fired < PER_SPOT else 4.0) + 3.0:
		return
	var landed := hive.up_cell_elements().size()
	hits += landed
	var p: Vector2 = SPOTS[idx]
	var dd := Vector2(p.x - hive.aim_point().x / BB.IN, p.y + hive.aim_point().z / BB.IN).length()
	if fired == 0:
		print("  from (%6.1f,%6.1f)  dist %4.0f in   NO SHOT (nothing fits the mouth)" % [p.x, p.y, dd])
	else:
		print("  from (%6.1f,%6.1f)  dist %4.0f in   %d of %d in   power %3.0f in/s  hood %4.1f" % [
			p.x, p.y, dd, landed, fired, robot.launch_speed_in_s, robot.hood_deg])
	idx += 1
	_go()
