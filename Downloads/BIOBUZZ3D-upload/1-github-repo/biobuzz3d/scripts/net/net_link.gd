class_name NetLink
extends RefCounted
##
## ONE CONNECTION POINT, WHATEVER CARRIES THE PACKETS.
##
## Backends (all behind the same send / poll):
##   EOS    Epic Online Services P2P through the EOSG plugin's
##          EOSGMultiplayerPeer. NAT punch-through first, Epic's relay when a
##          direct path cannot be made. This is what crosses home routers.
##   ENET   plain Godot ENet to an address and port. Works on one machine and
##          on one LAN; across the internet only if the host has forwarded a
##          port, which this game never asks anyone to do. Used by the tests.
##   LOOP   in-process pair: the host's own game talking to its own room.
##
## Channels:
##   0 CONTROL  reliable, ordered   lobby, seats, pause, retry, results
##   1 INPUT    unreliable          driver / operator commands, 60 per second
##   2 STATE    unreliable          authoritative snapshots, 60 per second
##                                    (6 per second while the room is halted)
##   3 BULK     reliable, ordered   scenario data, replay chunks
##
## EOS P2P CARRIES AT MOST 1170 BYTES A PACKET, and EOSG uses 6 of them. Every
## backend is held to the same MAX_DATAGRAM so the tests on ENet exercise the
## same splitting the internet path needs: a message too big for one datagram
## is cut into fragments here and put back together at the other end.
## Reliable fragments arrive in order; an unreliable message (a large
## snapshot) is used only if every fragment arrives, otherwise it is dropped
## like any other lost snapshot.
##
## SIMULATED CONDITIONS (`sim`) are for testing on one machine: they delay every
## datagram in both directions at this end, add jitter, and drop the given
## share of UNRELIABLE datagrams. A model of a bad connection — not the internet.
##

const CH_CONTROL := 0
const CH_INPUT := 1
const CH_STATE := 2
const CH_BULK := 3
const CHANNELS := 4

## 1170 (EOS_P2P_MAX_PACKET_SIZE) minus EOSG's 6-byte header.
const MAX_DATAGRAM := 1164
const FRAG := 0x04
const FRAG_HEAD := 7
## A fragmented message may not claim to be larger than this.
const MAX_MESSAGE := 4 * 1024 * 1024
const FRAG_STALE_MS := 3000

enum Kind { NONE, ENET, LOOP, EOS }

var kind := Kind.NONE
var is_server := false
var mp: MultiplayerPeer
var error := OK
var sim := {"latency_ms": 0.0, "jitter_ms": 0.0, "loss": 0.0}
var bytes_out := 0
var bytes_in := 0
var packets_out := 0
var packets_in := 0
var dropped_by_sim := 0
var fragments_out := 0
var fragments_dropped := 0
## The largest datagram ever handed to the transport (tests: must never
## exceed MAX_DATAGRAM, the EOS limit).
var max_datagram_seen := 0

## peer id -> "direct" | "relayed" | "lan" | "local"
var routes := {}
## Tests (simulated EOS): report this route for every peer.
var route_label := ""

var _events: Array = []          # signals from the peer, delivered on poll
var _out_q: Array = []           # [due_ms, peer, ch, bytes]
var _in_q: Array = []            # [due_ms, event]
var _last_due := {}
var _rng := RandomNumberGenerator.new()
var _msg_id := 0
var _parts := {}                 # "peer:ch:id" -> {count, got, chunks, t}
var _was_connected := false
var _closed := false
# LOOP
var _other: NetLink
var _loop_inbox: Array = []
var _loop_self_id := 0
var _loop_peer_id := 0
# EOS: remote product user id -> network type (1 direct, 2 relayed)
var _eos_net := {}

func _init() -> void:
	_rng.randomize()

# ============================================================== creating ==

static func enet_server(port: int, max_peers: int, bind := "*") -> NetLink:
	var l := NetLink.new()
	l.kind = Kind.ENET
	l.is_server = true
	var p := ENetMultiplayerPeer.new()
	p.set_bind_ip(bind)
	l.error = p.create_server(port, max_peers, CHANNELS)
	if l.error == OK:
		l._adopt(p)
	return l

static func enet_client(address: String, port: int) -> NetLink:
	var l := NetLink.new()
	l.kind = Kind.ENET
	var p := ENetMultiplayerPeer.new()
	l.error = p.create_client(address, port, CHANNELS)
	if l.error == OK:
		l._adopt(p)
	return l

## Wrap an already created EOSGMultiplayerPeer (server or client).
static func eos(peer: MultiplayerPeer, server: bool) -> NetLink:
	var l := NetLink.new()
	l.kind = Kind.EOS
	l.is_server = server
	l._adopt(peer)
	if peer.has_signal("peer_connection_established"):
		peer.connect("peer_connection_established", l._on_eos_established)
	return l

## Two ends of an in-process connection: [server end, client end].
static func loop_pair() -> Array:
	var a := NetLink.new()
	var b := NetLink.new()
	a.kind = Kind.LOOP
	b.kind = Kind.LOOP
	a.is_server = true
	a._other = b
	b._other = a
	a._loop_self_id = 1
	b._loop_self_id = 2
	a._loop_peer_id = 2
	b._loop_peer_id = 1
	a.routes[2] = "local"
	b.routes[1] = "local"
	a._loop_inbox.append({"type": "connect", "peer": 2})
	b._loop_inbox.append({"type": "connect", "peer": 1})
	return [a, b]

func _adopt(p: MultiplayerPeer) -> void:
	mp = p
	mp.peer_connected.connect(func(id: int) -> void:
		_events.append({"type": "connect", "peer": id})
		if kind == Kind.ENET:
			routes[id] = "lan"
			_fast_timeouts(id))
	mp.peer_disconnected.connect(func(id: int) -> void:
		_events.append({"type": "disconnect", "peer": id}))

## Notice a dead ENet link within a few seconds, not ENet's default ~30.
func _fast_timeouts(id: int) -> void:
	var ep := mp as ENetMultiplayerPeer
	if ep == null:
		return
	var pp := ep.get_peer(id)
	if pp:
		pp.set_timeout(0, 3000, 6000)

func _on_eos_established(d: Dictionary) -> void:
	var who := String(d.get("remote_user_id", ""))
	_eos_net[who] = int(d.get("network_type", 0))

## How this peer's packets travel, when the backend can say.
func route(peer: int) -> String:
	if route_label != "":
		return route_label
	if kind == Kind.EOS and mp != null and mp.has_method("get_peer_user_id"):
		var who := String(mp.call("get_peer_user_id", peer))
		match int(_eos_net.get(who, 0)):
			1: return "direct"
			2: return "relayed"
		return "connecting"
	return String(routes.get(peer, ""))

func set_sim(spec: String) -> void:
	var p := spec.split(",")
	if p.size() >= 1 and p[0].is_valid_float():
		sim["latency_ms"] = maxf(0.0, float(p[0]))
	if p.size() >= 2 and p[1].is_valid_float():
		sim["jitter_ms"] = maxf(0.0, float(p[1]))
	if p.size() >= 3 and p[2].is_valid_float():
		sim["loss"] = clampf(float(p[2]), 0.0, 0.9)

func sim_active() -> bool:
	return float(sim["latency_ms"]) > 0.0 or float(sim["jitter_ms"]) > 0.0 \
		or float(sim["loss"]) > 0.0

func is_open() -> bool:
	return not _closed and (kind == Kind.LOOP or mp != null)

## A client end that has reached its server.
func connected() -> bool:
	if _closed:
		return false
	if kind == Kind.LOOP:
		return _other != null and not _other._closed
	return mp != null and mp.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED

# ================================================================= send ===

static func _reliable(ch: int) -> bool:
	return ch == CH_CONTROL or ch == CH_BULK

func send(peer: int, ch: int, bytes: PackedByteArray) -> void:
	if not is_open():
		return
	if bytes.size() + 1 <= MAX_DATAGRAM:
		var d := PackedByteArray([ch & 0x03])
		d.append_array(bytes)
		_send_datagram(peer, ch, d)
		return
	if bytes.size() > MAX_MESSAGE:
		push_warning("NetLink: message of %d bytes refused" % bytes.size())
		return
	_msg_id = (_msg_id + 1) & 0xFFFF
	var room := MAX_DATAGRAM - FRAG_HEAD
	var count := int(ceil(float(bytes.size()) / float(room)))
	for i in count:
		var d2 := PackedByteArray()
		d2.resize(FRAG_HEAD)
		d2.encode_u8(0, (ch & 0x03) | FRAG)
		d2.encode_u16(1, _msg_id)
		d2.encode_u16(3, i)
		d2.encode_u16(5, count)
		d2.append_array(bytes.slice(i * room, mini((i + 1) * room, bytes.size())))
		fragments_out += 1
		_send_datagram(peer, ch, d2)

func _send_datagram(peer: int, ch: int, d: PackedByteArray) -> void:
	if not sim_active():
		_raw_send(peer, ch, d)
		return
	if not _reliable(ch) and _rng.randf() < float(sim["loss"]):
		dropped_by_sim += 1
		return
	_out_q.append([_due(peer, ch, _reliable(ch)), peer, ch, d])

func _raw_send(peer: int, ch: int, d: PackedByteArray) -> void:
	max_datagram_seen = maxi(max_datagram_seen, d.size())
	bytes_out += d.size()
	packets_out += 1
	if kind == Kind.LOOP:
		if _other != null and not _other._closed:
			_other._loop_inbox.append({"type": "packet", "peer": _loop_self_id,
				"channel": ch, "data": d})
		return
	if mp == null or mp.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	mp.set_target_peer(peer)
	mp.set_transfer_channel(ch + 1)
	mp.set_transfer_mode(MultiplayerPeer.TRANSFER_MODE_RELIABLE if _reliable(ch)
		else MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)
	mp.put_packet(d)

func _due(peer: int, ch: int, reliable: bool) -> float:
	var now := float(Time.get_ticks_usec()) / 1000.0
	var d := now + float(sim["latency_ms"]) \
		+ _rng.randf_range(-float(sim["jitter_ms"]), float(sim["jitter_ms"]))
	d = maxf(now, d)
	if reliable:
		var key := "%d:%d" % [peer, ch]
		d = maxf(d, float(_last_due.get(key, 0.0)))
		_last_due[key] = d
	return d

# ================================================================= poll ===

## Everything that happened since the last poll, as dictionaries:
##   {type: "connect" | "disconnect" | "packet", peer, channel, data}
func poll() -> Array:
	var out: Array = []
	if _closed:
		return out
	var now := float(Time.get_ticks_usec()) / 1000.0
	if not _out_q.is_empty():
		var keep: Array = []
		for item in _out_q:
			if float(item[0]) <= now:
				_raw_send(item[1], item[2], item[3])
			else:
				keep.append(item)
		_out_q = keep
	var raw: Array = []
	if kind == Kind.LOOP:
		raw = _loop_inbox
		_loop_inbox = []
	elif mp != null:
		var before_status := _was_connected
		# a client whose connection has ended is inactive: polling it is an error
		if mp.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
			mp.poll()
			for _guard in 8192:
				if mp.get_available_packet_count() <= 0:
					break
				var from := mp.get_packet_peer()
				var data := mp.get_packet()
				raw.append({"type": "packet", "peer": from, "data": data})
		raw = _events + raw
		_events = []
		# a client whose server never answered, or went away without a word
		if not is_server:
			var st := mp.get_connection_status()
			if st == MultiplayerPeer.CONNECTION_CONNECTED:
				_was_connected = true
			elif before_status and st == MultiplayerPeer.CONNECTION_DISCONNECTED:
				_was_connected = false
				raw.append({"type": "disconnect", "peer": 1})
	for e in raw:
		var ev: Dictionary = e
		if String(ev["type"]) != "packet":
			_deliver(ev, out, now)
			continue
		var d: PackedByteArray = ev["data"]
		if d.is_empty():
			continue
		bytes_in += d.size()
		packets_in += 1
		var ch := int(d[0]) & 0x03
		ev["channel"] = ch
		if sim_active():
			if not _reliable(ch) and _rng.randf() < float(sim["loss"]):
				dropped_by_sim += 1
				continue
			_in_q.append([_due(int(ev["peer"]), 100 + ch, _reliable(ch)), ev])
		else:
			_deliver(ev, out, now)
	if not _in_q.is_empty():
		var keep2: Array = []
		for item2 in _in_q:
			if float(item2[0]) <= now:
				_deliver(item2[1], out, now)
			else:
				keep2.append(item2)
		_in_q = keep2
	return out

## Unwrap one datagram (or pass a connect / disconnect through).
func _deliver(ev: Dictionary, out: Array, now: float) -> void:
	if String(ev["type"]) != "packet":
		out.append(ev)
		return
	var d: PackedByteArray = ev["data"]
	var head := int(d[0])
	var ch := head & 0x03
	if head & FRAG == 0:
		out.append({"type": "packet", "peer": ev["peer"], "channel": ch, "data": d.slice(1)})
		return
	if d.size() < FRAG_HEAD:
		return
	var id := d.decode_u16(1)
	var idx := d.decode_u16(3)
	var count := d.decode_u16(5)
	if count < 2 or idx >= count or count * (MAX_DATAGRAM - FRAG_HEAD) > MAX_MESSAGE + MAX_DATAGRAM:
		return
	var key := "%d:%d:%d" % [int(ev["peer"]), ch, id]
	var slot: Dictionary = _parts.get(key, {})
	if slot.is_empty() or int(slot["count"]) != count:
		slot = {"count": count, "got": 0, "chunks": {}, "t": now}
		_parts[key] = slot
	if not (slot["chunks"] as Dictionary).has(idx):
		(slot["chunks"] as Dictionary)[idx] = d.slice(FRAG_HEAD)
		slot["got"] = int(slot["got"]) + 1
	if int(slot["got"]) == count:
		var whole := PackedByteArray()
		for i in count:
			whole.append_array((slot["chunks"] as Dictionary)[i])
		_parts.erase(key)
		out.append({"type": "packet", "peer": ev["peer"], "channel": ch, "data": whole})
	# forget half-arrived unreliable messages
	if _parts.size() > 8:
		for k in _parts.keys():
			if now - float((_parts[k] as Dictionary)["t"]) > FRAG_STALE_MS:
				_parts.erase(k)
				fragments_dropped += 1

# ================================================================ close ===

## Drop one remote peer (the room removing or refusing someone).
func kick(peer: int) -> void:
	if kind == Kind.LOOP:
		return
	if mp != null and is_server:
		mp.disconnect_peer(peer)

## Give queued reliable messages a moment to leave before closing.
func flush(ms := 150) -> void:
	var t := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t < ms and not _out_q.is_empty():
		poll()
	if mp != null:
		mp.poll()

func close() -> void:
	if _closed:
		return
	_closed = true
	if kind == Kind.LOOP:
		if _other != null and not _other._closed:
			_other._loop_inbox.append({"type": "disconnect", "peer": _loop_self_id})
		return
	if mp != null:
		mp.close()
	_out_q.clear()
	_in_q.clear()
