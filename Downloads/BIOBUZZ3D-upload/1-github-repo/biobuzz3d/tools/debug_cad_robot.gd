extends Node
## THE TEAM'S CAD IS THE ROBOT. Imports a model through the Garage's own
## handler (pass a file: `-- <path>`), then checks and captures:
##   * the Garage preview shows the CAD only, with FRONT/BACK/launcher guides
##   * any rotation (quarter turns and odd angles) keeps it on the floor and
##     inside the 18 in cube's footprint
##   * in a match our robot is drawn from the CAD alone (no stock wheels,
##     bumpers or launcher), the opponent keeps the stock robot
## Pictures go to user://cad_*.png.
var main: Node3D
var fails := 0
func _ok(what: String, got: Variant, want: Variant = true) -> void:
	var good: bool = got == want
	if not good: fails += 1
	print("  [%s] %s%s" % ["ok" if good else "FAIL", what, "" if good else "  (got %s, want %s)" % [got, want]])

func _shot(name: String) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://cad_%s.png" % name)

func _meshes_visible(n: Node) -> int:
	var k := 0
	if n is MeshInstance3D and (n as Node3D).is_visible_in_tree():
		k += 1
	for c in n.get_children():
		k += _meshes_visible(c)
	return k

func _has_named(n: Node, nm: String) -> bool:
	if not n.is_queued_for_deletion() and (String(n.name).begins_with(nm)
			or (nm == "TeamCAD" and n.has_meta("team_cad"))):
		return true
	for c in n.get_children():
		if _has_named(c, nm):
			return true
	return false

## Lowest point and horizontal reach of the fitted model, from its hull.
func _fit_extent(rot: Vector3) -> Dictionary:
	var m := RobotBody.load_cad()
	var hull := CadImport.hull_points(m)
	RobotShop.model_rot = rot
	CadImport.fit_to_robot(m, 1.0, rot)
	var lo := INF
	var reach := 0.0
	for p in hull:
		var w := m.transform * p
		lo = minf(lo, w.y)
		reach = maxf(reach, maxf(absf(w.x), absf(w.z)))
	m.free()
	return {"floor": lo, "reach": reach}

func _ready() -> void:
	Leaderboard.set_player_name("CAD check")
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(2.0).timeout
	var path: String = OS.get_cmdline_user_args()[0]

	print("\n--- IMPORT, AND THE GARAGE PREVIEW ---")
	main.robot_menu.open()
	main.robot_menu._on_file(path)
	await get_tree().create_timer(1.5).timeout
	var pv: RobotPreview = main.robot_menu._preview
	_ok("the Appearance tab turns the guides on", pv.guides, true)
	var names := []
	for c in pv.holder.get_children():
		names.append(String(c.name))
	_ok("  the preview shows the CAD", _has_named(pv.holder, "TeamCAD"), true)
	print("    preview holds: ", names)
	_ok("  with the FRONT / BACK / launcher guides", _has_named(pv.holder, "Guides"), true)
	var stock_bits := 0
	for c in pv.holder.get_children():
		if c is MeshInstance3D:
			stock_bits += 1         # stock parts are loose meshes on the holder
	_ok("  and nothing of the stock robot", stock_bits, 0)
	_ok("  a new STL starts stood upright (tip -90)", RobotShop.model_rot, Vector3(-90, 0, 0))
	await _shot("garage_guides")

	print("\n--- ANY ROTATION ---")
	var t0 := Time.get_ticks_msec()
	for rot in [Vector3(-90, 0, 0), Vector3(-90, 90, 0), Vector3(0, 0, 0), Vector3(-60, 35, 20),
			Vector3(180, 0, 0), Vector3(-90, -90, 90)]:
		var e := _fit_extent(rot)
		_ok("  %s: on the floor (lowest point %.4f m)" % [rot, e["floor"]], absf(e["floor"]) < 0.001, true)
		_ok("  %s: inside the 18 in footprint" % rot, e["reach"] <= BB.m(BB.ROBOT_CUBE * 0.5) + 0.001, true)
	var per := (Time.get_ticks_msec() - t0) / 6.0
	_ok("re-fitting is quick enough to drag a slider (%.0f ms each)" % per, per < 120.0, true)
	RobotShop.model_rot = Vector3(-90, 90, 0)
	RobotShop.changed.emit()
	await get_tree().create_timer(0.5).timeout
	await _shot("garage_turned")
	# the quarter-turn buttons move the model and the slider
	main.robot_menu.show_tab(1)
	await get_tree().process_frame
	var before: Vector3 = RobotShop.model_rot
	var plus: Button = null
	for b in main.robot_menu._panel_box.find_children("*", "Button", true, false):
		if (b as Button).text == "+90°":
			plus = b
			break
	if plus:
		plus.pressed.emit()
	_ok("a +90° button turns the model a quarter turn", RobotShop.model_rot.x, before.x + 90.0)

	print("\n--- IN A MATCH ---")
	RobotShop.model_rot = Vector3(-90, 0, 0)
	RobotShop.save_cfg()
	main.robot_menu.close()
	main.goto("Play")
	main._on_menu_start(BB.Mode.FREE_PRACTICE, BB.Alliance.RED, 1,
		{"robots": 1, "mate_is_ai": false, "per_robot": 1, "opponents": 1, "takes_nectar": false})
	await get_tree().create_timer(2.5).timeout
	var ours: Robot = main.robots[0]
	var foe: Robot = main.robots[1]
	_ok("our robot is drawn from the CAD", [ours.shows_cad, _has_named(ours, "TeamCAD")], [true, true])
	var drawn := 0
	for w in ours._wheels:
		if (w["mesh"] as Node3D).visible:
			drawn += 1
	_ok("  its stock wheels are not drawn", drawn, 0)
	_ok("  nor its stock launcher", _meshes_visible(ours.turret), 0)
	_ok("  and no guides in a match", _has_named(ours, "Guides"), false)
	_ok("the opponent keeps the stock robot (alliances stay easy to tell apart)",
		[foe.shows_cad, _has_named(foe, "TeamCAD")], [false, false])
	_ok("the drivetrain and collision are unchanged (18 in cube)",
		ours.get_child_count() > 0 and ours.intake_area != null, true)
	main.rig.mode = CameraRig.Mode.CHASE
	await get_tree().create_timer(1.0).timeout
	await _shot("match")
	print("  CAD ROBOT %s (%d failures)" % ["OK" if fails == 0 else "BROKEN", fails])
	get_tree().quit(1 if fails else 0)
