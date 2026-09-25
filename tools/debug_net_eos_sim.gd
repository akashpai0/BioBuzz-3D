extends Node
## SIMULATED EPIC ONLINE SERVICES: THE INTERNET PATH'S OWN CODE, WITHOUT EPIC.
##
## The real internet path needs the EOSG plugin, Epic credentials and Epic's
## servers, none of which this machine has. This runs NetEOS and NetClient's
## real host / join code against stand-ins with EOSG's API (tools/fake_eos):
## a lobby "service" that is a file, anonymous device-id login, and links
## that are really ENet on 127.0.0.1 labelled with the route the relay
## setting would give. Two separate programs: this one hosts, a second one
## (tools/eos_sim_guest.tscn) joins with the invite.
##
## SIMULATED. It checks the game's logic around EOS; it says nothing about
## Epic's service, NAT punch-through or relays.
var main: Node3D
var fails := 0
var checks := 0

func _ok(what: String, got: Variant, want: Variant = true) -> void:
	checks += 1
	var good: bool = got == want
	if not good:
		fails += 1
	print("  [%s] %s%s" % ["ok" if good else "FAIL", what, "" if good else "  (got %s, want %s)" % [got, want]])

static func port_for(user: String) -> int:
	return 17700 + absi(hash(user)) % 50

func _ready() -> void:
	OS.set_environment("FAKE_EOS_DEVICE", "host")
	for p in ["user://fake_eos_device_host.txt", "user://fake_eos_device_guest.txt", FakeEOS.REG,
			"user://eos_sim_invite.txt", "user://eos_sim_guest.json"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	var cf := ConfigFile.new()
	for k in ["product_id", "sandbox_id", "deployment_id", "client_id", "client_secret"]:
		cf.set_value("eos", k, "simulated-" + k)
	cf.save("user://eos_credentials.cfg")
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(3.0).timeout
	var net: NetClient = main.net
	FakeEOS.install(get_tree(), net.eos, port_for)

	print("\n--- HOSTING OVER (SIMULATED) EOS ---")
	_ok("with the plugin and credentials present, internet play is offered", net.eos.unavailable_reason(), "")
	var err: String = await net.host_room("Sim room", "Host", "internet")
	_ok("the game hosted a room over EOS", err, "")
	_ok("  after logging in anonymously with a new device id", [net.eos.status, net.eos.product_user_id != "",
		FileAccess.file_exists("user://fake_eos_device_host.txt")], ["ready", true, true])
	_ok("  NAT type read", net.eos.nat_type, "moderate")
	var inv := NetInvite.parse(net.invite)
	_ok("the invite is an internet one: lobby id, this host's id, a secret", [inv.get("kind"),
		String(inv.get("host", "")) == net.eos.product_user_id], ["eos", true])
	var reg := FakeEOS.read()
	var attrs := {}
	if reg.has(String(inv.get("lobby", ""))):
		for a in reg[inv["lobby"]]["attributes"]:
			attrs[a["key"]] = a["value"]
	_ok("the lobby lists build, room name and 'not locked' — and NOT the secret",
		[attrs.get("bb_compat"), attrs.get("bb_room"), attrs.get("bb_locked"), str(attrs).contains(String(inv.get("secret", "x")))],
		[NetRole.compat(), "Sim room", false, false])
	var fi := FileAccess.open("user://eos_sim_invite.txt", FileAccess.WRITE)
	fi.store_string(net.invite)
	fi.close()
	OS.set_environment("FAKE_EOS_DEVICE", "guest")
	var guest := OS.create_process(OS.get_executable_path(), ["--path",
		ProjectSettings.globalize_path("res://"), "--headless", "res://tools/eos_sim_guest.tscn"])
	OS.set_environment("FAKE_EOS_DEVICE", "host")
	net.share_standard("1v0_free")
	await _until(func() -> bool: return net._built_rev >= 1, 30.0)
	net.send(NetProto.SEAT, {"robot": 0, "role": "driver"})
	var ok := await _until(func() -> bool:
		for q in net.session.state.get("parts", []):
			if String(q["name"]) == "Guest" and bool(q["ready"]):
				return true
		return false, 60.0)
	_ok("a second program found the room from the invite and joined as operator", ok, true)
	net.send(NetProto.READY, {"on": true})
	await _until(func() -> bool: return (net.session.state.get("blockers", ["x"]) as Array).is_empty(), 10.0)
	net.send(NetProto.START)
	await _until(func() -> bool: return net.room_state() == "running", 20.0)
	var h0 := (main.robots[0] as Robot).hopper.size()
	await get_tree().create_timer(3.0).timeout
	_ok("the guest's operator inputs reach the host's world", (main.robots[0] as Robot).hopper.size() < h0, true)

	print("\n--- WHAT A JOINER IS TOLD ---")
	net.send(NetProto.LOCK, {"on": true})
	await get_tree().create_timer(1.0).timeout
	var r_locked: Dictionary = await net.eos.resolve(inv)
	_ok("a locked room: the lobby says so before any connection is tried", [r_locked.get("ok"), r_locked.get("reason")], [false, "locked"])
	net.send(NetProto.LOCK, {"on": false})
	await get_tree().create_timer(1.0).timeout
	var forged := inv.duplicate()
	forged["host"] = "ffffffffffffffffffffffffffffffff"
	var r_forged: Dictionary = await net.eos.resolve(forged)
	_ok("an invite whose host id does not match the lobby's owner is refused", r_forged.get("reason"), "invalid")
	var reg2 := FakeEOS.read()
	var saved_attrs: Array = reg2[inv["lobby"]]["attributes"].duplicate(true)
	for a2 in reg2[inv["lobby"]]["attributes"]:
		if a2["key"] == "bb_compat":
			a2["value"] = "p9-r9-s9-f9-t9"
	FakeEOS.write(reg2)
	var r_old: Dictionary = await net.eos.resolve(inv)
	_ok("a room on a different build is refused with both versions named", [r_old.get("reason"), String(r_old.get("error", "")).contains(NetRole.GAME_VERSION)], ["incompatible", true])
	reg2[inv["lobby"]]["attributes"] = saved_attrs
	FakeEOS.write(reg2)

	print("\n--- THE HOST ENDS THE SESSION ---")
	net.leave("done")
	await _until(func() -> bool: return net.room == null and not net.in_room(), 10.0)
	await get_tree().create_timer(1.0).timeout
	_ok("the room's lobby entry is removed", FakeEOS.read().has(String(inv["lobby"])), false)
	var r_closed: Dictionary = await net.eos.resolve(inv)
	_ok("  so its invite now says the room is not open any more", [r_closed.get("reason"), String(r_closed.get("error", "")).contains("not open")], ["closed", true])
	await _until(func() -> bool: return FileAccess.file_exists("user://eos_sim_guest.json"), 20.0)
	var g: Variant = JSON.parse_string(FileAccess.get_file_as_string("user://eos_sim_guest.json"))
	if g is Dictionary:
		print("    guest: ", g)
		_ok("the guest logged in with its own device id (a different player id)", String(g.get("user", "")) != net.eos.product_user_id and String(g.get("user", "")) != "", true)
		_ok("  forced relay was applied and shown as 'relayed'", String(g.get("route", "")), "relayed")
		_ok("  and it was told the host ended the session", String(g.get("end", "")).contains("host"), true)
	else:
		_ok("the guest program reported back", false, true)
	OS.kill(guest)
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://eos_credentials.cfg"))
	print("  EOS SIMULATION %s (%d checks, %d failures)" % ["OK" if fails == 0 else "BROKEN", checks, fails])
	get_tree().quit(1 if fails > 0 else 0)

func _until(cond: Callable, secs: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(secs * 1000.0) and not cond.call():
		await get_tree().process_frame
	return cond.call()
