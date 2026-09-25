extends Node
##
## THE MATCH REPORT, THE STATS, AND THE AUTO RECORDER.
##
## Three things that all silently produce plausible-looking rubbish if they are
## wrong: a breakdown whose lines do not add up to its own total, stats that
## count a miss as a made shot, and a saved auto that replays as nothing.
##
var main: Node3D
var fails := 0
var t := 0.0
var stage := 0
var routine: AutoRoutine
var replay_moved := 0.0
var replay_start := Vector3.ZERO

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	main.menu.close()
	await get_tree().create_timer(1.5).timeout
	main._on_menu_start(BB.Mode.FREE_PRACTICE, BB.Alliance.RED, 1,
		{"robots": 1, "per_robot": 1, "opponents": 0})
	await get_tree().create_timer(2.0).timeout
	print("\n--- MATCH REPORT, STATS AND AUTO ---")
	_test_breakdown()
	await _test_stats()
	await _test_auto()
	print("  %s  (%d failures)" % [
		"REPORT AND AUTO OK" if fails == 0 else "PROBLEMS", fails])
	get_tree().quit(1 if fails > 0 else 0)

func _ok(label: String, got, want) -> void:
	var good: bool = got == want
	if not good:
		fails += 1
	print("  %s %-52s got %s   want %s" % ["PASS" if good else "FAIL", label, str(got), str(want)])

# ============================================================== breakdown ====

func _test_breakdown() -> void:
	var sc: Scoring = main.mm.scoring
	sc.leave[BB.Alliance.RED] = 2
	sc.park_auto[BB.Alliance.RED] = 1
	sc.park_teleop[BB.Alliance.RED] = 2
	sc.tips[BB.Alliance.RED] = 4
	sc.fouls_against[BB.Alliance.BLUE] = 15

	var live := sc.breakdown(main.field, false)
	var fin := sc.breakdown(main.field, true)
	var r: Dictionary = fin[BB.Alliance.RED]

	_ok("LEAVE counts robots, not points", r["leave_n"], 2)
	_ok("LEAVE points are 3 each", r["leave"], 6)
	_ok("AUTO PARK is its own line", r["park_auto"], BB.PTS_PARK)
	_ok("END PARK is its own line", r["park_teleop"], 2 * BB.PTS_PARK)
	_ok("TIPS count and points agree", r["tips"], r["tips_n"] * BB.PTS_TIP)
	_ok("fouls land on the other alliance", r["foul"], 15)

	# END-ONLY rows must be zero while the match is running and only appear
	# once the field is at rest, or a driver chases points that are not there
	for k in Scoring.END_ONLY:
		_ok("%s is zero mid-match" % k, int(live[BB.Alliance.RED][k]), 0)

	# the total has to be the sum of its own visible lines, or the report lies
	var sum := 0
	for k in ["leave", "park_auto", "park_teleop", "tips", "cell",
			"flower", "bottom", "garden", "foul"]:
		sum += int(r[k])
	_ok("TOTAL equals the sum of its lines", r["total"], sum)

	# every REPORT row must exist in the data, or the screen prints blanks
	var missing := ""
	for row in Scoring.REPORT:
		if String(row[0]) == "_h":
			continue
		if not r.has(String(row[0])):
			missing = String(row[0])
	_ok("every printed row has data behind it", missing, "")

	_ok("SWARM needs 16 LEAVE+PARK",
		sc.rp_rows(BB.Alliance.RED, fin)[0][1], r["leave"] + r["park"] >= 16)
	_ok("POLLINATOR 1 at 4 tips", sc.rp_rows(BB.Alliance.RED, fin)[1][1], true)
	_ok("POLLINATOR 2 not yet at 4 tips", sc.rp_rows(BB.Alliance.RED, fin)[2][1], false)

# ================================================================== stats ====

func _test_stats() -> void:
	var robot: Robot = main.robot
	var st: MatchStats = main.stats
	main.mm.phase = BB.Phase.TELEOP
	# park it where it can actually score, fill it, and empty the hopper at the
	# hive so the made-shot path is exercised end to end
	robot.auto_drive = true
	robot.set_drive(0, 0, 0)
	robot.teleport(Transform3D(Basis.IDENTITY, BB.fp(-12.75, -52.0, 0.0)))
	await get_tree().physics_frame
	while robot.hopper.size() < BB.HOPPER_CAP:
		var e := GameElement.make(BB.Kind.POLLEN)
		main.add_child(e)
		e.global_position = robot.to_global(Vector3(0, BB.m(6.0), 0))
		robot._take(e)
	await get_tree().create_timer(1.2).timeout
	var fired := 0
	while fired < 4:
		if robot.aim_locked and robot.can_fire():
			robot.fire()
			fired += 1
		await get_tree().physics_frame
	await get_tree().create_timer(3.5).timeout

	var s := st.summary(robot)
	_ok("shots were counted", int(s["shots"]), 4)
	_ok("at least one was counted as MADE", int(s["made"]) >= 1, true)
	_ok("made is never more than taken", int(s["made"]) <= int(s["shots"]), true)
	_ok("accuracy matches the counts",
		absf(float(s["accuracy"]) - float(s["made"]) / 4.0 * 100.0) < 0.01, true)
	_ok("collected was counted", int(s["collected"]) >= 4, true)
	_ok("every printed stat row has a value",
		MatchStats.rows(s).size() > 10, true)

# =================================================================== auto ====

func _test_auto() -> void:
	var robot: Robot = main.robot
	main.mm.mode = BB.Mode.FREE_PRACTICE
	robot.auto_drive = false
	main.auto_player.begin_record(robot)
	# drive a shape by hand, the way a person recording an auto would
	robot.auto_drive = true
	for i in 90:
		robot.set_drive(0.0, 0.0, 1.0)
		await get_tree().physics_frame
	for i in 60:
		robot.set_drive(0.0, 0.6, 0.0)
		await get_tree().physics_frame
	robot.set_drive(0, 0, 0)
	routine = main.auto_player.stop_record()

	_ok("something was recorded", routine.frames.size() > 20, true)
	_ok("routine length is sane", routine.length_s() > 0.5 and routine.length_s() < 20.0, true)
	_ok("trailing dead time was trimmed",
		int((routine.frames[-1] as Array)[3]) != 0
		or absf(float((routine.frames[-1] as Array)[2])) > 0.02
		or absf(float((routine.frames[-1] as Array)[1])) > 0.02, true)

	_ok("it saves", routine.save_as("harness-test"), true)
	var back := AutoRoutine.load_named("harness-test")
	_ok("it loads back", back != null and back.frames.size() == routine.frames.size(), true)
	_ok("it is listed", AutoRoutine.list_saved().has("harness-test"), true)

	# replay it and check the robot actually goes somewhere
	robot.teleport(Transform3D(Basis.IDENTITY, BB.fp(0.0, 0.0, 0.0)))
	await get_tree().physics_frame
	replay_start = robot.global_position
	main.auto_player.begin_play(robot, back)
	var guard := 0
	while main.auto_player.playing and guard < 2000:
		replay_moved = maxf(replay_moved,
			(robot.global_position - replay_start).length() / BB.IN)
		guard += 1
		await get_tree().physics_frame
	_ok("replaying it drives the robot", replay_moved > 12.0, true)
	_ok("playback releases the robot when it ends", robot.auto_drive, false)

	AutoRoutine.delete_named("harness-test")
	_ok("it deletes", AutoRoutine.list_saved().has("harness-test"), false)
