class_name NetInvite
extends RefCounted
##
## THE INVITE A HOST COPIES AND A FRIEND PASTES.
##
## It is the whole discovery-and-admission story, with no service of ours in
## between:
##
##   BBZ1-E.<lobby id>.<host product user id>.<secret>     over the internet
##   BBZ1-L.<address>:<port>.<secret>                      same network only
##
## E (Epic Online Services): the lobby id lets the joiner's game look the room
##   up in Epic's lobby service (is it still open, which build, locked?), the
##   host id is who to open an EOS peer-to-peer connection to (Epic punches
##   through both routers, or relays when it cannot), and the secret is what
##   the host's game checks before letting anyone in. The lobby is only a
##   directory entry: nobody joins it, so it cannot be filled up by strangers,
##   and without the secret a connection is refused and dropped.
## L (local network): an address on the same LAN, for play at the same school
##   or house, and for the tests. It does not cross home routers.
##
## The secret is 26 base-32 characters (130 bits) from the system's secure
## random source: an invite cannot be guessed, only shared. A new room makes
## a new secret, so an old invite stops working when its room ends.
##

const PREFIX := "BBZ1-"
const ALPHABET := "ABCDEFGHJKMNPQRSTUVWXYZ23456789"   # 31 symbols, no look-alikes
const SECRET_LEN := 26

static func new_secret() -> String:
	var crypto := Crypto.new()
	var n := ALPHABET.length()
	var limit := 256 - (256 % n)
	var out := ""
	while out.length() < SECRET_LEN:
		for byte in crypto.generate_random_bytes(32):
			if byte < limit and out.length() < SECRET_LEN:
				out += ALPHABET[byte % n]
	return out

static func make_eos(lobby_id: String, host_user: String, secret: String) -> String:
	return "%sE.%s.%s.%s" % [PREFIX, lobby_id, host_user, secret]

static func make_lan(address: String, port: int, secret: String) -> String:
	return "%sL.%s:%d.%s" % [PREFIX, address, port, secret]

static func _id_ok(t: String, lo: int, hi: int) -> bool:
	if t.length() < lo or t.length() > hi:
		return false
	for ch in t:
		if not (ch in "0123456789abcdefABCDEF-_" or (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z")):
			return false
	return true

## Text off the clipboard -> {ok, kind: "eos" | "lan", ..., error}
static func parse(text: String) -> Dictionary:
	var t := text.strip_edges().replace(" ", "").replace("\n", "").replace("\r", "")
	if not t.begins_with(PREFIX):
		return {"ok": false, "error": "That is not a BioBuzz invite. Paste the whole invite the host copied — it starts with BBZ1-."}
	var body := t.substr(PREFIX.length())
	var parts := body.split(".")
	if parts.size() < 1:
		return {"ok": false, "error": "That invite is incomplete. Ask the host to copy it again."}
	var secret := String(parts[-1]).to_upper()
	if secret.length() != SECRET_LEN:
		return {"ok": false, "error": "That invite is incomplete. Ask the host to copy it again."}
	for ch in secret:
		if not ALPHABET.contains(ch):
			return {"ok": false, "error": "That invite has a typo in it. Copy and paste it rather than typing it."}
	match String(parts[0]):
		"E":
			if parts.size() != 4 or not _id_ok(parts[1], 8, 64) or not _id_ok(parts[2], 8, 64):
				return {"ok": false, "error": "That internet invite is incomplete. Ask the host to copy it again."}
			return {"ok": true, "kind": "eos", "lobby": String(parts[1]), "host": String(parts[2]),
				"secret": secret}
		"L":
			# address:port may itself contain dots (an IPv4 address)
			var mid := body.substr(2, body.length() - 2 - SECRET_LEN - 1)
			var hp := NetRole.split_address(mid, 0)
			if String(hp[0]) == "" or int(hp[1]) <= 0:
				return {"ok": false, "error": "That network invite has no address. Ask the host to copy it again."}
			return {"ok": true, "kind": "lan", "address": String(hp[0]), "port": int(hp[1]),
				"secret": secret}
	return {"ok": false, "error": "That invite is from a different version of the game."}

## This computer's addresses other people on the same network could use.
static func lan_addresses() -> Array:
	var out: Array = []
	for a in IP.get_local_addresses():
		var s := String(a)
		if s.contains(":") or s.begins_with("127.") or s.begins_with("169.254."):
			continue
		out.append(s)
	out.sort_custom(func(x, y) -> bool: return _rank(x) < _rank(y))
	return out

static func _rank(a: String) -> int:
	if a.begins_with("192.168."):
		return 0
	if a.begins_with("10."):
		return 1
	if a.begins_with("172."):
		return 2
	return 3
