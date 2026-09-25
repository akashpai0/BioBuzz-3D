extends Node
## Renders the game under a virtual display and saves screenshots, so the UI can
## actually be looked at instead of assumed. Not part of the game.
var main: Node3D
var step := 0

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(2.5).timeout
	await _snap("menu")
	main.menu.close()
	main.rig.mode = CameraRig.Mode.DRIVER
	main.mm.mode = BB.Mode.TELEOP_ONLY
	main.mm.start()
	await get_tree().physics_frame
	main.robot.teleport(Transform3D(Basis.IDENTITY, BB.fp(-12.75, -50.0, 0.0)))
	# fill the hopper so the collected POLLEN is visible riding inside the frame
	while main.robot.hopper.size() < BB.HOPPER_CAP:
		var e := GameElement.make(BB.Kind.POLLEN)
		main.add_child(e)
		e.global_position = main.robot.to_global(Vector3(0, BB.m(6.0), 0))
		main.robot._take(e)
	await get_tree().create_timer(2.0).timeout
	await _snap("match")
	main.rig.mode = CameraRig.Mode.OVERHEAD
	await get_tree().create_timer(1.2).timeout
	await _snap("overhead")
	main.rig.mode = CameraRig.Mode.CHASE
	await get_tree().create_timer(1.5).timeout
	await _snap("chase")
	main.rig.mode = CameraRig.Mode.DRIVER
	main.robot.teleport(Transform3D(Basis(Vector3.UP, PI), BB.fp(-30.0, -40.0, 0.0)))
	await get_tree().create_timer(1.2).timeout
	await _snap("robot")

	# --- and the full house: two drivers plus an AI opponent, so the second
	# driver's strip and a contested field can both be looked at.
	main._on_menu_start(BB.Mode.TELEOP_ONLY, BB.Alliance.RED, 2,
		{"robots": 2, "per_robot": 1, "opponents": 1})
	await get_tree().create_timer(2.5).timeout
	main.rig.mode = CameraRig.Mode.DRIVER
	for r in main.robots:
		while r.hopper.size() < 3:
			var e2 := GameElement.make(BB.Kind.POLLEN)
			main.add_child(e2)
			e2.global_position = r.to_global(Vector3(0, BB.m(6.0), 0))
			r._take(e2)
	await get_tree().create_timer(1.5).timeout
	await _snap("coop")
	main.rig.mode = CameraRig.Mode.OVERHEAD
	await get_tree().create_timer(1.2).timeout
	await _snap("coop_overhead")
	get_tree().quit()

func _snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://_shots/%s.png" % name)
	print("saved %s  %dx%d" % [name, img.get_width(), img.get_height()])
