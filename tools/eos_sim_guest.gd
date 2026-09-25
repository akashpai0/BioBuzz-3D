extends Node
## The second program of debug_net_eos_sim: a full copy of the game that
## joins the simulated-EOS room from the invite file, with "Always relay" set,
## takes OPERATOR on robot 1, readies and fires. Writes what it saw.
var main: Node3D

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(3.0).timeout
	var net: NetClient = main.net
	FakeEOS.install(get_tree(), net.eos, preload("res://tools/debug_net_eos_sim.gd").port_for)
	net.eos.set_relay_mode("force")
	var inv := FileAccess.get_file_as_string("user://eos_sim_invite.txt").strip_edges()
	var err: String = await net.join_room(inv, "Guest")
	var out := {"join_error": err}
	var t0 := Time.get_ticks_msec()
	while not net.in_room() and Time.get_ticks_msec() - t0 < 30000:
		await get_tree().process_frame
	out["joined"] = net.in_room()
	out["user"] = net.eos.product_user_id
	while net.session.scenario_rev < 1 and Time.get_ticks_msec() - t0 < 40000:
		await get_tree().process_frame
	net.send(NetProto.SEAT, {"robot": 0, "role": "operator"})
	await get_tree().create_timer(0.5).timeout
	net.send(NetProto.READY, {"on": true})
	await get_tree().create_timer(1.0).timeout
	print("[guest] part=", net.session.my_part(), " rev=", net.session.scenario_rev, " err=", net.session.scenario_error, " state_rev=", net.session.state.get("scenario", {}).get("rev"), " lobby msg=", net.lobby._msg.text if net.lobby._msg else "")
	var last_p := 0
	while net.room_state() != "running" and Time.get_ticks_msec() - t0 < 60000:
		if Time.get_ticks_msec() - last_p > 4000:
			last_p = Time.get_ticks_msec()
			print("[guest] waiting: state=", net.room_state(), " built=", net._built_rev, " building=", net._building, " snaps=", net.session.snaps.size(), " acked=", net._acked_run, " run=", net.session.state.get("run"))
		await get_tree().process_frame
	out["route"] = net.session.route
	# anything held from before the countdown is ignored until let go, so
	# press after the run has started, like a person would
	await get_tree().create_timer(0.5).timeout
	# hold fire as the operator (this program's keyboard)
	var ev := InputEventKey.new()
	for k in [KEY_SPACE]:
		ev.keycode = k
		ev.physical_keycode = k
		ev.pressed = true
		Input.parse_input_event(ev)
	await get_tree().create_timer(1.0).timeout
	print("[guest] device=", net._device, " fire pressed=", DriverInput.pressed(net._device, "fire"), " seq=", net.session.seq, " state=", net.room_state(), " menu=", net.menu_open)
	while net.in_room() and Time.get_ticks_msec() - t0 < 120000:
		await get_tree().process_frame
	out["end"] = net.session.error_text
	var f := FileAccess.open("user://eos_sim_guest.json.tmp", FileAccess.WRITE)
	f.store_string(JSON.stringify(out))
	f.close()
	DirAccess.rename_absolute(ProjectSettings.globalize_path("user://eos_sim_guest.json.tmp"),
		ProjectSettings.globalize_path("user://eos_sim_guest.json"))
	get_tree().quit(0)
