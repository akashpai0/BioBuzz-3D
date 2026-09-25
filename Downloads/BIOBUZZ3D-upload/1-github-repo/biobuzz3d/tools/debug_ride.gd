extends Node
## Drives the robot straight through a field of loose POLLEN and watches its
## ride height. This is the levitation bug: with the suspension raycasts able to
## hit elements, driving over a ball read as a huge spring compression and threw
## the robot into the air, after which the drivetrain stopped working.
var main: Node3D
var robot: Robot
var t := 0.0
var max_h := -99.0
var min_wheels := 9

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
	robot.teleport(Transform3D(Basis.IDENTITY, BB.fp(-40.0, -60.0, 0.0)))
	# a carpet of pollen straight down the lane the robot is about to drive
	for i in 26:
		var e := GameElement.make(BB.Kind.POLLEN)
		main.add_child(e)
		e.global_position = BB.fp(-40.0 + float(i % 3 - 1) * 5.0,
			-50.0 + float(i) * 3.5, 2.0)
	await get_tree().create_timer(0.6).timeout
	robot.set_drive(0.0, 0.0, 1.0)
	print("\n--- RIDE HEIGHT OVER LOOSE POLLEN ---")

func _physics_process(d: float) -> void:
	if robot == null:
		return
	t += d
	if t < 0.5:
		return
	var h := robot.global_position.y / BB.IN
	max_h = maxf(max_h, h)
	var on := 0
	for l in robot.wheel_loads():
		if l > 1.0:
			on += 1
	min_wheels = mini(min_wheels, on)
	if fmod(t, 1.0) < d:
		print("  t=%4.1f  chassis %5.2f in   wheels loaded %d   speed %5.1f in/s" % [
			t, h, on, robot.speed_in_s()])
	if t > 7.0:
		print("\n  max chassis height %.2f in (start 0.00)   fewest wheels loaded %d" % [
			max_h, min_wheels])
		var ok := max_h < 4.0 and min_wheels >= 2
		print("  %s" % ("PASS - stays on its wheels" if ok else "FAIL - levitating"))
		get_tree().quit(0 if ok else 1)
