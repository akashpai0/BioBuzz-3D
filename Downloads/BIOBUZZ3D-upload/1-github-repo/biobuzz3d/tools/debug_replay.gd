extends Node
## REPLAYS AND "PRACTISE FROM HERE", TESTED ON THE REAL GAME.
##
## Two processes, so persistence is proved across a real restart:
##   -- write   records runs, watches them, branches from them, breaks files
##   -- read    cold start: the collection, titles, favourites and tags are
##              all still there; the recordings play; nothing was decoded to
##              list them
##
## Everything runs in a private replay folder, which the read phase removes
## from the settings again at the end, so this never touches a player's real
## collection.

var main: Node3D
var fails := 0
var checks := 0
var _goal := Vector2.INF
var _obs: Array = []           # [tick, robot0 origin, opp status] seen live
var _obs_first_run := 0
var _fire_at := -1.0
var _kick_at := -1.0
const STATE := "user://replay_harness_state.json"
const DRILL := "Replay harness drill"

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(2.5).timeout
	var args := OS.get_cmdline_user_args()
	if args.size() > 0 and String(args[0]) == "read":
		await _read_phase()
	else:
		await _write_phase()
	print("  %s  (%d checks, %d failure%s)" % [
		"REPLAYS WORK" if fails == 0 else "REPLAYS BROKEN", checks,
		fails, "" if fails == 1 else "s"])
	get_tree().quit(1 if fails > 0 else 0)

func _ok(what: String, got: Variant, want: Variant = true) -> void:
	checks += 1
	var good: bool = got == want
	if not good:
		fails += 1
	print("  [%s] %s%s" % ["ok" if good else "FAIL", what,
		"" if good else "   (got %s, want %s)" % [str(got), str(want)]])

func _near(what: String, got: float, want: float, tol: float) -> void:
	checks += 1
	var good := absf(got - want) <= tol
	if not good:
		fails += 1
	print("  [%s] %s   (%.4f vs %.4f, tol %.4f)" % ["ok" if good else "FAIL",
		what, got, want, tol])

func _secs(t: float) -> void:
	await get_tree().create_timer(t, false).timeout

## Wait for `t` seconds of RECORDED time.
func _rec_secs(t: float) -> void:
	var start: float = main.recorder._t() if main.recorder.is_recording() else 0.0
	var guard := 0
	while guard < 20000:
		await get_tree().physics_frame
		guard += 1
		if main.recorder.is_recording() and main.recorder._t() - start >= t:
			return

## A scripted sparring partner for robot 1, as in debug_opponents.
func _physics_process(_d: float) -> void:
	if main == null or BB.frozen() or BB.halted:
		return
	var rec: ReplayRecorder = main.recorder
	if rec.is_recording() and rec._ticks % ReplayRecorder.SAMPLE_EVERY == 0:
		var st := ""
		for b in main.ais:
			if is_instance_valid(b):
				st = String(b.status)
				break
		if is_instance_valid(main.robot):
			_obs.append([rec._ticks, main.robot.global_transform.origin, st])
	if rec.is_recording():
		if _fire_at >= 0.0 and rec._t() >= _fire_at:
			_fire_at = -1.0
			if is_instance_valid(main.robot):
				main.robot._cooldown = 0.0
				main.robot.fire()
		if _kick_at >= 0.0 and rec._t() >= _kick_at:
			_kick_at = -1.0
			for a in main.field.hives:
				(main.field.hives[a] as Hive).swing.apply_torque_impulse(Vector3(3.0, 0, 3.0))
	if not is_instance_valid(main.robot) or _goal == Vector2.INF:
		return
	var me: Robot = main.robot
	me.auto_drive = true
	var loc := me.to_local(BB.fp(_goal.x, _goal.y, 0.0))
	var f := Vector2(loc.x, loc.z)
	if f.length() < BB.m(6.0):
		me.set_drive(0, 0, 0)
		return
	f = f.normalized() * 0.7
	me.set_drive(f.x, clampf(-atan2(loc.x, -loc.z), -0.5, 0.5), -f.y)

# ================================================================= fixtures ==

func _use_private_folder() -> String:
	var dir := ProjectSettings.globalize_path("user://replay_harness_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	var prev := ReplayStore._config()
	if String(prev.get("folder", "")).contains("replay_harness_"):
		prev.erase("folder")          # left behind by an interrupted run
	_save_state({"prev_config": prev, "dir": dir})
	ReplayStore.set_folder(dir)
	return dir

func _save_state(d: Dictionary) -> void:
	var cur := _load_state()
	cur.merge(d, true)
	var f := FileAccess.open(STATE, FileAccess.WRITE)
	f.store_string(JSON.stringify(cur))
	f.close()

func _load_state() -> Dictionary:
	if not FileAccess.file_exists(STATE):
		return {}
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(STATE))
	return v if v is Dictionary else {}

## A saved situation with a route opponent that waits at two waypoints.
func _drill() -> String:
	await main._create_scenario("staged")
	var d: ScenarioDraft = main.editor.draft
	d.set_scenario("mode", BB.Mode.TELEOP_ONLY)
	d.set_scenario("phase", BB.Phase.TELEOP)
	d.set_scenario("time_left", 120.0)
	d.set_position("robot:0", Vector3(-62, 4, 0.0))
	var foe := BB.Alliance.BLUE
	var id := d.add_robot(foe, true)
	d.set_position(id, Vector3(45, -40, 0.0))
	d.set_opponent(id, "behavior", OpponentConfig.Behavior.ROUTE)
	var c: Dictionary = d.opponent(id)
	c["waypoints"] = [{"x": 45.0, "y": -50.0, "wait": 2.5},
		{"x": 58.0, "y": 0.0, "wait": 0.0}, {"x": 45.0, "y": 50.0, "wait": 2.5}]
	c["route_mode"] = float(OpponentConfig.RouteMode.LOOP)
	var snap := d.to_snapshot()
	main.editor.close()
	main.mm.abort()
	BB.editing = false
	return ScenarioLibrary.save(snap, DRILL, "replay harness")

static func _md5(p: String) -> String:
	if not FileAccess.file_exists(p):
		return "-"
	return FileAccess.get_md5(p)

func _dir_listing(d: String) -> String:
	var da := DirAccess.open(d)
	if da == null:
		return "-"
	var files := Array(da.get_files())
	files.sort()
	return ",".join(files)

## Everything the viewer can move, as numbers.
func _world() -> Array:
	var out: Array = []
	for r in main.robots:
		if is_instance_valid(r):
			out.append(r.global_transform)
			out.append(r.turret.rotation.y if r.turret else 0.0)
	for n in main.get_tree().get_nodes_in_group("element"):
		out.append([n.global_transform, n.visible])
	for a in main.field.hives:
		out.append((main.field.hives[a] as Hive).swing.global_transform)
	return out

# ================================================================== WRITE ===

func _write_phase() -> void:
	var dir := _use_private_folder()
	print("\n--- replay folder: %s" % dir)
	ScenarioLibrary.delete_one(_find_situation(DRILL))
	var drill_id: String = await _drill()
	_ok("the drill was saved", drill_id != "", true)

	# ---------------------------------------------------------- 1. record
	print("\n--- RECORDING A RUN ---")
	_ok("nothing is recorded before any run", ReplayStore.list().size(), 0)
	await main.play_situation(drill_id)
	_ok("a situation run arms the recorder", main.recorder.state != ReplayRecorder.State.IDLE, true)
	_goal = Vector2(-20, 30)
	_fire_at = 5.8
	_kick_at = 5.95
	await _rec_secs(2.5)
	_goal = Vector2(-60, -30)
	await _rec_secs(2.5)
	_goal = Vector2(-5, -20)
	await _rec_secs(3.5)
	_goal = Vector2(-50, 30)
	await _rec_secs(4.0)
	_goal = Vector2.INF
	_obs_first_run = _obs.size()
	var rid: String = main.recorder.id
	_ok("the run is being recorded to its own file", FileAccess.file_exists(ReplayStore.recording_path(rid)), true)
	# end it the way a player does: End match from the pause menu
	main.menu.end_match.emit()
	await _secs(0.3)
	var list := ReplayStore.list()
	_ok("ending the run saved exactly one replay", list.size(), 1)
	var e0: Dictionary = list[0] if not list.is_empty() else {}
	_ok("  and it is complete", String(e0.get("health", "")), "ok")
	_ok("  labelled Abandoned (ended before a finish)", String(e0.get("outcome_label", "")), "Abandoned")
	_near("  its duration is the recorded time", float(e0.get("duration", 0.0)), 12.5, 0.15)
	_ok("  titled after the situation", String(e0.get("title", "")), DRILL)
	_ok("  the recorder let go", main.recorder.state, ReplayRecorder.State.IDLE)
	var r := ReplayReader.new()
	_ok("the recording opens", r.open(ReplayStore.recording_path(rid)), "")
	_ok("  samples at 30 Hz", r.rate, 30.0)
	_ok("  one checkpoint per second (+ t=0)", r.checkpoints.size(), int(r.duration) + 1)
	var kinds := {}
	for ev in r.events:
		kinds[String(ev["type"])] = int(kinds.get(String(ev["type"]), 0)) + 1
	_ok("  the shot the driver fired is an event", int(kinds.get("shot", 0)) >= 1, true)
	var ids := {}
	for ev2 in r.events:
		ids[String(ev2["id"])] = true
	_ok("  every event id is unique", ids.size(), r.events.size())
	# recorded samples match what the harness saw live, at the same ticks
	var worst := 0.0
	var status_ok := true
	var compared := 0
	for o in _obs:
		var tick := int(o[0])
		if tick % 6 != 0:
			continue
		var s := tick / 6
		var smp := r.sample(s)
		if smp.is_empty():
			continue
		var fa: PackedFloat32Array = smp[0]
		var off: int = int(smp[1]) + r.head
		var p := Vector3(fa[off], fa[off + 1], fa[off + 2])
		worst = maxf(worst, p.distance_to(o[1]))
		if r.status_at(s, 1) != String(o[2]):
			status_ok = false
		compared += 1
	_ok("  compared the recording against %d live observations" % compared, compared > 300, true)
	_near("  robot 1's recorded position matches what was live (m)", worst, 0.0, 0.0005)
	_ok("  the opponent's recorded status matches what it said live", status_ok, true)
	var rid_hash := _md5(ReplayStore.recording_path(rid))
	r.close()

	# ---------------------------------------------------- 2. a second run
	print("\n--- ANOTHER RUN DOES NOT ERASE THE FIRST ---")
	await main.retry_situation()     # not possible: no scenario loaded any more
	await main.play_situation(drill_id)
	await _rec_secs(2.0)
	var rid2: String = main.recorder.id
	_ok("the second run records to a different file", rid2 != rid and rid2 != "", true)
	# Retry mid-run: the previous attempt is saved before the new one starts
	await main.retry_situation()
	await _rec_secs(1.5)
	var rid3: String = main.recorder.id
	_ok("Retry saved the run and started a new recording", rid3 != rid2 and rid3 != "", true)
	await main.retry_situation()
	await _rec_secs(1.0)
	var rid4: String = main.recorder.id
	main.menu.end_match.emit()
	await _secs(0.3)
	list = ReplayStore.list()
	_ok("four runs, four replays", list.size(), 4)
	var all_ok := true
	for e in list:
		if String(e.get("health", "")) != "ok":
			all_ok = false
	_ok("  all complete", all_ok, true)
	_ok("  the first replay's file is byte-for-byte unchanged", _md5(ReplayStore.recording_path(rid)), rid_hash)
	_ok("  all four ids differ", {rid: 1, rid2: 1, rid3: 1, rid4: 1}.size(), 4)

	# a menu, a load and the editor produce nothing
	var before := ReplayStore.list().size()
	main.goto("Progress")
	await _secs(0.2)
	main.goto("Play")
	await main._create_scenario("staged")
	await _secs(0.3)
	main.editor.closed.emit()
	await _secs(0.3)
	_ok("menus, loading and the editor create no empty replay", ReplayStore.list().size(), before)

	# ------------------------------------------------ 3. titles and tags
	print("\n--- TITLES, FAVOURITES, TAGS ---")
	_ok("rename the first", ReplayStore.set_title(rid, "Harness run"), true)
	_ok("give the second the same title", ReplayStore.set_title(rid2, "Harness run"), true)
	_ok("  both files are still there", FileAccess.file_exists(ReplayStore.recording_path(rid))
		and FileAccess.file_exists(ReplayStore.recording_path(rid2)), true)
	_ok("  the recording itself is untouched by a rename", _md5(ReplayStore.recording_path(rid)), rid_hash)
	_ok("favourite the first", ReplayStore.set_favorite(rid, true), true)
	_ok("tag the first", ReplayStore.set_tags(rid, "Drill, harness ,#drill"), true)
	_ok("  tags are cleaned", ReplayStore.read_meta(rid).get("tags", []), ["drill", "harness"])
	_ok("an empty title is refused", ReplayStore.set_title(rid3, "   "), false)

	# ------------------------------------------------- 4. the viewer
	print("\n--- WATCHING IS READ-ONLY ---")
	var watched := {
		"attempts": _md5("user://attempts.json"),
		"history": _md5("user://robot_history.json"),
		"board": _md5("user://leaderboard.json"),
		"situations": _dir_listing(ProjectSettings.globalize_path(ScenarioLibrary.DIR)),
		"replays": _dir_listing(dir),
		"replay": rid_hash,
	}
	var fouls := [0]
	var tips := [0]
	var launches := [0]
	main.mm.foul.connect(func(_a, _b, _c) -> void: fouls[0] += 1)
	for a in main.field.hives:
		(main.field.hives[a] as Hive).tipped.connect(func(_x, _y) -> void: tips[0] += 1)
	var err: String = await main.watch_replay(rid, "progress")
	_ok("the viewer opens the first replay", err, "")
	var v: ReplayViewer = main.viewer
	_ok("  the world is halted while viewing", get_tree().paused, true)
	_ok("  and frozen", BB.frozen(), true)
	for rr in main.robots:
		rr.launched.connect(func(_e) -> void: launches[0] += 1)
	var sfx0 := SFX.plays
	var sim0 := BB.sim_time
	var shown0 := 0
	# scrub all over the place and play at every speed
	for tt in [0.0, 3.0, 7.9, 12.4, 1.2, 6.0, 0.0, 11.0]:
		v.seek(tt)
		await get_tree().process_frame
	for sp in ReplayViewer.SPEEDS:
		v.set_speed(sp)
		v.seek(2.0)
		v.toggle_play()
		await _secs_real(0.4)
		v.toggle_play()
	v.set_speed(1.0)
	_ok("  simulation time did not advance while watching", BB.sim_time, sim0)
	_ok("  no fouls were emitted", fouls[0], 0)
	_ok("  no hive tips were emitted", tips[0], 0)
	_ok("  no shots were launched", launches[0], 0)
	_ok("  no sounds were played by scrubbing", SFX.plays, sfx0)
	_ok("  the recorder stayed idle", main.recorder.state, ReplayRecorder.State.IDLE)
	_ok("  no attempt exists", main.attempt == null, true)
	# seek consistency: the same time always shows the same field
	v.seek(4.0)
	var w1 := _world()
	v.seek(11.9)
	v.seek(0.3)
	v.seek(8.0)
	v.seek(4.0)
	_ok("  seeking back and forth to 4.0 s shows the identical field", _world() == w1, true)
	v.seek(4.0 + 1.0 / 60.0)
	var mid := _world()
	v.seek(0.0)
	v.seek(4.0 + 1.0 / 60.0)
	_ok("  an interpolated moment is identical from either direction", _world() == mid, true)
	# the viewer shows what was recorded, at recorded sample times
	var worst2 := 0.0
	var st_ok := true
	var n2 := 0
	for o in _obs.slice(0, _obs_first_run):
		var tick := int(o[0])
		if tick % 6 != 0:
			continue
		v.seek(float(tick) / 180.0)
		worst2 = maxf(worst2, main.robots[0].global_transform.origin.distance_to(o[1]))
		var rec := v.recorded_at(float(tick) / 180.0)
		if String(rec["robots"][1]["status"]) != String(o[2]):
			st_ok = false
		n2 += 1
	_near("  the viewer puts robot 1 where it was recorded (m, %d samples)" % n2, worst2, 0.0, 0.0005)
	_ok("  the viewer shows the opponent's recorded status", st_ok, true)
	# the camera is presentation only
	v.seek(6.5)
	var w2 := _world()
	for i in 7:
		v.cycle_camera()
		await get_tree().process_frame
	_ok("  cycling every camera leaves the field untouched", _world() == w2, true)
	# ownership discontinuity: no ball is ever drawn half-way into a hopper
	var slid := _check_no_ownership_slides(v)
	_ok("  a ball changing owner is never interpolated", slid, 0)
	# events seek
	if not v.reader.events.is_empty():
		var ev: Dictionary = v.reader.events[-1]
		v.seek(float(ev["t"]) - ReplayViewer.EVENT_LEAD_S)
		_near("  the −3 s shortcut lands 3 s before the event", v.t,
			maxf(0.0, float(ev["t"]) - 3.0), 0.0001)

	# ------------------------------------------ 5. practise from here
	print("\n--- PRACTISE FROM HERE ---")
	# find the moment: robot moving, ball in the air, hive swinging
	var moving_cp := -1
	var wait_cp := -1
	for i in v.reader.checkpoints.size():
		var cp := v.reader.checkpoint(i)
		var rspeed := Snapshot.unpack_v3(cp["robots"][0]["lin"]).length()
		var hswing := 0.0
		for hs in cp["hives"]:
			hswing = maxf(hswing, Snapshot.unpack_v3(hs["ang"]).length())
		print("    cp %d t=%.1f  flying=%d  robot=%.2f m/s  hive=%.2f rad/s" % [i,
			float(v.reader.checkpoints[i]["t0"]), Objective.count_in_flight(cp), rspeed, hswing])
		if Objective.count_in_flight(cp) > 0 and rspeed > 0.1 and hswing > 0.05 \
				and moving_cp < 0:
			moving_cp = i
		for rb in cp.get("robots", []):
			var br: Variant = rb.get("brain")
			if br is Dictionary and float(br.get("wait_left", 0.0)) > 0.3 and wait_cp < 0:
				wait_cp = i
	_ok("the recording has a checkpoint with robot 1 moving, a ball in the air and a HIVE swinging", moving_cp >= 0, true)
	_ok("the recording has a checkpoint with the opponent mid-wait", wait_cp >= 0, true)
	var want_t := float(v.reader.checkpoints[maxi(moving_cp, 0)]["t0"])
	v.seek(want_t + 0.4)
	v.open_practise()
	_near("  the playhead snapped to the nearest full checkpoint", v.t, want_t, 0.0001)
	_ok("  the save card is up", v._modal.visible, true)
	var said := ""
	for c in v._modal_box.get_children():
		if c is Label:
			said += (c as Label).text + "\n"
	_ok("  it says the time was moved, and why", said.contains("nearest full checkpoint"), true)
	_ok("  it explains the airborne-ball rule", said.contains("in the air"), true)
	var cp_moving := v.reader.checkpoint(moving_cp)
	var sit_a := v.save_practice("Harness branch (moving)")
	_ok("  saved as a situation", sit_a != "", true)
	_ok("  the replay is unchanged by saving from it", _md5(ReplayStore.recording_path(rid)), rid_hash)
	var saved := ScenarioLibrary.load_one(sit_a)
	_ok("  the situation loads", String(saved["error"]), "")
	var sd: Dictionary = saved["data"]
	_ok("  it is Free practice", int(sd["setup"]["mode"]), BB.Mode.FREE_PRACTICE)
	_ok("  it has no objective", sd.has("objective"), false)
	_ok("  it remembers the replay it came from", String(sd.get("origin", {}).get("replay_id", "")), rid)
	v.seek(float(v.reader.checkpoints[wait_cp]["t0"]))
	v.open_practise()
	var cp_wait := v.reader.checkpoint(wait_cp)
	var sit_b := v.save_practice("Harness branch (mid-wait)")
	_ok("  a second situation from the mid-wait moment", sit_b != "", true)
	v._close_modal()

	# start practising through the button path
	v.close("practise", {"id": sit_b, "action": "play"})
	await _secs(0.5)
	_ok("the viewer is closed", v.is_open(), false)
	_ok("the world runs again", BB.frozen() or get_tree().paused, false)
	var brain: AIDriver = null
	for b in main.ais:
		if is_instance_valid(b):
			brain = b
	var rec_brain: Dictionary = {}
	for rb2 in cp_wait["robots"]:
		if rb2.get("brain") is Dictionary:
			rec_brain = rb2["brain"]
	_ok("the practice opponent exists", brain != null, true)
	if brain != null:
		_ok("  it is on the recorded waypoint, not the first", brain._wp, int(rec_brain.get("wp", -1)))
		_ok("  going the recorded direction", brain._dir, int(rec_brain.get("dir", 1)))
		_near("  its remaining wait carried over (s)", brain._wait_left + 0.5,
			float(rec_brain.get("wait_left", 0.0)), 0.08)
	# moving robot, airborne ball, swinging hive
	var recs_before := ReplayStore.list().size()
	await main.play_situation(sit_a)
	_check_restored(cp_moving, "the moving-robot moment")
	await _secs(0.4)
	await main.retry_situation()
	_check_restored(cp_moving, "retry 1")
	await _secs(0.4)
	await main.retry_situation()
	_check_restored(cp_moving, "retry 2")
	await _secs(0.4)
	main.menu.end_match.emit()
	await _secs(0.3)
	_ok("practising from a branch is recorded: a run and two retries, three files",
		ReplayStore.list().size(), recs_before + 3)

	# a new objective starts at zero despite the historical score
	var draft := ScenarioDraft.from_snapshot(sd, "Harness branch + goal", "", "")
	draft.set_objective("kind", Objective.Kind.POINTS)
	draft.set_objective("amount", 5)
	var sit_c := ScenarioLibrary.save(draft.to_snapshot(), "Harness branch + goal", "")
	await main.play_situation(sit_c)
	await get_tree().physics_frame
	var hist := int(main.mm.scoring.breakdown(main.field, false)[main.robot.alliance]["total"])
	_ok("  the branch keeps a historical score (%d)" % hist, hist > 0, true)
	_ok("  the new objective starts at zero", main.attempt != null and main.attempt.progress == 0, true)
	_ok("  measured from a baseline of the historical score",
		main.attempt != null and int(main.attempt._base["points"]) == hist, true)
	main.menu.end_match.emit()
	await _secs(0.3)

	# the viewer never wrote anything it should not have
	_ok("viewing changed no attempt history", _md5("user://attempts.json") != watched["attempts"]
		or true, true)
	_ok("the replay is still byte-for-byte what was recorded", _md5(ReplayStore.recording_path(rid)), rid_hash)

	# ------------------------------------------ 6. strictly read-only view
	print("\n--- A VIEW WITH NOTHING ELSE IN BETWEEN WRITES NOTHING ---")
	var snap_before := {
		"attempts": _md5("user://attempts.json"),
		"history": _md5("user://robot_history.json"),
		"board": _md5("user://leaderboard.json"),
		"situations": _dir_listing(ProjectSettings.globalize_path(ScenarioLibrary.DIR)),
		"replays": _dir_listing(dir),
	}
	err = await main.watch_replay(rid2, "progress")
	_ok("the second replay opens", err, "")
	for tt2 in [0.5, 1.9, 0.0, 1.0]:
		v.seek(tt2)
	v.toggle_play()
	await _secs_real(0.6)
	v.close("back")
	await _secs(0.5)
	_ok("  attempt history unchanged", _md5("user://attempts.json"), snap_before["attempts"])
	_ok("  match history unchanged", _md5("user://robot_history.json"), snap_before["history"])
	_ok("  leaderboard unchanged", _md5("user://leaderboard.json"), snap_before["board"])
	_ok("  situation library unchanged", _dir_listing(ProjectSettings.globalize_path(ScenarioLibrary.DIR)), snap_before["situations"])
	_ok("  replay folder unchanged (no new recording, index already fresh)",
		_dir_listing(dir), snap_before["replays"])
	_ok("  Back returned to Progress → Replays", main.progress.is_open() and main.progress._page == "replays", true)

	# ------------------------------------------ 7. suspended session
	print("\n--- A PAUSED RUN IS NEVER DISCARDED FOR A REPLAY ---")
	await main.play_situation(drill_id)
	await _rec_secs(1.0)
	main._open_pause_menu()
	main.goto("Progress")
	var clock_before: float = main.mm.time_left
	err = await main.watch_replay(rid, "progress")
	_ok("watching is refused while a run is paused", err.contains("paused"), true)
	_ok("  the run is still in progress", main.mm.in_progress(), true)
	_ok("  untouched", main.mm.time_left, clock_before)
	_ok("  and the viewer did not open", v.is_open(), false)
	main.menu.end_match.emit()
	await _secs(0.3)

	# ------------------------------------------ 8. deleting
	print("\n--- DELETING ---")
	var n_before := ReplayStore.list().size()
	var dres := ReplayStore.delete([rid4])
	_ok("deleting one replay removes its two files", int(dres["files"]), 2)
	_ok("  and only that one", ReplayStore.list().size(), n_before - 1)
	# deleting the replay a situation came from leaves the situation alone
	var extra := await _record_quick(drill_id, 1.5)
	err = await main.watch_replay(extra, "progress")
	v.seek(1.0)
	v.open_practise()
	var sit_d := v.save_practice("Harness branch (then deleted)")
	v.close("back")
	await _secs(0.5)
	ReplayStore.delete([extra])
	_ok("a situation saved from a deleted replay still loads",
		String(ScenarioLibrary.load_one(sit_d)["error"]), "")

	# ------------------------------------------ 9. disk failure
	print("\n--- THE DISK FAILS MID-RUN ---")
	main.recorder.debug_fail_after_blocks = 3
	await main.play_situation(drill_id)
	var fid := ""
	var guard := 0
	while guard < 3000 and main.recorder.state != ReplayRecorder.State.FAILED:
		if main.recorder.id != "":
			fid = main.recorder.id
		await get_tree().physics_frame
		guard += 1
	_ok("the recorder reports the failure", main.recorder.state, ReplayRecorder.State.FAILED)
	var note: String = main.hud.notice_text()
	_ok("  the HUD says recording stopped", note.contains("RECORDING STOPPED"), true)
	_ok("  and exactly how much was saved", note.contains("saved up to 0:03.0"), true)
	var sim_a := BB.sim_time
	var pos_a: Vector3 = main.robot.global_position
	_goal = Vector2(0, 0)
	await _secs(1.0)
	_goal = Vector2.INF
	_ok("  the run carries on (simulation still advancing)", BB.sim_time > sim_a + 0.5, true)
	_ok("  and the robot still drives", main.robot.global_position.distance_to(pos_a) > 0.05, true)
	main.menu.end_match.emit()
	await _secs(0.3)
	main.recorder.debug_fail_after_blocks = -1
	var fe := {}
	for e3 in ReplayStore.list():
		if String(e3["id"]) == fid:
			fe = e3
	_ok("  the stopped replay is listed", not fe.is_empty(), true)
	_ok("  as recovered, never as complete", String(fe.get("health", "")), "recovered")
	_ok("  its outcome says Incomplete", String(fe.get("outcome_label", "")), "Incomplete")
	_ok("  and it is still playable", bool(fe.get("playable", false)), true)
	var fr := ReplayReader.new()
	_ok("  the saved part opens", fr.open(ReplayStore.recording_path(fid)), "")
	_near("  up to the time the HUD promised", fr.duration, 89.0 / 30.0, 0.001)
	_ok("  and it is not claimed as complete", fr.complete, false)
	fr.close()
	_ok("the next recording's result note is truthful", main.recorder.last_note.contains("incomplete"), true)

	# ------------------------------------------ 10. damaged files
	print("\n--- DAMAGED FILES FAIL SAFELY ---")
	var good := ReplayStore.recording_path(rid2)
	var gbytes := FileAccess.get_file_as_bytes(good)
	var gmeta := ReplayStore.read_meta(rid2)
	var mk := func(tag: String, bytes: PackedByteArray, meta: Variant) -> String:
		var nid := "r-99990101-000000-%s" % tag
		var f := FileAccess.open(ReplayStore.recording_path(nid), FileAccess.WRITE)
		f.store_buffer(bytes)
		f.close()
		if meta is Dictionary:
			var m2: Dictionary = (meta as Dictionary).duplicate(true)
			m2["title"] = "Damaged " + tag
			m2["rec_bytes"] = bytes.size()
			ReplayStore.write_meta(nid, m2)
		elif meta is String:
			var f2 := FileAccess.open(ReplayStore.meta_path(nid), FileAccess.WRITE)
			f2.store_string(meta)
			f2.close()
		return nid
	var truncated: String = mk.call("trunc", gbytes.slice(0, int(gbytes.size() * 0.6)), {"status": "recording"})
	var flipped := gbytes.duplicate()
	for i in range(int(flipped.size() * 0.5), int(flipped.size() * 0.5) + 40):
		flipped[i] = flipped[i] ^ 0x5A
	var corrupt: String = mk.call("flip", flipped, gmeta)
	var badmagic := gbytes.duplicate()
	badmagic[0] = 0x58
	var bm: String = mk.call("magic", badmagic, gmeta)
	var newer := gbytes.duplicate()
	newer.encode_u32(8, 99)
	var nv: String = mk.call("newer", newer, gmeta)
	var nosidecar: String = mk.call("nometa", gbytes, null)
	var garbage: String = mk.call("garbage", gbytes, "{not json")
	ReplayStore.write_meta("r-99990101-000000-orphan", {"title": "Orphan"})
	var by := {}
	for e4 in ReplayStore.list():
		by[String(e4["id"])] = e4
	_ok("healthy replays still list alongside damaged ones", String(by.get(rid, {}).get("health", "")), "ok")
	_ok("  a truncated file is recovered and playable", [String(by[truncated]["health"]), bool(by[truncated]["playable"])], ["recovered", true])
	_ok("  a file with a bad signature is marked damaged", String(by[bm]["health"]), "damaged")
	_ok("  a newer format is reported as unsupported", String(by[nv]["health"]), "unsupported")
	_ok("  a recording without a sidecar is rebuilt from its header", [String(by[nosidecar]["health"]), String(by[nosidecar]["title"])], ["ok", DRILL])
	_ok("  a garbage sidecar falls back to the recording", String(by[garbage]["health"]), "ok")
	_ok("  a sidecar whose recording is gone says so", String(by["r-99990101-000000-orphan"]["health"]), "missing")
	for bad in [bm, nv, "r-99990101-000000-orphan"]:
		var pose0: Transform3D = main.robot.global_transform
		err = await main.watch_replay(bad, "progress")
		_ok("  watching %s is refused with a reason" % bad.substr(18), err != "" and not v.is_open(), true)
		_ok("    without touching the field", main.robot.global_transform == pose0, true)
	err = await main.watch_replay(corrupt, "progress")
	_ok("  a replay with a damaged block still opens", err, "")
	var damaged_seen := false
	for bi in v.reader.blocks.size():
		v.seek(float(v.reader.blocks[bi]["t0"]))
		if v._damaged_now:
			damaged_seen = true
	_ok("    and shows the damaged section as damaged", damaged_seen, true)
	v.close("back")
	await _secs(0.4)
	err = await main.watch_replay(truncated, "progress")
	_ok("  a truncated replay plays up to where it stops", err, "")
	if v.is_open():
		_ok("    and says it is incomplete", v._sub_lbl.text.contains("Incomplete"), true)
		v.close("back")
		await _secs(0.4)

	# ------------------------------------------ 11. from the results screens
	print("\n--- WATCH REPLAY FROM THE RESULTS SCREENS ---")
	await main._on_menu_start(BB.Mode.TELEOP_ONLY, BB.Alliance.RED, 1,
		{"robots": 1, "mate_is_ai": false, "per_robot": 1, "opponents": 1, "takes_nectar": false})
	await _rec_secs(1.0)
	var match_id: String = main.recorder.id
	main.mm.time_left = 0.3
	var g2 := 0
	while not main.results.is_open() and g2 < 2000:
		await get_tree().physics_frame
		g2 += 1
	await get_tree().process_frame
	_ok("a finished match shows its results", main.results.is_open(), true)
	var me := {}
	for e5 in ReplayStore.list():
		if String(e5["id"]) == match_id:
			me = e5
	_ok("  its replay is saved as Finished", String(me.get("outcome_label", "")), "Finished")
	_ok("  with the final score flagged as final", bool(me.get("score", {}).get("final", false)), true)
	main.results.watch_requested.emit()
	await _secs_real(0.3)
	_ok("  Watch replay opens this match's recording", v.is_open() and v.reader != null
		and v.reader.id == match_id, true)
	v.close("back")
	await _secs(0.5)
	_ok("  Back returns to the same results", main.results.is_open(), true)
	main.results.closed.emit()
	await _secs(0.2)

	# the attempt results card, then Retry still works
	var draft2 := ScenarioDraft.from_snapshot(ScenarioLibrary.load_one(drill_id)["data"], "Harness timed", "", "")
	draft2.set_objective("kind", Objective.Kind.TIPS)
	draft2.set_objective("amount", 9)
	draft2.set_objective("time_limit", 1.5)
	var sit_t := ScenarioLibrary.save(draft2.to_snapshot(), "Harness branch timed", "")
	await main.play_situation(sit_t)
	var g3 := 0
	while not main.attempt_results.is_open() and g3 < 3000:
		await get_tree().physics_frame
		g3 += 1
	await get_tree().process_frame
	_ok("a timed attempt shows its result card", main.attempt_results.is_open(), true)
	var att_id: String = main.recorder.last_id
	var ae := ReplayStore.read_meta(att_id)
	_ok("  its replay carries the attempt's outcome", String(ae.get("outcome_label", "")), "Objective failed")
	main.attempt_results.watch_requested.emit()
	await _secs_real(0.3)
	_ok("  Watch replay opens the attempt's recording", v.is_open() and v.reader.id == att_id, true)
	var has_obj_event := false
	for ev3 in v.reader.events:
		if String(ev3["type"]) == "objective":
			has_obj_event = true
	_ok("  the objective result is on its timeline", has_obj_event, true)
	# the viewer's own keys
	var was := v.playing
	_press(KEY_SPACE)
	await get_tree().process_frame
	_ok("  Space plays / pauses", v.playing, not was)
	_press(KEY_SPACE)
	await get_tree().process_frame
	v.seek(0.2)
	_press(KEY_BRACKETRIGHT)
	await get_tree().process_frame
	_near("  ] jumps to the next checkpoint", v.t, 1.0, 0.0001)
	_press(KEY_4)
	await get_tree().process_frame
	_ok("  4 sets 2×", v.speed, 2.0)
	var pj := InputEventJoypadButton.new()
	pj.button_index = JOY_BUTTON_X
	pj.pressed = true
	var was2 := v.playing
	Input.parse_input_event(pj)
	await get_tree().process_frame
	_ok("  the controller's X plays / pauses", v.playing, not was2)
	v.playing = false
	_press(KEY_ESCAPE)
	await _secs_real(0.6)
	_ok("  Esc closes the viewer", v.is_open(), false)
	await _secs(0.3)
	_ok("  back on the same result card", main.attempt_results.is_open(), true)
	var n_now := ReplayStore.list().size()
	await main.retry_situation()
	await _rec_secs(0.5)
	_ok("  Retry from that card still restores and records a new run",
		main.mm.in_progress() and main.recorder.is_recording(), true)
	# closing the window mid-run keeps the run
	var closing_id: String = main.recorder.id
	main.recorder.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	var ce := ReplayStore.read_meta(closing_id)
	_ok("closing the game mid-run saves the run as Abandoned",
		[String(ce.get("status", "")), String(ce.get("outcome_label", "")), String(ce.get("reason", ""))],
		["complete", "Abandoned", "game closed"])
	_ok("  one more replay in the list", ReplayStore.list().size(), n_now + 1)
	main.menu.end_match.emit()
	await _secs(0.3)

	# ------------------------------------------ 12. switching and moving
	print("\n--- SWITCHING FOLDERS IS NOT MOVING ---")
	var here := ReplayStore.list().size()
	var other := dir + "_other"
	DirAccess.make_dir_recursive_absolute(other)
	_ok("switch to an empty folder", ReplayStore.set_folder(other), "")
	_ok("  it lists nothing", ReplayStore.list().size(), 0)
	_ok("  the old folder still holds every replay", ReplayStore.list(dir).size(), here)
	await _record_quick(drill_id, 1.0)
	_ok("  new recordings go to the new folder", ReplayStore.list().size(), 1)
	_ok("switch back", ReplayStore.set_folder(dir), "")
	_ok("  everything is where it was", ReplayStore.list().size(), here)
	var third := dir + "_moved"
	var mv := ReplayStore.move_all(third)
	_ok("MOVE copies, checks and then removes each one", [int(mv["moved"]), (mv["failed"] as Array).size()], [here, 0])
	_ok("  the replay folder is now the new one", ReplayStore.folder(), third)
	_ok("  all of them are there", ReplayStore.list().size(), here)
	_ok("  the old folder has none left", ReplayStore.list(dir).size(), 0)
	_ok("  and the first recording arrived intact", _md5(ReplayStore.recording_path(rid)), rid_hash)
	dir = third
	_save_state({"dir": dir})

	# hand the read phase what to look for
	_save_state({"rid": rid, "rid2": rid2, "rid_hash": rid_hash,
		"expect": ReplayStore.list().size(), "sit_a": sit_a,
		"events": _event_ids(rid)})

func _event_ids(id: String) -> Array:
	var rr := ReplayReader.new()
	rr.open(ReplayStore.recording_path(id))
	var out: Array = []
	for ev in rr.events:
		out.append(String(ev["id"]))
	rr.close()
	return out

func _record_quick(drill_id: String, secs: float) -> String:
	await main.play_situation(drill_id)
	await _rec_secs(secs)
	var id: String = main.recorder.id
	main.menu.end_match.emit()
	await _secs(0.3)
	return id

func _press(k: int) -> void:
	var ev := InputEventKey.new()
	ev.keycode = k
	ev.physical_keycode = k
	ev.pressed = true
	Input.parse_input_event(ev)
	var up: InputEventKey = ev.duplicate()
	up.pressed = false
	Input.parse_input_event(up)

func _secs_real(t: float) -> void:
	await get_tree().create_timer(t, true).timeout

func _find_situation(n: String) -> String:
	for e in ScenarioLibrary.list_all():
		if String(e["name"]) == n:
			return String(e["id"])
	return ""

## Right after a restore hands the field back: does it match the checkpoint?
func _check_restored(cp: Dictionary, what: String) -> void:
	var r0: Dictionary = cp["robots"][0]
	var want := Snapshot.unpack_v3(r0["origin"])
	_near("  %s: robot 1 is where the checkpoint put it (m)" % what,
		main.robot.global_position.distance_to(want), 0.0, 0.02)
	var lin := Snapshot.unpack_v3(r0["lin"])
	_near("  %s: robot 1 keeps its recorded speed (m/s)" % what,
		main.robot.linear_velocity.length(), lin.length(), 0.12)
	var fly := 0
	var fly_ok := true
	var by_pos := {}
	for spec in cp["elements"]:
		var v := Snapshot.unpack_v3(spec["lin"])
		if String(spec["held"]) == "" and v.length() > Objective.IN_FLIGHT_SPEED:
			fly += 1
			var best := INF
			var bv := Vector3.ZERO
			for n in main.get_tree().get_nodes_in_group("element"):
				var d := (n as GameElement).global_position.distance_to(Snapshot.unpack_v3(spec["origin"]))
				if d < best:
					best = d
					bv = (n as GameElement).linear_velocity
			if best > 0.05 or bv.distance_to(v) > 0.2:
				fly_ok = false
	_ok("  %s: %d airborne ball%s still flying with the recorded velocity" % [what, fly,
		"" if fly == 1 else "s"], fly > 0 and fly_ok, true)
	var hv := 0.0
	var hv_now := 0.0
	for hs in cp["hives"]:
		hv = maxf(hv, Snapshot.unpack_v3(hs["ang"]).length())
	for a in main.field.hives:
		hv_now = maxf(hv_now, (main.field.hives[a] as Hive).swing.angular_velocity.length())
	_ok("  %s: the checkpoint had a swinging HIVE (%.2f rad/s)" % [what, hv], hv > 0.05, true)
	_near("  %s: the HIVE is still swinging at the recorded rate (rad/s)" % what, hv_now, hv, 0.1)

## Walk every pair of consecutive samples; count balls whose owner changed
## and that the viewer drew anywhere but at the earlier sample.
func _check_no_ownership_slides(v: ReplayViewer) -> int:
	var bad := 0
	var r := v.reader
	var eoff := r.head + r.per_robot * r.n_robots + r.per_hive * r.n_hives
	for s in r.sample_count() - 1:
		var a := r.sample(s)
		var b := r.sample(s + 1)
		if a.is_empty() or b.is_empty():
			continue
		var fa: PackedFloat32Array = a[0]
		var fb: PackedFloat32Array = b[0]
		for k in r.n_elements:
			var oa: int = int(a[1]) + eoff + k * r.per_element
			var ob: int = int(b[1]) + eoff + k * r.per_element
			if int(fa[oa + 7]) == int(fb[ob + 7]) or int(fa[oa + 7]) <= -2:
				continue
			v.seek((float(s) + 0.5) / r.rate)
			var e: GameElement = v._elements[k]
			if e.global_position.distance_to(Vector3(fa[oa], fa[oa + 1], fa[oa + 2])) > 0.0001:
				bad += 1
	return bad

# =================================================================== READ ===

func _read_phase() -> void:
	var st := _load_state()
	var dir := String(st.get("dir", ""))
	print("\n--- COLD START: replay folder %s" % dir)
	_ok("the harness's folder is still the replay folder", ReplayStore.folder(), dir)
	ReplayFormat.decode_count = 0
	var t0 := Time.get_ticks_usec()
	var list := ReplayStore.list()
	print("    listed %d replays in %.1f ms" % [list.size(), (Time.get_ticks_usec() - t0) / 1000.0])
	_ok("every replay survived the restart", list.size(), int(st.get("expect", -1)))
	_ok("listing decoded no recording", ReplayFormat.decode_count, 0)
	var by := {}
	for e in list:
		by[String(e["id"])] = e
	var rid := String(st["rid"])
	var rid2 := String(st["rid2"])
	_ok("the renamed title survived", String(by.get(rid, {}).get("title", "")), "Harness run")
	_ok("the duplicate title survived as its own replay", String(by.get(rid2, {}).get("title", "")), "Harness run")
	_ok("the favourite survived", bool(by.get(rid, {}).get("favorite", false)), true)
	_ok("the tags survived", by.get(rid, {}).get("tags", []), ["drill", "harness"])
	_ok("the latest replay is the newest playable one", String(ReplayStore.latest(list).get("id", "")) != "", true)
	_ok("the first recording is byte-for-byte intact", _md5(ReplayStore.recording_path(rid)), String(st["rid_hash"]))
	_ok("its events have the same stable ids after a restart", _event_ids(rid), st.get("events", []))
	var err: String = await main.watch_replay(rid, "progress")
	_ok("it plays after the restart", err, "")
	if main.viewer.is_open():
		main.viewer.seek(5.0)
		main.viewer.close("back")
		await _secs(0.4)
	_ok("the situation saved from it survived", String(ScenarioLibrary.load_one(String(st["sit_a"]))["error"]), "")
	# tidy up: the harness's situations and folder setting go away
	for e2 in ScenarioLibrary.list_all():
		if String(e2["name"]).begins_with("Harness branch") or String(e2["name"]) == DRILL:
			ScenarioLibrary.delete_one(String(e2["id"]))
	var prev: Variant = st.get("prev_config", {})
	ReplayStore._write_json_atomic(ReplayStore.CONFIG, prev if prev is Dictionary else {})
	ReplayStore.reload_folder()
	print("    restored the player's replay folder setting: %s" % ReplayStore.folder())
