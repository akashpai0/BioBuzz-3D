extends Node
## THE CONNECTION PROTOTYPE, PROVED WITH SEPARATE PROGRAMS ON ONE MACHINE.
##
## This process is a full copy of the game that HOSTS a room from inside
## itself (Play -> Online practice -> Host room): its own world is the room's
## simulation, and its player drives with this computer's keyboard. A second,
## separate program joins with the invite and operates the same robot.
##
## Transport here is the same-network (ENet) path on 127.0.0.1: separate
## programs, not separate computers, and NOT the internet. The internet path
## (EOS peer-to-peer, relay fallback) needs Epic credentials and a second
## internet connection: see ONLINE.md, "Internet test".
##
## Also checked, because the host is now a player's game:
##  - the host's PERSONAL menu does not pause the shared world
##  - a SHARED pause halts the world while the network keeps answering
##  - the host leaving ends the session for the guest, who keeps a replay
var main: Node3D
var fails := 0
var checks := 0

func _ok(what: String, got: Variant, want: Variant = true) -> void:
	checks += 1
	var good: bool = got == want
	if not good:
		fails += 1
	print("  [%s] %s%s" % ["ok" if good else "FAIL", what, "" if good else "  (got %s, want %s)" % [got, want]])

func _ready() -> void:
	var inv_file := ProjectSettings.globalize_path("user://2proc_invite.txt")
	var out := ProjectSettings.globalize_path("user://2proc_bot.json")
	for p in [inv_file, out]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	# an exported build has its project inside it: no --path
	var base: Array = [] if OS.has_feature("template") else ["--path", ProjectSettings.globalize_path("res://")]
	var bot := OS.create_process(OS.get_executable_path(), base + ["--headless", "res://tools/net_bot_proc.tscn",
		"--", "--invite-file", inv_file, "--seat", "0:operator",
		"--fire-every", "0.8", "--for", "40", "--out", out, "--name", "Operator program"])
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(3.0).timeout
	var net: NetClient = main.net
	print("\n--- WHEN EPIC ONLINE SERVICES IS UNAVAILABLE, NOTHING BREAKS ---")
	var no_eos: String = await net.host_room("Internet room", "Host driver", "internet")
	# Without the plugin, without credentials, or (with both) when Epic cannot
	# be reached from here: hosting must fail with a sentence, not break.
	if no_eos == "":
		# Epic reachable from this machine: the internet room opened for real.
		print("  (Epic Online Services is reachable here: an internet room opened; ending it)")
		net.leave("")
		await _until(func() -> bool: return net.room == null, 10.0)
		_ok("hosting over the internet opened a real room, and it ends cleanly", net.room == null, true)
	else:
		print("  (said: %s)" % no_eos)
		_ok("hosting over the internet when Epic Online Services is unavailable says why, in words",
			no_eos.contains("Epic") or no_eos.contains("credentials"), true)
	var no_eos2: String = await net.join_room(NetInvite.make_eos("0123456789abcdef0123456789abcdef",
		"0002aaaabbbbccccddddeeeeffff0000", NetInvite.new_secret()), "Host driver")
	_ok("  joining an internet invite says the same", no_eos2 == no_eos, true)
	_ok("  and the game is not left half in a room", [net.active(), net.room == null, BB.halted], [false, true, false])
	net.method = "lan"

	print("\n--- HOSTING FROM INSIDE THE GAME ---")
	var err: String = await net.host_room("Two programs", "Host driver", "lan")
	_ok("the game opened a room with no server anywhere", err, "")
	await _until(func() -> bool: return net.in_room(), 10.0)
	_ok("  and its own player is in it, as host", [net.in_room(), net.owner(), net.hosting], [true, true, true])
	_ok("  the invite is a same-network one", net.invite.begins_with("BBZ1-L."), true)
	var f := FileAccess.open(inv_file + ".tmp", FileAccess.WRITE)
	f.store_string(net.invite)
	f.close()
	DirAccess.rename_absolute(inv_file + ".tmp", inv_file)
	net.share_standard("1v0_free")
	await _until(func() -> bool: return net._built_rev >= 1, 30.0)
	_ok("the host's world is the live one (not a puppet)", [BB.puppet, net._built_rev >= 1], [false, true])
	net.send(NetProto.SEAT, {"robot": 0, "role": "driver"})
	await _until(func() -> bool:
		for q in net.session.state.get("parts", []):
			if String(q["name"]) == "Operator program" and bool(q["ready"]):
				return true
		return false, 40.0)
	var guest := {}
	for q in net.session.state.get("parts", []):
		if String(q["name"]) == "Operator program":
			guest = q
	_ok("the separate program joined with the invite and took OPERATOR", guest.get("seat", []), [0, "operator"])
	net.send(NetProto.READY, {"on": true})
	await _until(func() -> bool: return (net.session.state.get("blockers", ["x"]) as Array).is_empty(), 10.0)
	net.send(NetProto.START)
	await _until(func() -> bool: return net.room_state() == "running", 20.0)
	_ok("host (driver) and guest (operator) share one robot in a running room", net.room_state(), "running")
	await get_tree().create_timer(0.5).timeout

	print("\n--- BOTH ROLES AT ONCE ---")
	var h0 := _hopper()
	var p0: Vector3 = main.robots[0].global_position
	await _key(KEY_W, 2.5)
	var p1: Vector3 = main.robots[0].global_position
	var h1 := _hopper()
	print("    moved %.2f m while the hopper went %d -> %d" % [p0.distance_to(p1), h0, h1])
	_ok("the host's keyboard drove it", p0.distance_to(p1) > 0.5, true)
	_ok("the guest program fired during the same seconds", h1 < h0, true)

	print("\n--- THE HOST'S PERSONAL MENU DOES NOT FREEZE ANYONE ---")
	var t0 := BB.sim_now()
	var fr0 := Engine.get_physics_frames()
	var ev := InputEventAction.new()
	ev.action = "pause"
	ev.pressed = true
	Input.parse_input_event(ev)
	var evu := InputEventAction.new()
	evu.action = "pause"
	evu.pressed = false
	Input.parse_input_event(evu)
	await get_tree().create_timer(0.3).timeout
	_ok("Esc opened the host's own menu", net.menu_open, true)
	await get_tree().create_timer(1.5).timeout
	_ok("  the shared world kept running (not halted)", BB.halted, false)
	_ok("  simulated time advanced ~1.5 s behind the menu", BB.sim_now() - t0 > 1.0, true)
	_ok("  the room still says running", net.room_state(), "running")
	var me := net.session.my_part()
	_ok("  and shows the host as in a menu (neutral)", bool(me.get("menu", false)), true)
	net.set_menu(false)
	await get_tree().create_timer(0.3).timeout

	print("\n--- A SHARED PAUSE HALTS THE WORLD, NOT THE NETWORK ---")
	net.send(NetProto.PAUSE)
	await _until(func() -> bool: return net.room_state() == "paused", 5.0)
	_ok("the host paused the room", net.room_state(), "paused")
	_ok("  the world is halted", BB.halted, true)
	var st0 := BB.sim_now()
	var ping_before := int(guest.get("ping", -1))
	await get_tree().create_timer(3.0).timeout
	_ok("  no simulated time passed while paused", absf(BB.sim_now() - st0) < 0.001, true)
	var gq := {}
	for q in net.session.state.get("parts", []):
		if String(q["name"]) == "Operator program":
			gq = q
	_ok("  the guest is still connected and still pinging while paused", [bool(gq.get("connected", false)), float(gq.get("ping", -1.0)) >= 0.0], [true, true])
	net.send(NetProto.RESUME)
	await _until(func() -> bool: return net.room_state() == "running", 8.0)
	_ok("resumed with a shared countdown", net.room_state(), "running")

	print("\n--- RETRY TOGETHER ---")
	var run0 := int(net.session.state.get("run", 0))
	net.send(NetProto.RETRY)
	await _until(func() -> bool: return int(net.session.state.get("run", 0)) > run0 and net.room_state() == "countdown", 20.0)
	_ok("retry restored the start; both programs confirmed it; shared countdown", [int(net.session.state.get("run", 0)) > run0, net.room_state()], [true, "countdown"])
	_ok("  the hopper is full again", _hopper(), 4)
	await _until(func() -> bool: return net.room_state() == "running", 10.0)
	# a key already down when the countdown ends is ignored until let go
	# (nothing held from before a run counts), so press after the start
	await get_tree().create_timer(0.3).timeout
	var q0: Vector3 = main.robots[0].global_position
	await _key(KEY_W, 2.0)
	_ok("  and both roles work in the new run", [(main.robots[0].global_position as Vector3).distance_to(q0) > 0.3, _hopper() < 4], [true, true])

	print("\n--- IDENTICAL STATE IN BOTH PROGRAMS ---")
	var mine_rows := {}
	var keep := func() -> void:
		for sn in net.session.snaps:
			mine_rows[str(sn["tick"])] = Array(sn["row"] as PackedFloat32Array)
	get_tree().process_frame.connect(keep)
	await get_tree().create_timer(3.0).timeout
	get_tree().process_frame.disconnect(keep)

	print("\n--- THE HOST LEAVES: THE SESSION ENDS CLEANLY ---")
	net.leave("You ended the session.")
	await _until(func() -> bool: return not net.in_room() and net.room == null, 10.0)
	_ok("the host's game is back in its own menus, room gone", [net.in_room(), net.room == null, net.hosting], [false, true, false])
	_ok("  offline play is usable again (world not halted)", BB.halted, false)
	_ok("  the host is told in its own words", String(net.online_screen._msg.text).begins_with("You ended the session"), true)
	await _until(func() -> bool: return FileAccess.file_exists(out), 30.0)
	var got: Variant = ReplayStore.parse_json(FileAccess.get_file_as_string(out))
	var same := 0
	var diff := 0
	if got is Dictionary:
		var rows: Dictionary = (got as Dictionary).get("rows", {})
		for k in mine_rows:
			if rows.has(k):
				var a: Array = mine_rows[k]
				var b: Array = rows[k]
				var eq := a.size() == b.size()
				if eq:
					for j in a.size():
						if absf(float(a[j]) - float(b[j])) > 1e-4:
							eq = false
							break
				if eq:
					same += 1
				else:
					diff += 1
		print("    guest program: fired %d times, saw %d snapshots, ended with: %s" % [
			int(got.get("fired", 0)), int(got.get("snaps_in", 0)), String(got.get("end", ""))])
		_ok("the guest program was told the session ended", String(got.get("end", "")).contains("host"), true)
	_ok("both programs received identical authoritative state for the same ticks (%d compared)" % same,
		same > 20 and diff == 0, true)
	OS.kill(bot)
	print("  PROTOTYPE %s (%d checks, %d failures)" % ["OK" if fails == 0 else "BROKEN", checks, fails])
	get_tree().quit(1 if fails > 0 else 0)

func _hopper() -> int:
	return (main.robots[0] as Robot).hopper.size()

func _key(k: int, secs: float) -> void:
	var ev := InputEventKey.new()
	ev.keycode = k
	ev.physical_keycode = k
	ev.pressed = true
	Input.parse_input_event(ev)
	await get_tree().create_timer(secs).timeout
	var up := InputEventKey.new()
	up.keycode = k
	up.physical_keycode = k
	up.pressed = false
	Input.parse_input_event(up)

func _until(cond: Callable, secs: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(secs * 1000.0) and not cond.call():
		await get_tree().process_frame
	return cond.call()
