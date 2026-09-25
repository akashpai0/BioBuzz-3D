extends Node
## ONLINE PRACTICE ROOMS, TESTED END TO END ON ONE MACHINE.
##
## Rooms are HOSTED by other copies of the game (headless, --host-test), the
## way a player's game hosts one; players are protocol bots (NetBot) in this
## process, each with its own connection, joining with the room's invite.
## This proves the protocol, admission, the authority rules and the recovery
## paths. It is NOT a test over the internet: everything here is same-network
## ENet on 127.0.0.1 (the EOS path is the same room code behind a different
## transport; see ONLINE.md for what has and has not been tested).
##
##   -- write   the whole battery; online replays land in a private folder
##   -- read    cold start: those replays are still there and branch offline

var main: Node3D
var host_a := -1
var host_b := -1
var fails := 0
var checks := 0
const PORT_A := 17420
const PORT_B := 17421
const STATE := "user://net_harness_state.json"

func _ok(what: String, got: Variant, want: Variant = true) -> void:
	checks += 1
	var good: bool = got == want
	if not good:
		fails += 1
	print("  [%s] %s%s" % ["ok" if good else "FAIL", what,
		"" if good else "   (got %s, want %s)" % [str(got), str(want)]])

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(2.5).timeout
	var args := OS.get_cmdline_user_args()
	if args.size() > 0 and String(args[0]) == "read":
		await _read_phase()
	else:
		await _write_phase()
		for pid in [host_a, host_b]:
			if pid > 0:
				OS.kill(pid)
	print("  %s  (%d checks, %d failure%s)" % ["ONLINE ROOMS WORK" if fails == 0
		else "ONLINE ROOMS BROKEN", checks, fails, "" if fails == 1 else "s"])
	get_tree().quit(1 if fails > 0 else 0)

# ================================================================ helpers ==

var _bots: Array = []

func _bot(n: String) -> NetBot:
	var b := NetBot.new(n)
	_bots.append(b)
	b.s.replay_hook = func(run: int, idx: int, bytes: PackedByteArray) -> void:
		if not b.has_meta("writer"):
			b.set_meta("writer", NetReplayWriter.new())
		(b.get_meta("writer") as NetReplayWriter).on_chunk(run, idx, bytes)
	return b

func _pump(secs: float) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(secs * 1000.0):
		for b in _bots:
			(b as NetBot).poll()
		await get_tree().process_frame

func _until(cond: Callable, secs: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(secs * 1000.0):
		for b in _bots:
			(b as NetBot).poll()
		if cond.call():
			return true
		await get_tree().process_frame
	return false

func _notices(b: NetBot) -> String:
	return " | ".join(b.s.take_notices())

func _state_json(b: NetBot) -> String:
	return String(b.s.state.get("state", ""))

## Start a headless host (a copy of the game hosting a room) and read its invite.
func _host(port: int, owner: String) -> Array:
	var f := ProjectSettings.globalize_path("user://net_invite_%d.txt" % port)
	if FileAccess.file_exists(f):
		DirAccess.remove_absolute(f)
	var pid := OS.create_process(OS.get_executable_path(), ["--path",
		ProjectSettings.globalize_path("res://"), "--headless", "--", "--host-test",
		"--port", str(port), "--owner", owner, "--invite-file", f, "--grace", "4"])
	await _until(func() -> bool: return FileAccess.file_exists(f), 30.0)
	return [pid, FileAccess.get_file_as_string(f).strip_edges()]

## A situation with: our human robot (P1), a human opponent, and an AI route
## opponent that waits at its first waypoint — captured while it IS waiting,
## so its remaining wait is part of the saved state.
func _mid_wait_situation() -> Dictionary:
	await main._create_scenario("staged")
	var d: ScenarioDraft = main.editor.draft
	d.set_scenario("mode", BB.Mode.TELEOP_ONLY)
	d.set_scenario("phase", BB.Phase.TELEOP)
	d.set_scenario("time_left", 120.0)
	d.set_position("robot:0", Vector3(-62, 4, 0))
	var h := d.add_robot(BB.Alliance.BLUE, false)
	d.set_position(h, Vector3(62, -30, 0))
	var id := d.add_robot(BB.Alliance.BLUE, true)
	d.set_position(id, Vector3(45, 40, 0))
	d.set_opponent(id, "behavior", OpponentConfig.Behavior.ROUTE)
	var c: Dictionary = d.opponent(id)
	c["waypoints"] = [{"x": 45.0, "y": 40.0, "wait": 6.0}, {"x": 45.0, "y": -10.0, "wait": 0.0}]
	c["route_mode"] = float(OpponentConfig.RouteMode.LOOP)
	await main._test_scenario(d.to_snapshot())
	var br: AIDriver = null
	for b in main.ais:
		if is_instance_valid(b):
			br = b
	var guard := 0
	while guard < 1200 and (br == null or br._wait_left < 3.0 or br._wait_left > 4.0):
		await get_tree().physics_frame
		guard += 1
	var snap := Snapshot.capture(main)
	main.mm.abort()
	main.editor_return = false
	snap["meta"] = {"name": "Harness mid-wait", "note": ""}
	return snap

func _share(owner: NetBot, snap: Dictionary) -> void:
	var w := NetScenario.encode(snap)
	owner.s.send(NetProto.SET_SCENARIO, {"data": w["data"], "raw_len": w["raw_len"]})

func _raw_scenario(owner: NetBot, bytes: PackedByteArray, raw_len: int) -> void:
	owner.s.send(NetProto.SET_SCENARIO, {"data": bytes, "raw_len": raw_len})

func _opp_status(b: NetBot, robot: int) -> String:
	for r in b.s.slow.get("robots", []):
		if int(r.get("i", -1)) == robot:
			return String(r.get("status", ""))
	return ""

static func _wait_secs(status: String) -> float:
	var re := RegEx.create_from_string("Waiting: ([0-9.]+) s")
	var m := re.search(status)
	return float(m.get_string(1)) if m else -1.0

# ================================================================== write ==

func _write_phase() -> void:
	var dir := ProjectSettings.globalize_path("user://net_harness_replays_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	var prev := ReplayStore._config()
	ReplayStore.set_folder(dir)
	_save_state({"dir": dir, "prev": prev})

	print("\n--- INVITES: WHAT THEY CARRY, AND WHAT THEY DO NOT ACCEPT ---")
	var seen := {}
	for i in 2000:
		seen[NetInvite.new_secret()] = true
	_ok("secrets are 26 characters from a 31-symbol alphabet (~128 bits), none repeated in 2000",
		[NetInvite.new_secret().length(), seen.size()], [26, 2000])
	var sample := NetInvite.make_eos("0123456789abcdef0123456789abcdef", "0002aaaabbbbccccddddeeeeffff0000", NetInvite.new_secret())
	var pe := NetInvite.parse("  " + sample.to_lower().replace("bbz1-e", "BBZ1-E") + "\n")
	_ok("an internet invite parses back to lobby, host and secret (pasted with spaces, lower case)",
		[pe.get("ok"), pe.get("kind"), String(pe.get("lobby", "")).length(), String(pe.get("secret", "")).length()], [true, "eos", 32, 26])
	var bads := ["hello", "BBZ1-", "BBZ1-E.abc.def.SHORT", "BBZ1-L.nowhere.AAAAAAAAAAAAAAAAAAAAAAAAAA",
		"BBZ1-X.1.2.AAAAAAAAAAAAAAAAAAAAAAAAAA", "BBZ1-E.abc.def.AAAAAAAAAAAAAAAAAAAAAAAAA0"]
	var refused := 0
	for t in bads:
		if not bool(NetInvite.parse(t).get("ok", false)):
			refused += 1
	_ok("garbage, truncated, typo'd and unknown-kind invites are refused with a sentence", refused, bads.size())

	print("\n--- A ROOM HOSTED BY ANOTHER COPY OF THE GAME ---")
	var ha: Array = await _host(PORT_A, "Owner")
	host_a = ha[0]
	var inv_a: String = ha[1]
	_ok("the host's game published a same-network invite", inv_a.begins_with("BBZ1-L.127.0.0.1:%d." % PORT_A), true)
	var old := _bot("Old build")
	old.s.compat_override = "p0-r0-s0-f0-t0"
	old.join(inv_a)
	await _until(func() -> bool: return old.s.phase == "failed", 10.0)
	_ok("a different game build is refused by the host", old.s.error_reason, "incompatible")
	_ok("  with a sentence naming both builds", old.s.error_text.contains(NetRole.GAME_VERSION), true)
	var guess := _bot("Guesser")
	guess.join_with_secret("127.0.0.1", PORT_A, NetInvite.new_secret())
	await _until(func() -> bool: return guess.s.phase == "failed", 10.0)
	_ok("a connection with the wrong secret is refused, and says so", [guess.s.error_reason, guess.s.error_text.contains("not valid")], ["invalid", true])
	await _pump(1.0)
	_ok("  and is dropped by the host (not left hanging on)", guess.s.room.connected(), false)
	var own := _bot("Owner")
	own.join(inv_a)
	await _until(func() -> bool: return own.s.phase in ["in_room", "failed"], 30.0)
	_ok("the host's player is in, with the host's controls", [own.s.phase, own.s.is_owner], ["in_room", true])
	var p1 := _bot("Ada")
	var p2 := _bot("Ben")
	var p3 := _bot("Cy")
	for b in [p1, p2, p3]:
		b.join(inv_a)
	await _until(func() -> bool: return p1.s.phase == "in_room" and p2.s.phase == "in_room" and p3.s.phase == "in_room", 20.0)
	_ok("three players joined with the invite", [p1.s.phase, p2.s.phase, p3.s.phase], ["in_room", "in_room", "in_room"])
	_ok("  none of them is the host", [p1.s.is_owner, p2.s.is_owner, p3.s.is_owner], [false, false, false])

	# ---- non-owners cannot run the room
	p1.s.send(NetProto.START, {})
	p1.s.send(NetProto.LOCK, {"on": true})
	p1.s.send(NetProto.KICK, {"pid": own.s.pid})
	await _pump(0.6)
	_ok("host-only commands from a player are refused", _notices(p1).contains("Only the host"), true)
	_ok("  and changed nothing", [bool(own.s.state.get("locked", false)), own.s.phase], [false, "in_room"])

	print("\n--- SCENARIOS ARE UNTRUSTED DATA ---")
	var rev0 := int(own.s.state.get("scenario", {}).get("rev", 0))
	_raw_scenario(own, PackedByteArray([1, 2, 3, 4]), 4)
	_raw_scenario(own, "{not json".to_utf8_buffer().compress(FileAccess.COMPRESSION_ZSTD), 9)
	_raw_scenario(own, PackedByteArray([0]), 900000000)
	var bad := JSON.stringify({"format": "biobuzz.situation", "version": 1}).to_utf8_buffer()
	_raw_scenario(own, bad.compress(FileAccess.COMPRESSION_ZSTD), bad.size())
	var good_snap: Dictionary = await _mid_wait_situation()
	var many := good_snap.duplicate(true)
	for i in 8:
		many["robots"].append((many["robots"][0] as Dictionary).duplicate(true))
	_share(own, many)
	var far := good_snap.duplicate(true)
	far["robots"][0]["origin"] = [100.0, 0.0, 0.0]
	_share(own, far)
	var badid := good_snap.duplicate(true)
	badid["elements"][0]["id"] = "../../etc"
	_share(own, badid)
	var longs := good_snap.duplicate(true)
	longs["meta"] = {"name": "x".repeat(5000)}
	_share(own, longs)
	await _pump(1.5)
	var said := _notices(own)
	_ok("garbage, lies about size, broken JSON, missing parts, 11 robots, a robot 100 m away, a path as an id, a 5000-character name: all refused",
		said.count("cannot be used online"), 8)
	_ok("  and the room's scenario never changed", int(own.s.state.get("scenario", {}).get("rev", 0)), rev0)

	_share(own, good_snap)
	await _until(func() -> bool: return p1.s.scenario_rev > rev0 and p2.s.scenario_rev > rev0 and p3.s.scenario_rev > rev0, 15.0)
	_ok("a valid situation reaches every player", [p1.s.scenario_rev, p2.s.scenario_rev, p3.s.scenario_rev].all(func(r) -> bool: return r > rev0), true)
	# the summary rides the room state (control channel); the scenario itself
	# rides the bulk channel, so either can land first
	await _until(func() -> bool: return int(own.s.state.get("scenario", {}).get("rev", 0)) > rev0, 10.0)
	var sm: Dictionary = own.s.state.get("scenario", {}).get("summary", {})
	_ok("  everyone sees its summary (3 robots, one AI on a route)", [(sm.get("robots", []) as Array).size(),
		(sm.get("robots", []) as Array).filter(func(r) -> bool: return bool(r["ai"])).size()], [3, 1])
	_ok("  and the note that custom CAD models are not shared", str(sm.get("notes", [])).contains("built-in model"), true)

	print("\n--- SEATS ARE GRANTED ONE AT A TIME ---")
	p1.s.send(NetProto.SEAT, {"robot": 0, "role": "driver"})
	p2.s.send(NetProto.SEAT, {"robot": 0, "role": "driver"})
	await _pump(0.6)
	var holder := int(own.s.state["seats"][0]["driver"])
	_ok("two players asking for the same seat at once: exactly one gets it",
		holder == p1.s.pid or holder == p2.s.pid, true)
	var loser := p2 if holder == p1.s.pid else p1
	_ok("  the other is told", _notices(loser).contains("already has that seat"), true)
	loser.s.send(NetProto.SEAT, {"robot": 0, "role": "whole"})
	await _pump(0.5)
	_ok("whole-robot cannot be taken while someone drives it", _notices(loser).contains("already has that seat"), true)
	p3.s.send(NetProto.SEAT, {"robot": 2, "role": "whole"})
	await _pump(0.5)
	_ok("a seat on the AI robot is refused", _notices(p3).contains("driven by the AI"), true)
	var drv := p1 if holder == p1.s.pid else p2
	var opr := loser
	opr.s.send(NetProto.SEAT, {"robot": 0, "role": "operator"})
	p3.s.send(NetProto.SEAT, {"robot": 1, "role": "whole"})
	await _pump(0.6)
	own.s.send(NetProto.START, {})
	await _pump(0.5)
	_ok("starting before anyone is ready is refused with the reason", _notices(own).contains("not ready"), true)
	for b2 in [drv, opr, p3]:
		b2.s.send(NetProto.READY, {"on": true})
	await _pump(0.6)
	_ok("with every human robot covered and ready, nothing blocks the start", own.s.state.get("blockers", ["?"]), [])
	own.s.send(NetProto.START, {})
	await _until(func() -> bool: return _state_json(own) == "running", 20.0)
	_ok("the run starts after everyone confirmed the restored field", _state_json(own), "running")
	for b3 in [drv, opr, p3, own]:
		b3.send_inputs = true
	await _pump(0.4)

	print("\n--- ONE AUTHORITATIVE SIMULATION ---")
	var w0 := _wait_secs(_opp_status(own, 2))
	_ok("the AI opponent resumed MID-WAIT from the shared situation (%.1f s left)" % w0, w0 > 1.5 and w0 < 4.5, true)
	var a0 := drv.robot_pos(0)
	var h0 := drv.robot_hopper(0)
	drv.input["move"] = Vector2(0, 1)
	drv.hold("fire", true)                      # a driver's fire must do nothing
	opr.input["move"] = Vector2(1, 0)           # an operator's stick must do nothing
	await _pump(1.0)
	_ok("driver's stick drives", drv.robot_pos(0).distance_to(a0) > 0.3, true)
	_ok("driver's fire button reaches no mechanism", drv.robot_hopper(0), h0)
	opr.hold("fire", true)
	await _pump(1.0)
	_ok("operator fires while the driver drives, at the same time", drv.robot_hopper(0) < h0, true)
	drv.input["move"] = Vector2.ZERO
	drv.hold("fire", false)
	opr.hold("fire", false)
	opr.input["move"] = Vector2.ZERO
	await _pump(1.0)
	var c0 := own.robot_pos(0)
	opr.input["move"] = Vector2(0, 1)
	await _pump(0.8)
	_ok("operator's stick moves no wheel", own.robot_pos(0).distance_to(c0) < 0.03, true)
	opr.input["move"] = Vector2.ZERO
	var spect := _bot("Spectator")
	spect.join(inv_a, "Spec")
	await _until(func() -> bool: return spect.s.phase == "in_room", 10.0)
	_ok("someone joining mid-run comes in as a spectator", spect.s.my_seat(), [])
	spect.s.send(NetProto.SEAT, {"robot": 1, "role": "driver"})
	await _pump(0.5)
	_ok("  who cannot take a seat while the run is on", _notices(spect).contains("Seats change"), true)
	# agreement: the same tick is the same numbers everywhere
	await _pump(0.5)
	var common := -1
	for sa in drv.s.snaps:
		for sb in p3.s.snaps:
			if int(sa["tick"]) == int(sb["tick"]):
				common = int(sa["tick"])
				_ok("two players' copies of server tick %d are identical" % common,
					(sa["row"] as PackedFloat32Array) == (sb["row"] as PackedFloat32Array), true)
				break
		if common >= 0:
			break
	_ok("  score, clock and event log agree", [drv.s.slow.get("events"), drv.latest()["row"][1] >= 0.0],
		[p3.s.slow.get("events"), true])

	print("\n--- PAUSE FREEZES EVERYTHING, INCLUDING AN OPPONENT'S WAIT ---")
	await _until(func() -> bool: return _wait_secs(_opp_status(own, 2)) < 0.0 or true, 0.1)
	own.s.send(NetProto.PAUSE, {})
	await _until(func() -> bool: return _state_json(p3) == "paused", 5.0)
	_ok("owner pause reaches everyone", _state_json(p3), "paused")
	var pz0 := own.robot_pos(1)
	var st0 := _opp_status(own, 2)
	p3.input["move"] = Vector2(0, 1)
	await _pump(1.5)
	_ok("while paused, inputs move nothing", own.robot_pos(1).distance_to(pz0) < 0.01, true)
	_ok("  and the opponent's state does not advance (%s)" % st0, _opp_status(own, 2), st0)
	p3.input["move"] = Vector2.ZERO
	p1.s.send(NetProto.PAUSE, {})
	await _pump(0.3)
	own.s.send(NetProto.RESUME, {})
	await _until(func() -> bool: return _state_json(own) == "running", 8.0)
	_ok("resume goes through a shared countdown back to running", _state_json(own), "running")

	print("\n--- A HOST ON A SLOW HOME UPLOAD ---")
	var n0 := drv.s.snaps_in
	await _pump(2.0)
	var fast := float(drv.s.snaps_in - n0) / 2.0
	p1.s.send(NetProto.SET_RATE, {"low": true})
	await _pump(0.3)
	_ok("only the host can change the update rate", _notices(p1).contains("Only the host"), true)
	own.s.send(NetProto.SET_RATE, {"low": true})
	await _pump(0.5)
	n0 = drv.s.snaps_in
	await _pump(2.0)
	var slow := float(drv.s.snaps_in - n0) / 2.0
	print("    snapshots per second: %.0f normal, %.0f low upload" % [fast, slow])
	_ok("low upload halves the snapshot rate (about 60 -> 30 a second)", fast > 50.0 and slow > 24.0 and slow < 36.0, true)
	own.s.send(NetProto.SET_RATE, {"low": false})
	await _pump(0.3)

	print("\n--- RETRY: ONE RESTORE, A NEW RUN, OLD PACKETS IGNORED ---")
	var run0 := int(own.s.state.get("run", 0))
	var stale := NetProto.pack_input(run0, 999999, 0, {"move": Vector2(0, 1), "turn": 0.0,
		"precision": 1.0, "held": {"fire": true}, "presses": {}})
	opr.s.send(NetProto.RETRY, {})
	await _pump(0.4)
	_ok("a player's retry is a request the owner sees", str(own.s.state.get("requests", [])).contains("retry"), true)
	own.s.send(NetProto.RETRY, {})
	await _until(func() -> bool: return int(own.s.state.get("run", 0)) == run0 + 1 and _state_json(own) == "running", 20.0)
	_ok("retry restored the situation as run %d and everyone is running again" % (run0 + 1), _state_json(own), "running")
	var start0 := Snapshot.unpack_v3(good_snap["robots"][0]["origin"])
	_ok("  robot 1 is back where the situation put it", own.robot_pos(0).distance_to(start0) < 0.08, true)
	var w1 := _wait_secs(_opp_status(own, 2))
	var saved_wait := 0.0
	for rb in good_snap["robots"]:
		if rb.get("brain") is Dictionary:
			saved_wait = float(rb["brain"].get("wait_left", 0.0))
	_ok("  the opponent is waiting again, from the situation's remaining wait (%.1f s, saved %.2f s)" % [w1, saved_wait],
		w1 > 0.0 and absf(w1 - saved_wait) < 0.4, true)
	own.s.send(NetProto.PAUSE, {})
	await _until(func() -> bool: return _state_json(own) == "paused", 5.0)
	await _pump(0.3)
	var wp0 := _opp_status(own, 2)
	await _pump(1.5)
	_ok("  paused mid-wait, the wait does not run down (%s)" % wp0, _opp_status(own, 2), wp0)
	own.s.send(NetProto.RESUME, {})
	await _until(func() -> bool: return _state_json(own) == "running", 8.0)
	drv.send_inputs = false
	var q0 := own.robot_pos(0)
	var hq := own.robot_hopper(0)
	for i in 30:
		drv.s.room.send(1, NetLink.CH_INPUT, stale)
		await _pump(0.03)
	await _pump(0.5)
	_ok("packets from the previous run move nothing and fire nothing",
		[own.robot_pos(0).distance_to(q0) < 0.02, own.robot_hopper(0)], [true, hq])
	drv.send_inputs = true

	print("\n--- A FROZEN CONNECTION CANNOT KEEP A ROBOT DRIVING ---")
	drv.input["move"] = Vector2(0, 1)
	await _pump(0.8)
	_bots.erase(drv)                            # stop polling: no more inputs
	var t_stop := Time.get_ticks_msec()
	await _pump(0.5)
	var f0 := own.robot_pos(0)
	await _pump(0.8)
	_ok("after inputs stop, the robot comes to rest (stale-input timeout 250 ms)",
		own.robot_pos(0).distance_to(f0) < 0.03, true)
	_bots.append(drv)
	drv.input["move"] = Vector2.ZERO

	print("\n--- DISCONNECT, PAUSE, RECONNECT TO THE SAME SEAT ---")
	drv.s.drop_link()
	await _until(func() -> bool: return _state_json(own) == "paused", 8.0)
	_ok("a seated player dropping pauses the room", _state_json(own), "paused")
	_ok("  naming the seat", String(own.s.state.get("pause_reason", "")).contains("driver"), true)
	drv.input["move"] = Vector2(0, 1)
	drv.s.reconnect_now()
	await _until(func() -> bool: return drv.s.phase == "in_room", 10.0)
	_ok("the same player reconnected with their token", drv.s.phase, "in_room")
	_ok("  to the same seat", drv.s.my_seat(), [0, "driver"])
	await _pump(0.5)
	own.s.send(NetProto.RESUME, {})
	await _until(func() -> bool: return _state_json(own) == "running", 8.0)
	var r0 := own.robot_pos(0)
	await _pump(0.8)
	_ok("  a stick still pushed from before the drop does NOT drive", own.robot_pos(0).distance_to(r0) < 0.03, true)
	drv.input["move"] = Vector2.ZERO
	await _pump(0.3)
	drv.input["move"] = Vector2(0, 1)
	await _pump(0.8)
	_ok("  after returning to neutral, it drives again", own.robot_pos(0).distance_to(r0) > 0.2, true)
	drv.input["move"] = Vector2.ZERO

	print("\n--- A PLAYER WHO DOES NOT COME BACK; REASSIGNING THE SEAT ---")
	p3.s.drop_link()
	_bots.erase(p3)
	await _until(func() -> bool: return _state_json(own) == "paused", 8.0)
	await _pump(5.0)                             # grace is 4 s in this test
	var gone := true
	for q in own.s.state.get("parts", []):
		if String(q["name"]) == "Cy":
			gone = false
	_ok("after the grace period the absent player is removed", gone, true)
	_ok("  and their robot's seat is empty, NOT given to the AI", [int(own.s.state["seats"][1]["whole"]), bool(own.s.state["seats"][1]["ai"])], [-1, false])
	own.s.send(NetProto.REASSIGN, {"robot": 1, "role": "whole", "to": spect.s.pid})
	await _pump(0.6)
	_ok("the owner gives the seat to the spectator", spect.s.my_seat(), [1, "whole"])
	own.s.send(NetProto.RESUME, {})
	await _pump(0.6)
	_ok("  resuming now needs fresh readiness from everyone seated", _notices(own).contains("not ready"), true)
	for b5 in [spect, drv, opr]:
		b5.s.send(NetProto.READY, {"on": true})
	await _pump(0.4)
	own.s.send(NetProto.RESUME, {})
	await _until(func() -> bool: return _state_json(own) == "running", 8.0)
	_ok("  after they are ready, the room resumes", _state_json(own), "running")

	print("\n--- LOCK, REMOVE ---")
	own.s.send(NetProto.LOCK, {"on": true})
	await _pump(0.8)
	var late := _bot("Late")
	late.join(inv_a)
	await _until(func() -> bool: return late.s.phase == "failed", 10.0)
	_ok("a locked room refuses new players", late.s.error_reason, "locked")
	own.s.send(NetProto.LOCK, {"on": false})
	own.s.send(NetProto.PAUSE, {})
	await _pump(0.5)
	own.s.send(NetProto.KICK, {"pid": spect.s.pid})
	await _until(func() -> bool: return spect.s.phase == "closed", 6.0)
	_ok("a removed player is told", [spect.s.phase, spect.s.error_text.contains("removed")], ["closed", true])
	spect.s.reconnect_now()
	await _until(func() -> bool: return spect.s.phase == "failed", 10.0)
	_ok("  and their token no longer works", spect.s.error_reason, "expired")

	print("\n--- ROOMS ARE SEPARATE ---")
	var hb: Array = await _host(PORT_B, "Other")
	host_b = hb[0]
	var inv_b: String = hb[1]
	var own_b := _bot("Other")
	own_b.join(inv_b)
	await _until(func() -> bool: return own_b.s.phase == "in_room", 30.0)
	var wrong := _bot("Wrong room")
	var pa := NetInvite.parse(inv_a)
	wrong.join_with_secret("127.0.0.1", PORT_B, String(pa["secret"]))
	await _until(func() -> bool: return wrong.s.phase == "failed", 10.0)
	_ok("room A's invite secret does not open room B", wrong.s.error_reason, "invalid")
	var cross := _bot("Cross")
	cross.s.token = drv.s.token
	cross.s.link_factory = func() -> NetLink: return NetLink.enet_client("127.0.0.1", PORT_B)
	cross.s.reconnect_now()
	await _until(func() -> bool: return cross.s.phase == "failed", 10.0)
	_ok("a seat token from room A does not open room B", cross.s.error_reason, "expired")
	_ok("room B knows nothing of room A's players", (own_b.s.state.get("parts", []) as Array).size(), 1)
	_ok("  and receives no snapshots of A's field", own_b.s.snaps_in, 0)

	print("\n--- RESULTS ARE THE HOST'S SIMULATION'S, AND EVERYONE GETS THE SAME ONE ---")
	own.s.send(NetProto.LOBBY, {})
	await _pump(0.8)
	var timed := good_snap.duplicate(true)
	timed["objective"] = Objective.blank()
	timed["objective"]["kind"] = Objective.Kind.TIPS
	timed["objective"]["amount"] = 8
	timed["objective"]["time_limit"] = 2.0
	_share(own, timed)
	await _pump(0.3)
	var tn := _notices(own)
	if tn != "":
		print("    owner was told: ", tn)
	await _until(func() -> bool: return int(drv.s.scenario_rev) == int(own.s.state.get("scenario", {}).get("rev", -1)), 10.0)
	await _pump(0.5)
	opr.s.send(NetProto.SEAT, {"robot": 1, "role": "whole"})
	await _pump(0.3)
	drv.s.send(NetProto.SEAT, {"robot": 0, "role": "whole"})
	await _pump(0.5)
	for b4 in [drv, opr]:
		b4.s.send(NetProto.READY, {"on": true})
	await _pump(0.5)
	own.s.send(NetProto.START, {})
	await _until(func() -> bool: return _state_json(own) == "results", 20.0)
	_ok("a timed objective ends the run for everyone", [_state_json(drv), _state_json(opr)], ["results", "results"])
	_ok("  with the same result", drv.s.result, opr.s.result)
	_ok("  a failed objective, on time", [String(drv.s.result.get("state", "")), String(drv.s.result.get("reason", ""))], ["failed", "timeout"])

	print("\n--- EACH PLAYER KEEPS THEIR OWN REPLAYS ---")
	await _pump(1.0)
	var listed := ReplayStore.list(dir)
	var online := listed.filter(func(e) -> bool: return String(e.get("kind", "")) == "online")
	print("    %d online replays written by the bots" % online.size())
	_ok("every bot saved the runs it was in", online.size() >= 6, true)
	var complete := online.filter(func(e) -> bool: return String(e.get("health", "")) == "ok")
	_ok("  the finished ones are complete", complete.size() >= 3, true)
	var sp_w: NetReplayWriter = spect.get_meta("writer") if spect.has_meta("writer") else null
	_ok("  the player who joined mid-run still got the run from its start", sp_w != null and sp_w.gaps == 0 and sp_w.bad == 0, true)
	var ex: Dictionary = complete[0] if not complete.is_empty() else {}
	_ok("  labelled Online practice, with the roster", [String(ex.get("mode_name", "")),
		(ex.get("online", {}) as Dictionary).has("roster")], ["Online practice", true])
	_save_state({"replay": String(ex.get("id", ""))})

	print("\n--- THE HOST LEAVING ENDS THE SESSION; ITS INVITE STOPS WORKING ---")
	own.s.leave()
	_bots.erase(own)
	await _until(func() -> bool: return drv.s.phase == "closed", 8.0)
	_ok("everyone is told the session ended, and why", [drv.s.phase, drv.s.error_text.contains("host")], ["closed", true])
	var dw: NetReplayWriter = drv.get_meta("writer") if drv.has_meta("writer") else null
	_ok("  each player's replays so far are kept", dw != null and ReplayStore.list(dir).size() >= online.size(), true)
	await _pump(1.5)
	var after := _bot("After")
	after.join(inv_a)
	await _until(func() -> bool: return after.s.phase == "failed", 12.0)
	_ok("the ended room's invite no longer connects", after.s.error_reason, "unreachable")
	own_b.s.leave()

func _save_state(d: Dictionary) -> void:
	var cur := {}
	if FileAccess.file_exists(STATE):
		var v: Variant = ReplayStore.parse_json(FileAccess.get_file_as_string(STATE))
		cur = v if v is Dictionary else {}
	cur.merge(d, true)
	var f := FileAccess.open(STATE, FileAccess.WRITE)
	f.store_string(JSON.stringify(cur))
	f.close()

# =================================================================== read ==

func _read_phase() -> void:
	var st: Variant = ReplayStore.parse_json(FileAccess.get_file_as_string(STATE))
	var dir := String(st["dir"])
	print("\n--- COLD START: ONLINE REPLAYS, OFFLINE ---")
	var list := ReplayStore.list(dir)
	var e := {}
	for x in list:
		if String(x["id"]) == String(st["replay"]):
			e = x
	_ok("the online replay survived the restart", String(e.get("health", "")), "ok")
	var r := ReplayReader.new()
	_ok("  it opens", r.open(ReplayStore.recording_path(String(st["replay"]), dir)), "")
	var cp := r.checkpoint(mini(1, r.checkpoints.size() - 1))
	_ok("  its checkpoints are complete situations", Snapshot.validate(cp), "")
	var sit := ReplayBranch.make_situation(cp, r.id, r.title())
	var sid := ScenarioLibrary.save(sit, "Harness from online", "")
	await main.play_situation(sid)
	await get_tree().create_timer(0.5).timeout
	_ok("Practise from here works offline: the online moment plays here", main.mm.in_progress(), true)
	_ok("  with the online roster (a human-driven opponent stays human)",
		[main.robots.size(), (main.robots[1] as Robot).ai_driver, (main.robots[2] as Robot).ai_driver], [3, false, true])
	_ok("  and this computer's controls on robot 1", (main.robots[0] as Robot).device != DriverInput.NONE, true)
	main.menu.end_match.emit()
	ScenarioLibrary.delete_one(sid)
	r.close()
	var prev: Variant = st.get("prev", {})
	ReplayStore._write_json_atomic(ReplayStore.CONFIG, prev if prev is Dictionary else {})
	ReplayStore.reload_folder()
