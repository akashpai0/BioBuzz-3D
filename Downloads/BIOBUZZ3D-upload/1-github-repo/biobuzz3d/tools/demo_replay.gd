extends Node
## THE REPLAY WORKFLOW, RENDERED.
##
## Not a test: a filmed walk through the feature exactly as a player uses it,
## with scripted input standing in for the player:
##   play an attempt -> Watch replay -> find the shot in the events ->
##   jump 3 s earlier -> Practise from here -> Start practising -> Retry
## plus stills of the library, its dialogs and its empty state.
##
## Run under xvfb with --fixed-fps 30 so every frame is exactly 1/30 s of game
## and playback time, whatever the software renderer's real speed:
##   xvfb-run godot --path . --resolution 1600x900 --fixed-fps 30 tools/demo_replay.tscn
## Frames go to _shots/demo_replay/ (JPEG, every 2nd frame = 15 fps) and
## stills to _shots/replay_*.png.

var main: Node3D
var _goal := Vector2.INF
var _cap: Label
var _cap_sub: Label
var _frame := 0
var _film := false
var _fire_when_locked := false
const FRAMES := "res://_shots/demo_replay"
const EVERY := 2

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(2.5).timeout
	var dir := ProjectSettings.globalize_path("user://replay_demo")
	DirAccess.make_dir_recursive_absolute(dir)
	var da := DirAccess.open(dir)
	for f in da.get_files():
		DirAccess.remove_absolute(dir.path_join(f))
	var prev := ReplayStore._config()
	ReplayStore.set_folder(dir)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FRAMES))
	var fd := DirAccess.open(ProjectSettings.globalize_path(FRAMES))
	for f2 in fd.get_files():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(FRAMES).path_join(f2))
	_caption_layer()
	RenderingServer.frame_post_draw.connect(_on_drawn)

	# ---- the empty library, first
	main.goto("Progress")
	main.progress.show_replays()
	await _frames(4)
	await _still("replay_library_empty")
	main.goto("Play")

	var sid := await _situation()
	# ============================================ 1. play an attempt
	_film = not OS.get_cmdline_user_args().has("stills")
	_say("1 · Play an attempt", "Objective: 1 made shot in 10 s. Scripted driver: straight across the opponent's lane, shot fired early.")
	await main.play_situation(sid)
	main.rig.mode = CameraRig.Mode.DRIVER
	_goal = Vector2(-26, 8)
	await _sim(3.2)
	main.robot._cooldown = 0.0
	main.robot.fire()
	_goal = Vector2(-40, 20)
	var guard := 0
	while not main.attempt_results.is_open() and guard < 600:
		await _frames(1)
		guard += 1
	_goal = Vector2.INF
	await _frames(20)
	await _still("replay_attempt_results")

	# ============================================ 2. watch it
	_say("2 · Watch replay", "The recording opens at the start. The field is posed from recorded samples; nothing is simulated.")
	main.attempt_results.watch_requested.emit()
	await _until(func() -> bool: return main.viewer.is_open(), 300)
	var v: ReplayViewer = main.viewer
	v.set_camera("overview")
	_key(KEY_SPACE)
	await _frames(60)
	_say("3 · Find the moment", "Events list: every shot, successful shot, tip, foul and phase change, with its recorded time.")
	_key(KEY_E)
	await _frames(45)
	await _still("replay_viewer_events")
	var shot_t := -1.0
	for ev in v.reader.events:
		if String(ev["type"]) == "shot":
			shot_t = float(ev["t"])
			break
	# click the event's "−3 s" button, as a player would
	for row in v._events_box.get_children():
		if row is HBoxContainer and row.get_child_count() == 2:
			var go := row.get_child(0) as Button
			if go.text.begins_with(ReplayViewer._clock(shot_t)):
				(row.get_child(0) as Button).pressed.emit()
				await _frames(30)
				_say("3 · Find the moment", "“−3 s”: jump to three seconds before the shot to see the lead-up.")
				(row.get_child(1) as Button).pressed.emit()
				break
	await _frames(20)
	v.set_speed(0.5)
	_key(KEY_SPACE)
	_say("4 · Choose an earlier moment", "Half speed from 3 s before the shot. Camera: follow P1 (a viewer setting, not part of the recording).")
	v.set_camera("follow:0")
	await _frames(60)
	await _still("replay_viewer_follow")
	_key(KEY_SPACE)
	v.set_camera("overview")
	v.set_speed(1.0)
	# scrub back a little by timeline click
	v.seek(maxf(0.0, shot_t - 2.6))
	await _frames(12)
	_say("5 · Practise from here", "Only complete recorded checkpoints can be practised from. Between them, the playhead snaps to the nearest one and says so.")
	_key(KEY_P)
	await _frames(75)
	await _still("replay_practise_card")
	# type a name
	var edit: LineEdit = null
	for c in v._modal_box.get_children():
		if c is LineEdit:
			edit = c
	if edit:
		edit.text = "Before the blocked lane"
		await _frames(10)
		edit.text_submitted.emit(edit.text)
	await _frames(60)
	await _still("replay_saved_card")
	_say("6 · Start practising", "The saved situation restores the recorded moment: poses, velocities, hoppers, opponent route and wait state.")
	var start_btn: Button = null
	for c2 in v._modal_box.get_children():
		if c2 is HBoxContainer:
			for b in c2.get_children():
				if b is Button and (b as Button).text.begins_with("Start practising"):
					start_btn = b
	if start_btn:
		start_btn.pressed.emit()
	await _until(func() -> bool: return not main.viewer.is_open() and main.mm.in_progress(), 300)
	main.rig.mode = CameraRig.Mode.DRIVER
	_goal = Vector2(-56, -36)
	await _sim(3.0)
	await _still("replay_practising")
	_goal = Vector2(-40, -44)
	await _sim(2.0)
	_say("7 · Retry", "Retry goes straight back to the saved moment — every time.")
	_goal = Vector2.INF
	await main.retry_situation()
	main.rig.mode = CameraRig.Mode.DRIVER
	await _sim(1.5)
	_goal = Vector2(-56, -36)
	await _sim(2.0)
	_goal = Vector2.INF
	_film = false
	_say("", "")
	main.menu.end_match.emit()
	await _frames(10)

	# ============================================ library stills
	var ids: Array = []
	for e in ReplayStore.list():
		ids.append(String(e["id"]))
	if ids.size() >= 2:
		ReplayStore.set_favorite(ids[-1], true)
		ReplayStore.set_tags(ids[-1], "lane, blocked")
		ReplayStore.set_title(ids[-1], "Blocked lane — first try")
	# an interrupted recording and a damaged one, so the states are visible
	main.recorder.debug_fail_after_blocks = 2
	await main.play_situation(sid)
	await _sim(4.0)
	main.menu.end_match.emit()
	main.recorder.debug_fail_after_blocks = -1
	await _frames(5)
	var bad := ReplayStore.recording_path("r-20260101-000000-0000")
	var f := FileAccess.open(bad, FileAccess.WRITE)
	f.store_string("not a replay")
	f.close()
	ReplayStore.write_meta("r-20260101-000000-0000", {"title": "Copied from a USB stick",
		"created": "2026-01-01T00:00:00", "created_local": "2026-01-01 00:00"})
	main.goto("Progress")
	main.progress.show_replays()
	await _frames(6)
	await _still("replay_library")
	var sc: ScrollContainer = main.progress._s["scroll"]
	sc.scroll_vertical = 100000
	await _frames(4)
	await _still("replay_library_bottom")
	sc.scroll_vertical = 0
	main.progress.replays.selected = {}
	for id in ids.slice(0, 2):
		main.progress.replays.selected[String(id)] = true
	main.progress.refresh()
	await _frames(3)
	main.progress.replays.confirm_delete(main.progress.replays.selected.keys())
	await _frames(6)
	await _still("replay_delete_confirm")
	for c3 in main.progress.get_children():
		if c3 is ConfirmationDialog:
			(c3 as ConfirmationDialog).hide()
			c3.queue_free()
	main.progress.replays.selected = {}
	main.progress.replays._folder_chosen("/home/player/Videos/BIOBUZZ replays")
	await _frames(6)
	await _still("replay_folder_dialog")
	for c4 in main.progress.get_children():
		if c4 is AcceptDialog:
			(c4 as AcceptDialog).hide()
			c4.queue_free()
	# a paused run behind the library
	main.goto("Play")
	await main.play_situation(sid)
	await _sim(1.0)
	main._open_pause_menu()
	main.goto("Progress")
	main.progress.show_replays()
	await _frames(6)
	await _still("replay_suspended")
	main.menu.end_match.emit()
	await _frames(4)

	# a match results card, finished quickly
	main.goto("Play")
	await main._on_menu_start(BB.Mode.TELEOP_ONLY, BB.Alliance.RED, 1,
		{"robots": 1, "mate_is_ai": false, "per_robot": 1, "opponents": 1, "takes_nectar": false})
	await _sim(1.0)
	main.mm.time_left = 0.5
	await _until(func() -> bool: return main.results.is_open(), 600)
	await _frames(10)
	await _still("replay_match_results")

	ReplayStore._write_json_atomic(ReplayStore.CONFIG, prev)
	ReplayStore.reload_folder()
	print("DEMO DONE: %d frames" % (_frame / EVERY))
	get_tree().quit()

# ================================================================== helpers ==

func _situation() -> String:
	for e in ScenarioLibrary.list_all():
		if String(e["name"]) == "Replay demo: blocked lane":
			ScenarioLibrary.delete_one(String(e["id"]))
	await main._create_scenario("staged")
	var d: ScenarioDraft = main.editor.draft
	d.set_scenario("mode", BB.Mode.TELEOP_ONLY)
	d.set_scenario("phase", BB.Phase.TELEOP)
	d.set_scenario("time_left", 120.0)
	d.set_position("robot:0", Vector3(-62, 4, 0.0))
	var id := d.add_robot(BB.Alliance.BLUE, true)
	d.set_position(id, Vector3(-30, -30, 0.0))
	d.set_opponent(id, "behavior", OpponentConfig.Behavior.ROUTE)
	var c: Dictionary = d.opponent(id)
	c["waypoints"] = [{"x": -30.0, "y": -30.0, "wait": 0.5}, {"x": -30.0, "y": 36.0, "wait": 0.5}]
	c["route_mode"] = float(OpponentConfig.RouteMode.BACK_AND_FORTH)
	d.set_objective("kind", Objective.Kind.SHOTS)
	d.set_objective("amount", 1)
	d.set_objective("time_limit", 10.0)
	var snap := d.to_snapshot()
	main.editor.close()
	main.mm.abort()
	BB.editing = false
	return ScenarioLibrary.save(snap, "Replay demo: blocked lane", "demo")

func _physics_process(_d: float) -> void:
	if main == null or BB.frozen() or BB.halted or not is_instance_valid(main.robot):
		return
	if _goal == Vector2.INF:
		return
	var me: Robot = main.robot
	me.auto_drive = true
	var loc := me.to_local(BB.fp(_goal.x, _goal.y, 0.0))
	var f := Vector2(loc.x, loc.z)
	if f.length() < BB.m(5.0):
		me.set_drive(0, 0, 0)
		return
	f = f.normalized() * 0.75
	me.set_drive(f.x, clampf(-atan2(loc.x, -loc.z), -0.5, 0.5), -f.y)

func _key(k: int) -> void:
	var ev := InputEventKey.new()
	ev.keycode = k
	ev.physical_keycode = k
	ev.pressed = true
	Input.parse_input_event(ev)
	var up := ev.duplicate()
	up.pressed = false
	Input.parse_input_event(up)

func _on_drawn() -> void:
	if not _film:
		return
	_frame += 1
	if _frame % EVERY != 0:
		return
	var img := get_viewport().get_texture().get_image()
	img.resize(1280, 720, Image.INTERPOLATE_BILINEAR)
	img.save_jpg(ProjectSettings.globalize_path(FRAMES).path_join("f%05d.jpg" % (_frame / EVERY)), 0.88)

func _frames(n: int) -> void:
	for i in n:
		await RenderingServer.frame_post_draw

## Simulated seconds of live play (works because --fixed-fps pins each frame).
func _sim(t: float) -> void:
	var start := BB.sim_now()
	var guard := 0
	while BB.sim_now() - start < t and guard < 3000:
		await RenderingServer.frame_post_draw
		guard += 1

func _until(cond: Callable, max_frames: int) -> void:
	var n := 0
	while not cond.call() and n < max_frames:
		await RenderingServer.frame_post_draw
		n += 1

func _still(name: String) -> void:
	# stills show the game alone; captions are for the film
	var cap_panel := _cap.get_parent().get_parent() as Control
	var was := cap_panel.visible
	cap_panel.visible = false
	var filming := _film
	_film = false
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
		ProjectSettings.globalize_path("res://_shots/%s.png" % name))
	print("still: ", name)
	cap_panel.visible = was
	_film = filming

func _caption_layer() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 90
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(layer)
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.72)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	p.add_theme_stylebox_override("panel", sb)
	p.anchor_left = 0.5
	p.anchor_right = 0.5
	p.offset_left = -430
	p.offset_right = 430
	p.offset_top = 300
	p.name = "Caption"
	layer.add_child(p)
	var vb := VBoxContainer.new()
	p.add_child(vb)
	_cap = Label.new()
	_cap.add_theme_font_size_override("font_size", 26)
	_cap.add_theme_color_override("font_color", Gui.ACCENT)
	_cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_cap)
	_cap_sub = Label.new()
	_cap_sub.add_theme_font_size_override("font_size", 16)
	_cap_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_cap_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_cap_sub.custom_minimum_size = Vector2(820, 0)
	vb.add_child(_cap_sub)
	p.visible = false

func _say(t: String, sub: String) -> void:
	_cap.text = t
	_cap_sub.text = sub
	(_cap.get_parent().get_parent() as Control).visible = t != "" and _film
