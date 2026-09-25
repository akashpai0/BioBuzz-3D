class_name NetRoomServer
extends Node
##
## ONE PRIVATE ROOM: THE ONLY SIMULATION ITS PLAYERS SHARE — RUNNING INSIDE
## THE HOST PLAYER'S OWN GAME.
##
## The host's ordinary world under `main` — physics, robots, AI, match clock,
## scoring, fouls, objectives, the replay recorder — is the authority. Every
## other player's computer sends only what their seat is allowed to press and
## draws what this room sends back. The host plays too: their own game talks
## to this room through an in-process link, exactly like everyone else, so
## the host gets no shortcut to the simulation that a guest does not.
##
## THE HOST is the room owner: they choose the scenario, start, pause, retry,
## lock and remove. There is no other server and no host migration: if the
## host leaves, or is gone past the reconnection allowance, the room ends
## cleanly for everyone and every player keeps the replays they have.
##
## ADMISSION: an invite carries a secret made when the room opened. A player
## who presents it (and the same game build) is let in; anyone else is
## refused and dropped. How the joiner found this computer — an Epic Online
## Services lobby lookup, or an address on the same network — is decided
## before any of this runs (NetClient / NetEOS).
##
## STATES
##   lobby      seats, roster, scenario; the world is halted
##   loading    the scenario is restored; waiting for every seated player to
##              confirm they have the new run's state
##   countdown  3 s, shared; the world is still halted
##   running    the world runs; seated players' inputs are applied
##   paused     halted: by the owner, or because a seated player disconnected
##   results    an attempt or match ended; halted
##
## A HALTED WORLD NEVER HALTS THE ROOM. This node, its links and every menu
## run PROCESS_MODE_ALWAYS, so pausing the shared simulation leaves the
## network answering, and the host's personal menu never pauses anything.
##
## TIMING RULES (documented in ONLINE.md):
##   STALE_INPUT_MS   a seat whose inputs stop for this long is set to neutral
##   SILENT_MS        a player who sends nothing at all for this long is
##                    treated as disconnected, whatever the transport says
##   GRACE_S          a disconnected player may come back to the same seat
##

signal closed(why: String)
## Something a room directory (the EOS lobby) shows changed.
signal status_changed(status: Dictionary)

const STALE_INPUT_MS := 250
const SILENT_MS := 8000
const GRACE_S_DEFAULT := 60.0
## Reconnection grace, seconds. 60 unless started with --grace (tests).
var GRACE_S := GRACE_S_DEFAULT
const COUNTDOWN_S := 3.0
const SNAP_EVERY := 3                  # physics ticks: 60 snapshots per second
## THE HOST'S UPLOAD. A home connection sends everything the room says to
## every guest: about 58 KB/s per guest at 60 snapshots a second. "Low upload"
## halves that (30 a second); guests draw a little further behind to match.
const SNAP_EVERY_LOW := 6
const SNAP_EVERY_HALTED := 30          # 6 per second while nothing moves
const MAX_INPUT_PER_S := 90
const ROLES := ["whole", "driver", "operator"]

var main: Node3D
## Every way in: [0] is normally the host's own in-process link.
var links: Array = []
## The admission secret, as it appears in the invite.
var invite_secret := ""
## Tests only (headless host): a joiner with this name becomes the owner.
var test_owner_name := ""
var load_report := false

var room_name := "Room"
var code := ""
var parts := {}                        # pid -> participant
var by_peer := {}                      # "link:peer" -> pid
var next_pid := 1
var owner_pid := -1
var locked := false
var state := "lobby"
var run_id := 0
var countdown_end_ms := 0
var pause_reason := ""
var requests: Array = []               # [{pid, kind}]
var result: Dictionary = {}
var ai_mask: Array = []
var seats: Array = []                  # per robot {whole, driver, operator} -> pid or -1
var scenario: Dictionary = {}
var scenario_rev := 0
var scenario_wire: Dictionary = {}     # {raw_len, data}
var scenario_notes: Array = []
var summary: Dictionary = {}
var layout := {"robots": 0, "hives": 0, "elements": 0}
var attempt_no := 0
var snap_every := SNAP_EVERY

var _robots: Array = []
var _hives: Array = []
var _elements: Array = []
var _row := PackedFloat32Array()
var _dirty := true
var _slow_dirty := true
var _last_state_ms := 0
var _last_slow_ms := 0
var _last_slow := {}
var _created_ms := 0
var _busy := false                     # a restore is in progress
var _chunks: Array = []                # the current recording's chunks
var _chunk_run := -1
const MAX_CHUNK_BYTES := 64 * 1024 * 1024
var _chunk_bytes := 0
var _kicks: Array = []                 # [due_ms, link, peer]: refused, drop after the reply
var _refused := {}                     # "link:peer" -> count of refused entries

## Counters for the tests and the load report.
var stats := {"inputs": 0, "stale_run": 0, "old_seq": 0, "rate_limited": 0,
	"malformed": 0, "masked": 0, "unseated": 0, "not_running": 0,
	"neutral_wait": 0, "rejected": 0, "tick_us": 0, "tick_n": 0, "tick_max_us": 0,
	"refused": 0}

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	GRACE_S = clampf(float(NetRole.arg("grace", str(GRACE_S_DEFAULT))), 2.0, 600.0)
	load_report = NetRole.args.has("load-report")
	main.net_room = self
	_created_ms = Time.get_ticks_msec()
	if invite_secret == "":
		invite_secret = NetInvite.new_secret()
	# nothing moves until there is a run to play
	if main.menu:
		main.menu.close()
	main.mm.abort()
	BB.set_menu_halt(true)
	_log("room open")

func add_link(l: NetLink) -> void:
	if String(NetRole.arg("net-sim", "")) != "" and l.kind != NetLink.Kind.LOOP:
		l.set_sim(String(NetRole.arg("net-sim", "")))
	links.append(l)

func _log(t: String) -> void:
	print("[room] %s" % t)

func _key(l: NetLink, peer: int) -> String:
	return "%d:%d" % [links.find(l), peer]

# ================================================================== pump ===

func _process(_d: float) -> void:
	if _closing:
		return
	for l in links:
		var link: NetLink = l
		for e in link.poll():
			match String(e["type"]):
				"connect":
					pass
				"disconnect":
					_on_disconnect(link, int(e["peer"]))
				"packet":
					_on_packet(link, int(e["peer"]), int(e["channel"]), e["data"])
	var now := Time.get_ticks_msec()
	if not _kicks.is_empty():
		var keep: Array = []
		for k in _kicks:
			if now >= int(k[0]):
				(k[1] as NetLink).kick(int(k[2]))
			else:
				keep.append(k)
		_kicks = keep
	_timers(now)
	if load_report and now - _last_load_ms >= 5000:
		_load_report(now)
	if _dirty and now - _last_state_ms >= 50 or now - _last_state_ms >= 1000:
		_broadcast_state()
	if now - _last_slow_ms >= 200:
		_send_slow()

func _physics_process(_d: float) -> void:
	if _closing:
		return
	var t0 := Time.get_ticks_usec()
	var running := state == "running" and not BB.halted
	var now := Time.get_ticks_msec()
	if running:
		_stale_inputs(now)
	var every := snap_every if running or state == "countdown" else SNAP_EVERY_HALTED
	# never while a restore is rebuilding the world: a snapshot then would be
	# the OLD field labelled with the NEW run
	if not _busy and not _robots.is_empty() and Engine.get_physics_frames() % every == 0:
		_send_snapshot()
	if running:
		var c := Time.get_ticks_usec() - t0
		stats["tick_us"] = int(stats["tick_us"]) + c
		stats["tick_n"] = int(stats["tick_n"]) + 1
		stats["tick_max_us"] = maxi(int(stats["tick_max_us"]), c)

# ================================================================= load ===

var _last_load_ms := 0
var _last_bytes := [0, 0]

## A line of measured load: physics frame time against the 5.56 ms a 180 Hz
## tick allows, the room's own share of it, traffic, people.
func _load_report(now: int) -> void:
	var dt := maxf(0.001, float(now - _last_load_ms) / 1000.0)
	_last_load_ms = now
	var bo := 0
	var bi := 0
	for l in links:
		bo += (l as NetLink).bytes_out
		bi += (l as NetLink).bytes_in
	var out_rate := float(bo - int(_last_bytes[0])) / dt
	var in_rate := float(bi - int(_last_bytes[1])) / dt
	_last_bytes = [bo, bi]
	var phys_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var n := maxi(1, int(stats["tick_n"]))
	var seated := 0
	for pid in parts:
		if not (parts[pid]["seat"] as Array).is_empty():
			seated += 1
	print("[room] LOAD state=%s players=%d seated=%d physics=%.2fms/tick room=%.0fus avg %.0fus max out=%.1fKB/s in=%.1fKB/s mem=%.0fMB inputs=%d stale=%d old=%d masked=%d" % [
		state, parts.size(), seated, phys_ms, float(stats["tick_us"]) / n,
		float(stats["tick_max_us"]), out_rate / 1024.0, in_rate / 1024.0,
		_rss_mb(), int(stats["inputs"]),
		int(stats["stale_run"]), int(stats["old_seq"]), int(stats["masked"])])
	stats["tick_us"] = 0
	stats["tick_n"] = 0
	stats["tick_max_us"] = 0

## Resident memory of this process. Release builds report 0 for Godot's own
## allocator counter, so on Linux read the kernel's figure.
static func _rss_mb() -> float:
	var own := OS.get_static_memory_usage() / 1048576.0
	if own > 0.0 or OS.get_name() != "Linux":
		return own
	var out: Array = []
	OS.execute("cat", ["/proc/%d/status" % OS.get_process_id()], out)
	for line in String(out[0] if not out.is_empty() else "").split("\n"):
		if line.begins_with("VmRSS:"):
			return float(line.split(":")[1].strip_edges().split(" ")[0]) / 1024.0
	return 0.0

## What an outside directory (the EOS lobby) should show about this room.
func _tell_directory() -> void:
	status_changed.emit({"players": _present_count(), "locked": locked, "state": state,
		"max": NetRole.MAX_PARTICIPANTS, "room": room_name})

func _present_count() -> int:
	return parts.size()

# ============================================================= entering ===

func _on_packet(l: NetLink, peer: int, ch: int, data: PackedByteArray) -> void:
	var pid: int = by_peer.get(_key(l, peer), -1)
	if pid >= 0 and parts.has(pid):
		(parts[pid] as Dictionary)["last_rx_ms"] = Time.get_ticks_msec()
	if ch == NetLink.CH_INPUT:
		_on_input(pid, data)
		return
	var m := NetProto.unpack(data, NetProto.MAX_BULK if ch == NetLink.CH_BULK else NetProto.MAX_CONTROL)
	if m.is_empty():
		stats["malformed"] = int(stats["malformed"]) + 1
		return
	var type: int = m[0]
	var p: Dictionary = m[1]
	if pid < 0:
		if type == NetProto.ENTER:
			_enter(l, peer, p)
		else:
			stats["malformed"] = int(stats["malformed"]) + 1
		return
	var who: Dictionary = parts.get(pid, {})
	if who.is_empty():
		return
	_handle(pid, who, type, p)

## Refuse, say why, and drop the connection once the reply has had time to go.
func _deny(l: NetLink, peer: int, reason: String, text: String) -> void:
	stats["refused"] = int(stats["refused"]) + 1
	l.send(peer, NetLink.CH_CONTROL, NetProto.pack(NetProto.DENY,
		{"reason": reason, "text": text}))
	if l.kind != NetLink.Kind.LOOP:
		_kicks.append([Time.get_ticks_msec() + 400, l, peer])

## Constant-time comparison, so the secret cannot be guessed a letter at a time.
static func _same(a: String, b: String) -> bool:
	var x := a.to_utf8_buffer()
	var y := b.to_utf8_buffer()
	var diff := x.size() ^ y.size()
	for i in mini(x.size(), y.size()):
		diff |= x[i] ^ y[i]
	return diff == 0 and x.size() > 0

func _enter(l: NetLink, peer: int, p: Dictionary) -> void:
	if NetProto.s(p, "compat", 64) != NetRole.compat():
		_deny(l, peer, "incompatible", ("This room runs game build %s (%s). Your copy "
			+ "is %s. Everyone in a room needs the same build.") % [
			NetRole.GAME_VERSION, NetRole.compat(), NetProto.s(p, "version", 40)])
		return
	var name := NetProto.clean_name(NetProto.s(p, "name", 40))
	# ---- coming back to a seat
	var tok := NetProto.s(p, "token", 64)
	if tok != "":
		for pid in parts:
			var q: Dictionary = parts[pid]
			if _same(String(q["token"]), tok):
				if bool(q["connected"]) and q["link"] != null:
					# the same player on a new connection before this end had
					# noticed the old one drop: the token is theirs, so the
					# new link replaces the old one
					by_peer.erase(_key(q["link"], int(q["peer"])))
					(q["link"] as NetLink).kick(int(q["peer"]))
				_attach(pid, l, peer)
				q["needs_neutral"] = true
				q["restore_ack"] = -1
				_log("%s reconnected" % q["name"])
				_welcome(pid, true, p)
				return
		_deny(l, peer, "expired", "Your place in that room has expired or the room was reset.")
		return
	# ---- first time in: the host's own link, or the invite's secret
	var is_host_link := l.kind == NetLink.Kind.LOOP and owner_pid < 0
	if not is_host_link and not _same(NetProto.s(p, "secret", 64), invite_secret):
		_deny(l, peer, "invalid", "That invite is not valid for this room. Ask the host for a new one.")
		return
	var becomes_owner := is_host_link or (test_owner_name != "" and name == test_owner_name
		and owner_pid < 0)
	if locked and not becomes_owner:
		_deny(l, peer, "locked", "The host has locked this room.")
		return
	if _present_count() >= NetRole.MAX_PARTICIPANTS:
		_deny(l, peer, "full", "The room is full (%d players)." % NetRole.MAX_PARTICIPANTS)
		return
	var pid2 := next_pid
	next_pid += 1
	var q2 := {
		"pid": pid2, "name": name, "token": NetProto.token(24), "owner": becomes_owner,
		"connected": false, "link": null, "peer": -1, "seat": [], "ready": false,
		"scen_ack": -1, "restore_ack": -1, "menu": false, "last_seq": 0,
		"last_input_ms": 0, "win_start": 0, "win_n": 0, "needs_neutral": true,
		"counters": {}, "disconnected_ms": 0, "ping_ms": -1.0,
		"joined_mid_run": state == "running", "last_rx_ms": Time.get_ticks_msec(),
	}
	parts[pid2] = q2
	if becomes_owner:
		owner_pid = pid2
	_attach(pid2, l, peer)
	_log("%s joined%s" % [q2["name"], " (host)" if pid2 == owner_pid else ""])
	_welcome(pid2, false, p)
	_tell_directory()

func _attach(pid: int, l: NetLink, peer: int) -> void:
	var q: Dictionary = parts[pid]
	q["link"] = l
	q["peer"] = peer
	q["connected"] = true
	q["disconnected_ms"] = 0
	q["last_rx_ms"] = Time.get_ticks_msec()
	by_peer[_key(l, peer)] = pid
	_dirty = true

func _welcome(pid: int, back: bool, p: Dictionary) -> void:
	var q: Dictionary = parts[pid]
	_to(pid, NetLink.CH_CONTROL, NetProto.WELCOME, {"pid": pid, "token": q["token"],
		"owner": pid == owner_pid, "room": room_name, "code": code, "reconnected": back,
		"run": run_id, "version": NetRole.GAME_VERSION})
	if not scenario_wire.is_empty():
		_send_scenario(pid)
	_broadcast_state()
	_send_slow(true)
	# replay chunks this player missed from the current recording
	if _chunk_run >= 0:
		var have_run := NetProto.i(p, "replay_run", -1, 1 << 30, -1)
		var from := 0
		if have_run == _chunk_run:
			from = NetProto.i(p, "replay_next", 0, 1 << 30, 0)
		for k in range(from, _chunks.size()):
			_send_chunk(pid, _chunk_run, k, _chunks[k])

# ============================================================ handling ===

func _handle(pid: int, q: Dictionary, type: int, p: Dictionary) -> void:
	var is_owner := pid == owner_pid
	match type:
		NetProto.PING:
			_to(pid, NetLink.CH_CONTROL, NetProto.PONG, {"t": NetProto.i(p, "t", 0, 1 << 62, 0)})
			q["ping_ms"] = float(NetProto.i(p, "last_rtt", -1, 60000, -1))
		NetProto.SEAT:
			_seat_request(pid, q, NetProto.i(p, "robot", -1, 7, -1), NetProto.s(p, "role", 12))
		NetProto.READY:
			var on := NetProto.b(p, "on")
			if on and int(q["scen_ack"]) != scenario_rev:
				_reject(pid, "Wait for the scenario to finish loading before you are ready.")
				return
			if on and scenario.is_empty():
				_reject(pid, "The owner has not chosen a scenario yet.")
				return
			q["ready"] = on
			_dirty = true
		NetProto.SCENARIO_ACK:
			if NetProto.i(p, "rev", -1, 1 << 30, -1) == scenario_rev:
				q["scen_ack"] = scenario_rev
				_dirty = true
		NetProto.RESTORE_ACK:
			if NetProto.i(p, "run", -1, 1 << 30, -1) == run_id:
				q["restore_ack"] = run_id
				_dirty = true
				_maybe_countdown()
		NetProto.MENU:
			q["menu"] = NetProto.b(p, "open")
			_dirty = true
		NetProto.LEAVE:
			_remove(pid, "%s left the room." % q["name"])
		NetProto.PAUSE:
			if is_owner:
				_pause("Paused by %s." % q["name"])
			else:
				_request(pid, "pause")
		NetProto.RETRY:
			if is_owner:
				_retry()
			else:
				_request(pid, "retry")
		NetProto.RESUME:
			if is_owner:
				_resume()
		NetProto.START:
			if is_owner:
				_start()
		NetProto.LOBBY:
			if is_owner:
				_to_lobby()
		NetProto.END:
			if is_owner:
				_close("The host ended the session.")
		NetProto.LOCK:
			if is_owner:
				locked = NetProto.b(p, "on")
				_dirty = true
				_tell_directory()
		NetProto.KICK:
			if is_owner:
				var target := NetProto.i(p, "pid", -1, 1 << 30, -1)
				if target != owner_pid and parts.has(target):
					var tq: Dictionary = parts[target]
					if bool(tq["connected"]) and tq["link"] != null:
						_to(target, NetLink.CH_CONTROL, NetProto.CLOSED,
							{"reason": "removed", "text": "The host removed you from the room."})
						_kicks.append([Time.get_ticks_msec() + 400, tq["link"], int(tq["peer"])])
					_remove(target, "%s was removed by the host." % tq["name"])
		NetProto.SET_RATE:
			if is_owner:
				snap_every = SNAP_EVERY_LOW if NetProto.b(p, "low") else SNAP_EVERY
				_dirty = true
		NetProto.SET_AI:
			if is_owner:
				_set_ai(pid, NetProto.i(p, "robot", -1, 7, -1), NetProto.b(p, "on"))
		NetProto.SET_SCENARIO:
			if is_owner:
				_set_scenario(pid, p)
		NetProto.REASSIGN:
			if is_owner:
				_reassign(pid, NetProto.i(p, "robot", -1, 7, -1), NetProto.s(p, "role", 12),
					NetProto.i(p, "to", -1, 1 << 30, -1))
		_:
			pass
	if not is_owner and type in [NetProto.START, NetProto.RESUME, NetProto.LOBBY,
			NetProto.END, NetProto.LOCK, NetProto.KICK, NetProto.SET_AI,
			NetProto.SET_SCENARIO, NetProto.REASSIGN, NetProto.SET_RATE]:
		stats["rejected"] = int(stats["rejected"]) + 1
		_reject(pid, "Only the host can do that.")

func _reject(pid: int, text: String) -> void:
	_to(pid, NetLink.CH_CONTROL, NetProto.REJECT, {"text": text})

func _request(pid: int, kind: String) -> void:
	for r in requests:
		if int(r["pid"]) == pid and String(r["kind"]) == kind:
			return
	requests.append({"pid": pid, "kind": kind})
	_dirty = true

# =============================================================== seats ===

func _seat_of(pid: int) -> Array:
	var q: Dictionary = parts.get(pid, {})
	return q.get("seat", []) if not q.is_empty() else []

func _seat_request(pid: int, q: Dictionary, robot: int, role: String) -> void:
	if state in ["running", "countdown", "loading"]:
		_reject(pid, "Seats change in the lobby or while the room is paused.")
		return
	# release
	if robot < 0:
		_free_seat(pid)
		_clear_ready()
		return
	if robot >= seats.size() or not (role in ROLES):
		_reject(pid, "That seat does not exist.")
		return
	if bool(ai_mask[robot]):
		_reject(pid, "That robot is driven by the AI. The owner can hand it to people.")
		return
	var s: Dictionary = seats[robot]
	var taken := int(s[role]) >= 0 and int(s[role]) != pid
	var clash := false
	if role == "whole":
		clash = (int(s["driver"]) >= 0 and int(s["driver"]) != pid) \
			or (int(s["operator"]) >= 0 and int(s["operator"]) != pid)
	else:
		clash = int(s["whole"]) >= 0 and int(s["whole"]) != pid
	if taken or clash:
		# THE ONE PLACE TWO REQUESTS CAN MEET. Messages are handled one at a
		# time, so the first one here owns the seat and the second is told.
		_reject(pid, "Someone already has that seat.")
		return
	_free_seat(pid)
	s[role] = pid
	q["seat"] = [robot, role]
	_clear_ready()
	_dirty = true

func _free_seat(pid: int) -> void:
	for s in seats:
		for role in ROLES:
			if int(s[role]) == pid:
				s[role] = -1
	var q: Dictionary = parts.get(pid, {})
	if not q.is_empty():
		q["seat"] = []
	_dirty = true

## CHANGING WHO HOLDS WHAT CLEARS EVERYONE'S READINESS. Nobody starts a run on
## a roster they did not agree to.
func _clear_ready() -> void:
	for pid in parts:
		(parts[pid] as Dictionary)["ready"] = false
	if state == "paused":
		_roles_changed_since_pause = true
	_dirty = true

func _reassign(owner: int, robot: int, role: String, to: int) -> void:
	if not (state in ["lobby", "paused", "results"]):
		_reject(owner, "Pause the room before reassigning a seat.")
		return
	if robot < 0 or robot >= seats.size() or not (role in ROLES) or not parts.has(to):
		_reject(owner, "That seat or player does not exist.")
		return
	var s: Dictionary = seats[robot]
	var holder := int(s[role])
	if holder >= 0 and parts.has(holder) and bool(parts[holder]["connected"]):
		_reject(owner, "That seat's player is still connected.")
		return
	if holder >= 0:
		_free_seat(holder)
	_free_seat(to)
	if role == "whole":
		for r2 in ["driver", "operator"]:
			if int(s[r2]) >= 0:
				_free_seat(int(s[r2]))
	elif int(s["whole"]) >= 0:
		_free_seat(int(s["whole"]))
	s[role] = to
	parts[to]["seat"] = [robot, role]
	parts[to]["needs_neutral"] = true
	_clear_ready()

func _rebuild_seats() -> void:
	var old := seats
	seats = []
	for i in ai_mask.size():
		seats.append({"whole": -1, "driver": -1, "operator": -1})
	for pid in parts:
		var q: Dictionary = parts[pid]
		var st: Array = q["seat"]
		if st.is_empty():
			continue
		var r := int(st[0])
		if r < seats.size() and not bool(ai_mask[r]):
			(seats[r] as Dictionary)[String(st[1])] = pid
		else:
			q["seat"] = []
	_dirty = true

func _set_ai(owner: int, robot: int, on: bool) -> void:
	if not (state in ["lobby", "results"]):
		_reject(owner, "Change who drives in the lobby.")
		return
	if robot < 0 or robot >= ai_mask.size():
		return
	ai_mask[robot] = on
	(scenario["setup"] as Dictionary)["ai_mask"] = ai_mask.duplicate()
	for role in ROLES:
		var holder := int(seats[robot][role])
		if holder >= 0:
			_free_seat(holder)
	_new_revision()

## Anything that changes what will be simulated is a new revision: everyone
## must receive and confirm it, and nobody is still Ready for the old one.
func _new_revision() -> void:
	scenario_rev += 1
	scenario_wire = NetScenario.encode(scenario)
	summary = NetScenario.summary(scenario, scenario_notes)
	for pid in parts:
		var q: Dictionary = parts[pid]
		q["ready"] = false
		q["scen_ack"] = -1
		if bool(q["connected"]):
			_send_scenario(pid)
	_rebuild_seats()

# ============================================================ scenario ===

func _set_scenario(owner: int, p: Dictionary) -> void:
	if not (state in ["lobby", "results"]) or _busy:
		_reject(owner, "Choose a scenario in the lobby.")
		return
	var res := {}
	var key := NetProto.s(p, "standard", 24)
	if key != "":
		if not NetScenario.STANDARD.has(key):
			_reject(owner, "Unknown setup.")
			return
		var prof: Dictionary = p.get("profile", {}) if p.get("profile") is Dictionary else {}
		res = await _standard(key, prof)
	else:
		var data: Variant = p.get("data")
		if not (data is PackedByteArray):
			_reject(owner, "The scenario did not arrive.")
			return
		res = NetScenario.decode(NetProto.i(p, "raw_len", 0, NetScenario.MAX_RAW, 0), data)
	if not bool(res.get("ok", false)):
		_reject(owner, "That scenario cannot be used online: %s" % String(res.get("error", "")))
		return
	scenario = res["data"]
	scenario_notes = res.get("notes", [])
	var su: Dictionary = scenario["setup"]
	ai_mask = (su.get("ai_mask", []) as Array).duplicate()
	result = {}
	_new_revision()
	_log("scenario rev %d: %s" % [scenario_rev, summary.get("name", "")])

## A standard setup, built the way an offline match is: the owner's robot
## profile, a staged field, the clock at the start.
func _standard(key: String, profile: Dictionary) -> Dictionary:
	var spec: Dictionary = NetScenario.STANDARD[key]
	_busy = true
	BB.set_menu_halt(false)
	_apply_profile(profile)
	main.mm.abort()
	main.mm.mode = int(spec["mode"])
	var n_ours: int = spec["ours"]
	var n_foes: int = spec["foes"]
	# as offline: our robots are people, opponents start as AI; the owner can
	# switch any robot either way in the lobby
	var mask: Array = []
	for i in n_ours + n_foes:
		mask.append(i >= n_ours)
	main.opts = {"robots": n_ours, "mate_is_ai": false, "per_robot": 1,
		"opponents": n_foes, "takes_nectar": false, "ai_mask": mask}
	main._build_robots(BB.Alliance.RED, 1)
	await main.stage()
	main.mm.start()
	var snap := Snapshot.capture(main, randi())
	main.mm.abort()
	BB.set_menu_halt(true)
	_busy = false
	snap["meta"] = {"name": String(spec["name"]), "note": ""}
	return NetScenario.check(snap)

## The simulated hardware is the scenario's, never this machine's Garage.
func _apply_profile(p: Dictionary) -> void:
	RobotShop.model_path = ""
	RobotShop.source = clampi(NetProto.i(p, "source", 0, 2, 0), 0, 2)
	if RobotShop.source == RobotShop.Source.HARDWARE:
		RobotShop.source = RobotShop.Source.STOCK
	RobotShop.specs = NetScenario.clean_specs(p.get("specs", {}))
	RobotShop.robot_name = NetProto.clean_name(NetProto.s(p, "name", 40, "Robot"))

func _send_scenario(pid: int) -> void:
	_to(pid, NetLink.CH_BULK, NetProto.SCENARIO, {"rev": scenario_rev,
		"raw_len": int(scenario_wire["raw_len"]), "data": scenario_wire["data"],
		"notes": scenario_notes})

# ========================================================= run control ===

func _required() -> Array:
	var out: Array = []
	for s in seats:
		for role in ROLES:
			if int(s[role]) >= 0:
				out.append(int(s[role]))
	return out

## Why the owner cannot start yet, in words; empty when they can.
func start_blockers() -> Array:
	var out: Array = []
	if scenario.is_empty():
		out.append("Choose a scenario.")
		return out
	for i in seats.size():
		if bool(ai_mask[i]):
			continue
		var s: Dictionary = seats[i]
		var covered := int(s["whole"]) >= 0 or (int(s["driver"]) >= 0 and int(s["operator"]) >= 0)
		if not covered:
			out.append("%s needs a whole-robot player, or a driver and an operator (or set it to AI)." % _robot_label(i))
	for pid in _required():
		var q: Dictionary = parts[pid]
		if not bool(q["connected"]):
			out.append("%s is disconnected." % q["name"])
		elif int(q["scen_ack"]) != scenario_rev:
			out.append("%s is still loading the scenario." % q["name"])
		elif not bool(q["ready"]):
			out.append("%s is not ready." % q["name"])
	return out

func _robot_label(i: int) -> String:
	for r in summary.get("robots", []):
		if int(r["index"]) == i:
			return "Robot %d (%s, %s)" % [i + 1, r["label"], BB.alliance_name(int(r["alliance"]))]
	return "Robot %d" % (i + 1)

func _start() -> void:
	if not (state in ["lobby", "results"]):
		return
	var why := start_blockers()
	if not why.is_empty():
		_reject(owner_pid, String(why[0]))
		return
	requests.clear()
	await _restore_run()

## Put the room's scenario on the field, halted, as a new run. Every seated
## player must confirm they have the new run's state before the countdown.
func _restore_run() -> void:
	_busy = true
	_robots = []
	state = "loading"
	_dirty = true
	_finish_recording("abandoned")
	main._end_attempt("abandoned")
	DriverInput.clear_all_virtual()
	run_id += 1
	attempt_no += 1
	var su: Dictionary = scenario["setup"]
	_apply_profile({"source": su.get("profile", 0), "specs": su.get("specs", {}),
		"name": su.get("robot_name", "Robot")})
	BB.set_menu_halt(false)
	var problems: Array = await Snapshot.restore(main, scenario)
	# halt on the same frame the restore handed the motion back, so not one
	# physics step runs before the countdown ends
	BB.set_menu_halt(true)
	for line in problems:
		_log("restore: %s" % line)
	main.scenario_source = scenario
	main.scenario_id = "online"
	main.scenario_run = true
	# The objective, if the scenario has one, measured from THIS instant:
	# the historical score in the scenario is its baseline, and the world is
	# halted, so nothing counts until the countdown ends.
	main._start_attempt()
	_index_world()
	# (confirmations are compared with run_id, which changed above, so no
	# confirmation of an older run can count for this one)
	for pid in parts:
		var q: Dictionary = parts[pid]
		q["last_seq"] = 0
		q["counters"] = {}
	_busy = false
	_dirty = true
	_send_snapshot()
	_maybe_countdown()

func _index_world() -> void:
	_robots = []
	for r in main.robots:
		_robots.append(r)
	for i in _robots.size():
		var rob: Robot = _robots[i]
		if not rob.ai_driver:
			rob.device = DriverInput.VIRTUAL + 2 * i
			rob.op_device = DriverInput.VIRTUAL + 2 * i + 1
	_hives = [main.field.hives[BB.Alliance.RED], main.field.hives[BB.Alliance.BLUE]]
	var by_sid := {}
	for n in get_tree().get_nodes_in_group("element"):
		if is_instance_valid(n) and not n.is_queued_for_deletion():
			by_sid[String(n.get_meta("sid", ""))] = n
	var ids := by_sid.keys()
	ids.sort()
	_elements = []
	for k in ids:
		_elements.append(by_sid[k])
	layout = {"robots": _robots.size(), "hives": 2, "elements": _elements.size()}
	_row = PackedFloat32Array()
	_row.resize(ReplayRecorder.HEAD + ReplayRecorder.PER_ROBOT * _robots.size()
		+ ReplayRecorder.PER_HIVE * 2 + ReplayRecorder.PER_ELEMENT * _elements.size())

func _maybe_countdown() -> void:
	if state != "loading" or _busy:
		return
	for pid in _required():
		var q: Dictionary = parts[pid]
		if not bool(q["connected"]) or int(q["restore_ack"]) != run_id:
			return
	_begin_countdown()

func _begin_countdown() -> void:
	_roles_changed_since_pause = false
	state = "countdown"
	countdown_end_ms = Time.get_ticks_msec() + int(COUNTDOWN_S * 1000.0)
	pause_reason = ""
	_dirty = true

func _go() -> void:
	# neutral first: nothing held before the countdown counts
	DriverInput.clear_all_virtual()
	for pid in parts:
		(parts[pid] as Dictionary)["counters"] = {}
	state = "running"
	_dirty = true
	if main.mm.paused:
		main.mm.resume()
	else:
		BB.set_menu_halt(false)
	if main.recorder.state == ReplayRecorder.State.IDLE:
		_arm_recording()

func _pause(reason: String) -> void:
	if not (state in ["running", "countdown"]):
		return
	state = "paused"
	pause_reason = reason
	if main.mm.in_progress() and not main.mm.paused:
		main.mm.pause()
	BB.set_menu_halt(true)
	DriverInput.clear_all_virtual()
	requests = requests.filter(func(r) -> bool: return String(r["kind"]) != "pause")
	_dirty = true
	_log(reason)

func _resume() -> void:
	if state != "paused":
		return
	var why: Array = []
	for pid in _required():
		var q: Dictionary = parts[pid]
		if not bool(q["connected"]):
			why.append("%s is disconnected." % q["name"])
		elif not bool(q["ready"]) and _roles_changed_since_pause:
			why.append("%s is not ready." % q["name"])
	for i in seats.size():
		if bool(ai_mask[i]):
			continue
		var s: Dictionary = seats[i]
		if not (int(s["whole"]) >= 0 or (int(s["driver"]) >= 0 and int(s["operator"]) >= 0)):
			why.append("%s has nobody in a seat." % _robot_label(i))
	if not why.is_empty():
		_reject(owner_pid, String(why[0]))
		return
	_begin_countdown()

var _roles_changed_since_pause := false

func _retry() -> void:
	if scenario.is_empty() or _busy:
		return
	if not (state in ["running", "paused", "results", "countdown"]):
		return
	requests.clear()
	result = {}
	await _restore_run()

func _to_lobby() -> void:
	if _busy:
		return
	_finish_recording("abandoned")
	main._end_attempt("abandoned")
	main.mm.abort()
	BB.set_menu_halt(true)
	DriverInput.clear_all_virtual()
	state = "lobby"
	requests.clear()
	_clear_ready()
	_dirty = true

func on_attempt_finished(rec: Dictionary) -> void:
	if String(rec.get("state", "")) == "abandoned":
		return
	result = {"kind": "attempt", "state": rec.get("state", ""), "reason": rec.get("reason", ""),
		"progress": rec.get("progress", 0), "goal": rec.get("goal", 0),
		"elapsed": rec.get("elapsed", 0.0), "points": rec.get("points", 0),
		"made": rec.get("made", 0), "shots": rec.get("shots", 0), "fouls": rec.get("fouls", 0),
		"objective": Objective.describe(rec.get("objective", {})), "run": run_id,
		"attempt_no": attempt_no}
	_enter_results()

func on_match_finished(res: Dictionary) -> void:
	if not result.is_empty() and int(result.get("run", -1)) == run_id:
		return
	var b: Dictionary = res.get("breakdown", {})
	result = {"kind": "match", "red": int(b.get(BB.Alliance.RED, {}).get("total", 0)),
		"blue": int(b.get(BB.Alliance.BLUE, {}).get("total", 0)), "run": run_id,
		"attempt_no": attempt_no}
	_enter_results()

func _enter_results() -> void:
	state = "results"
	if main.mm.in_progress() and not main.mm.paused:
		main.mm.pause()
	BB.set_menu_halt(true)
	DriverInput.clear_all_virtual()
	_dirty = true
	for pid in parts:
		_to(pid, NetLink.CH_CONTROL, NetProto.RESULT, result)

# ============================================================ recording ===

func _arm_recording() -> void:
	var roster: Array = []
	for i in seats.size():
		var s: Dictionary = seats[i]
		var row := {"robot": i, "label": _robot_label(i), "ai": bool(ai_mask[i])}
		for role in ROLES:
			if int(s[role]) >= 0 and parts.has(int(s[role])):
				row[role] = parts[int(s[role])]["name"]
		roster.append(row)
	var sname := String(summary.get("name", "Scenario"))
	main.recorder.sink = _on_chunk
	main.recorder.begin({"kind": "online", "mode": main.mm.mode,
		"mode_name": "Online practice", "title": "Online · %s · %s" % [room_name, sname],
		"scenario_id": "", "scenario_name": sname,
		"our_alliance": int(scenario["setup"].get("alliance", 0)),
		"header_extra": {"online": {"room": room_name, "run": run_id,
			"match_mode": summary.get("mode", ""), "roster": roster}}})
	_chunks = []
	_chunk_bytes = 0
	_chunk_run = run_id

func _on_chunk(bytes: PackedByteArray, _type: int) -> void:
	var k := _chunks.size()
	if _chunk_bytes + bytes.size() <= MAX_CHUNK_BYTES:
		_chunks.append(bytes)
		_chunk_bytes += bytes.size()
	else:
		_chunks.append(PackedByteArray())   # too old to resend; the index stays
	for pid in parts:
		if bool(parts[pid]["connected"]):
			_send_chunk(pid, _chunk_run, k, bytes)

func _send_chunk(pid: int, run: int, index: int, bytes: PackedByteArray) -> void:
	if bytes.is_empty():
		return
	_to(pid, NetLink.CH_BULK, NetProto.REPLAY_CHUNK, {"run": run, "index": index, "bytes": bytes})

func _finish_recording(outcome: String) -> void:
	if main.recorder.state != ReplayRecorder.State.IDLE:
		main.recorder.finish(outcome, "")

# ================================================================ inputs ===

func _on_input(pid: int, data: PackedByteArray) -> void:
	var q: Dictionary = parts.get(pid, {})
	if q.is_empty():
		stats["unseated"] = int(stats["unseated"]) + 1
		return
	var v := NetProto.unpack_input(data)
	if v.is_empty():
		stats["malformed"] = int(stats["malformed"]) + 1
		return
	var now := Time.get_ticks_msec()
	# rate: a window of one second
	if now - int(q["win_start"]) >= 1000:
		q["win_start"] = now
		q["win_n"] = 0
	q["win_n"] = int(q["win_n"]) + 1
	if int(q["win_n"]) > MAX_INPUT_PER_S:
		stats["rate_limited"] = int(stats["rate_limited"]) + 1
		return
	if int(v["run"]) != (run_id & 0xFFFF):
		stats["stale_run"] = int(stats["stale_run"]) + 1
		return
	if int(v["seq"]) <= int(q["last_seq"]):
		stats["old_seq"] = int(stats["old_seq"]) + 1
		return
	q["last_seq"] = int(v["seq"])
	q["last_input_ms"] = now
	var st: Array = q["seat"]
	if st.is_empty():
		stats["unseated"] = int(stats["unseated"]) + 1
		return
	if bool(v["menu"]):
		v = NetProto.neutral_input()
	if bool(q["needs_neutral"]):
		# COMING BACK TO A SEAT: nothing counts until the hands are at rest
		if not NetProto.is_neutral(v):
			stats["neutral_wait"] = int(stats["neutral_wait"]) + 1
			_apply_seat(q, NetProto.neutral_input(), false)
			return
		q["needs_neutral"] = false
		q["counters"] = (v["presses"] as Dictionary).duplicate()
		_dirty = true
	if state != "running" or BB.halted:
		stats["not_running"] = int(stats["not_running"]) + 1
		q["counters"] = (v["presses"] as Dictionary).duplicate()
		return
	stats["inputs"] = int(stats["inputs"]) + 1
	_apply_seat(q, v, true)

## Write one player's accepted input into the virtual devices their seat owns,
## and nothing else. A driver's fire button reaches no mechanism; an
## operator's stick moves no wheel.
func _apply_seat(q: Dictionary, v: Dictionary, count_presses: bool) -> void:
	var st: Array = q["seat"]
	if st.is_empty():
		return
	var robot: int = st[0]
	var role: String = st[1]
	var drv := DriverInput.VIRTUAL + 2 * robot
	var op := drv + 1
	var held: Dictionary = v["held"]
	var old: Dictionary = q["counters"]
	var pr: Dictionary = v["presses"]
	var diff := {}
	for a in NetProto.PRESSES:
		if not old.has(a):
			diff[a] = 0
		else:
			diff[a] = mini((int(pr.get(a, 0)) - int(old[a])) & 0xFF, 4)
	if count_presses:
		q["counters"] = pr.duplicate()
	if role == "whole" or role == "driver":
		var dh := {}
		for a2 in NetProto.DRIVER_HELD:
			dh[a2] = bool(held.get(a2, false))
		DriverInput.set_virtual(drv, v["move"], float(v["turn"]), float(v["precision"]), dh)
		for a3 in NetProto.DRIVER_PRESSES:
			DriverInput.add_virtual_presses(drv, a3, int(diff[a3]))
	elif _drives_anything(v, false):
		# counted, never applied: this seat does not drive
		stats["masked"] = int(stats["masked"]) + 1
	if role == "whole" or role == "operator":
		var oh := {}
		for a4 in NetProto.OPERATOR_HELD:
			oh[a4] = bool(held.get(a4, false))
		var cur: Dictionary = DriverInput.virtual_state(op)
		DriverInput.set_virtual(op, cur.get("move", Vector2.ZERO), 0.0, 1.0, oh)
		for a5 in NetProto.OPERATOR_PRESSES:
			DriverInput.add_virtual_presses(op, a5, int(diff[a5]))
	elif _drives_anything(v, true):
		# counted, never applied: this seat does not run the mechanisms
		stats["masked"] = int(stats["masked"]) + 1

static func _drives_anything(v: Dictionary, operator_part: bool) -> bool:
	var held: Dictionary = v["held"]
	if operator_part:
		for a in NetProto.OPERATOR_HELD:
			if bool(held.get(a, false)):
				return true
		return false
	return (v["move"] as Vector2).length() > 0.05 or absf(float(v["turn"])) > 0.05

## Inputs that stop arriving stop counting: after STALE_INPUT_MS the seat's
## sticks and held buttons go to neutral, so no robot drives or fires on a
## frozen connection.
func _stale_inputs(now: int) -> void:
	for pid in parts:
		var q: Dictionary = parts[pid]
		var st: Array = q["seat"]
		if st.is_empty():
			continue
		if now - int(q["last_input_ms"]) > STALE_INPUT_MS or not bool(q["connected"]):
			var robot: int = st[0]
			var role: String = st[1]
			if role != "operator":
				DriverInput.clear_virtual(DriverInput.VIRTUAL + 2 * robot)
			if role != "driver":
				DriverInput.clear_virtual(DriverInput.VIRTUAL + 2 * robot + 1)

# ============================================================ snapshots ===

func _send_snapshot() -> void:
	if _robots.is_empty() or _row.is_empty():
		return
	for r in _robots:
		if not is_instance_valid(r):
			return                        # mid-restore
	ReplayRecorder.fill_row(_row, 0, 0.0, main.mm, main.field, _robots, _hives, _elements)
	var acks: Array = []
	for pid in parts:
		var q: Dictionary = parts[pid]
		acks.append([pid, int(q["last_seq"])])
	var pkt := NetProto.pack_snapshot(run_id, Engine.get_physics_frames(), acks, _row, layout)
	for pid2 in parts:
		var q2: Dictionary = parts[pid2]
		if bool(q2["connected"]) and q2["link"] != null:
			(q2["link"] as NetLink).send(int(q2["peer"]), NetLink.CH_STATE, pkt)

## Things that change less often than poses and must not be lost: opponent
## status lines, the event log, the objective card, each robot's toggles.
func _send_slow(force := false) -> void:
	_last_slow_ms = Time.get_ticks_msec()
	var robots: Array = []
	for i in _robots.size():
		var r: Variant = _robots[i]
		if not is_instance_valid(r):
			continue
		var rob: Robot = r
		var status := ""
		for b in main.ais:
			if is_instance_valid(b) and b.robot == rob:
				status = String(b.status)
		robots.append({"i": i, "status": status, "auto_aim": rob.auto_aim,
			"field_centric": rob.field_centric, "intake": rob.intake_on,
			"launch": snappedf(rob.launch_speed_in_s, 1.0), "locked": rob.aim_locked,
			"blocked": rob.aim_blocked, "dist": snappedf(rob.aim_dist_in, 1.0),
			"label": rob.driver_label})
	var obj := {}
	if main.attempt != null and is_instance_valid(main.attempt):
		var at: Attempt = main.attempt
		obj = {"text": Objective.describe(at.objective), "status": at.status_text(),
			"time": at.time_text(), "pending": at.pending_confirmation()}
	var slow := {"run": run_id, "robots": robots, "events": Array(main.mm.events),
		"objective": obj, "human": [main.mm.human_pending(BB.Alliance.RED),
			main.mm.human_pending(BB.Alliance.BLUE)]}
	if not force and slow == _last_slow:
		return
	_last_slow = slow
	for pid in parts:
		if bool(parts[pid]["connected"]):
			_to(pid, NetLink.CH_CONTROL, NetProto.SLOW, slow)

func _broadcast_state() -> void:
	_last_state_ms = Time.get_ticks_msec()
	_dirty = false
	var plist: Array = []
	var now := Time.get_ticks_msec()
	for pid in parts:
		var q: Dictionary = parts[pid]
		var left := 0.0
		if not bool(q["connected"]):
			left = maxf(0.0, GRACE_S - float(now - int(q["disconnected_ms"])) / 1000.0)
		plist.append({"pid": pid, "name": q["name"], "owner": pid == owner_pid,
			"connected": q["connected"], "seat": q["seat"], "ready": q["ready"],
			"acked": int(q["scen_ack"]) == scenario_rev, "menu": q["menu"],
			"route": (q["link"] as NetLink).route(int(q["peer"])) if bool(q["connected"]) and q["link"] != null else "",
			"ping": q["ping_ms"], "grace": left, "needs_neutral": q["needs_neutral"],
			"restored": int(q["restore_ack"]) == run_id})
	var seat_rows: Array = []
	for i in seats.size():
		var s: Dictionary = seats[i]
		seat_rows.append({"robot": i, "label": _robot_label(i), "ai": bool(ai_mask[i]),
			"whole": s["whole"], "driver": s["driver"], "operator": s["operator"]})
	var st := {
		"state": state, "room": room_name, "code": code, "owner": owner_pid,
		"locked": locked, "run": run_id, "pause_reason": pause_reason,
		"countdown_ms": maxi(0, countdown_end_ms - now) if state == "countdown" else 0,
		"requests": requests, "parts": plist, "seats": seat_rows,
		"scenario": {"rev": scenario_rev, "summary": summary},
		"blockers": start_blockers(), "capacity": NetRole.MAX_PARTICIPANTS,
		"layout": layout, "result": result, "snap_every": snap_every,
	}
	for pid2 in parts:
		if bool(parts[pid2]["connected"]):
			_to(pid2, NetLink.CH_CONTROL, NetProto.ROOM_STATE, st)

func _to(pid: int, ch: int, type: int, payload: Dictionary) -> void:
	var q: Dictionary = parts.get(pid, {})
	if q.is_empty() or q["link"] == null or not bool(q["connected"]):
		return
	(q["link"] as NetLink).send(int(q["peer"]), ch, NetProto.pack(type, payload))

# ======================================================= connections ===

func _on_disconnect(l: NetLink, peer: int) -> void:
	var pid: int = by_peer.get(_key(l, peer), -1)
	by_peer.erase(_key(l, peer))
	if pid < 0 or not parts.has(pid):
		return
	var q: Dictionary = parts[pid]
	if q["link"] != l or int(q["peer"]) != peer:
		return
	_lost(pid)

## A participant's connection is gone (the transport said so, or they went
## silent). Their seat goes neutral and, mid-run, the room pauses.
func _lost(pid: int) -> void:
	var q: Dictionary = parts[pid]
	if not bool(q["connected"]):
		return
	if q["link"] != null:
		by_peer.erase(_key(q["link"], int(q["peer"])))
	q["connected"] = false
	q["link"] = null
	q["peer"] = -1
	q["disconnected_ms"] = Time.get_ticks_msec()
	q["menu"] = false
	_neutral_seat(q)
	_dirty = true
	var st: Array = q["seat"]
	var where := ""
	if not st.is_empty():
		where = " (%s, %s)" % [_robot_label(int(st[0])), _role_name(String(st[1]))]
	_log("%s disconnected%s" % [q["name"], where])
	if state in ["running", "countdown", "loading"] and (not st.is_empty() or pid == owner_pid):
		var txt := "%s%s disconnected. Waiting up to %d s for them to come back." % [
			q["name"], where, int(GRACE_S)]
		if pid == owner_pid:
			txt += " If the host does not return, the session ends."
		if state == "loading":
			state = "running"            # so _pause applies; nothing has run
		_pause(txt)

func _neutral_seat(q: Dictionary) -> void:
	var st: Array = q["seat"]
	if st.is_empty():
		return
	DriverInput.clear_virtual(DriverInput.VIRTUAL + 2 * int(st[0]))
	DriverInput.clear_virtual(DriverInput.VIRTUAL + 2 * int(st[0]) + 1)

static func _role_name(role: String) -> String:
	return {"whole": "whole robot", "driver": "driver", "operator": "operator"}.get(role, role)

func _remove(pid: int, why: String) -> void:
	if not parts.has(pid):
		return
	var q: Dictionary = parts[pid]
	var had_seat: bool = not (q["seat"] as Array).is_empty()
	_neutral_seat(q)
	_free_seat(pid)
	if q["link"] != null:
		by_peer.erase(_key(q["link"], int(q["peer"])))
	parts.erase(pid)
	requests = requests.filter(func(r) -> bool: return int(r["pid"]) != pid)
	_log(why)
	_tell_directory()
	if pid == owner_pid:
		_close("The host left, so the session has ended." if why.contains("left")
			else "The host did not come back in time, so the session has ended.")
		return
	if had_seat:
		_clear_ready()
		if state in ["running", "countdown"]:
			_pause(why + " Their seat is empty: reassign it or end the session.")
	_dirty = true

func _timers(now: int) -> void:
	if state == "countdown" and now >= countdown_end_ms:
		_go()
	for pid in parts.keys():
		var q: Dictionary = parts[pid]
		# gone quiet: whatever the transport thinks, nothing is arriving
		if bool(q["connected"]) and now - int(q["last_rx_ms"]) > SILENT_MS \
				and (q["link"] as NetLink).kind != NetLink.Kind.LOOP:
			_log("%s went silent" % q["name"])
			_lost(pid)
		if not bool(q["connected"]) and now - int(q["disconnected_ms"]) > int(GRACE_S * 1000.0):
			_remove(pid, "%s did not come back in time." % q["name"])
			if _closing:
				return

var _closing := false

## END THE SESSION for everyone: tell every player why, give the message a
## moment to leave, close every link. The host's game goes back to its menus
## (NetClient), with its replays kept like everyone else's.
func _close(why: String) -> void:
	if _closing:
		return
	_closing = true
	_log("closing: %s" % why)
	_finish_recording("abandoned")
	for pid in parts:
		_to(pid, NetLink.CH_CONTROL, NetProto.CLOSED, {"reason": "closed", "text": why})
	for _i in 6:
		for l in links:
			(l as NetLink).poll()
		await get_tree().create_timer(0.05).timeout
	for l2 in links:
		(l2 as NetLink).close()
	DriverInput.clear_all_virtual()
	if main.net_room == self:
		main.net_room = null
	closed.emit(why)

## The host ends the session on purpose.
func end_session(why := "The host ended the session.") -> void:
	_close(why)
