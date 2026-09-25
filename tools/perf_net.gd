extends Node
## ONLINE LOAD AND RESPONSIVENESS, MEASURED — ON ONE MACHINE.
##
##   godot --headless --path . tools/perf_net.tscn [-- quick | idle | baseline]
##
## THE ROOM RUNS IN A HOST PLAYER'S GAME: each condition starts a headless
## copy of the game hosting a room (--host-test, no local player) and eight
## protocol players join it with the invite. The host's CPU here is the ROOM'S
## cost (simulation + networking); a real host also draws the game on screen,
## which this headless host does not.
##
## The intended full room: 2 v 2, every robot human, every robot split into a
## driver and an operator — 8 players, the maximum. For each network condition
## a fresh room is made, all 8 take their seats, and for WINDOW seconds every
## driver drives and every operator works the mechanisms at 60 inputs per
## second, exactly the rate the real client sends.
##
## Measured:
##   room process CPU share and resident memory (from /proc), its own tick cost
##   (LOAD lines it prints), bytes per second each
##   way per player and at the server, snapshot rate and size, and
##   responsiveness for driver 1: from the input that starts a drive to (a) the
##   server acknowledging that input in a snapshot and (b) the first snapshot
##   in which the robot has moved 2 cm — compared with the same drive offline.
##
## CONDITIONS ARE SIMULATED at each player's end (NetLink.sim): one-way delay
## added on the way out AND on the way in, so the round trip grows by twice
## the one-way figure, plus jitter and loss of unreliable packets in both
## directions. This is a model of a bad connection on loopback. It is NOT a
## measurement of the internet.
##
## Output: a table on stdout and user://perf_net.json.

var PORT := 17500
var host_pid := -1
var invite := ""
var WINDOW := 30.0
const MOVE_M := 0.02

## [label, spec "one-way ms, jitter ms, loss share", round trip it adds]
var CONDITIONS := [
	["loopback, no simulation", "", "≈0 ms"],
	["RTT ≈ 30 ms, jitter ±3, 0 % loss", "15,3,0", "+30 ms"],
	["RTT ≈ 60 ms, jitter ±8, 2 % loss each way", "30,8,0.02", "+60 ms"],
	["RTT ≈ 100 ms, jitter ±15, 5 % loss each way", "50,15,0.05", "+100 ms"],
	["RTT ≈ 200 ms, jitter ±30, 10 % loss each way", "100,30,0.10", "+200 ms"],
]

var main: Node3D
var _bots: Array = []
var _results: Array = []

func _ready() -> void:
	Engine.max_fps = 240
	var args := OS.get_cmdline_user_args()
	if args.has("quick"):
		WINDOW = 10.0
		CONDITIONS = [CONDITIONS[0], CONDITIONS[3]]
	print("=== ONLINE LOAD — %d cores, %s ===" % [OS.get_processor_count(), OS.get_processor_name()])
	if args.has("idle"):
		await _idle_room()
		return
	var base := await _offline_baseline()
	if args.has("baseline"):
		print("offline baseline: %s" % str(base))
		get_tree().quit(0)
		return
	print("offline baseline: first 2 cm of motion %.0f ms after the input (median of %d) %s" % [base["mean_ms"], base["n"], str(base.get("all_ms", []))])
	for c in CONDITIONS:
		var r := await _condition(String(c[0]), String(c[1]), String(c[2]), float(base["mean_ms"]))
		_results.append(r)
		_print_row(r)
	var recon := await _reconnect_trials()
	var out := {"cores": OS.get_processor_count(), "cpu": OS.get_processor_name(),
		"window_s": WINDOW, "offline_baseline": base, "conditions": _results,
		"reconnect": recon, "note": "Simulated conditions on loopback. Not the internet."}
	var f := FileAccess.open("user://perf_net.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "  "))
	f.close()
	print("wrote %s" % ProjectSettings.globalize_path("user://perf_net.json"))
	get_tree().quit(0)

## A fresh headless host for each measurement.
func _start_host(owner: String) -> bool:
	if host_pid > 0:
		OS.kill(host_pid)
		await get_tree().create_timer(0.5).timeout
	PORT += 1
	var f := ProjectSettings.globalize_path("user://perf_invite.txt")
	if FileAccess.file_exists(f):
		DirAccess.remove_absolute(f)
	host_pid = OS.create_process(OS.get_executable_path(), ["--path",
		ProjectSettings.globalize_path("res://"), "--headless", "--", "--host-test",
		"--port", str(PORT), "--owner", owner, "--invite-file", f, "--load-report"])
	var t0 := Time.get_ticks_msec()
	while not FileAccess.file_exists(f) and Time.get_ticks_msec() - t0 < 30000:
		await get_tree().process_frame
	invite = FileAccess.get_file_as_string(f).strip_edges() if FileAccess.file_exists(f) else ""
	return invite != ""

# ============================================================ offline base ==

## The same drive, offline: robot at rest, forward pushed, time until it has
## moved 2 cm. This is physics (acceleration), not network, and every online
## figure below includes it too.
func _offline_baseline() -> Dictionary:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(2.5).timeout
	main._on_menu_start(BB.Mode.FREE_PRACTICE, BB.Alliance.RED, 1,
		{"robots": 1, "mate_is_ai": false, "per_robot": 1, "opponents": 0, "takes_nectar": false})
	await get_tree().create_timer(3.0).timeout
	var times: Array = []
	if main.robots.is_empty():
		return {"mean_ms": 0.0, "n": 0, "error": "no offline robot"}
	var ev := InputEventKey.new()
	ev.keycode = KEY_W
	ev.physical_keycode = KEY_W
	for i in 8:
		# back and forth with short pushes, so the robot never ends a trial
		# against a wall; each trial starts only once the robot is at rest
		# a NEW event object for every press and release: Godot ignores a
		# re-sent one
		ev = InputEventKey.new()
		ev.keycode = KEY_W if i % 2 == 0 else KEY_S
		ev.physical_keycode = ev.keycode
		var still := 0
		var last: Vector3 = main.robots[0].global_position
		var guard0 := 0
		while still < 60 and guard0 < 1800:
			await get_tree().physics_frame
			var now_p: Vector3 = main.robots[0].global_position
			still = still + 1 if now_p.distance_to(last) < 0.0002 else 0
			last = now_p
			guard0 += 1
		var p0: Vector3 = main.robots[0].global_position
		var t0 := Time.get_ticks_usec()
		ev.pressed = true
		Input.parse_input_event(ev)
		var guard := 0
		while guard < 400 and (main.robots[0].global_position as Vector3).distance_to(p0) < MOVE_M:
			await get_tree().physics_frame
			guard += 1
		times.append(float(Time.get_ticks_usec() - t0) / 1000.0)
		await get_tree().create_timer(0.3).timeout
		var up := InputEventKey.new()
		up.keycode = ev.keycode
		up.physical_keycode = ev.keycode
		up.pressed = false
		Input.parse_input_event(up)
	main.queue_free()
	main = null
	await get_tree().create_timer(0.5).timeout
	var st := _stats(times)
	# the median is the figure used: one trial can catch a frame hitch
	return {"mean_ms": float(st.get("median", 0.0)), "n": times.size(), "all_ms": times}

# =============================================================== condition ==

func _condition(label: String, spec: String, adds: String, base_ms: float) -> Dictionary:
	print("\n--- %s ---" % label)
	_bots.clear()
	if not await _start_host("P1"):
		return {"label": label, "error": "host did not start"}
	var own := _bot("P1", spec)
	own.join(invite)
	await _until(func() -> bool: return own.s.phase in ["in_room", "failed"], 30.0)
	if own.s.phase != "in_room":
		return {"label": label, "error": own.s.error_text}
	for i in range(1, 8):
		_bot("P%d" % (i + 1), spec).join(invite)
	await _until(func() -> bool:
		for b in _bots:
			if (b as NetBot).s.phase != "in_room":
				return false
		return true, 40.0)
	own.s.send(NetProto.SET_SCENARIO, {"standard": "2v2_free"})
	await _until(func() -> bool: return own.s.scenario_rev >= 1, 20.0)
	for r in 4:
		own.s.send(NetProto.SET_AI, {"robot": r, "on": false})
		await _pump(0.3)
	await _pump(1.0)
	for i in 8:
		var b: NetBot = _bots[i]
		b.s.send(NetProto.SEAT, {"robot": i / 2, "role": "driver" if i % 2 == 0 else "operator"})
		await _pump(0.15)
	await _pump(1.0)
	for b2 in _bots:
		(b2 as NetBot).s.send(NetProto.READY, {"on": true})
	await _until(func() -> bool: return (own.s.state.get("blockers", ["x"]) as Array).is_empty(), 20.0)
	own.s.send(NetProto.START, {})
	await _until(func() -> bool: return String(own.s.state.get("state", "")) == "running", 30.0)
	var seated := 0
	for sr in own.s.state.get("seats", []):
		for role in ["driver", "operator"]:
			if int((sr as Dictionary).get(role, -1)) >= 0:
				seated += 1
	var who: Array = []
	for bq in _bots:
		who.append("%s=%s" % [(bq as NetBot).name, str((bq as NetBot).s.my_seat())])
	print("  %d players, %d seats filled, state %s · %s" % [_bots.size(), seated, own.s.state.get("state", ""), " ".join(who)])
	for b3 in _bots:
		(b3 as NetBot).send_inputs = true
	await _pump(1.0)

	var room_pid := host_pid
	var cpu0 := _cpu_ticks(room_pid)
	var bytes0: Array = []
	for b4 in _bots:
		bytes0.append([(b4 as NetBot).s.room.bytes_in, (b4 as NetBot).s.room.bytes_out,
			(b4 as NetBot).s.room.packets_in, (b4 as NetBot).s.snaps_in])
	var t0 := Time.get_ticks_usec()

	# the window: driver 1 runs response trials, everyone else plays
	var drv: NetBot = _bots[0]
	var ack_ms: Array = []
	var move_ms: Array = []
	var delays: Array = []
	var trial_start := 0
	var trial_seq := -1
	var trial_pos := Vector3.INF
	var got_ack := false
	var got_move := false
	var phase_t := 0.0
	var driving := false
	var last_send := 0.0
	var clock := 0.0
	var jit := {}
	while clock < WINDOW:
		var now_s := float(Time.get_ticks_usec() - t0) / 1e6
		var dt := now_s - clock
		clock = now_s
		phase_t += dt
		# driver 1: 1.6 s at rest, then forward for 1.2 s
		if not driving and phase_t > 1.6:
			driving = true
			phase_t = 0.0
			drv.input["move"] = Vector2(0, 1 if move_ms.size() % 2 == 0 else -1)
			trial_start = Time.get_ticks_usec()
			trial_seq = -1
			trial_pos = drv.robot_pos(0)
			got_ack = false
			got_move = false
		elif driving and phase_t > 1.2:
			driving = false
			phase_t = 0.0
			drv.input["move"] = Vector2.ZERO
		# other drivers wander; operators run the intake and fire now and then
		for i in range(1, 8):
			var b5: NetBot = _bots[i]
			if i % 2 == 0:
				b5.input["move"] = Vector2(sin(clock * 0.7 + i), cos(clock * 0.5 + i) * 0.8)
				b5.input["turn"] = sin(clock * 1.3 + i) * 0.5
			else:
				b5.hold("fire", fmod(clock + i * 0.3, 2.0) < 0.2)
				b5.hold("turret_left", fmod(clock + i, 3.0) < 0.5)
		# inputs at 60 Hz, as the real client sends them
		var send_now := clock - last_send >= 1.0 / 60.0
		if send_now:
			last_send = clock
		for b6 in _bots:
			(b6 as NetBot).send_inputs = send_now
			(b6 as NetBot).poll()
		if driving and trial_seq < 0 and send_now:
			trial_seq = drv.s.seq
		# (a) the server has acknowledged the input that started the drive
		if driving and trial_seq >= 0 and not got_ack and not drv.s.snaps.is_empty():
			var ak: Dictionary = drv.s.snaps[-1].get("acks", {})
			if int(ak.get(drv.s.pid, -1)) >= trial_seq:
				got_ack = true
				ack_ms.append(float(Time.get_ticks_usec() - trial_start) / 1000.0)
		# (b) the first snapshot showing the robot 2 cm further on
		if driving and not got_move and trial_pos != Vector3.INF \
				and drv.robot_pos(0).distance_to(trial_pos) > MOVE_M:
			got_move = true
			move_ms.append(float(Time.get_ticks_usec() - trial_start) / 1000.0)
		# the render delay the real client would choose from this arrival pattern
		for bi in _bots.size():
			var bb: NetBot = _bots[bi]
			if bb.s.snaps.is_empty():
				continue
			var sn: Dictionary = bb.s.snaps[-1]
			var st: Dictionary = jit.get(bi, {"samples": [], "last": -1})
			if int(sn["tick"]) != int(st["last"]):
				st["last"] = int(sn["tick"])
				var at := float(sn["arrived"]) / 1e6 * 180.0
				(st["samples"] as Array).append([at, at - float(sn["tick"])])
				while (st["samples"] as Array).size() > 1 and at - float(st["samples"][0][0]) > 360.0:
					(st["samples"] as Array).pop_front()
				var base := INF
				for smp in st["samples"]:
					base = minf(base, float(smp[1]))
				var j := 0.0
				for smp2 in st["samples"]:
					j += float(smp2[1]) - base
				j /= float((st["samples"] as Array).size())
				st["delay"] = clampf(6.0 + 2.0 * j, 6.0, 45.0)
			jit[bi] = st
		await get_tree().process_frame
	for bi2 in jit:
		delays.append(float(jit[bi2].get("delay", 6.0)) / 180.0 * 1000.0)

	var secs := float(Time.get_ticks_usec() - t0) / 1e6
	var cpu1 := _cpu_ticks(room_pid)
	var per_in: Array = []
	var per_out: Array = []
	var snap_rate: Array = []
	var snap_size: Array = []
	var pings: Array = []
	for i2 in _bots.size():
		var b7: NetBot = _bots[i2]
		per_in.append(float(b7.s.room.bytes_in - int(bytes0[i2][0])) / secs / 1024.0)
		per_out.append(float(b7.s.room.bytes_out - int(bytes0[i2][1])) / secs / 1024.0)
		snap_rate.append(float(b7.s.snaps_in - int(bytes0[i2][3])) / secs)
		var pk := b7.s.room.packets_in - int(bytes0[i2][2])
		snap_size.append(float(b7.s.room.bytes_in - int(bytes0[i2][0])) / maxf(1.0, pk))
		pings.append(b7.s.ping_ms)
	var r := {
		"label": label, "spec": spec, "adds_rtt": adds, "players": _bots.size(),
		"seats": seated, "window_s": secs,
		"room_cpu_pct": 100.0 * float(cpu1 - cpu0) / 100.0 / secs,
		"room_rss_mb": _rss_mb(room_pid),
		
		"client_down_kbs": _mean(per_in), "client_up_kbs": _mean(per_out),
		"server_up_kbs": _sum(per_in), "server_down_kbs": _sum(per_out),
		"snaps_per_s": _mean(snap_rate), "bytes_per_packet_in": _mean(snap_size),
		"ping_ms": _mean(pings),
		"ack_ms": _stats(ack_ms), "move_ms": _stats(move_ms),
		"added_over_offline_ms": _mean(move_ms) - base_ms,
		"render_delay_ms": _mean(delays),
		"input_to_screen_est_ms": _mean(move_ms) + _mean(delays),
		"stale_or_dropped": drv.s.room.dropped_by_sim,
	}
	# everyone leaves; the room closes with its owner
	for b8 in _bots:
		(b8 as NetBot).send_inputs = false
	own.s.leave()
	await _pump(0.5)
	for b9 in _bots:
		(b9 as NetBot).s.leave()
	await get_tree().create_timer(2.0).timeout
	return r

## What an open room costs while nobody is playing: lobby, then paused.
func _idle_room() -> void:
	await _start_host("Owner")
	var own := _bot("Owner", "")
	own.join(invite)
	await _until(func() -> bool: return own.s.phase == "in_room", 30.0)
	own.s.send(NetProto.SET_SCENARIO, {"standard": "2v2_free"})
	await _until(func() -> bool: return own.s.scenario_rev >= 1, 20.0)
	await _pump(2.0)
	var pid := host_pid
	var c0 := _cpu_ticks(pid)
	var t0 := Time.get_ticks_msec()
	await _pump(20.0)
	var secs := float(Time.get_ticks_msec() - t0) / 1000.0
	print("IDLE lobby, 4 robots on the field, 1 player: host game (headless) %.1f %% of one core, %.0f MB (%.0f s)" % [
		100.0 * float(_cpu_ticks(pid) - c0) / 100.0 / secs, _rss_mb(pid), secs])
	own.s.leave()
	await _pump(0.5)
	OS.kill(host_pid)
	get_tree().quit(0)

## Drop and come back, with the worst simulated connection, five times.
func _reconnect_trials() -> Dictionary:
	print("\n--- RECONNECTING UNDER 5 % LOSS, RTT ≈ 100 ms ---")
	_bots.clear()
	var spec := "50,15,0.05"
	await _start_host("Owner")
	var own := _bot("Owner", spec)
	own.join(invite)
	await _until(func() -> bool: return own.s.phase == "in_room", 30.0)
	var p := _bot("Driver", spec)
	p.join(invite)
	await _until(func() -> bool: return p.s.phase == "in_room", 30.0)
	own.s.send(NetProto.SET_SCENARIO, {"standard": "1v0_free"})
	await _until(func() -> bool: return p.s.scenario_rev >= 1, 20.0)
	p.s.send(NetProto.SEAT, {"robot": 0, "role": "whole"})
	await _pump(1.0)
	p.s.send(NetProto.READY, {"on": true})
	own.s.send(NetProto.READY, {"on": true})
	await _pump(1.0)
	own.s.send(NetProto.START, {})
	await _until(func() -> bool: return String(own.s.state.get("state", "")) == "running", 20.0)
	p.send_inputs = true
	own.send_inputs = true
	var times: Array = []
	var same_seat := 0
	for k in 5:
		await _pump(1.0)
		p.s.drop_link()
		await _until(func() -> bool: return String(own.s.state.get("state", "")) == "paused", 10.0)
		var t0 := Time.get_ticks_msec()
		p.s.reconnect_now()
		var ok := await _until(func() -> bool: return p.s.phase == "in_room" and not p.s.snaps.is_empty(), 20.0)
		times.append(float(Time.get_ticks_msec() - t0) if ok else -1.0)
		if p.s.my_seat() == [0, "whole"]:
			same_seat += 1
		await _pump(0.8)
		own.s.send(NetProto.RESUME, {})
		await _until(func() -> bool: return String(own.s.state.get("state", "")) in ["running", "countdown"], 10.0)
	own.s.leave()
	p.s.leave()
	await _pump(0.5)
	OS.kill(host_pid)
	var r := {"trials": times.size(), "same_seat": same_seat, "ms": _stats(times)}
	print("  back in the seat with fresh state: %s ms (same seat %d/%d)" % [str(times), same_seat, times.size()])
	return r

# ================================================================= helpers ==

func _bot(n: String, spec: String) -> NetBot:
	var b := NetBot.new(n)
	b.s.sim_spec = spec
	_bots.append(b)
	return b

func _pump(secs: float) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(secs * 1000.0):
		for b in _bots:
			(b as NetBot).poll()
		await get_tree().process_frame

func _until(cond: Callable, secs: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(secs * 1000.0):
		for b in _bots:
			(b as NetBot).poll()
		if cond.call():
			return true
		await get_tree().process_frame
	return false

func _pid_of(pattern: String) -> int:
	var out: Array = []
	OS.execute("pgrep", ["-f", "--", pattern], out)
	var lines := String(out[0] if not out.is_empty() else "").strip_edges().split("\n")
	return int(lines[0]) if lines.size() > 0 and lines[0].is_valid_int() else -1

func _cpu_ticks(pid: int) -> int:
	if pid <= 0:
		return 0
	var o: Array = []
	OS.execute("cat", ["/proc/%d/stat" % pid], o)
	var s := String(o[0]) if not o.is_empty() else ""
	if not s.contains(")"):
		return 0
	var parts := s.substr(s.rfind(")") + 2).split(" ")
	return int(parts[11]) + int(parts[12])      # utime + stime, 1/100 s

func _rss_mb(pid: int) -> float:
	if pid <= 0:
		return 0.0
	var o: Array = []
	OS.execute("cat", ["/proc/%d/status" % pid], o)
	for line in String(o[0] if not o.is_empty() else "").split("\n"):
		if line.begins_with("VmRSS:"):
			return float(line.split(":")[1].strip_edges().split(" ")[0]) / 1024.0
	return 0.0

func _mean(a: Array) -> float:
	return _sum(a) / maxf(1.0, a.size())

func _sum(a: Array) -> float:
	var s := 0.0
	for v in a:
		s += float(v)
	return s

func _stats(a: Array) -> Dictionary:
	if a.is_empty():
		return {"n": 0}
	var b := a.duplicate()
	b.sort()
	return {"n": b.size(), "mean": _mean(b), "min": b[0], "median": b[b.size() / 2], "max": b[-1]}

func _print_row(r: Dictionary) -> void:
	if r.has("error"):
		print("  ERROR %s" % r["error"])
		return
	print("  host game (headless: simulation + networking, no drawing): %.0f %% of one core, %.0f MB" % [
		r["room_cpu_pct"], r["room_rss_mb"]])
	print("  per player: down %.1f KB/s, up %.1f KB/s · host total: up %.0f KB/s, down %.0f KB/s" % [
		r["client_down_kbs"], r["client_up_kbs"], r["server_up_kbs"], r["server_down_kbs"]])
	print("  snapshots %.1f/s, %.0f B per packet received · ping %.0f ms" % [
		r["snaps_per_s"], r["bytes_per_packet_in"], r["ping_ms"]])
	print("  input -> server ack: %s" % _fmt(r["ack_ms"]))
	print("  input -> 2 cm of motion in a snapshot: %s (offline %.0f; network adds %.0f)" % [
		_fmt(r["move_ms"]), r["move_ms"].get("mean", 0.0) - r["added_over_offline_ms"], r["added_over_offline_ms"]])
	print("  client render delay %.0f ms -> input to screen ≈ %.0f ms" % [r["render_delay_ms"], r["input_to_screen_est_ms"]])

func _fmt(s: Dictionary) -> String:
	if int(s.get("n", 0)) == 0:
		return "no samples"
	return "mean %.0f ms (min %.0f, median %.0f, max %.0f, n=%d)" % [s["mean"], s["min"], s["median"], s["max"], s["n"]]
