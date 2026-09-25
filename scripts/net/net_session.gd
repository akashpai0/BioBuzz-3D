class_name NetSession
extends RefCounted
##
## ONE PLAYER'S CONNECTION TO A ROOM: entering -> in_room -> (reconnect) -> gone.
##
## Protocol only. It never touches the game world, so the full game client,
## the host's own view of its room and the test bots all share it. `poll()`
## must be called every frame.
##
## HOW TO REACH THE ROOM is given as a factory that makes a fresh NetLink
## (EOS peer-to-peer to the host, ENet to a LAN address, or the host's own
## in-process link). Reconnecting simply calls it again.
##

signal changed(what: String)

## EOS may take several seconds to punch through, and longer to fall back to
## its relay; a LAN connection is immediate.
var connect_timeout_ms := 20000
const RECONNECT_WINDOW_MS := 60000
## How long to keep trying to get back in; the room holds the seat for 60 s.
var reconnect_window_ms := RECONNECT_WINDOW_MS
const RECONNECT_EVERY_MS := 3000
## Nothing at all from the room for this long: the link is dead, whatever the
## transport says. (The room sends at least six snapshots a second.)
const SILENT_MS := 6000
const SNAP_BUFFER := 90

var room: NetLink
var link_factory: Callable          # () -> NetLink (null on failure)
var server_peer := 1

## idle | entering | in_room | reconnecting | failed | closed
var phase := "idle"
var error_reason := ""
var error_text := ""
var secret := ""
var token := ""
var pid := -1
var is_owner := false
var room_name := ""
var code := ""
var display_name := "Player"
## How the packets travel: direct | relayed | lan | local | connecting
var route := ""

var state: Dictionary = {}
var slow: Dictionary = {}
var result: Dictionary = {}
var scenario: Dictionary = {}
var scenario_rev := -1
var scenario_notes: Array = []
var scenario_error := ""
var snaps: Array = []        # decoded snapshots, oldest first
var last_tick := 0
var seq := 0
var ping_ms := -1.0
var notices: Array = []      # [text] for the UI, newest last
var sim_spec := ""
var replay_hook: Callable    # (run, index, bytes)
var replay_run := -1
var replay_next := 0
var auto_ack_scenario := true
## Tests only: pretend to be a different build.
var compat_override := ""

var _t_start := 0
var _last_ping := 0
var _reconnect_since := 0
var _last_try := 0
var _last_rx := 0
## Counters for tests and the connection line.
var snaps_in := 0
var snaps_bad := 0
var snaps_old_run := 0
var _gap_missing := 0.0
var _gap_seen := 0.0
## Messages sent before the room has let this player in: held, then sent in
## order the moment it does (a host's first click can beat its own WELCOME).
var _pending: Array = []

func _now() -> int:
	return Time.get_ticks_msec()

# ================================================================ start ===

## Connect and enter. `factory` makes the link; `secret_` is the invite's.
func join(factory: Callable, secret_: String, name: String) -> void:
	link_factory = factory
	secret = secret_
	display_name = NetProto.clean_name(name)
	error_reason = ""
	error_text = ""
	phase = "entering"
	_t_start = _now()
	_open_link()
	changed.emit("phase")

func _open_link() -> void:
	if room:
		room.close()
	room = link_factory.call() if link_factory.is_valid() else null
	if room != null and room.error != OK:
		room = null
	if room != null and sim_spec != "" and room.kind != NetLink.Kind.LOOP:
		room.set_sim(sim_spec)
	_last_rx = _now()

func _fail(reason: String, text: String) -> void:
	phase = "failed"
	error_reason = reason
	error_text = text
	if room:
		room.close()
	changed.emit("phase")

func leave() -> void:
	if room and phase in ["in_room", "reconnecting"]:
		# LEAVE must reach the room before the link goes, or the room takes it
		# for a dropped connection and holds the seat through the grace period
		send(NetProto.LEAVE, {})
		room.flush(200)
	if room:
		room.close()
	phase = "idle"
	changed.emit("phase")

# ================================================================= pump ===

func poll() -> void:
	var now := _now()
	if room != null:
		for e2 in room.poll():
			_room_event(e2)
	match phase:
		"entering":
			if room == null:
				_fail("unreachable", "Could not start a connection to the host.")
			elif now - _t_start > connect_timeout_ms:
				_fail("unreachable", ("The host's game did not answer. They may have closed "
					+ "the room, or a network in between blocks the connection."))
		"reconnecting":
			if now - _reconnect_since > reconnect_window_ms:
				_fail("lost", "Lost the connection to the host and could not get back in.")
			elif now - _last_try > RECONNECT_EVERY_MS:
				_last_try = now
				_open_link()
		"in_room":
			if now - _last_ping > 1000:
				_last_ping = now
				send(NetProto.PING, {"t": Time.get_ticks_usec(), "last_rtt": int(ping_ms)})
			if now - _last_rx > SILENT_MS and room != null and room.kind != NetLink.Kind.LOOP:
				_start_reconnecting()

func _start_reconnecting() -> void:
	phase = "reconnecting"
	_reconnect_since = _now()
	_last_try = _now()
	notices.append("Connection lost — reconnecting…")
	changed.emit("phase")

func _compat() -> String:
	return compat_override if compat_override != "" else NetRole.compat()

## Start reconnecting now (tests, and when this end knows the link is dead).
func reconnect_now() -> void:
	if token == "":
		return
	phase = "reconnecting"
	_reconnect_since = _now()
	_last_try = 0
	changed.emit("phase")

## Tests: drop the link as if the network had gone.
func drop_link() -> void:
	if room:
		room.close()

# ================================================================= room ===

func _room_event(e: Dictionary) -> void:
	_last_rx = _now()
	match String(e["type"]):
		"connect":
			var p := {"name": display_name, "compat": _compat(),
				"version": NetRole.GAME_VERSION}
			if phase == "reconnecting" and token != "":
				p["token"] = token
				p["replay_run"] = replay_run
				p["replay_next"] = replay_next
			else:
				p["secret"] = secret
			route = room.route(server_peer)
			room.send(server_peer, NetLink.CH_CONTROL, NetProto.pack(NetProto.ENTER, p))
		"disconnect":
			if phase == "in_room":
				_start_reconnecting()
		"packet":
			if int(e["channel"]) == NetLink.CH_STATE:
				_on_snapshot(e["data"])
				return
			var m := NetProto.unpack(e["data"], NetProto.MAX_BULK)
			if m.is_empty():
				return
			_on_message(int(m[0]), m[1])

func _on_message(type: int, p: Dictionary) -> void:
	match type:
		NetProto.WELCOME:
			pid = NetProto.i(p, "pid", 0, 1 << 30, -1)
			token = NetProto.s(p, "token", 64)
			is_owner = NetProto.b(p, "owner")
			room_name = NetProto.s(p, "room", 40)
			if NetProto.s(p, "code", 400) != "":
				code = NetProto.s(p, "code", 400)
			var back := NetProto.b(p, "reconnected")
			phase = "in_room"
			var queued := _pending
			_pending = []
			for q in queued:
				send(int(q[0]), q[1])
			if room:
				route = room.route(server_peer)
			if back:
				notices.append("Reconnected. Let go of the controls to take your seat back.")
			changed.emit("welcome")
		NetProto.DENY:
			_fail(NetProto.s(p, "reason", 24), NetProto.s(p, "text", 300))
		NetProto.CLOSED:
			phase = "closed"
			error_reason = NetProto.s(p, "reason", 24)
			error_text = NetProto.s(p, "text", 300)
			room.close()
			changed.emit("phase")
		NetProto.ROOM_STATE:
			state = p
			if int(p.get("owner", -1)) == pid:
				is_owner = true
			if room:
				route = room.route(server_peer)
			changed.emit("state")
		NetProto.SLOW:
			slow = p
			changed.emit("slow")
		NetProto.RESULT:
			result = p
			changed.emit("result")
		NetProto.REJECT:
			notices.append(NetProto.s(p, "text", 300))
			changed.emit("notice")
		NetProto.PONG:
			ping_ms = float(Time.get_ticks_usec() - NetProto.i(p, "t", 0, 1 << 62, 0)) / 1000.0
		NetProto.SCENARIO:
			_on_scenario(p)
		NetProto.REPLAY_CHUNK:
			var bytes: Variant = p.get("bytes")
			if bytes is PackedByteArray and replay_hook.is_valid():
				var run := NetProto.i(p, "run", 0, 1 << 30, 0)
				var idx := NetProto.i(p, "index", 0, 1 << 30, 0)
				replay_hook.call(run, idx, bytes)
				if run != replay_run:
					replay_run = run
					replay_next = 0
				replay_next = maxi(replay_next, idx + 1)

func _on_scenario(p: Dictionary) -> void:
	var data: Variant = p.get("data")
	var rev := NetProto.i(p, "rev", 0, 1 << 30, -1)
	if not (data is PackedByteArray):
		scenario_error = "The scenario did not arrive intact."
		changed.emit("scenario")
		return
	var res := NetScenario.decode(NetProto.i(p, "raw_len", 0, NetScenario.MAX_RAW, 0), data)
	if not bool(res.get("ok", false)):
		scenario_error = "Your copy of the game could not use this scenario: %s" % String(res.get("error", ""))
		scenario = {}
		changed.emit("scenario")
		return
	scenario = res["data"]
	scenario_rev = rev
	scenario_error = ""
	scenario_notes = []
	for n in p.get("notes", []):
		if n is String:
			scenario_notes.append((n as String).substr(0, 200))
	changed.emit("scenario")
	if auto_ack_scenario:
		ack_scenario()

func ack_scenario() -> void:
	send(NetProto.SCENARIO_ACK, {"rev": scenario_rev})

func _on_snapshot(data: PackedByteArray) -> void:
	var want_layout: Dictionary = state.get("layout", {})
	if want_layout.is_empty() or int(want_layout.get("robots", 0)) == 0:
		return
	var s := NetProto.unpack_snapshot(data, want_layout)
	if s.is_empty():
		snaps_bad += 1
		return
	if int(s["run"]) != (int(state.get("run", 0)) & 0xFFFF):
		snaps_old_run += 1
		return
	snaps_in += 1
	s["arrived"] = Time.get_ticks_usec()
	if int(s["tick"]) <= last_tick and not snaps.is_empty():
		return                                # late or duplicate
	# loss, measured from the snapshots themselves (numbered by server tick,
	# sent every 3 ticks while running): works on any transport
	if not snaps.is_empty() and String(state.get("state", "")) == "running":
		var gap := int(s["tick"]) - last_tick
		var every := clampi(int(state.get("snap_every", 3)), 1, 30)
		if gap >= every and gap <= 30 * every:
			_gap_seen += 1.0
			_gap_missing += float(gap / every - 1)
			if _gap_seen > 300.0:
				_gap_seen *= 0.5
				_gap_missing *= 0.5
	last_tick = int(s["tick"])
	snaps.append(s)
	while snaps.size() > SNAP_BUFFER:
		snaps.pop_front()
	changed.emit("snap")

## New run: forget the old run's snapshots.
func reset_snaps() -> void:
	snaps.clear()
	last_tick = 0

# ================================================================= send ===

func send(type: int, payload: Dictionary) -> void:
	if room == null:
		return
	if phase == "entering":
		if _pending.size() < 32:
			_pending.append([type, payload])
		return
	room.send(server_peer, NetLink.CH_BULK if type == NetProto.SET_SCENARIO else NetLink.CH_CONTROL,
		NetProto.pack(type, payload))

func send_input(v: Dictionary) -> void:
	if room == null or phase != "in_room":
		return
	seq += 1
	room.send(server_peer, NetLink.CH_INPUT,
		NetProto.pack_input(int(state.get("run", 0)), seq, last_tick, v))

## Share of snapshots that did not arrive recently (0..1), whatever carried them.
func loss() -> float:
	var total := _gap_seen + _gap_missing
	return _gap_missing / total if total >= 30.0 else 0.0

func take_notices() -> Array:
	var out := notices
	notices = []
	return out

func my_part() -> Dictionary:
	for q in state.get("parts", []):
		if int(q.get("pid", -1)) == pid:
			return q
	return {}

func my_seat() -> Array:
	return my_part().get("seat", [])
