extends Node
##
## Two things: does a TWO-INTAKE robot really collect from behind, does a
## ONE-INTAKE robot really not, and does a ball that leaves the FIELD come back
## to a human player area instead of hanging in the air.
##
var main: Node3D
var robot: Robot
var t := 0.0
var fails := 0
var stage := 0
var rear_two := 0
var rear_one := 0
var out_ball: GameElement
var out_pos := Vector3.ZERO
var fouls_before := 0

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	main.menu.close()
	main.mm.mode = BB.Mode.FREE_PRACTICE
	await get_tree().create_timer(1.8).timeout
	main.mm.start()
	print("\n--- DUAL INTAKE AND OUT-OF-FIELD ---")
	_setup(2)

## Put a fresh robot with `n` intakes in a clear spot and drop POLLEN BEHIND it.
func _setup(n: int) -> void:
	main._build_robots(BB.Alliance.RED, n)
	robot = main.robot
	robot.auto_drive = true
	robot.set_drive(0, 0, 0)
	await get_tree().physics_frame
	robot.teleport(Transform3D(Basis.IDENTITY, BB.fp(-45.0, -30.0, 0.0)))
	for e in get_tree().get_nodes_in_group("element"):
		var el: GameElement = e
		if el.held_by == null and Vector2(el.fx() + 45.0, el.fy() + 30.0).length() < 30.0:
			el.queue_free()
	await get_tree().physics_frame
	# four POLLEN directly behind the robot (it faces +y, so behind is -y)
	for i in 4:
		var e := GameElement.make(BB.Kind.POLLEN)
		main.add_child(e)
		e.exited_field.connect(main.mm.on_element_left_field)
		e.global_position = BB.fp(-45.0 + float(i - 2) * 3.4, -41.0, 2.0)
	t = 0.0

func _ok(label: String, got, want) -> void:
	var good: bool = got == want
	if not good:
		fails += 1
	print("  %s %-52s got %s   want %s" % ["PASS" if good else "FAIL", label, str(got), str(want)])

func _physics_process(d: float) -> void:
	if robot == null:
		return
	t += d
	match stage:
		0:      # two intakes: back into the pile
			robot.set_drive(0, 0, -0.5)
			if t > 3.5:
				rear_two = robot.hopper.size()
				stage = 1
				_setup(1)
		1:      # one intake: same manoeuvre, should collect nothing
			robot.set_drive(0, 0, -0.5)
			if t > 3.5:
				rear_one = robot.hopper.size()
				robot.set_drive(0, 0, 0)
				stage = 2
				t = 0.0
				fouls_before = main.mm.scoring.fouls_against[BB.Alliance.RED]
				# fling a ball clean out of the arena
				out_ball = GameElement.make(BB.Kind.POLLEN)
				main.add_child(out_ball)
				out_ball.exited_field.connect(main.mm.on_element_left_field)
				out_ball.global_position = BB.fp(0.0, 0.0, 30.0)
				out_ball.apply_central_impulse(Vector3(9.0, 3.0, 0.0) * out_ball.mass)
		2:
			# the human player takes a couple of seconds to walk it back now,
			# so this waits longer than the old instant teleport needed
			if t > 9.0:
				out_pos = out_ball.global_position
				_report()

func _report() -> void:
	_ok("two intakes collect from behind", rear_two >= 3, true)
	_ok("one intake does not collect from behind", rear_one, 0)
	var x := out_pos.x / BB.IN
	var y := -out_pos.z / BB.IN
	var z := out_pos.y / BB.IN
	var lz := BB.loading_zone(BB.Alliance.RED if x < 0.0 else BB.Alliance.BLUE)
	_ok("returned ball is inside the field", absf(x) < BB.FIELD_HALF and absf(y) < BB.FIELD_HALF, true)
	_ok("returned to a LOADING ZONE (human player area)", BB.rect_has(lz, x, y), true)
	_ok("returned ball is on the tiles, not hanging in the air", z < 6.0, true)
	_ok("leaving the field cost a MINOR foul",
		main.mm.scoring.fouls_against[BB.Alliance.RED] - fouls_before, BB.FOUL_MINOR)
	print("\n  rear pickup: two-intake %d, one-intake %d" % [rear_two, rear_one])
	print("  returned to (%.1f, %.1f) at %.1f in high" % [x, y, z])
	print("  %s  (%d failures)" % ["OK" if fails == 0 else "PROBLEMS", fails])
	get_tree().quit(1 if fails > 0 else 0)
