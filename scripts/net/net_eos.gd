class_name NetEOS
extends Node
##
## EPIC ONLINE SERVICES: LOGIN, THE ROOM DIRECTORY, AND PEER-TO-PEER LINKS.
##
## Uses the EOSG plugin ("Epic Online Services Godot", MIT, 3ddelano) —
## GDExtension + its high-level autoloads (HPlatform, HAuth, HLobbies, HP2P).
## EVERYTHING HERE IS LOOKED UP AT RUN TIME. No script in this game names an
## EOSG class directly, so a copy of the game without the plugin, or without
## Epic credentials, still opens, still plays offline, and only says so when
## someone picks "Over the internet".
##
## What each piece is for:
##   Connect login (Device ID)  every player gets an anonymous Product User ID
##                              for this game. No Epic account, no sign-in
##                              screen, nothing to install.
##   Lobby                      the host publishes a directory entry: build,
##                              room name, locked, player count. The invite
##                              carries its id. Joiners LOOK IT UP (a search by
##                              id); they never join it, so they cannot fill it.
##   P2P (EOSGMultiplayerPeer)  the game traffic: NAT punch-through between the
##                              two routers, Epic's relay when that fails.
##                              Relay use: allowed (default), forced (to test
##                              the relay path on purpose), or refused.
##
## Credentials come from res://eos_credentials.cfg (built into the game) or
## user://eos_credentials.cfg (for testing without rebuilding). See ONLINE.md.
##

signal status_changed

const ADDON := "res://addons/epic-online-services-godot/"
const EOS_SCRIPT := ADDON + "eos.gd"
const CRED_PATHS := ["user://eos_credentials.cfg", "res://eos_credentials.cfg"]
const SOCKET := "BBROOM"
const BUCKET := "biobuzz3d"

## missing_plugin | missing_credentials | idle | starting | ready | error
var status := "idle"
var status_text := ""
var product_user_id := ""
var nat_type := ""
## allow | force | off
var relay_mode := "allow"

var _eos: GDScript
var _started := false
## Where the EOSG addon lives (the simulated-EOS test points this elsewhere).
var addon_dir := ADDON
## Tests only: make links without EOSG (server: bool, host_user: String) -> NetLink
var link_maker: Callable
var _lobby: Object          # HLobby of the room this computer hosts

# ============================================================ availability ==

static func plugin_present() -> bool:
	return ClassDB.class_exists("EOSGMultiplayerPeer") and ResourceLoader.exists(EOS_SCRIPT)

func _auto(name: String) -> Node:
	return get_node_or_null("/root/" + name)

static func credentials() -> Dictionary:
	for p in CRED_PATHS:
		var cf := ConfigFile.new()
		if cf.load(p) != OK:
			continue
		var d := {}
		for k in ["product_name", "product_version", "product_id", "sandbox_id",
				"deployment_id", "client_id", "client_secret", "encryption_key"]:
			d[k] = String(cf.get_value("eos", k, ""))
		if d["product_id"] != "" and d["client_id"] != "":
			d["source"] = p
			return d
	return {}

## Why internet play is not available, in words; "" when it is.
func unavailable_reason() -> String:
	var present := link_maker.is_valid() or plugin_present()
	if not present or _auto("HPlatform") == null:
		return ("Internet play needs the Epic Online Services plugin (EOSG) in this build. "
			+ "This copy does not have it, so only same-network play is available. See ONLINE.md.")
	if credentials().is_empty():
		return ("Internet play needs this game's Epic Online Services credentials "
			+ "(eos_credentials.cfg). This copy does not have them. See ONLINE.md.")
	return ""

# ================================================================ helpers ==

func _ns(path: String) -> Variant:
	if _eos == null:
		_eos = load(addon_dir + "eos.gd")
	var cur: Variant = _eos
	for part in path.split("."):
		cur = (cur as Script).get_script_constant_map().get(part)
		if cur == null:
			return null
	return cur

func _new(path: String) -> Object:
	var cls: Variant = _ns(path)
	return (cls as GDScript).new() if cls is GDScript else null

func _enum(path: String, key: String) -> int:
	var e: Variant = _ns(path)
	return int((e as Dictionary).get(key, -1)) if e is Dictionary else -1

func _ok(ret: Variant) -> bool:
	return bool(_eos.call("is_success", ret)) if _eos != null else false

func _result(ret: Variant) -> String:
	return String(_eos.call("result_str", ret)) if _eos != null else str(ret)

func _ieos() -> Object:
	return Engine.get_singleton("IEOS") if Engine.has_singleton("IEOS") else null

func _status_to(s: String, t: String) -> void:
	status = s
	status_text = t
	status_changed.emit()

# ================================================================== start ==

## Platform + anonymous login, once. Returns true when ready.
func ensure_ready(display_name: String) -> bool:
	if status == "ready":
		return true
	var why := unavailable_reason()
	if why != "":
		_status_to("missing_plugin" if why.contains("plugin") else "missing_credentials", why)
		return false
	if status == "starting":
		while status == "starting":
			await get_tree().process_frame
		return status == "ready"
	_status_to("starting", "Connecting to Epic Online Services…")
	# THE SERVICE MUST KEEP TICKING WHILE THE SHARED WORLD IS PAUSED: the room
	# halts the scene tree, and EOSG's runtime autoload pumps the SDK from its
	# _process. Pausable, it would stop every packet the moment the host
	# paused — so everything EOS runs on is set to always process.
	for n in ["EOSGRuntime", "HPlatform", "HAuth", "HLobbies", "HP2P", "HLog"]:
		var node := _auto(n)
		if node:
			node.process_mode = Node.PROCESS_MODE_ALWAYS
	if not _started:
		var c := credentials()
		var creds: Object = (load(addon_dir + "heos/hcredentials.gd") as GDScript).new()
		creds.set("product_name", c["product_name"] if c["product_name"] != "" else "BioBuzz3D")
		creds.set("product_version", NetRole.GAME_VERSION)
		for k in ["product_id", "sandbox_id", "deployment_id", "client_id", "client_secret"]:
			creds.set(k, c[k])
		if String(c["encryption_key"]) != "":
			creds.set("encryption_key", c["encryption_key"])
		var ok: bool = await _auto("HPlatform").call("setup_eos_async", creds)
		if not ok:
			_status_to("error", "Epic Online Services did not start. Check the credentials in eos_credentials.cfg and the log.")
			return false
		_started = true
	if not await _login(display_name):
		return false
	apply_relay_mode()
	_status_to("ready", "Connected to Epic Online Services.")
	_refresh_nat()
	return true

## Anonymous, persistent: the same Device ID is reused every time, so a player
## keeps one Product User ID. Only if this computer has none yet is one made.
func _login(display_name: String) -> bool:
	var auth := _auto("HAuth")
	for attempt in 2:
		var opts := _new("Connect.LoginOptions")
		var cred := _new("Connect.Credentials")
		cred.set("type", _enum("ExternalCredentialType", "DeviceidAccessToken"))
		cred.set("token", null)
		opts.set("credentials", cred)
		var info := _new("Connect.UserLoginInfo")
		info.set("display_name", NetProto.clean_name(display_name).substr(0, 32))
		opts.set("user_login_info", info)
		var ok: bool = await auth.call("login_game_services_async", opts)
		if ok:
			product_user_id = String(auth.get("product_user_id"))
			return product_user_id != ""
		if attempt == 0:
			# no Device ID on this computer yet: make one, then try again
			var copts := _new("Connect.CreateDeviceIdOptions")
			copts.set("device_model", "%s %s" % [OS.get_name(), OS.get_model_name()])
			(_ns("Connect.ConnectInterface") as GDScript).call("create_device_id", copts)
			var ret: Variant = await Signal(_ieos(), "connect_interface_create_device_id_callback")
			if not _ok(ret) and _result(ret) != "DuplicateNotAllowed":
				_status_to("error", "Could not create this computer's anonymous Epic ID (%s)." % _result(ret))
				return false
	_status_to("error", "Could not sign in to Epic Online Services anonymously. Check the client policy (ONLINE.md) and the log.")
	return false

## allow: direct when possible, Epic's relay when not (normal play)
## force: always through the relay (to prove the relay path works)
## off:   never through the relay (to prove the direct path works)
func set_relay_mode(mode: String) -> void:
	relay_mode = mode
	if status == "ready":
		apply_relay_mode()

func apply_relay_mode() -> void:
	var key: String = {"allow": "AllowRelays", "force": "ForceRelays", "off": "NoRelays"}.get(relay_mode, "AllowRelays")
	_auto("HP2P").call("set_relay_control", _enum("P2P.RelayControl", key))

func _refresh_nat() -> void:
	var t: Variant = await _auto("HP2P").call("get_nat_type_async")
	var names: Dictionary = _ns("P2P.NATType") if _ns("P2P.NATType") is Dictionary else {}
	nat_type = "unknown"
	for k in names:
		if int(names[k]) == int(t):
			nat_type = String(k).to_lower()
	status_changed.emit()

# ================================================================ hosting ==

## Publish this computer's room and start listening. Returns
## {ok, link, invite, error}.
func host(room_name: String, secret: String) -> Dictionary:
	var opts := _new("Lobby.CreateLobbyOptions")
	opts.set("bucket_id", BUCKET)
	# a directory entry: our guests never join it. Room for a full team
	# anyway, so a lookup never treats it as "full"; joining the lobby grants
	# nothing (admission is the host's secret check).
	opts.set("max_lobby_members", NetRole.MAX_PARTICIPANTS)
	opts.set("permission_level", _enum("Lobby.LobbyPermissionLevel", "PublicAdvertised"))
	opts.set("presence_enabled", false)
	opts.set("allow_invites", false)
	opts.set("enable_join_by_id", false)
	opts.set("disable_host_migration", true)
	var lobby: Object = await _auto("HLobbies").call("create_lobby_async", opts)
	if lobby == null:
		return {"ok": false, "error": "Epic's lobby service would not create the room. Check the client policy allows Lobbies (ONLINE.md) and the log."}
	_lobby = lobby
	lobby.call("add_attribute", "bb_compat", NetRole.compat())
	lobby.call("add_attribute", "bb_version", NetRole.GAME_VERSION)
	lobby.call("add_attribute", "bb_room", NetProto.clean_name(room_name))
	lobby.call("add_attribute", "bb_locked", false)
	lobby.call("add_attribute", "bb_players", 1)
	await lobby.call("update_async")
	var link: NetLink
	if link_maker.is_valid():
		link = link_maker.call(true, product_user_id)
	else:
		var peer: Object = ClassDB.instantiate("EOSGMultiplayerPeer")
		link = NetLink.eos(peer as MultiplayerPeer, true)
		link.error = peer.call("create_server", SOCKET)
	if link == null or link.error != OK:
		await close_room()
		return {"ok": false, "error": "Could not open the peer-to-peer socket (error %d)." % (link.error if link else -1)}
	var lobby_id := String(lobby.get("lobby_id"))
	return {"ok": true, "link": link, "invite": NetInvite.make_eos(lobby_id, product_user_id, secret)}

## Keep the directory entry in step with the room (locked, player count).
func update_room(st: Dictionary) -> void:
	if _lobby == null:
		return
	_lobby.call("add_attribute", "bb_locked", bool(st.get("locked", false)))
	_lobby.call("add_attribute", "bb_players", int(st.get("players", 1)))
	await _lobby.call("update_async")

func close_room() -> void:
	if _lobby == null:
		return
	var l := _lobby
	_lobby = null
	await l.call("destroy_async")

# ================================================================ joining ==

## Look the room up in Epic's lobby service. Returns {ok, host, room, error}.
func resolve(inv: Dictionary) -> Dictionary:
	var found: Variant = await _auto("HLobbies").call("search_by_lobby_id_async", String(inv["lobby"]))
	if found == null:
		# the lookup itself failed (not "no such room"): try the host named in
		# the invite directly; its game still checks the secret and the build
		return {"ok": true, "host": String(inv["host"]), "room": "", "unverified": true}
	if (found as Array).is_empty():
		return {"ok": false, "reason": "closed",
			"error": "That room is not open any more. Ask the host for a new invite."}
	var lobby: Object = (found as Array)[0]
	var attrs := {}
	for a in lobby.get("attributes"):
		attrs[String((a as Dictionary).get("key", ""))] = (a as Dictionary).get("value")
	var owner := String(lobby.get("owner_product_user_id"))
	if owner != String(inv["host"]):
		return {"ok": false, "reason": "invalid",
			"error": "That invite does not match the room it points to. Ask the host to copy it again."}
	if String(attrs.get("bb_compat", "")) != NetRole.compat():
		return {"ok": false, "reason": "incompatible",
			"error": "The host is running game build %s. Yours is %s. Everyone needs the same build." % [
				String(attrs.get("bb_version", "?")), NetRole.GAME_VERSION]}
	if bool(attrs.get("bb_locked", false)):
		return {"ok": false, "reason": "locked", "error": "The host has locked this room."}
	return {"ok": true, "host": owner, "room": String(attrs.get("bb_room", ""))}

## A fresh peer-to-peer link to the host (a new one on every reconnect).
func connect_link(host_user: String) -> NetLink:
	if link_maker.is_valid():
		return link_maker.call(false, host_user)
	var peer: Object = ClassDB.instantiate("EOSGMultiplayerPeer")
	var l := NetLink.eos(peer as MultiplayerPeer, false)
	l.error = peer.call("create_client", SOCKET, host_user)
	return l
