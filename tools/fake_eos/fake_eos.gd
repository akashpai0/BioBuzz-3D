class_name FakeEOS
extends RefCounted
## SIMULATED EOS BACKEND for tools/debug_net_eos_sim.gd. Installs stand-ins for
## the EOSG autoloads (HPlatform, HAuth, HLobbies, HP2P) and the IEOS engine
## singleton, a lobby "service" that is a JSON file both test processes read,
## and a link maker that carries the traffic over ENet on 127.0.0.1 while
## reporting the route the relay setting would give ("direct" / "relayed").
##
## It proves NetEOS's and NetClient's own logic (login with a persistent
## device id, publishing the room, looking it up by invite, refusing closed,
## locked and different-build rooms, the relay setting, the route shown to
## players). It proves NOTHING about Epic's service, NAT punch-through or the
## relay: those only happen with the real plugin and real credentials.

const REG := "user://fake_eos_lobbies.json"

class FakeIEOS extends Object:
	signal connect_interface_create_device_id_callback(data: Dictionary)

class Platform extends Node:
	func setup_eos_async(_c) -> bool:
		await get_tree().process_frame
		return true

class Auth extends Node:
	var product_user_id := ""
	func login_game_services_async(_opts) -> bool:
		await get_tree().process_frame
		var path := "user://fake_eos_device_%s.txt" % String(OS.get_environment("FAKE_EOS_DEVICE"))
		if not FileAccess.file_exists(path):
			return false                      # no device id yet: NotFound
		product_user_id = FileAccess.get_file_as_string(path).strip_edges()
		return true

class FakeLobby extends RefCounted:
	var lobby_id := ""
	var owner_product_user_id := ""
	var attributes: Array = []
	func add_attribute(key: String, value: Variant, _vis = 0) -> bool:
		for a in attributes:
			if a["key"] == key:
				a["value"] = value
				return true
		attributes.append({"key": key, "value": value})
		return true
	func update_async() -> bool:
		await Engine.get_main_loop().process_frame
		var reg := FakeEOS.read()
		reg[lobby_id] = {"owner": owner_product_user_id, "attributes": attributes}
		FakeEOS.write(reg)
		return true
	func destroy_async() -> bool:
		await Engine.get_main_loop().process_frame
		var reg := FakeEOS.read()
		reg.erase(lobby_id)
		FakeEOS.write(reg)
		return true

class Lobbies extends Node:
	func create_lobby_async(_opts) -> Object:
		await get_tree().process_frame
		var l := FakeLobby.new()
		l.lobby_id = "%08x%08x%08x%08x" % [randi(), randi(), randi(), randi()]
		l.owner_product_user_id = String((get_node("/root/HAuth") as Auth).product_user_id)
		await l.update_async()
		return l
	func search_by_lobby_id_async(id: String):
		await get_tree().process_frame
		var reg := FakeEOS.read()
		if not reg.has(id):
			return []
		var l := FakeLobby.new()
		l.lobby_id = id
		l.owner_product_user_id = String(reg[id]["owner"])
		l.attributes = reg[id]["attributes"]
		return [l]

class P2PNode extends Node:
	var relay := 1
	func set_relay_control(v: int) -> int:
		relay = v
		return 0
	func get_nat_type_async() -> int:
		await get_tree().process_frame
		return 2

static func read() -> Dictionary:
	if not FileAccess.file_exists(REG):
		return {}
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(REG))
	return v if v is Dictionary else {}

static func write(d: Dictionary) -> void:
	var f := FileAccess.open(REG + ".tmp", FileAccess.WRITE)
	f.store_string(JSON.stringify(d))
	f.close()
	DirAccess.rename_absolute(ProjectSettings.globalize_path(REG + ".tmp"), ProjectSettings.globalize_path(REG))

## Put the stand-ins in place for this process and point `eos` at them.
static func install(tree: SceneTree, eos: NetEOS, port_for_host: Callable) -> void:
	if not Engine.has_singleton("IEOS"):
		Engine.register_singleton("IEOS", FakeIEOS.new())
	for pair in [["HPlatform", Platform], ["HAuth", Auth], ["HLobbies", Lobbies], ["HP2P", P2PNode]]:
		var existing: Node = tree.root.get_node_or_null(pair[0])
		if existing != null and existing.get_script() == pair[1]:
			continue
		if existing != null:
			# the real EOSG autoload is installed in this build: step it aside
			# so NetEOS finds the stand-in under the same name
			tree.root.remove_child(existing)
			existing.queue_free()
		var n: Node = (pair[1] as GDScript).new()
		n.name = pair[0]
		tree.root.add_child(n)
	eos.addon_dir = "res://tools/fake_eos/"
	eos.link_maker = func(server: bool, host_user: String) -> NetLink:
		var port: int = port_for_host.call(host_user)
		var l := NetLink.enet_server(port, 12) if server else NetLink.enet_client("127.0.0.1", port)
		var relay: int = (tree.root.get_node("HP2P") as P2PNode).relay
		l.route_label = "relayed" if relay == 2 else "direct"
		return l
