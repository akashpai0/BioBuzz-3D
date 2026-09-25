extends Node
## SAVED SITUATIONS, TESTED AS BEHAVIOUR.
##
## Runs in two phases, as two separate processes, because "survives closing the
## game" is not a thing one process can prove about itself:
##
##   -- write   builds an awkward field, captures it, saves it, quits
##   -- read    a COLD START: finds the file on disk and restores from it
##
## The read phase then retries twice and checks that nothing accumulated and
## nothing drifted.

var main: Node3D
var fails := 0
const NAME := "harness situation"
const EXPECT := "user://harness_expect.json"

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(2.0).timeout
	var args := OS.get_cmdline_user_args()
	var phase := String(args[0]) if args.size() > 0 else "write"
	if phase == "write":
		await _write_phase()
	else:
		await _read_phase()
	print("  %s  (%d failure%s)" % [
		"SITUATIONS WORK" if fails == 0 else "SITUATIONS BROKEN",
		fails, "" if fails == 1 else "s"])
	get_tree().quit(1 if fails > 0 else 0)

# =================================================================== write ===

func _write_phase() -> void:
	print("\n--- SITUATIONS: WRITE PHASE ---")
	for entry in ScenarioLibrary.list_all():
		if String(entry["name"]) == NAME:
			ScenarioLibrary.delete_one(String(entry["id"]))

	# a full match with an AI opponent, so there is a brain mid-thought
	main._on_menu_start(BB.Mode.TELEOP_ONLY, BB.Alliance.RED, 1,
		{"robots": 1, "mate_is_ai": false, "per_robot": 1, "opponents": 1,
		 "takes_nectar": false})
	await get_tree().create_timer(3.0).timeout

	var r: Robot = main.robot
	# a PARTIALLY loaded hopper: drop two of the four preloads
	while r.hopper.size() > 2:
		var e: GameElement = r.hopper.pop_back()
		e.release(Transform3D(Basis.IDENTITY,
			r.to_global(Vector3(0, BB.m(8.0), 0))), Vector3.ZERO)
	# something in the air, moving
	var flyer := _loose_element()
	if flyer:
		flyer.global_position = BB.fp(-20.0, -10.0, 40.0)
		flyer.linear_velocity = Vector3(1.4, 2.2, -0.8)
		flyer.angular_velocity = Vector3(3.0, 1.0, 2.0)
	# a HIVE caught mid-swing
	var hive: Hive = main.field.hives[BB.Alliance.RED]
	hive.swing.angular_velocity = Vector3(0.0, 0.0, 0.9)
	# a human feed still owed, with a delay part-way through
	var owed := _loose_element()
	if owed:
		main.mm._hand_to_human(BB.Alliance.RED, owed, 2.4)
	# a score and a foul on the board, so the bookkeeping has something in it
	main.mm.scoring.tips[BB.Alliance.RED] = 1
	main.mm.scoring.fouls_against[BB.Alliance.BLUE] = 10
	main.robot.linear_velocity = Vector3(0.6, 0.0, -0.4)

	await get_tree().physics_frame
	var snap := Snapshot.capture(main)
	var id := ScenarioLibrary.save(snap, NAME, "built by the test harness")
	_ok("the situation saved", id != "", true)

	# write down what we expect to see on the other side of a restart
	var expect := {
		"elements": (snap["elements"] as Array).size(),
		"hopper": (snap["robots"][0]["hopper"] as Array).size(),
		"robot_origin": snap["robots"][0]["origin"],
		"robot_lin": snap["robots"][0]["lin"],
		"flyer_lin": _find_flyer(snap),
		"hive_ang": snap["hives"][0]["ang"],
		"queue": (snap["match"]["human_queue"]["0"] as Array).size(),
		"queue_left": float((snap["match"]["human_queue"]["0"] as Array)[0][1]),
		"tips": snap["match"]["scoring"]["tips"],
		"fouls": snap["match"]["scoring"]["fouls_against"],
		"time_left": float(snap["match"]["time_left"]),
		"robots": (snap["robots"] as Array).size(),
	}
	var f := FileAccess.open(EXPECT, FileAccess.WRITE)
	f.store_string(JSON.stringify(expect))
	f.close()
	print("  wrote %d elements, %d in the hopper, %.2f s of feed owed" % [
		expect["elements"], expect["hopper"], expect["queue_left"]])

func _loose_element() -> GameElement:
	for n in get_tree().get_nodes_in_group("element"):
		var e: GameElement = n
		if e.held_by == null:
			return e
	return null

func _find_flyer(snap: Dictionary) -> Array:
	var best: Array = [0.0, 0.0, 0.0]
	var top := 0.0
	for spec in snap["elements"]:
		var v := Snapshot.unpack_v3(spec["lin"]).length()
		if v > top:
			top = v
			best = spec["lin"]
	return best

# ==================================================================== read ===

func _read_phase() -> void:
	print("\n--- SITUATIONS: READ PHASE (cold start) ---")
	var ef := FileAccess.open(EXPECT, FileAccess.READ)
	if ef == null:
		print("  FAIL no expectation file - run the write phase first")
		fails += 1
		return
	var parsed: Variant = JSON.parse_string(ef.get_as_text())
	var expect: Dictionary = parsed if parsed is Dictionary else {}
	ef.close()

	var id := ""
	for entry in ScenarioLibrary.list_all():
		if String(entry["name"]) == NAME:
			id = String(entry["id"])
	_ok("the situation is still on disk after a restart", id != "", true)
	if id == "":
		return

	var history_before: int = RobotShop.history().size()
	await main.play_situation(id)
	# Measured AT THE RESTORE BOUNDARY: a tenth of a second of real physics
	# later the robot has genuinely moved, which is the promise — the same
	# starting conditions, not a frozen world.
	main.mm.pause()

	# ---- what came back
	var n_elements: int = get_tree().get_nodes_in_group("element").size()
	_ok("every element came back", n_elements, int(expect["elements"]))
	_ok("the roster came back", main.robots.size(), int(expect["robots"]))
	_ok("the partially loaded hopper came back",
		main.robot.hopper.size(), int(expect["hopper"]))
	_near("the robot is where it was",
		main.robot.global_position, Snapshot.unpack_v3(expect["robot_origin"]), 0.01)
	_near("the robot is still moving",
		main.robot.linear_velocity, Snapshot.unpack_v3(expect["robot_lin"]), 0.05)
	_near("the airborne element kept its velocity",
		_fastest(), Snapshot.unpack_v3(expect["flyer_lin"]), 0.20)
	_near("the hive is still swinging",
		main.field.hives[BB.Alliance.RED].swing.angular_velocity,
		Snapshot.unpack_v3(expect["hive_ang"]), 0.25)
	_ok("the human still owes a ball",
		(main.mm.human_queue[BB.Alliance.RED] as Array).size(), int(expect["queue"]))
	if not (main.mm.human_queue[BB.Alliance.RED] as Array).is_empty():
		var left: float = float((main.mm.human_queue[BB.Alliance.RED] as Array)[0][1])
		_ok("  with the delay it had left, not a fresh one",
			absf(left - float(expect["queue_left"])) < 0.35, true)
	_ok("the scoreboard came back",
		main.mm.scoring.tips[BB.Alliance.RED], int(expect["tips"][0]))
	_ok("the fouls came back",
		main.mm.scoring.fouls_against[BB.Alliance.BLUE], int(expect["fouls"][1]))
	_ok("the clock came back",
		absf(main.mm.time_left - float(expect["time_left"])) < 1.0, true)
	_ok("loading raised no foul",
		_has_event("FOUL"), false)
	_ok("no driver command survived the load",
		main.robot._drive.length() < 0.001, true)

	# ---- retries do not accumulate or drift
	var score_before: int = main.mm.scoring.tips[BB.Alliance.RED]
	for i in 3:
		main.mm.resume()
		await get_tree().create_timer(0.8).timeout
		await main.retry_situation()
		main.mm.pause()
	_ok("three retries left the element count alone",
		get_tree().get_nodes_in_group("element").size(), int(expect["elements"]))
	_ok("  and the robot count alone", main.robots.size(), int(expect["robots"]))
	_ok("  and the starting score alone",
		main.mm.scoring.tips[BB.Alliance.RED], score_before)
	_near("  and put the robot back in the same place",
		main.robot.global_position, Snapshot.unpack_v3(expect["robot_origin"]), 0.01)
	_ok("  and the hopper back to the same load",
		main.robot.hopper.size(), int(expect["hopper"]))

	# ---- a situation attempt is not a match
	_ok("the run is flagged as a situation attempt", main.scenario_run, true)
	main._on_match_finished({"breakdown": main.mm.scoring.breakdown(main.field, true),
		"rp": {}})
	_ok("finishing it did not touch the match history",
		RobotShop.history().size(), history_before)
	main.results.close()

	# ---- a seat with no device must go dead, not steal another robot's
	Settings.seats.clear()
	Settings.set_seat_device(0, -1)
	Settings.set_seat_device(1, -1)
	main.opts = {"robots": 1, "mate_is_ai": false, "per_robot": 2,
		"opponents": 0, "takes_nectar": false}
	main._build_robots(BB.Alliance.RED, 1)
	await get_tree().create_timer(0.3).timeout
	_ok("two seats cannot share one keyboard",
		main.robot.op_device == DriverInput.NONE, true)
	_ok("  and the driver still has it", main.robot.device, -1)
	Settings.seats.clear()
	Settings.save_to_disk()

	# ---- a damaged file is reported, not crashed on
	var bad := "user://situations/broken.json"
	var bf := FileAccess.open(bad, FileAccess.WRITE)
	bf.store_string("{ this is not json")
	bf.close()
	var entry := ScenarioLibrary.load_one("broken")
	_ok("a damaged file is reported rather than crashing",
		String(entry["error"]) != "", true)
	_ok("  and the rest of the shelf still lists",
		ScenarioLibrary.list_all().size() >= 2, true)
	DirAccess.remove_absolute(bad)

	# ---- a file from a future version is refused politely
	_ok("a newer format is refused with a sentence",
		Snapshot.validate({"format": Snapshot.FORMAT, "version": 99}) != "", true)

func _fastest() -> Vector3:
	var best := Vector3.ZERO
	for n in get_tree().get_nodes_in_group("element"):
		var e: GameElement = n
		if e.linear_velocity.length() > best.length():
			best = e.linear_velocity
	return best

func _has_event(needle: String) -> bool:
	for line in main.mm.events:
		if String(line).findn(needle) >= 0:
			return true
	return false

# ================================================================== checks ===

func _ok(what: String, got: Variant, want: Variant) -> void:
	var pass_: bool = str(got) == str(want)
	if not pass_:
		fails += 1
	print("  %s %-52s got %s   want %s" % [
		"PASS" if pass_ else "FAIL", what, str(got), str(want)])

func _near(what: String, got: Vector3, want: Vector3, tol: float) -> void:
	var d := got.distance_to(want)
	var pass_: bool = d <= tol
	if not pass_:
		fails += 1
	print("  %s %-52s off by %.4f (tol %.2f)" % [
		"PASS" if pass_ else "FAIL", what, d, tol])
