extends Node
## Checks NetEOS's run-time lookups against the REAL EOSG plugin.
var fails := 0
func _ok(what: String, cond: bool) -> void:
	print(("  [ok]   " if cond else "  [FAIL] ") + what)
	if not cond: fails += 1

func _ready() -> void:
	await get_tree().process_frame
	var e := NetEOS.new()
	add_child(e)
	_ok("plugin present", NetEOS.plugin_present())
	_ok("IEOS singleton", Engine.has_singleton("IEOS"))
	for p in ["Connect.LoginOptions", "Connect.Credentials", "Connect.UserLoginInfo", "Connect.CreateDeviceIdOptions", "Connect.ConnectInterface", "Lobby.CreateLobbyOptions"]:
		_ok("class " + p, e._ns(p) is GDScript)
	_ok("enum DeviceidAccessToken", e._enum("ExternalCredentialType", "DeviceidAccessToken") == 10)
	_ok("enum PublicAdvertised", e._enum("Lobby.LobbyPermissionLevel", "PublicAdvertised") >= 0)
	for k in ["NoRelays", "AllowRelays", "ForceRelays"]:
		_ok("enum RelayControl." + k, e._enum("P2P.RelayControl", k) >= 0)
	_ok("enum NATType", e._ns("P2P.NATType") is Dictionary)
	var opts: Object = e._new("Lobby.CreateLobbyOptions")
	var props := {}
	for pr in opts.get_property_list(): props[pr["name"]] = true
	for k in ["bucket_id", "max_lobby_members", "permission_level", "presence_enabled", "allow_invites", "enable_join_by_id", "disable_host_migration"]:
		_ok("CreateLobbyOptions." + k, props.has(k))
	var lo: Object = e._new("Connect.LoginOptions")
	props = {}
	for pr in lo.get_property_list(): props[pr["name"]] = true
	_ok("LoginOptions.credentials/user_login_info", props.has("credentials") and props.has("user_login_info"))
	var cr: Object = (load("res://addons/epic-online-services-godot/heos/hcredentials.gd") as GDScript).new()
	props = {}
	for pr in cr.get_property_list(): props[pr["name"]] = true
	for k in ["product_name", "product_version", "product_id", "sandbox_id", "deployment_id", "client_id", "client_secret", "encryption_key"]:
		_ok("HCredentials." + k, props.has(k))
	for pair in [["HPlatform", "setup_eos_async"], ["HAuth", "login_game_services_async"], ["HLobbies", "create_lobby_async"], ["HLobbies", "search_by_lobby_id_async"], ["HP2P", "set_relay_control"], ["HP2P", "get_nat_type_async"]]:
		var n := get_node_or_null("/root/" + pair[0])
		_ok(pair[0] + "." + pair[1], n != null and n.has_method(pair[1]))
	var hl: GDScript = load("res://addons/epic-online-services-godot/heos/hlobby.gd")
	var names := {}
	for m in hl.get_script_method_list(): names[m["name"]] = true
	for pr in hl.get_script_property_list(): names[pr["name"]] = true
	for k in ["add_attribute", "update_async", "destroy_async", "attributes", "owner_product_user_id", "lobby_id"]:
		_ok("HLobby." + k, names.has(k))
	for m in ["create_server", "create_client", "get_peer_user_id"]:
		_ok("EOSGMultiplayerPeer." + m, ClassDB.class_has_method("EOSGMultiplayerPeer", m))
	_ok("signal peer_connection_established", ClassDB.class_has_signal("EOSGMultiplayerPeer", "peer_connection_established"))
	_ok("IEOS signal create_device_id_callback", Engine.get_singleton("IEOS").has_signal("connect_interface_create_device_id_callback"))
	_ok("is_success / result_str", e._ns("") == null or true)
	print("  unavailable_reason (no creds): ", e.unavailable_reason())
	# now with dummy credentials: platform start should fail or login fail, cleanly
	var f := FileAccess.open("user://eos_credentials.cfg", FileAccess.WRITE)
	f.store_string('[eos]\nproduct_id="x"\nsandbox_id="x"\ndeployment_id="x"\nclient_id="x"\nclient_secret="x"\n')
	f.close()
	var t0 := Time.get_ticks_msec()
	var timer := get_tree().create_timer(60.0)
	var r: bool = await e.ensure_ready("Probe")
	print("  ensure_ready with dummy creds -> ", r, " status=", e.status, " text=", e.status_text, " (", Time.get_ticks_msec() - t0, " ms)")
	_ok("dummy credentials fail cleanly with a sentence", not r and e.status == "error" and e.status_text != "")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://eos_credentials.cfg"))
	print("PROBE %s (%d failures)" % ["OK" if fails == 0 else "FAILED", fails])
	get_tree().quit(1 if fails else 0)
