extends Node
## Renders the results screen and the robot screen so they can be looked at.
var main: Node3D
var fails := 0

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	main.menu.close()
	await get_tree().create_timer(2.0).timeout
	main._on_menu_start(BB.Mode.TELEOP_ONLY, BB.Alliance.RED, 1,
		{"robots": 1, "per_robot": 1, "opponents": 0})
	await get_tree().create_timer(2.0).timeout

	# a plausible finished match rather than a blank one
	var sc: Scoring = main.mm.scoring
	sc.leave = {BB.Alliance.RED: 2, BB.Alliance.BLUE: 1}
	sc.park_auto = {BB.Alliance.RED: 1, BB.Alliance.BLUE: 0}
	sc.park_teleop = {BB.Alliance.RED: 2, BB.Alliance.BLUE: 1}
	sc.tips = {BB.Alliance.RED: 5, BB.Alliance.BLUE: 3}
	sc.fouls_against = {BB.Alliance.RED: 0, BB.Alliance.BLUE: 10}
	var robot: Robot = main.robot
	main.mm.phase = BB.Phase.TELEOP
	var st: MatchStats = main.stats
	var d: Dictionary = st.per[robot]
	d["shots"] = 23; d["made"] = 17; d["collected"] = 31; d["tips"] = 5
	d["distance_in"] = 4100.0; d["top_speed"] = 66.4
	d["t_moving"] = 88.0; d["t_full"] = 21.5; d["t_empty"] = 14.0; d["t_over"] = 2.3
	d["shot_dist_total"] = 23 * 51.0
	d["cycles"] = [8.2, 7.1, 9.4, 6.8, 7.9]
	d["score_times"] = [10.0, 18.2, 25.3, 34.7, 41.5, 49.4]

	var b := sc.breakdown(main.field, true)
	var rp := {BB.Alliance.RED: sc.ranking_points(BB.Alliance.RED, b),
		BB.Alliance.BLUE: sc.ranking_points(BB.Alliance.BLUE, b)}
	main.results.show_result(b, rp, sc, [st.summary(robot)])

	for pg in 2:
		main.results._show_page(pg)
		await get_tree().create_timer(0.5).timeout
		await RenderingServer.frame_post_draw
		_snap("results_%d" % pg)
		_check(main.results._root, "results page %d" % pg)
	main.results.close()

	RobotShop.source = RobotShop.Source.MEASURED
	RobotShop.use_specs = true
	main.robot_menu.open()
	for pg in 4:
		main.robot_menu._show_page(pg)
		await get_tree().create_timer(0.5).timeout
		await RenderingServer.frame_post_draw
		_snap("robot_%d" % pg)
		_check(main.robot_menu._root, "robot page %d" % pg)
	RobotShop.source = RobotShop.Source.STOCK
	RobotShop.use_specs = false
	print("  %s  (%d failures)" % ["ALL SCREENS FIT" if fails == 0 else "CLIPPED", fails])
	get_tree().quit(1 if fails > 0 else 0)

func _snap(name: String) -> void:
	var win := DisplayServer.window_get_size()
	get_viewport().get_texture().get_image().save_png(
		"res://_shots/%s_%dx%d.png" % [name, win.x, win.y])

func _check(root: Control, what: String) -> void:
	var bad: Array[String] = []
	_walk(root, get_viewport().get_visible_rect(), bad)
	if bad.is_empty():
		print("  PASS %s" % what)
	else:
		fails += 1
		print("  FAIL %s — off screen: %s" % [what, ", ".join(bad)])

func _walk(n: Node, screen: Rect2, bad: Array[String]) -> void:
	for c in n.get_children():
		if c is Button and (c as Button).is_visible_in_tree():
			var b := c as Button
			var r := Rect2(b.global_position, b.size)
			if not screen.encloses(r):
				bad.append("%s @ %s" % [b.text if b.text != "" else b.name, str(r.position)])
		_walk(c, screen, bad)
