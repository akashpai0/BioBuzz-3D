extends Node
## WHAT RECORDING COSTS, MEASURED.
##
## Run with --fixed-fps 180 so every frame is exactly one physics tick and the
## simulation runs as fast as the CPU allows (no real-time pacing):
##   godot --headless --fixed-fps 180 --path . tools/perf_replay.tscn -- match
##   ... -- long       20 simulated minutes of free practice, 2 robots moving
##   ... -- library    2 000 replays in one folder
## Numbers are printed, never asserted against a guess, except the bounded-
## memory and no-decode properties, which are the promises being made.

var main: Node3D
var fails := 0
var _goal_i := 0
var _goals := [Vector2(-40, 30), Vector2(-60, -30), Vector2(-10, -20), Vector2(-50, 10)]
var _drive := false

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(2.5).timeout
	var dir := ProjectSettings.globalize_path("user://replay_perf")
	DirAccess.make_dir_recursive_absolute(dir)
	_clear(dir)
	var prev := ReplayStore._config()
	ReplayStore.set_folder(dir)
	print("\nMACHINE: %s · %d logical cores · %s · Godot %s · headless, no GPU" % [
		OS.get_processor_name(), OS.get_processor_count(), OS.get_name(),
		Engine.get_version_info()["string"]])
	var args := OS.get_cmdline_user_args()
	var what := String(args[0]) if args.size() > 0 else "match"
	match what:
		"match": await _match()
		"long": await _long()
		"library": await _library(dir)
	ReplayStore._write_json_atomic(ReplayStore.CONFIG, prev)
	ReplayStore.reload_folder()
	print("  %s" % ("PERF DONE" if fails == 0 else "PERF: %d PROPERTY FAILURES" % fails))
	get_tree().quit(1 if fails > 0 else 0)

func _ok(what: String, good: bool) -> void:
	if not good:
		fails += 1
	print("  [%s] %s" % ["ok" if good else "FAIL", what])

func _clear(dir: String) -> void:
	var da := DirAccess.open(dir)
	if da == null:
		return
	for f in da.get_files():
		DirAccess.remove_absolute(dir.path_join(f))

func _physics_process(_d: float) -> void:
	if not _drive or main == null or BB.frozen() or BB.halted or not is_instance_valid(main.robot):
		return
	var me: Robot = main.robot
	me.auto_drive = true
	var g: Vector2 = _goals[_goal_i]
	var loc := me.to_local(BB.fp(g.x, g.y, 0.0))
	var f := Vector2(loc.x, loc.z)
	if f.length() < BB.m(8.0):
		_goal_i = (_goal_i + 1) % _goals.size()
		return
	f = f.normalized() * 0.8
	me.set_drive(f.x, clampf(-atan2(loc.x, -loc.z), -0.5, 0.5), -f.y)

func _ticks(n: int) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var frames := PackedFloat32Array()
	var last := t0
	for i in n:
		await get_tree().physics_frame
		var now := Time.get_ticks_usec()
		frames.append(float(now - last))
		last = now
	frames.sort()
	var tot := 0.0
	for v in frames:
		tot += v
	return {"avg_us": tot / float(n), "p99_us": frames[int(n * 0.99)],
		"wall_s": float(Time.get_ticks_usec() - t0) / 1e6}

# ---------------------------------------------------------------- match ---

func _match() -> void:
	var secs := 60
	var opts := {"robots": 2, "mate_is_ai": true, "per_robot": 1, "opponents": 2,
		"takes_nectar": false}
	print("\nSCENE: Teleop-only match, 4 robots (you + AI partner + 2 Collect opponents), 56 elements, %d s simulated" % secs)
	for recording in [false, true]:
		main._no_record_next = not recording
		await main._on_menu_start(BB.Mode.TELEOP_ONLY, BB.Alliance.RED, 1, opts)
		_drive = true
		var rec: ReplayRecorder = main.recorder
		rec.cost_usec_total = 0
		rec.cost_usec_max = 0
		rec.cost_ticks = 0
		rec.debug_keep_costs = recording
		rec.debug_costs = PackedInt32Array()
		var r := await _ticks(secs * 180)
		_drive = false
		print("  recording %s: whole tick avg %.0f µs, p99 %.0f µs (%.1f s wall for %d s simulated)" % [
			"ON " if recording else "OFF", r["avg_us"], r["p99_us"], r["wall_s"], secs])
		if recording:
			print("  recorder's own share: avg %.1f µs per tick, worst single tick %.2f ms (%d ticks)" % [
				float(rec.cost_usec_total) / float(maxi(rec.cost_ticks, 1)),
				rec.cost_usec_max / 1000.0, rec.cost_ticks])
			var c := rec.debug_costs.duplicate()
			var kinds := {"plain": [], "sample": [], "block+sample+capture": [], "checkpoint write": []}
			for i in c.size():
				var k := "plain"
				if i % 180 == 0:
					k = "block+sample+capture"
				elif i % 180 == ReplayRecorder.CHECKPOINT_WRITE_LAG:
					k = "checkpoint write"
				elif i % 6 == 0:
					k = "sample"
				(kinds[k] as Array).append(c[i])
			for k in kinds:
				var arr: Array = kinds[k]
				arr.sort()
				if arr.is_empty():
					continue
				var tot := 0
				for x in arr:
					tot += int(x)
				print("    %-22s %5d ticks: avg %6.0f µs, p99 %6.0f µs, max %6.0f µs" % [k, arr.size(),
					float(tot) / arr.size(), float(arr[int(arr.size() * 0.99)]), float(arr[-1])])
			print("    first tick (create file, header, sidecar): %.2f ms" % (rec.cost_open_usec / 1000.0))
			rec.debug_keep_costs = false
			var id := rec.id
			var dur := rec._t()
			main.menu.end_match.emit()
			await get_tree().create_timer(0.3).timeout
			var sz := FileAccess.get_size(ReplayStore.recording_path(id))
			print("  file: %s for %.1f s  ->  %.2f MB per minute" % [ReplayStore.size_text(sz),
				dur, float(sz) / 1048576.0 / dur * 60.0])
			_breakdown(ReplayStore.recording_path(id), dur)
			_ok("the recorder never buffered more than one block (%d samples)" % rec.max_buffered_samples,
				rec.max_buffered_samples <= ReplayRecorder.BLOCK)
		else:
			main.menu.end_match.emit()
			await get_tree().create_timer(0.3).timeout
	# checkpoint costs in isolation
	await main._on_menu_start(BB.Mode.TELEOP_ONLY, BB.Alliance.RED, 1, opts)
	await get_tree().create_timer(1.0).timeout
	var c0 := Time.get_ticks_usec()
	var snap := {}
	for i in 100:
		snap = Snapshot.capture(main, 1)
	var c1 := Time.get_ticks_usec()
	var js := ReplayFormat.json_bytes(snap)
	var c2 := Time.get_ticks_usec()
	var z := js.compress(FileAccess.COMPRESSION_ZSTD)
	var c3 := Time.get_ticks_usec()
	print("  one checkpoint: capture %.2f ms + JSON %.2f ms + zstd %.2f ms  ->  %s on disk (%s raw)" % [
		(c1 - c0) / 100000.0, (c2 - c1) / 1000.0, (c3 - c2) / 1000.0,
		ReplayStore.size_text(z.size()), ReplayStore.size_text(js.size())])
	main.menu.end_match.emit()
	await get_tree().create_timer(0.3).timeout

func _breakdown(path: String, dur: float) -> void:
	var s := ReplayFormat.scan(path)
	var by := {}
	for c in s["chunks"]:
		var k := int(c["type"])
		by[k] = int(by.get(k, 0)) + int(c["comp"]) + ReplayFormat.CHUNK_HEADER_BYTES
	var names := {1: "header", 2: "samples", 3: "checkpoints", 4: "events", 5: "final"}
	var parts: Array = []
	for k in by:
		parts.append("%s %.0f KB/min" % [names.get(k, str(k)), float(by[k]) / 1024.0 / dur * 60.0])
	print("  by kind: " + ", ".join(parts))

# ----------------------------------------------------------------- long ---

func _long() -> void:
	var args := OS.get_cmdline_user_args()
	var minutes := int(args[1]) if args.size() > 1 else 20
	print("\nSCENE: Free practice, you + 1 Collect opponent, 56 elements, %d minutes simulated, driver moving the whole time" % minutes)
	await main._on_menu_start(BB.Mode.FREE_PRACTICE, BB.Alliance.RED, 1,
		{"robots": 1, "mate_is_ai": false, "per_robot": 1, "opponents": 1, "takes_nectar": false})
	_drive = true
	var rec: ReplayRecorder = main.recorder
	var mem: Array = []
	var m0 := OS.get_static_memory_usage()
	for m in minutes:
		var r := await _ticks(60 * 180)
		var used := OS.get_static_memory_usage()
		mem.append(used)
		var sz := FileAccess.get_size(ReplayStore.recording_path(rec.id))
		print("  minute %2d: file %s, static memory %.1f MB (%+.2f MB since start), tick avg %.0f µs" % [
			m + 1, ReplayStore.size_text(sz), used / 1048576.0, (used - m0) / 1048576.0,
			r["avg_us"]])
	_drive = false
	var id := rec.id
	main.menu.end_match.emit()
	await get_tree().create_timer(0.3).timeout
	var p := ReplayStore.recording_path(id)
	var sz2 := FileAccess.get_size(p)
	print("  total: %s for %d minutes = %.2f MB per minute" % [ReplayStore.size_text(sz2),
		minutes, float(sz2) / 1048576.0 / float(minutes)])
	var grow := float(mem[-1] - mem[mini(4, mem.size() - 1)]) / 1048576.0
	print("  memory from minute 5 to minute %d: %+.2f MB" % [minutes, grow])
	_ok("recording memory is bounded (under 4 MB growth over %d minutes)" % (minutes - 5), grow < 4.0)
	_ok("the recorder never held more than one block (%d samples)" % rec.max_buffered_samples,
		rec.max_buffered_samples <= ReplayRecorder.BLOCK)
	# open and seek, cold
	var t0 := Time.get_ticks_usec()
	var rd := ReplayReader.new()
	var err := rd.open(p)
	var open_ms := (Time.get_ticks_usec() - t0) / 1000.0
	_ok("the %d-minute recording opens (%s)" % [minutes, err if err != "" else "ok"], err == "")
	print("  open (index %d chunks, read %d events): %.1f ms" % [
		ReplayFormat.scan(p)["chunks"].size(), rd.events.size(), open_ms])
	_ok("its beginning is still there (first sample at 0.0 s)", float(rd.blocks[0]["t0"]) == 0.0)
	_ok("and its end (%.1f s)" % rd.duration, rd.duration > float(minutes * 60) - 2.0)
	rd.close()
	var werr: String = await main.watch_replay(id, "progress")
	_ok("the viewer opens it", werr == "")
	if werr == "":
		var v: ReplayViewer = main.viewer
		var times := PackedFloat32Array()
		var rng := RandomNumberGenerator.new()
		rng.seed = 7
		for i in 200:
			var tt := rng.randf_range(0.0, v.reader.duration)
			var s0 := Time.get_ticks_usec()
			v.seek(tt)
			times.append(float(Time.get_ticks_usec() - s0) / 1000.0)
		times.sort()
		var tot := 0.0
		for x in times:
			tot += x
		print("  200 random seeks (cold block cache): avg %.2f ms, p95 %.2f ms, worst %.2f ms" % [
			tot / 200.0, times[190], times[199]])
		var q0 := Time.get_ticks_usec()
		v.seek(v.reader.duration * 0.5)
		for i in 60:
			v.seek(v.reader.duration * 0.5 + float(i) / 60.0)
		print("  sequential playback steps within cached blocks: %.3f ms each" % [
			(Time.get_ticks_usec() - q0) / 61000.0])
		var a0 := Time.get_ticks_usec()
		for i in 60:
			v._apply(v.reader.duration * 0.5 + float(i) / 60.0)
		var a1 := Time.get_ticks_usec()
		for i in 60:
			v._refresh_ui()
		var a2 := Time.get_ticks_usec()
		print("    of which posing the field: %.3f ms, updating the panels: %.3f ms" % [
			(a1 - a0) / 60000.0, (a2 - a1) / 60000.0])
		v.close("back")
		await get_tree().create_timer(0.5).timeout

# -------------------------------------------------------------- library ---

func _library(dir: String) -> void:
	var n := 2000
	print("\nSCENE: a folder of %d replays" % n)
	await main._on_menu_start(BB.Mode.TELEOP_ONLY, BB.Alliance.RED, 1,
		{"robots": 1, "mate_is_ai": false, "per_robot": 1, "opponents": 1, "takes_nectar": false})
	await get_tree().create_timer(3.0).timeout
	var id: String = main.recorder.id
	main.menu.end_match.emit()
	await get_tree().create_timer(0.3).timeout
	var rb := FileAccess.get_file_as_bytes(ReplayStore.recording_path(id))
	var meta := ReplayStore.read_meta(id)
	var c0 := Time.get_ticks_usec()
	for i in n - 1:
		var nid := "r-20200101-000000-%05d" % i
		var f := FileAccess.open(ReplayStore.recording_path(nid), FileAccess.WRITE)
		f.store_buffer(rb)
		f.close()
		var m := meta.duplicate(true)
		m["title"] = "Copy %d" % i
		m["created"] = "2020-01-01T00:%02d:%02d" % [(i / 60) % 60, i % 60]
		ReplayStore.write_meta(nid, m)
	print("  wrote %d copies of a %s recording in %.1f s" % [n - 1,
		ReplayStore.size_text(rb.size()), (Time.get_ticks_usec() - c0) / 1e6])
	DirAccess.remove_absolute(dir.path_join(ReplayStore.INDEX))
	ReplayFormat.decode_count = 0
	var t0 := Time.get_ticks_usec()
	var l1 := ReplayStore.list()
	var cold := (Time.get_ticks_usec() - t0) / 1000.0
	t0 = Time.get_ticks_usec()
	var l2 := ReplayStore.list()
	var warm := (Time.get_ticks_usec() - t0) / 1000.0
	print("  list with no index (reads every sidecar + 16-byte signature): %.0f ms" % cold)
	print("  list with a fresh index: %.0f ms" % warm)
	_ok("all %d listed" % n, l1.size() == n and l2.size() == n)
	_ok("listing decoded no recording (decodes: %d)" % ReplayFormat.decode_count,
		ReplayFormat.decode_count == 0)
	# the Progress page itself, first 25 rows
	var lib: ReplayLibrary = main.progress.replays
	t0 = Time.get_ticks_usec()
	main.goto("Progress")
	main.progress.show_replays()
	await get_tree().process_frame
	print("  Progress -> Replays opened with %d replays in %.0f ms (list %.0f ms)" % [n,
		(Time.get_ticks_usec() - t0) / 1000.0, lib.last_load_usec / 1000.0])
	lib.query = "copy 1998"
	t0 = Time.get_ticks_usec()
	var hits: Array = lib.filtered()
	print("  search over %d: %d hit(s) in %.1f ms" % [n, hits.size(), (Time.get_ticks_usec() - t0) / 1000.0])
	main.goto("Play")
	_clear(dir)
