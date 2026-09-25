extends Node
## Exercises GUI-local pointer coordinates and real Escape dispatch, not just
## draft setters. Run with an isolated APPDATA and a real render window.
var main: Node3D
var fails := 0
var checks := 0

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		fails += 1
	print("%s %s" % ["PASS" if ok else "FAIL", label])

func frames(n := 4) -> void:
	for i in n:
		await get_tree().process_frame

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Leaderboard.set_player_name("UI repair check")
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(2.0).timeout
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
	var args := OS.get_cmdline_user_args()
	var width := int(args[0]) if args.size() > 0 else 1920
	var height := int(args[1]) if args.size() > 1 else 1080
	DisplayServer.window_set_size(Vector2i(width, height))
	await frames(10)
	main.menu._mode_buttons[0].grab_focus()
	await frames()
	for look in Gui.Look.values():
		var b := Gui.button("Check", look)
		var focus := b.get_theme_stylebox("focus") as StyleBoxFlat
		var contained := true
		for side in [SIDE_LEFT, SIDE_RIGHT, SIDE_TOP, SIDE_BOTTOM]:
			contained = contained and focus.get_expand_margin(side) <= -1.0
		check("focus stays inside style %s" % look, contained)
		check("focus does not repaint style %s" % look, not focus.draw_center)
		b.free()
	await capture("play")
	var preview: RobotPreview = main.menu._preview
	var px := preview._texture.size * Vector2(preview._texture.get_screen_transform().x.length(),
		preview._texture.get_screen_transform().y.length())
	var display_scale := minf(px.x / 760.0, px.y / 460.0)
	check("preview renders at displayed pixel density",
		preview._vp.size.x >= floori(760.0 * display_scale))
	check("UI uses native canvas rendering", get_window().content_scale_mode == Window.CONTENT_SCALE_MODE_CANVAS_ITEMS)
	print("DISPLAY ", DisplayServer.window_get_size(), " canvas ", get_viewport().get_visible_rect().size)
	await main._create_scenario("empty")
	var ed: ScenarioEditor = main.editor
	ed._snap = false
	await frames()
	var gap: Rect2 = ed._centre.get_global_rect()
	for x in [-69.0, 69.0]:
		for y in [-69.0, 69.0]:
			var screen: Vector2 = ed._cam.unproject_position(BB.fp(x, y, 0.0))
			check("field corner visible %s %s" % [x,y], gap.has_point(screen))
	for top in [true, false]:
		ed._set_view(top)
		ed._zoom = 0.8
		ed._pan = Vector2(0.05, -0.08)
		ed._fit_view()
		await frames()
		# Clear floor positions; the angled camera must not be asked to select
		# an element hidden behind the solid HIVE.
		for point in [Vector3(-56, -56, 0), Vector3(56, -50, 0), Vector3(-58, 50, 0)]:
			ed._tool = ScenarioEditor.Tool.POLLEN
			var screen: Vector2 = ed._cam.unproject_position(BB.fp(point.x, point.y, 0.0))
			var local: Vector2 = ed._centre.get_global_transform_with_canvas().affine_inverse() * screen
			var move := InputEventMouseMotion.new()
			move.position = local
			ed._on_field_input(move)
			var ghost: Vector3 = BB.to_field(ed._ghost.global_position)
			check("ghost under pointer top=%s point=%s" % [top, point], Vector2(ghost.x,ghost.y).distance_to(Vector2(point.x,point.y)) < 0.02)
			var press := InputEventMouseButton.new()
			press.button_index = MOUSE_BUTTON_LEFT
			press.pressed = true
			press.position = local
			ed._on_field_input(press)
			await frames(12)
			var pos: Vector3 = ed.draft.position_of(ed._selected)
			check("placed under pointer top=%s point=%s" % [top, point], Vector2(pos.x,pos.y).distance_to(Vector2(point.x,point.y)) < 0.02)
			var id: String = ed._selected
			var node: Node3D = ed._node_for(id)
			var pick_screen: Vector2 = ed._cam.unproject_position(node.global_position)
			press.position = ed._centre.get_global_transform_with_canvas().affine_inverse() * pick_screen
			ed._tool = ScenarioEditor.Tool.SELECT
			ed._selected = ""
			ed._on_field_input(press)
			check("select under pointer top=%s" % top, ed._selected == id)
			var destination: Vector3 = point + Vector3(3, 4, 0)
			var drag_world: Vector3 = BB.fp(destination.x, destination.y, 0.0) - ed._drag_offset
			move.position = ed._centre.get_global_transform_with_canvas().affine_inverse() * ed._cam.unproject_position(drag_world)
			ed._on_field_input(move)
			ed._release()
			var moved: Vector3 = ed.draft.position_of(id)
			check("drag follows pointer top=%s" % top, Vector2(moved.x,moved.y).distance_to(Vector2(destination.x,destination.y)) < 0.02)
			ed.draft.remove_object(id)
			await ed._sync_world()
	ed._set_view(true)
	# Leave a sample in the capture so the actual editable field is visible.
	ed.draft.add_element(BB.Kind.POLLEN, -1, Vector3(36, 36, ScenarioDraft.rest_height(BB.Kind.POLLEN)))
	await ed._sync_world()
	ed._selected = ""
	ed._refresh_all()
	await frames()
	await capture("editor")
	for phase in [BB.Phase.PRE, BB.Phase.TELEOP, BB.Phase.DONE]:
		ed.draft.set_scenario("phase", phase)
		ed.draft.set_scenario("time_left", 20.0 if phase == BB.Phase.TELEOP else 0.0)
		var before := JSON.stringify(ed.draft.data)
		await main._test_scenario(ed.draft.to_snapshot())
		await frames(5)
		var esc := InputEventKey.new()
		esc.keycode = KEY_ESCAPE
		esc.physical_keycode = KEY_ESCAPE
		esc.pressed = true
		Input.parse_input_event(esc)
		await frames(20)
		esc.pressed = false
		Input.parse_input_event(esc)
		check("Escape returns to editor in phase %s" % phase, ed.is_open() and not main.editor_return)
		check("Escape preserves draft in phase %s" % phase, JSON.stringify(ed.draft.data) == before)
	var bodies_frozen := true
	for r in main.robots:
		bodies_frozen = bodies_frozen and r.freeze
	for ball in get_tree().get_nodes_in_group("element"):
		bodies_frozen = bodies_frozen and ball.freeze
	check("editor return leaves world frozen", BB.editing and bodies_frozen)
	print("UI REPAIRS: %d checks, %d failures" % [checks, fails])
	get_tree().quit(0 if fails == 0 else 1)

func capture(label: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var path := "user://repair_%s_%s.png" % [label, DisplayServer.window_get_size().x]
	get_viewport().get_texture().get_image().save_png(path)
	print("CAPTURE ", ProjectSettings.globalize_path(path))
