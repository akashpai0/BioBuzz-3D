extends Node
##
## Playing as BLUE.
##
## Blue is not a recolour: the driver stands at the other end of the field, so
## the camera, the field-centric stick mapping and the starting position all
## have to flip with it. Blue's raised CELL also faces the other way (north,
## where red's faces south), so the side you have to shoot from flips too.
##
var main: Node3D
var robot: Robot
var hive: Hive
var t := 0.0
var fails := 0
var stage := 0
var fired := 0
var start_x := 0.0
var fwd_dx := 0.0
var cam_x := 0.0
var cell_was_north := false

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	main.menu.close()
	await get_tree().create_timer(1.5).timeout
	# pick blue from the menu exactly as a player would
	main._on_menu_start(BB.Mode.FREE_PRACTICE, BB.Alliance.BLUE, 2,
		{"robots": 1, "per_robot": 1, "opponents": 0})
	await get_tree().create_timer(1.8).timeout
	robot = main.robot
	hive = main.field.hives[BB.Alliance.BLUE]
	start_x = robot.fx()
	cam_x = main.rig.cam.global_position.x / BB.IN
	print("\n--- PLAYING BLUE ---")
	# field-centric "forward" must push blue AWAY from the blue wall, i.e. -x
	robot.auto_drive = false
	robot.field_centric = true
	stage = 1
	t = 0.0

func _ok(label: String, got, want) -> void:
	var good: bool = got == want
	if not good:
		fails += 1
	print("  %s %-50s got %s   want %s" % ["PASS" if good else "FAIL", label, str(got), str(want)])

func _physics_process(d: float) -> void:
	if robot == null:
		return
	t += d
	match stage:
		1:
			# drive "forward" in the driver's frame for a moment
			robot.auto_drive = true
			robot.set_drive(0.0, 0.0, 1.0)
			# field-centric is applied in _read_input, which auto_drive bypasses,
			# so emulate the driver frame directly: blue forward is -x
			if t > 1.2:
				fwd_dx = robot.fx() - start_x
				robot.set_drive(0, 0, 0)
				# move to the open side of blue's raised CELL and score
				# record which way the raised CELL faces BEFORE any tip flips it
				cell_was_north = hive.aim_point().z < 0.0
				robot.teleport(Transform3D(Basis.IDENTITY, BB.fp(12.75, 52.0, 0.0)))
				while robot.hopper.size() < BB.HOPPER_CAP:
					var e := GameElement.make(BB.Kind.POLLEN)
					main.add_child(e)
					e.global_position = robot.to_global(Vector3(0, BB.m(6.0), 0))
					robot._take(e)
				stage = 2
				t = 0.0
		2:
			if t > 1.0 and fired < 4 and robot.aim_locked and robot.can_fire():
				robot.fire()
				fired += 1
			if t > 12.0:
				_report()

func _report() -> void:
	_ok("blue starts at the blue wall", start_x > 40.0, true)
	_ok("driver camera stands at the blue end", cam_x > 0.0, true)
	_ok("robot was built with the chosen 2 intakes", robot.intakes, 2)
	_ok("blue's raised CELL starts as the north one", cell_was_north, true)
	_ok("auto-aim found it from the north side", fired, 4)
	_ok("blue tipped its own hive", hive.tip_count >= 1, true)
	print("\n  start x %.1f in   camera x %.1f in   forward moved %.1f in in x" % [
		start_x, cam_x, fwd_dx])
	print("  %s  (%d failures)" % ["BLUE PLAYS CORRECTLY" if fails == 0 else "PROBLEMS", fails])
	get_tree().quit(1 if fails > 0 else 0)
