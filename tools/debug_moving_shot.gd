extends Node
## Shots taken ON THE MOVE. fire() adds the robot's velocity to the ball, so
## without lead compensation a shot taken while driving drifts off target. Each
## case drives in a different direction relative to the CELL and empties the
## hopper while moving.
var main: Node3D
var robot: Robot
var hive: Hive
var t := 0.0
var idx := 0
var fired := 0
var hits := 0
var shots := 0
var busy := false
var fire_speed := 0.0

## Each case starts far enough back that the whole burst stays in range — a
## robot driving AT the cell runs into the "too close, no arc clears the roof"
## zone, which is correct behaviour but leaves nothing to measure.
const CASES := [
	{"n": "strafing right", "d": Vector3(1, 0, 0), "y": -56.0},
	{"n": "strafing left", "d": Vector3(-1, 0, 0), "y": -56.0},
	{"n": "driving at it", "d": Vector3(0, 0, 0.42), "y": -70.0},
	{"n": "backing away", "d": Vector3(0, 0, -1), "y": -50.0},
	{"n": "diagonal", "d": Vector3(0.7, 0, 0.42), "y": -68.0},
]

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	main.menu.close()
	main.mm.mode = BB.Mode.FREE_PRACTICE
	await get_tree().create_timer(1.8).timeout
	robot = main.robot
	hive = main.field.hives[BB.Alliance.RED]
	main.mm.start()
	robot.auto_drive = true
	robot.field_centric = false
	for e in hive.up_cell_elements():
		e.queue_free()
	print("\n--- SHOOTING ON THE MOVE ---")
	_go()

func _go() -> void:
	if idx >= CASES.size():
		var pct := 100.0 * float(hits) / maxf(float(shots), 1.0)
		print("\n  %d of %d shots entered while moving  (%.0f%%)" % [hits, shots, pct])
		print("  %s" % ("PASS" if pct >= 90.0 else "FAIL - lead compensation is off"))
		get_tree().quit(0 if pct >= 90.0 else 1)
		return
	busy = true
	robot.set_drive(0, 0, 0)
	robot.teleport(Transform3D(Basis.IDENTITY, BB.fp(-12.75, CASES[idx]["y"], 0.0)))
	for e in hive.up_cell_elements():
		e.queue_free()
	while robot.hopper.size() < BB.HOPPER_CAP:
		var e := GameElement.make(BB.Kind.POLLEN)
		main.add_child(e)
		e.global_position = robot.to_global(Vector3(0, BB.m(6.0), 0))
		robot._take(e)
	await get_tree().create_timer(0.6).timeout
	var c: Dictionary = CASES[idx]
	robot.set_drive(c["d"].x, 0.0, c["d"].z)
	fired = 0
	fire_speed = 0.0
	t = 0.0
	busy = false

func _physics_process(d: float) -> void:
	if robot == null or busy:
		return
	t += d
	# let it get up to speed first, then empty the hopper while still moving
	if t > 0.45 and fired < BB.HOPPER_CAP and t < 5.0:
		if robot.aim_locked and robot.can_fire():
			robot.fire()
			if fired == 0:
				fire_speed = robot.speed_in_s()
			fired += 1
			shots += 1
		return
	if t < 7.5:
		return
	robot.set_drive(0, 0, 0)
	var landed := hive.up_cell_elements().size()
	hits += landed
	var c: Dictionary = CASES[idx]
	print("  %-16s at %5.1f in/s   %d of %d in" % [c["n"], fire_speed, landed, maxi(fired, 1)])
	idx += 1
	_go()
