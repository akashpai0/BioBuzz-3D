extends Node
## Stage 1 smoke: a headless HOST process (the game hosting a room, no local
## player) and two protocol clients sharing one robot as driver and operator.
## Same-network invite on 127.0.0.1: separate programs, one machine.
var host_pid := -1
var fails := 0

func _ok(what: String, got: Variant, want: Variant = true) -> void:
	var good: bool = got == want
	if not good:
		fails += 1
	print("  [%s] %s%s" % ["ok" if good else "FAIL", what, "" if good else "  (got %s, want %s)" % [got, want]])

func _ready() -> void:
	var inv_file := ProjectSettings.globalize_path("user://smoke_invite.txt")
	if FileAccess.file_exists(inv_file):
		DirAccess.remove_absolute(inv_file)
	host_pid = OS.create_process(OS.get_executable_path(), ["--path",
		ProjectSettings.globalize_path("res://"), "--headless", "--", "--host-test",
		"--port", "17400", "--owner", "Alice", "--invite-file", inv_file])
	await _until(func() -> bool: return FileAccess.file_exists(inv_file), 30.0)
	var invite := FileAccess.get_file_as_string(inv_file).strip_edges()
	_ok("the host process published an invite", invite.begins_with("BBZ1-L."), true)
	var a := NetBot.new("Alice")
	var b := NetBot.new("Bob")
	a.join(invite)
	await _until(func() -> bool: a.poll(); return a.s.phase in ["in_room", "failed"], 30.0)
	_ok("Alice (host's controls) entered with the invite", a.s.phase, "in_room")
	b.join(invite)
	await _until(func() -> bool: a.poll(); b.poll(); return b.s.phase in ["in_room", "failed"], 20.0)
	_ok("Bob entered with the invite", b.s.phase, "in_room")
	a.s.send(NetProto.SET_SCENARIO, {"standard": "1v0_free", "profile": {}})
	await _until(func() -> bool: a.poll(); b.poll(); return b.s.scenario_rev >= 1, 20.0)
	_ok("the scenario reached Bob", b.s.scenario_rev >= 1, true)
	a.s.send(NetProto.SEAT, {"robot": 0, "role": "driver"})
	b.s.send(NetProto.SEAT, {"robot": 0, "role": "operator"})
	await _pump([a, b], 0.5)
	a.s.send(NetProto.READY, {"on": true})
	b.s.send(NetProto.READY, {"on": true})
	await _pump([a, b], 0.5)
	print("    blockers: ", a.s.state.get("blockers"))
	a.s.send(NetProto.START, {})
	await _until(func() -> bool: a.poll(); b.poll(); return a.room_state() == "running", 20.0)
	_ok("the run started", a.room_state(), "running")
	var p0 := a.robot_pos(0)
	var h0 := a.robot_hopper(0)
	a.send_inputs = true
	b.send_inputs = true
	await _pump([a, b], 0.3)          # neutral first: the seat opens on it
	a.input["move"] = Vector2(0, 1)
	b.hold("fire", true)
	await _pump([a, b], 2.0)
	var p1 := a.robot_pos(0)
	print("    moved %.2f m, hopper %d -> %d" % [p0.distance_to(p1), h0, a.robot_hopper(0)])
	_ok("the driver drove it", p0.distance_to(p1) > 0.3, true)
	_ok("the operator fired at the same time", a.robot_hopper(0) < h0, true)
	_ok("both clients see the same last tick's pose", a.robot_pos(0).distance_to(b.robot_pos(0)) < 0.2, true)
	a.s.send(NetProto.END, {})
	await _pump([a, b], 1.0)
	_ok("ending closes the room for Bob", b.s.phase, "closed")
	await get_tree().create_timer(1.0).timeout
	OS.kill(host_pid)
	print("  SMOKE %s (%d failures)" % ["OK" if fails == 0 else "BROKEN", fails])
	get_tree().quit(1 if fails > 0 else 0)

func _until(cond: Callable, secs: float) -> void:
	var t := 0.0
	while t < secs and not cond.call():
		await get_tree().process_frame
		t += get_process_delta_time()

func _pump(bots: Array, secs: float) -> void:
	var t := 0.0
	while t < secs:
		for bt in bots:
			bt.poll()
		await get_tree().process_frame
		t += get_process_delta_time()
