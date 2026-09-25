extends Node
## ONLINE PRACTICE, RENDERED — ON ONE MACHINE.
##
##   xvfb-run godot --path . --resolution 1280x720 tools/demo_online.tscn
##
## Not a test: a filmed walk through the feature as a player uses it. This
## process is computer 1 — the full game, rendered — and it HOSTS the room:
## its own world is the room's simulation, and its player drives with the
## keyboard. Computer 2 is a SEPARATE PROGRAM (tools/net_bot_proc.tscn) that
## joins with the invite and operates the same robot. Both on this one machine,
## connected by the same-network path on 127.0.0.1: this shows the feature
## working, it is not evidence about the internet (that path needs Epic
## credentials and a second connection — see ONLINE.md).
##
## The film runs in REAL TIME (networked play cannot be slowed down), so each
## captured frame is stored with its wall-clock time and the video is
## assembled at those times: software rendering gives a low frame rate, but
## nothing in the film is sped up or slowed down.
##
## Output: _shots/online_*.png stills, _shots/demo_online/ frames + times.txt

var main: Node3D
var net: NetClient
var host_pid := -1
var bot_pid := -1
var _film := false
var _frames := 0
var _t0 := 0
var _times: Array = []
var _cap: Label
var _cap_sub: Label
var _mark := Vector2.ZERO           # the objective's area centre, inches
const FRAMES := "res://_shots/demo_online"

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	_caption_layer()
	RenderingServer.frame_post_draw.connect(_on_drawn)
	var fd := ProjectSettings.globalize_path(FRAMES)
	DirAccess.make_dir_recursive_absolute(fd)
	for f in DirAccess.open(fd).get_files():
		DirAccess.remove_absolute(fd.path_join(f))
	await _wait(3.0)
	# software rendering in the recording container is slow: cheapest look
	# (no MSAA, no shadows, 3D drawn at 60 % and scaled up). Not saved.
	Settings.set_value("video/msaa", 0.0, false)
	Settings.set_value("video/shadows", 0.0, false)
	Settings.apply_all()
	get_viewport().scaling_3d_scale = 0.6
	net = main.net

	await _error_stills()
	await _player_view_still()
	await _film_session()

	print("DEMO DONE: %d frames over %.1f s" % [_frames, (Time.get_ticks_msec() - _t0) / 1000.0])
	var f := FileAccess.open(fd.path_join("times.txt"), FileAccess.WRITE)
	f.store_string("\n".join(_times))
	f.close()
	if host_pid > 0:
		OS.kill(host_pid)
	if bot_pid > 0:
		OS.kill(bot_pid)
	get_tree().quit(0)

# =============================================================== stills ====

func _error_stills() -> void:
	main.goto("Play")
	await _wait(1.0)
	await _still("online_play_card")
	main.menu.open_online.emit()
	await _wait(0.8)
	var os_: OnlineScreen = net.online_screen
	os_._name.text = "Julian"
	await _wait(0.5)
	await _still("online_screen")
	os_._invite.text = "K7PM-Q2XR"
	os_._join()
	await _wait(0.8)
	await _still("online_error_bad_invite")
	os_._msg.text = ""
	# this build has no Epic Online Services plugin: say so, plainly
	net.method = "internet"
	os_._refresh_how()
	await os_._host()
	await _wait(0.5)
	await _still("online_error_no_eos")
	os_._msg.text = ""
	net.method = "lan"
	os_._refresh_how()

## The lobby as a guest: another copy of the game hosts, "Coach Lee" is its host.
func _player_view_still() -> void:
	var f := ProjectSettings.globalize_path("user://demo_guest_invite.txt")
	if FileAccess.file_exists(f):
		DirAccess.remove_absolute(f)
	host_pid = OS.create_process(OS.get_executable_path(), ["--path",
		ProjectSettings.globalize_path("res://"), "--headless", "--", "--host-test",
		"--port", "17630", "--owner", "Coach Lee", "--invite-file", f])
	await _until(func() -> bool: return FileAccess.file_exists(f), 30.0)
	var inv := FileAccess.get_file_as_string(f).strip_edges()
	var own := NetBot.new("Coach Lee")
	own.join(inv)
	await _until_b([own], func() -> bool: return own.s.phase == "in_room", 20.0)
	own.s.send(NetProto.SET_SCENARIO, {"standard": "2v2_teleop"})
	await _until_b([own], func() -> bool: return own.s.scenario_rev >= 1, 20.0)
	own.s.send(NetProto.SEAT, {"robot": 1, "role": "whole"})
	var os_: OnlineScreen = net.online_screen
	os_._invite.text = inv
	os_._join()
	await _until_b([own], func() -> bool: return net.in_room() and net.session.scenario_rev >= 1, 20.0)
	await _pump([own], 1.5)
	net.send(NetProto.SEAT, {"robot": 0, "role": "driver"})
	await _pump([own], 1.5)
	await _still("online_lobby_guest")
	net.leave("done")
	own.s.leave()
	await _pump([own], 1.0)
	OS.kill(host_pid)
	host_pid = -1
	await _wait(1.0)

# ================================================================= film ====

## A saved situation to share: 2 v 2 (teammate and both opponents AI), with
## an objective for robot 1 — reach a mark 34 in ahead within 40 s.
func _make_situation() -> String:
	await main._create_scenario("staged")
	var d: ScenarioDraft = main.editor.draft
	d.set_scenario("mode", BB.Mode.FREE_PRACTICE)
	d.set_scenario("phase", BB.Phase.TELEOP)
	d.set_scenario("time_left", 120.0)
	d.add_robot(BB.Alliance.RED, true)
	d.add_robot(BB.Alliance.BLUE, true)
	d.add_robot(BB.Alliance.BLUE, true)
	var p0 := d.position_of("robot:0")
	d.set_objective("kind", Objective.Kind.REACH)
	d.set_objective("target", Objective.Target.ROBOT)
	d.set_objective("robot", 0)
	d.set_objective("time_limit", 40.0)
	_mark = Vector2(p0.x + 34.0, p0.y)
	d.set_area("x", p0.x + 34.0)
	d.set_area("y", p0.y)
	d.set_area("r", 14.0)
	var snap := d.to_snapshot()
	var id := ScenarioLibrary.save(snap, "Drive to the mark (2 v 2)", "Demo situation for online practice.")
	main.editor.closed.emit()
	await _wait(1.0)
	return id

func _film_session() -> void:
	var sit_id := await _make_situation()
	main.goto("Play")
	await _wait(0.5)
	_film = true
	_t0 = Time.get_ticks_msec()
	_say("Online practice", "Computer 1 (this screen) hosts: its own game runs the room. Computer 2 is a separate program on THIS machine — not the internet.")
	await _wait(2.5)
	main.menu.open_online.emit()
	var os_: OnlineScreen = net.online_screen
	os_._name.text = ""
	os_._room_name.text = ""
	await _wait(0.8)
	await _type(os_._name, "Julian")
	await _type(os_._room_name, "Pandara drive practice")
	await _wait(0.6)
	await _still("online_host")
	_press(os_._root, "Host room")
	await _until(func() -> bool: return net.in_room(), 30.0)
	await _wait(1.0)
	_say("An invite, not a server", "Copy it and send it to the team. Over the internet it points Epic's lobby lookup at this game; here it is a same-network address.")
	var code_file := ProjectSettings.globalize_path("user://demo_online_invite.txt")
	var fo := FileAccess.open(code_file + ".tmp", FileAccess.WRITE)
	fo.store_string(net.invite)
	fo.close()
	DirAccess.rename_absolute(code_file + ".tmp", code_file)
	bot_pid = OS.create_process(OS.get_executable_path(), ["--path",
		ProjectSettings.globalize_path("res://"), "--headless", "res://tools/net_bot_proc.tscn",
		"--", "--invite-file", code_file, "--seat", "0:operator",
		"--fire-every", "1.4", "--for", "120", "--name", "Maya (computer 2)",
		"--out", ProjectSettings.globalize_path("user://demo_online_bot.json")])
	await _until(func() -> bool: return (net.session.state.get("parts", []) as Array).size() >= 2, 20.0)
	await _wait(1.5)
	_say("Share a scenario", "The host shares a saved situation: 2 v 2 with AI teammate and opponents, and an objective. Every computer confirms the same revision.")
	var lob: LobbyScreen = net.lobby
	for i in lob._choices.size():
		if String(lob._choices[i][2]) == sit_id:
			lob._pick = i
	lob._rebuild(net.session.state)
	await _wait(1.0)
	_press(lob._root, "Use this")
	await _until(func() -> bool: return net.session.scenario_rev >= 1 and net._built_rev >= 1, 20.0)
	await _wait(2.0)
	_say("Choose roles", "Julian takes DRIVER on robot 1. Maya takes OPERATOR on the same robot. The server grants each seat — two people can never hold one role.")
	_press_prefix(lob._root, "Driver")
	await _until(func() -> bool:
		for sr in net.session.state.get("seats", []):
			if int(sr["robot"]) == 0 and int(sr["operator"]) >= 0 and int(sr["driver"]) >= 0:
				return true
		return false, 20.0)
	await _wait(2.5)
	await _still("online_lobby_owner")
	_say("Ready up", "The host can start once every seated player is ready.")
	_press(lob._root, "Ready")
	await _until(func() -> bool: return (net.session.state.get("blockers", ["x"]) as Array).is_empty(), 20.0)
	await _wait(1.5)
	_press_prefix(lob._root, "Start")
	_say("Shared countdown", "")
	await _until(func() -> bool: return net.room_state() == "countdown", 10.0)
	await _wait(1.0)
	await _still("online_countdown")
	await _until(func() -> bool: return net.room_state() == "running", 10.0)
	_say("Practise together", "Julian drives to the mark with his keyboard; Maya's program fires. One simulation, in the host's game. (This recording machine draws in software at a few frames a second.)")
	await _wait(1.5)
	await _still("online_hud_running")
	await _drive_to(_mark, 30.0)
	await _until(func() -> bool: return net.room_state() == "results", 12.0)
	await _wait(2.5)
	await _still("online_results")
	_say("Retry together", "Everyone gets the same result from the host's game. The host retries: the start is restored, old packets are ignored, every computer confirms, then one countdown.")
	await _wait(2.0)
	_press(net.hud._root, "Retry for everyone")
	await _until(func() -> bool: return net.room_state() == "countdown", 20.0)
	await _wait(1.0)
	await _still("online_retry_countdown")
	await _until(func() -> bool: return net.room_state() == "running", 10.0)
	_say("The host's own menu", "Opening it does NOT pause anyone: the host's controls go neutral, everyone is told, the room keeps running.")
	await _drive(KEY_D, 0.4)
	_key(KEY_ESCAPE)
	await _wait(2.5)
	await _still("online_personal_menu")
	_say("Shared pause", "The host pauses for everyone: physics, mechanisms, AI and clocks freeze; the network and menus stay live.")
	_press(net.hud._menu, "Pause the room")
	await _until(func() -> bool: return net.room_state() == "paused", 10.0)
	await _wait(2.5)
	await _still("online_paused")
	_press(net.hud._root, "Resume")
	await _until(func() -> bool: return net.room_state() == "running", 10.0)
	await _wait(1.5)
	_say("Computer 2 drops out", "The room pauses and names the empty seat. Nobody is replaced by AI; the host decides.")
	OS.kill(bot_pid)
	bot_pid = -1
	await _until(func() -> bool: return net.room_state() == "paused", 15.0)
	await _wait(3.0)
	await _still("online_seat_empty")
	_say("End the session", "The host ends it; the invite stops working. Each player keeps the replays in their own local collection.")
	_press(net.hud._root, "End session")
	await _until(func() -> bool: return not net.in_room(), 10.0)
	await _wait(2.5)
	await _still("online_session_ended")
	main.goto("Progress")
	main.progress.replays.mode_i = 4
	main.progress.show_replays()
	_say("Online replays, offline", "Labelled Online practice with the roster. Watch them, or Practise from here — no network needed.")
	await _wait(3.5)
	await _still("online_replays")
	_say("", "")
	await _wait(0.5)
	_film = false

# ================================================================ helpers ==

func _drive(k: int, secs: float) -> void:
	var ev := InputEventKey.new()
	ev.keycode = k
	ev.physical_keycode = k
	ev.pressed = true
	Input.parse_input_event(ev)
	await _wait(secs)
	var up := InputEventKey.new()
	up.keycode = k
	up.physical_keycode = k
	up.pressed = false
	Input.parse_input_event(up)
	await _wait(0.15)

## Short pushes toward a point, reading where the robot is from the picture
## this computer is showing (the server's snapshots), like a person would.
func _drive_to(target: Vector2, secs: float) -> void:
	var t := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t < int(secs * 1000.0) and net.room_state() == "running":
		var p: Vector3 = main.robots[0].global_position
		var here := Vector2(p.x / BB.IN, -p.z / BB.IN)
		var d := target - here
		if d.length() < 6.0:
			await _wait(0.4)
			continue
		var k := KEY_W
		if absf(d.x) >= absf(d.y):
			k = KEY_W if d.x > 0.0 else KEY_S
		else:
			k = KEY_A if d.y > 0.0 else KEY_D
		await _drive(k, clampf(d.length() / 90.0, 0.12, 0.5))
		await _wait(0.5)

func _key(k: int) -> void:
	var ev := InputEventKey.new()
	ev.keycode = k
	ev.physical_keycode = k
	ev.pressed = true
	Input.parse_input_event(ev)
	var up := InputEventKey.new()
	up.keycode = k
	up.physical_keycode = k
	up.pressed = false
	Input.parse_input_event(up)

func _type(le: LineEdit, t: String) -> void:
	le.grab_focus()
	for ch in t:
		le.text += ch
		le.caret_column = le.text.length()
		await _wait(0.05)

## Press the first visible button with exactly this text, the way a click does.
func _press(root: Node, text: String) -> bool:
	var b := _find(root, func(x: Button) -> bool: return x.text.strip_edges() == text.strip_edges())
	if b == null:
		print("demo: no button '%s'" % text)
		return false
	b.pressed.emit()
	return true

func _press_nth(root: Node, text: String, n: int) -> bool:
	var all: Array = []
	_find_all(root, text, all)
	if all.size() <= n:
		print("demo: no button #%d '%s'" % [n, text])
		return false
	(all[n] as Button).pressed.emit()
	return true

func _find_all(n: Node, text: String, out: Array) -> void:
	if n is Button and (n as Button).is_visible_in_tree() and (n as Button).text == text:
		out.append(n)
	for c in n.get_children():
		_find_all(c, text, out)

func _press_prefix(root: Node, prefix: String) -> bool:
	var b := _find(root, func(x: Button) -> bool: return x.text.begins_with(prefix))
	if b == null:
		print("demo: no button starting '%s'" % prefix)
		return false
	b.pressed.emit()
	return true

func _find(n: Node, ok: Callable) -> Button:
	if n is Button and (n as Button).is_visible_in_tree() and not (n as Button).disabled and ok.call(n):
		return n
	for c in n.get_children():
		var r := _find(c, ok)
		if r != null:
			return r
	return null

func _wait(secs: float) -> void:
	var t := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t < int(secs * 1000.0):
		await get_tree().process_frame

func _until(cond: Callable, secs: float) -> bool:
	var t := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t < int(secs * 1000.0):
		if cond.call():
			return true
		await get_tree().process_frame
	print("demo: timed out waiting")
	return false

func _pump(bots: Array, secs: float) -> void:
	var t := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t < int(secs * 1000.0):
		for b in bots:
			(b as NetBot).poll()
		await get_tree().process_frame

func _until_b(bots: Array, cond: Callable, secs: float) -> bool:
	var t := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t < int(secs * 1000.0):
		for b in bots:
			(b as NetBot).poll()
		if cond.call():
			return true
		await get_tree().process_frame
	return false

func _on_drawn() -> void:
	if not _film:
		return
	var img := get_viewport().get_texture().get_image()
	if img.get_width() != 1280:
		img.resize(1280, 720, Image.INTERPOLATE_BILINEAR)
	img.save_jpg(ProjectSettings.globalize_path(FRAMES).path_join("f%05d.jpg" % _frames), 0.85)
	_times.append("%d" % (Time.get_ticks_msec() - _t0))
	_frames += 1

func _still(name: String) -> void:
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
	sb.bg_color = Color(0, 0, 0, 0.78)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	p.add_theme_stylebox_override("panel", sb)
	p.anchor_left = 0.5
	p.anchor_right = 0.5
	p.anchor_top = 1.0
	p.anchor_bottom = 1.0
	p.offset_left = -440
	p.offset_right = 440
	p.offset_top = -150
	p.offset_bottom = -30
	layer.add_child(p)
	var vb := VBoxContainer.new()
	p.add_child(vb)
	_cap = Label.new()
	_cap.add_theme_font_size_override("font_size", 24)
	_cap.add_theme_color_override("font_color", Gui.ACCENT)
	_cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_cap)
	_cap_sub = Label.new()
	_cap_sub.add_theme_font_size_override("font_size", 16)
	_cap_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_cap_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_cap_sub.custom_minimum_size = Vector2(840, 0)
	vb.add_child(_cap_sub)
	p.visible = false

func _say(t: String, sub: String) -> void:
	_cap.text = t
	_cap_sub.text = sub
	(_cap.get_parent().get_parent() as Control).visible = t != "" and _film
