class_name NetClient
extends Node
##
## THIS COMPUTER'S SIDE OF AN ONLINE ROOM — AS THE HOST OR AS A GUEST.
##
## HOSTING: this computer's own world becomes the room's simulation. A
##          NetRoomServer runs inside this game; the host plays through an
##          in-process link to it, exactly like a guest, and sees the live
##          world (not a puppet). Guests reach it over Epic Online Services
##          peer-to-peer (or the local network).
## GUEST:   sends only what this player's seat may press, shaped by their own
##          controller profile. The world here is a PUPPET (BB.puppet): built
##          from the shared scenario, every body frozen, posed from the host's
##          snapshots, interpolated a little behind the newest. Nothing on a
##          guest's computer is authoritative: no prediction, no local
##          physics, no local scoring.
##
## Offline play is untouched: none of this runs unless the player goes to
## Play -> Online practice.
##

const CONFIG := "user://online.json"
## Same-network rooms listen here (the next few ports are tried if it is busy).
const LAN_PORT := 24560
const INPUT_EVERY := 3                 # physics ticks: 60 inputs per second
const TICK_HZ := 180.0

var main: Node3D
var session: NetSession
var writer := NetReplayWriter.new()
var online_screen: OnlineScreen
var lobby: LobbyScreen
var hud: NetHud

var display_name := ""
## internet | lan
var method := "internet"
var eos: NetEOS
## Hosting: the room this computer runs, and its invite.
var room: NetRoomServer
var hosting := false
var invite := ""
var _room_method := ""
var _relay_saved := "allow"
var _tearing := false
## Between pressing Host / Join and the first answer (EOS login, lookup).
var _starting := false
var menu_open := false
var _built_rev := -1
var _building := false
var _nodes := {}
var _last_run := -1
var _acked_run := -1
var _counters := {}
var _device := DriverInput.NONE
var _was_menu := false
var _last_phase := ""
## Interpolation clock
var _base_offset := INF
var _samples: Array = []               # [local_ticks - server_tick]
var delay_ticks := 9.0
var render_tick := 0.0
## Measured, for tests and the HUD
var input_latency_ms := -1.0
var _probe := {}

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_config()
	eos = NetEOS.new()
	eos.name = "EOS"
	add_child(eos)
	eos.process_mode = Node.PROCESS_MODE_ALWAYS
	eos.relay_mode = _relay_saved
	online_screen = OnlineScreen.new()
	online_screen.client = self
	add_child(online_screen)
	online_screen.build()
	lobby = LobbyScreen.new()
	lobby.client = self
	add_child(lobby)
	lobby.build()
	hud = NetHud.new()
	hud.client = self
	add_child(hud)
	hud.build()

func _load_config() -> void:
	var cfg: Variant = null
	if FileAccess.file_exists(CONFIG):
		cfg = ReplayStore.parse_json(FileAccess.get_file_as_string(CONFIG))
	if cfg is Dictionary:
		display_name = String((cfg as Dictionary).get("name", ""))
		method = String((cfg as Dictionary).get("method", "internet"))
		_relay_saved = String((cfg as Dictionary).get("relay", "allow"))
	if not (method in ["internet", "lan"]):
		method = "internet"
	if display_name == "":
		display_name = Leaderboard.player_name()

func save_config() -> void:
	ReplayStore._write_json_atomic(CONFIG, {"name": display_name, "method": method,
		"relay": eos.relay_mode if eos else _relay_saved})

## True from the moment a room is being joined until the player is back in
## the offline menus.
func active() -> bool:
	return _starting or (session != null and session.phase in ["entering", "in_room", "reconnecting"])

func in_room() -> bool:
	return session != null and session.phase in ["in_room", "reconnecting"]

func room_state() -> String:
	return String(session.state.get("state", "")) if session else ""

# =============================================================== screens ===

func open_online() -> void:
	online_screen.open()

## HOST A ROOM FROM THIS GAME. Returns "" or a sentence saying why not.
## A browser can open neither Epic's peer-to-peer links nor raw UDP, so the
## browser version is offline practice only.
const WEB_NO_ONLINE := ("Online rooms need the downloadable version of the game: a browser "
	+ "can't open the connections a room uses. Offline practice, drills and replays all work here.")

func host_room(room_title: String, name: String, how: String) -> String:
	if OS.has_feature("web"):
		return WEB_NO_ONLINE
	display_name = NetProto.clean_name(name)
	method = how
	save_config()
	if active() or room != null:
		return "Already in a room."
	_starting = true
	var secret := NetInvite.new_secret()
	var ext: NetLink = null
	if how == "internet":
		if not await eos.ensure_ready(display_name):
			_starting = false
			return eos.status_text
		var r: Dictionary = await eos.host(room_title, secret)
		if not bool(r.get("ok", false)):
			_starting = false
			return String(r.get("error", "Could not open the room."))
		ext = r["link"]
		invite = String(r["invite"])
	else:
		for k in 8:
			ext = NetLink.enet_server(LAN_PORT + k, NetRole.MAX_PARTICIPANTS + 4)
			if ext.error == OK:
				var addrs := NetInvite.lan_addresses()
				invite = NetInvite.make_lan(String(addrs[0]) if not addrs.is_empty() else "127.0.0.1",
					LAN_PORT + k, secret)
				break
		if ext == null or ext.error != OK:
			_starting = false
			return "Could not open a network port for the room on this computer."
	_room_method = how
	room = NetRoomServer.new()
	room.name = "Room"
	room.main = main
	room.room_name = NetProto.clean_name(room_title)
	room.code = invite
	room.invite_secret = secret
	add_child(room)
	var pair := NetLink.loop_pair()
	room.add_link(pair[0])
	room.add_link(ext)
	room.closed.connect(_on_room_closed)
	if how == "internet":
		room.status_changed.connect(func(st: Dictionary) -> void: eos.update_room(st))
	hosting = true
	_new_session()
	session.connect_timeout_ms = 5000
	var mine: NetLink = pair[1]
	session.join(func() -> NetLink: return mine, secret, display_name)
	_starting = false
	return ""

## JOIN A ROOM FROM AN INVITE. Returns "" or a sentence saying why not.
func join_room(invite_text: String, name: String) -> String:
	if OS.has_feature("web"):
		return WEB_NO_ONLINE
	display_name = NetProto.clean_name(name)
	save_config()
	if active() or room != null:
		return "Already in a room."
	var inv := NetInvite.parse(invite_text)
	if not bool(inv.get("ok", false)):
		return String(inv["error"])
	_starting = true
	var factory: Callable
	var timeout := 8000
	if String(inv["kind"]) == "eos":
		if not await eos.ensure_ready(display_name):
			_starting = false
			return eos.status_text
		var r: Dictionary = await eos.resolve(inv)
		if not bool(r.get("ok", false)):
			_starting = false
			return String(r.get("error", "Could not find that room."))
		var host_user := String(r["host"])
		factory = func() -> NetLink: return eos.connect_link(host_user)
		timeout = 25000
	else:
		var addr := String(inv["address"])
		var port := int(inv["port"])
		factory = func() -> NetLink: return NetLink.enet_client(addr, port)
	hosting = false
	invite = invite_text.strip_edges()
	_new_session()
	session.connect_timeout_ms = timeout
	session.join(factory, String(inv["secret"]), display_name)
	_starting = false
	return ""

## Tests (headless host): run a same-network room with no local player; the
## joiner named `owner_name` gets the host's controls. Returns the invite.
func host_headless(room_title: String, port: int, owner_name: String) -> String:
	var secret := NetInvite.new_secret()
	var ext := NetLink.enet_server(port, NetRole.MAX_PARTICIPANTS + 4)
	if ext.error != OK:
		return ""
	invite = NetInvite.make_lan("127.0.0.1", port, secret)
	room = NetRoomServer.new()
	room.name = "Room"
	room.main = main
	room.room_name = NetProto.clean_name(room_title)
	room.code = invite
	room.invite_secret = secret
	room.test_owner_name = owner_name
	add_child(room)
	room.add_link(ext)
	room.closed.connect(func(_w: String) -> void:
		room.queue_free()
		room = null)
	return invite

func _new_session() -> void:
	if session:
		session.leave()
	session = NetSession.new()
	session.sim_spec = String(NetRole.arg("net-sim", ""))
	session.replay_hook = _on_chunk
	if NetRole.args.has("reconnect-window"):
		session.reconnect_window_ms = int(float(NetRole.arg("reconnect-window", "60")) * 1000.0)
	writer = NetReplayWriter.new()
	session.changed.connect(_on_changed)
	_built_rev = -1
	_last_run = -1
	_acked_run = -1

## Back to the offline game, with a sentence saying why.
## The host pressed End session (its own screen then says so in its own words).
var _ended_by_me := false

func leave(why := "") -> void:
	if hosting and room != null:
		# THE HOST LEAVING ENDS THE SESSION for everyone (no host migration):
		# every guest is told, every replay is kept
		_ended_by_me = true
		room.end_session("The host ended the session.")
		return
	if session:
		session.leave()
	writer.finish(why if why != "" else "You left the room before the run ended.")
	_teardown(why)

func _on_room_closed(why: String) -> void:
	var was_internet := _room_method == "internet"
	if room:
		room.queue_free()
	room = null
	if was_internet:
		eos.close_room()
	if session and session.phase in ["in_room", "reconnecting", "entering"]:
		session.phase = "closed"
		session.error_text = why
		writer.finish("The session ended before the run did.")
		_teardown(why)

func _teardown(why: String) -> void:
	if _tearing:
		return
	_tearing = true
	if _ended_by_me:
		why = "You ended the session. Everyone keeps their replays."
		_ended_by_me = false
	menu_open = false
	hud.close()
	lobby.close()
	if hosting:
		hosting = false
		DriverInput.clear_all_virtual()
		main.mm.abort()
		BB.set_menu_halt(false)
		main.objective_hud.visible = true
		await main.stage()
	if BB.puppet:
		BB.set_puppet(false)
		for r in main.robots:
			if is_instance_valid(r):
				r.release_from_restore(Vector3.ZERO, Vector3.ZERO)
		for a in main.field.hives:
			(main.field.hives[a] as Hive).release_from_restore({})
		main.mm.abort()
		await main.stage()
	main.hud.visible = true
	_built_rev = -1
	invite = ""
	_tearing = false
	online_screen.open()
	if why != "":
		online_screen.show_message(why, true)

# =============================================================== session ===

func _on_changed(what: String) -> void:
	match what:
		"phase":
			if session.phase == "failed":
				var txt := session.error_text
				writer.finish("The connection to the room was lost.")
				if in_room_before():
					_teardown("Lost the room: " + txt)
				else:
					online_screen.show_message(txt, true)
			elif session.phase == "closed":
				writer.finish("The room closed before the run ended.")
				_teardown(session.error_text)
			elif session.phase == "reconnecting":
				hud.notice("Connection lost — reconnecting…")
		"welcome":
			online_screen.close()
			main.hud.visible = false
			if hosting:
				main.objective_hud.visible = false
			_show_room()
		"state":
			_on_state()
		"scenario":
			if session.scenario_error != "":
				lobby.show_message(session.scenario_error, true)
			elif hosting:
				# the host's world IS the room's world: nothing to build
				_built_rev = session.scenario_rev
				_aim_camera()
				lobby.refresh()
				_try_restore_ack()
			elif not _building:
				_build_puppet()
		"result":
			hud.show_result(session.result)
		"notice":
			for n in session.take_notices():
				if lobby.is_open():
					lobby.show_message(n, false)
				hud.notice(n)

var _had_room := false

func in_room_before() -> bool:
	return _had_room

func _show_room() -> void:
	_had_room = true
	var st := room_state()
	if st == "paused" and lobby.is_open():
		hud.open()
		lobby.refresh()
		hud.refresh()
		return                              # changing seats during a pause
	if st in ["", "lobby"]:
		hud.close()
		lobby.open()
	else:
		lobby.close()
		hud.open()
	lobby.refresh()
	hud.refresh()

func _on_state() -> void:
	var run := int(session.state.get("run", 0))
	if run != _last_run:
		_last_run = run
		session.reset_snaps()
		if hosting:
			_aim_camera.call_deferred()
		_counters = {}
		if _device != DriverInput.NONE:
			DriverInput.require_neutral(_device)
	_show_room()
	_try_restore_ack()

func _try_restore_ack() -> void:
	if room_state() != "loading":
		return
	var run := int(session.state.get("run", 0))
	if _acked_run == run or _building or _built_rev != session.scenario_rev:
		return
	if session.snaps.is_empty():
		return
	_acked_run = run
	session.send(NetProto.RESTORE_ACK, {"run": run})

# ========================================================== puppet world ===

func _build_puppet() -> void:
	if session.scenario.is_empty():
		return
	_building = true
	var rev := session.scenario_rev
	var model := RobotShop.model_path
	# built-in visuals online: other players' CAD models are not shared
	RobotShop.model_path = ""
	BB.set_puppet(false)
	await Snapshot.restore(main, session.scenario, true)
	RobotShop.model_path = model
	BB.editing = false
	BB.set_puppet(true)
	SFX.stop_all_loops()
	_nodes = WorldPose.index(main)
	_built_rev = rev
	_building = false
	_aim_camera()
	lobby.refresh()
	_try_restore_ack()
	if rev != session.scenario_rev:
		_build_puppet()                     # a newer one arrived meanwhile

func _aim_camera() -> void:
	var rig: CameraRig = main.rig
	rig.robots = main.robots
	var mine := my_robot()
	if mine >= 0 and mine < main.robots.size():
		rig.target = main.robots[mine]
		rig.follow = mine
		rig.alliance = (main.robots[mine] as Robot).alliance
	elif not main.robots.is_empty():
		rig.target = main.robots[0]
	if rig.mode == CameraRig.Mode.MENU:
		rig.mode = CameraRig.Mode.DRIVER

func my_robot() -> int:
	var st := session.my_seat() if session else []
	return int(st[0]) if not st.is_empty() else -1

func my_role() -> String:
	var st := session.my_seat() if session else []
	return String(st[1]) if not st.is_empty() else ""

# ================================================================ frame ===

func _process(_delta: float) -> void:
	if session == null:
		return
	session.poll()
	if not in_room():
		return
	_pose()
	hud.tick()
	lobby.tick()
	_try_restore_ack()

func _physics_process(_d: float) -> void:
	if session == null or session.phase != "in_room":
		return
	if Engine.get_physics_frames() % INPUT_EVERY != 0:
		return
	_send_input()

## THE INTERPOLATION CLOCK. Each snapshot carries the server tick it was taken
## on. The earliest-arriving one in the last two seconds fixes the offset
## between this computer's clock and the server's; arrival scatter above that
## is jitter. The field is drawn `delay_ticks` behind the newest estimate —
## two snapshot intervals plus twice the measured jitter — so there is almost
## always a snapshot on each side of the moment being drawn.
func _pose() -> void:
	var snaps: Array = session.snaps
	if hosting:
		# the live world is on screen; the newest snapshot only feeds the HUD
		if not snaps.is_empty():
			_shown = snaps[-1]
		return
	if snaps.is_empty() or _built_rev != session.scenario_rev or _building or _nodes.is_empty():
		return
	var now_ticks := float(Time.get_ticks_usec()) / 1e6 * TICK_HZ
	var newest: Dictionary = snaps[-1]
	var arrived_ticks := float(newest["arrived"]) / 1e6 * TICK_HZ
	var sample := arrived_ticks - float(newest["tick"])
	if _samples.is_empty() or _samples[-1][1] != int(newest["tick"]):
		_samples.append([arrived_ticks, int(newest["tick"]), sample])
		while _samples.size() > 1 and arrived_ticks - float(_samples[0][0]) > TICK_HZ * 2.0:
			_samples.pop_front()
		_base_offset = INF
		var jit := 0.0
		for sm in _samples:
			_base_offset = minf(_base_offset, float(sm[2]))
		for sm2 in _samples:
			jit += float(sm2[2]) - _base_offset
		jit /= float(_samples.size())
		# two snapshot intervals (3 ticks each, or 6 on a low-upload host) plus
		# twice the measured jitter
		var every := float(clampi(int(session.state.get("snap_every", 3)), 1, 30))
		delay_ticks = clampf(2.0 * every + 2.0 * jit, 2.0 * every, 60.0)
	var est := now_ticks - _base_offset
	render_tick = est - delay_ticks
	var a: Dictionary = snaps[0]
	var b: Dictionary = {}
	for i in snaps.size():
		var s: Dictionary = snaps[i]
		if float(s["tick"]) <= render_tick:
			a = s
			b = snaps[i + 1] if i + 1 < snaps.size() else {}
		else:
			break
	if float(a["tick"]) > render_tick:
		b = {}                                # older than anything we hold
	var alpha := 0.0
	if not b.is_empty():
		alpha = clampf((render_tick - float(a["tick"])) / maxf(1.0,
			float(b["tick"]) - float(a["tick"])), 0.0, 1.0)
	var lay: Dictionary = a["layout"]
	var fb: PackedFloat32Array = b["row"] if not b.is_empty() else PackedFloat32Array()
	WorldPose.apply(_nodes, a["row"], 0, fb, 0, alpha, not b.is_empty(),
		int(lay["robots"]), int(lay["hives"]), int(lay["elements"]))
	_shown = a

## The snapshot currently on screen (its numbers drive the online HUD).
var _shown: Dictionary = {}

func shown() -> Dictionary:
	return _shown

# ================================================================ input ===

func _send_input() -> void:
	var seat := session.my_seat()
	if seat.is_empty():
		return
	if _device == DriverInput.NONE or not (_device in DriverInput.devices()):
		_pick_device()
	var v := NetProto.neutral_input()
	var blocked: bool = menu_open or main.settings_menu.is_open() \
		or room_state() != "running"
	if blocked:
		v["menu"] = menu_open or main.settings_menu.is_open()
		_was_menu = true
	else:
		if _was_menu:
			_was_menu = false
			DriverInput.require_neutral(_device)
		var d := _device
		v["move"] = DriverInput.move(d)
		v["turn"] = DriverInput.turn(d)
		v["precision"] = DriverInput.precision_scale(d)
		var held := {}
		for a in NetProto.HELD:
			held[a] = DriverInput.pressed(d, a)
		v["held"] = held
		for a2 in NetProto.PRESSES:
			if DriverInput.just_pressed(d, a2):
				_counters[a2] = (int(_counters.get(a2, 0)) + 1) & 0xFF
	v["presses"] = _counters.duplicate()
	_probe_latency(v)
	session.send_input(v)

## This player's controller: the one their seat 1 uses offline, with seat 1's
## profile. The device number never leaves this computer.
func _pick_device() -> void:
	var devs := Settings.allocate_devices(1, DriverInput.devices())
	_device = int(devs[0]) if not devs.is_empty() else -1
	DriverInput.set_profile(_device, Settings.seat_profile(0))
	DriverInput.require_neutral(_device)

## INPUT-TO-SCREEN, measured: when the stick first leaves centre, note the
## sequence number; when a snapshot acknowledges that sequence AND shows this
## robot moving, the gap is what the player waited.
func _probe_latency(v: Dictionary) -> void:
	var moving := (v["move"] as Vector2).length() > 0.5
	if moving and _probe.is_empty():
		_probe = {"seq": session.seq + 1, "t": Time.get_ticks_usec(), "pos": _my_pos()}
	elif not moving:
		_probe = {}
	if not _probe.has("done") and not _probe.is_empty():
		var p := _my_pos()
		if p != Vector3.INF and _probe["pos"] != Vector3.INF \
				and p.distance_to(_probe["pos"]) > 0.02:
			input_latency_ms = float(Time.get_ticks_usec() - int(_probe["t"])) / 1000.0
			_probe["done"] = true

func _my_pos() -> Vector3:
	var r := my_robot()
	if r < 0 or r >= main.robots.size() or not is_instance_valid(main.robots[r]):
		return Vector3.INF
	return (main.robots[r] as Robot).global_position

func on_device_lost(label: String) -> void:
	_device = DriverInput.NONE
	set_menu(true)
	hud.notice("%s's controller disconnected. Your robot is neutral; online play continues. Plug it back in, then close this menu." % label)

# ================================================================= menu ===

## THE PERSONAL MENU DOES NOT PAUSE THE ROOM. While it is open this player's
## commands are neutral (the room is told, and shows it to everyone), and
## everyone else keeps playing.
func set_menu(on: bool) -> void:
	menu_open = on
	if session:
		session.send(NetProto.MENU, {"open": on})
	hud.refresh()

func _unhandled_input(ev: InputEvent) -> void:
	if not in_room():
		return
	if main.settings_menu.is_open():
		if ev.is_action_pressed("pause"):
			main.settings_menu.close()
			get_viewport().set_input_as_handled()
		return
	if ev.is_action_pressed("pause"):
		if lobby.is_open():
			return
		set_menu(not menu_open)
		get_viewport().set_input_as_handled()
	elif ev.is_action_pressed("cam_toggle") and not lobby.is_open():
		main.rig.cycle()
		get_viewport().set_input_as_handled()

# =============================================================== replays ===

func _on_chunk(run: int, index: int, bytes: PackedByteArray) -> void:
	var problem := writer.on_chunk(run, index, bytes)
	if problem != "":
		hud.notice(problem)

# ============================================================== commands ===

func owner() -> bool:
	return session != null and session.is_owner

func send(type: int, payload: Dictionary = {}) -> void:
	if session:
		session.send(type, payload)

## Share a saved situation from this computer's library.
func share_situation(id: String) -> String:
	var entry := ScenarioLibrary.load_one(id)
	if String(entry["error"]) != "":
		return String(entry["error"])
	var data: Dictionary = (entry["data"] as Dictionary).duplicate(true)
	var meta: Dictionary = data.get("meta", {})
	meta["name"] = String(entry["name"])
	data["meta"] = meta
	var res := NetScenario.check(data)
	if not bool(res["ok"]):
		return "That situation cannot be shared: %s" % String(res["error"])
	var wire := NetScenario.encode(res["data"])
	send(NetProto.SET_SCENARIO, {"data": wire["data"], "raw_len": wire["raw_len"]})
	return ""

func share_standard(key: String) -> void:
	send(NetProto.SET_SCENARIO, {"standard": key, "profile": {
		"source": RobotShop.source, "specs": RobotShop.specs.duplicate(),
		"name": RobotShop.robot_name}})

## Keep the room's scenario in this computer's library, as a NEW situation.
func save_scenario_locally() -> String:
	if session.scenario.is_empty():
		return ""
	var nm := "%s (from %s)" % [String(session.scenario.get("meta", {}).get("name", "Shared scenario")),
		session.room_name]
	return ScenarioLibrary.save(session.scenario, nm, "Shared in online room %s." % session.room_name)
