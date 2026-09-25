extends Node
## Stage 2: the real game client as a GUEST (puppet world, lobby, HUD) with a
## bot partner, both in a room hosted by another, headless copy of the game.
## Same-network invite on 127.0.0.1: separate programs, one machine.
var main: Node3D
var host_pid := -1
var fails := 0

func _ok(what: String, got: Variant, want: Variant = true) -> void:
	var good: bool = got == want
	if not good:
		fails += 1
	print("  [%s] %s%s" % ["ok" if good else "FAIL", what, "" if good else "  (got %s, want %s)" % [got, want]])

func _ready() -> void:
	var inv_file := ProjectSettings.globalize_path("user://client_invite.txt")
	if FileAccess.file_exists(inv_file):
		DirAccess.remove_absolute(inv_file)
	host_pid = OS.create_process(OS.get_executable_path(), ["--path",
		ProjectSettings.globalize_path("res://"), "--headless", "--", "--host-test",
		"--port", "17410", "--owner", "Tester", "--invite-file", inv_file])
	NetRole.args["reconnect-window"] = "5"
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(3.0).timeout
	var net: NetClient = main.net
	var bot := NetBot.new("Bot")
	main.menu.open_online.emit()
	_ok("Online practice opens", net.online_screen.is_open(), true)
	await _until(func() -> bool: return FileAccess.file_exists(inv_file), 30.0, [])
	var invite := FileAccess.get_file_as_string(inv_file).strip_edges()
	# pasted into the Join box, like a player would
	net.online_screen._invite.text = invite
	net.online_screen._name.text = "Tester"
	net.online_screen._join()
	await _until(func() -> bool: return net.in_room() or (net.session and net.session.phase == "failed"), 30.0, [bot])
	_ok("the game joined the hosted room with the pasted invite", net.in_room(), true)
	_ok("the lobby is showing", net.lobby.is_open(), true)
	bot.join(invite)
	await _until(func() -> bool: return bot.s.phase == "in_room", 20.0, [bot])
	_ok("a second player joined with the same invite", bot.s.phase, "in_room")
	net.share_standard("1v0_free")
	await _until(func() -> bool: return net._built_rev >= 1 and bot.s.scenario_rev >= 1, 30.0, [bot])
	_ok("the scenario is built as a puppet world here", net._built_rev >= 1 and BB.puppet, true)
	_ok("  and the world here is halted", get_tree().paused, true)
	net.send(NetProto.SEAT, {"robot": 0, "role": "driver"})
	bot.s.send(NetProto.SEAT, {"robot": 0, "role": "operator"})
	await _pump([bot], 0.6)
	net.send(NetProto.READY, {"on": true})
	bot.s.send(NetProto.READY, {"on": true})
	await _pump([bot], 0.6)
	_ok("nothing blocks the start", net.session.state.get("blockers", ["?"]), [])
	net.send(NetProto.START)
	await _until(func() -> bool: return net.room_state() == "running" and bot.room_state() == "running", 20.0, [bot])
	_ok("the run is on for everyone", [net.room_state(), bot.room_state()], ["running", "running"])
	_ok("the online HUD is up", net.hud.is_open(), true)
	bot.send_inputs = true
	await _pump([bot], 0.5)
	# drive with the keyboard of THIS computer
	var p0: Vector3 = main.robots[0].global_position
	_key(KEY_W, true)
	await _pump([bot], 1.5)
	var p1: Vector3 = main.robots[0].global_position
	print("    puppet moved %.2f m; input-to-screen %.0f ms" % [p0.distance_to(p1), net.input_latency_ms])
	_ok("pressing drive here moves the robot on the server, and it is drawn here", p0.distance_to(p1) > 0.3, true)
	_ok("  the bot sees the same robot where this screen draws it (within 0.25 m)",
		bot.robot_pos(0).distance_to(p1) < 0.25, true)
	# the personal menu neutralises this player only
	net.set_menu(true)
	await _pump([bot], 1.0)
	var q0 := bot.robot_pos(0)
	await _pump([bot], 0.6)
	var q1 := bot.robot_pos(0)
	_ok("with the personal menu open, the room keeps running", bot.room_state(), "running")
	_ok("  and this player's robot is neutral (still held W)", q0.distance_to(q1) < 0.05, true)
	var h0 := bot.robot_hopper(0)
	bot.hold("fire", true)
	await _pump([bot], 1.2)
	_ok("  while the operator can still fire", bot.robot_hopper(0) < h0, true)
	bot.hold("fire", false)
	_key(KEY_W, false)
	net.set_menu(false)
	# owner pause and retry
	net.send(NetProto.PAUSE)
	await _pump([bot], 0.6)
	_ok("owner pause pauses the room", bot.room_state(), "paused")
	var run0 := int(bot.s.state.get("run", 0))
	net.send(NetProto.RETRY)
	await _until(func() -> bool: return net.room_state() == "running", 20.0, [bot])
	print("    dbg acked=%d last_run=%d snaps=%d old=%d bad=%d built=%d rev=%d building=%s" % [net._acked_run, net._last_run,
		net.session.snaps.size(), net.session.snaps_old_run, net.session.snaps_bad, net._built_rev, net.session.scenario_rev, net._building])
	_ok("retry restores and counts down to a new run", [net.room_state(), int(bot.s.state.get("run", 0))], ["running", run0 + 1])
	_ok("  the robot is back at the scenario's start",
		bot.robot_pos(0).distance_to(Snapshot.unpack_v3(net.session.scenario["robots"][0]["origin"])) < 0.05, true)
	# a local replay disk failure does not stop the session
	await _pump([bot], 1.5)
	net.writer.debug_fail = true
	# a chunk has to arrive for the write to fail: wait for it, not a fixed time
	await _until(func() -> bool: return net.hud._notice.text.contains("stopped"), 15.0, [bot])
	_ok("a local replay write failure is reported on the HUD", net.hud._notice.text.contains("stopped"), true)
	_ok("  and the session carries on", [net.room_state(), bot.room_state()], ["running", "running"])
	net.writer.debug_fail = false
	# end the run: back to lobby → replay saved locally
	net.send(NetProto.RETRY)
	await _until(func() -> bool: return net.room_state() == "running", 20.0, [bot])
	await _pump([bot], 1.5)
	net.send(NetProto.LOBBY)
	await _pump([bot], 1.5)
	var found := {}
	for e in ReplayStore.list():
		if String(e.get("kind", "")) == "online" and String(e.get("health", "")) == "ok":
			found = e
			break
	_ok("the online run is in this computer's replay collection", not found.is_empty(), true)
	_ok("  labelled Online practice", String(found.get("mode_name", "")), "Online practice")
	_ok("  complete", String(found.get("health", "")), "ok")
	_ok("  with the roster", (found.get("online", {}) as Dictionary).has("roster"), true)
	var stopped := ReplayStore.list().filter(func(e) -> bool:
		return String(e.get("kind", "")) == "online" and String(e.get("health", "")) == "recovered")
	_ok("  the copy that hit the disk failure is kept, labelled incomplete", stopped.size() >= 1, true)
	# THE HOST'S GAME DIES: back to the menus, safely, with what was recorded
	net.send(NetProto.START)
	await _until(func() -> bool: return net.room_state() == "running", 20.0, [bot])
	await _pump([bot], 2.0)
	# the run's first chunk (its header) must have reached this player before
	# the host dies, or there is nothing to keep — wait for it, not a fixed time
	var header_in := func() -> bool: return net.writer._f != null and net.writer.run == int(net.session.state.get("run", -1))
	await _until(header_in, 15.0, [bot])
	var before := ReplayStore.list().size()
	print("    dbg writer run=%d id=%s next=%d failed=%s complete=%s open=%s room_run=%d" % [net.writer.run, net.writer.id,
		net.writer.next, net.writer.failed, net.writer.complete, net.writer._f != null, int(net.session.state.get("run", -1))])
	OS.kill(host_pid)
	await _until(func() -> bool: return net.online_screen.is_open(), 25.0, [bot])
	_ok("when the host's game dies, this player is returned to the menus", net.online_screen.is_open(), true)
	_ok("  with an explanation", net.online_screen._msg.text.contains("Lost"), true)
	_ok("  the world here is no longer a puppet", BB.puppet, false)
	var inc := ReplayStore.list().filter(func(e) -> bool:
		return String(e.get("kind", "")) == "online" and String(e.get("outcome_label", "")) == "Incomplete")
	_ok("  and the run's recording so far is kept, marked incomplete", inc.size() >= 2 and ReplayStore.list().size() >= before, true)
	print("  CLIENT %s (%d failures)" % ["OK" if fails == 0 else "BROKEN", fails])
	get_tree().quit(1 if fails > 0 else 0)

func _key(k: int, down: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = k
	ev.physical_keycode = k
	ev.pressed = down
	Input.parse_input_event(ev)

func _until(cond: Callable, secs: float, bots: Array) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(secs * 1000.0) and not cond.call():
		for b in bots:
			b.poll()
		await get_tree().process_frame

func _pump(bots: Array, secs: float) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(secs * 1000.0):
		for b in bots:
			b.poll()
		await get_tree().process_frame
