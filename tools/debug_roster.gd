extends Node
##
## THE ROSTER.
##
## The setup screen can now ask for a lot of combinations, and every one of
## them has to produce the right robots with the right people behind them:
## one or two on your alliance, the second either a person or an AI teammate,
## one or two people per robot, and up to two AI opponents.
##
## The failure that matters is silent: two seats handed the same controller, or
## a robot that nobody is driving but nothing says so.
##
var main: Node3D
var fails := 0

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	main.menu.close()
	await get_tree().create_timer(1.5).timeout
	print("\n--- ROSTER ---")

	await _case("solo", {"robots": 1, "per_robot": 1, "opponents": 0}, 1, 0, 0)
	await _case("two drivers", {"robots": 2, "per_robot": 1, "opponents": 0}, 2, 0, 0)
	await _case("driver + operator",
		{"robots": 1, "per_robot": 2, "opponents": 0}, 1, 0, 0)
	await _case("me + AI teammate",
		{"robots": 2, "mate_is_ai": true, "per_robot": 1, "opponents": 0}, 2, 1, 0)
	await _case("full house",
		{"robots": 2, "mate_is_ai": true, "per_robot": 2, "opponents": 2}, 4, 3, 2)

	await _nectar()

	print("  %s  (%d failures)" % [
		"THE ROSTER IS RIGHT" if fails == 0 else "ROSTER PROBLEMS", fails])
	get_tree().quit(1 if fails > 0 else 0)

func _ok(label: String, got, want) -> void:
	var good: bool = got == want
	if not good:
		fails += 1
	print("    %s %-44s got %s   want %s" % [
		"PASS" if good else "FAIL", label, str(got), str(want)])

func _case(name: String, opts: Dictionary, want_robots: int, want_ai: int,
		want_foes: int) -> void:
	print("  %s:" % name)
	main._on_menu_start(BB.Mode.FREE_PRACTICE, BB.Alliance.RED, 1, opts)
	await get_tree().create_timer(1.6).timeout

	_ok("robots on the field", main.robots.size(), want_robots)
	_ok("AI brains attached", main.ais.size(), want_ai)

	var ours := 0
	var foes := 0
	var human := 0
	for r in main.robots:
		if r.alliance == BB.Alliance.RED: ours += 1
		else: foes += 1
		if not r.ai_driver: human += 1
	_ok("opponents", foes, want_foes)
	_ok("ours", ours, want_robots - want_foes)

	# NOBODY may share a device with anybody else. Two seats on one controller
	# means two robots doing the same thing and no way to tell why.
	# Collect one entry per SEAT. A robot driven by one person contributes one
	# seat; a split robot contributes two. Any repeated device across that list
	# is two people on one controller.
	var seats: Array = []
	for r in main.robots:
		if r.ai_driver:
			continue
		seats.append(r.device)
		if r.device != r.op_device:
			seats.append(r.op_device)
	var clash := false
	var seen: Array = []
	for dev in seats:
		if dev <= DriverInput.NONE:
			continue
		if seen.has(dev):
			clash = true
		seen.append(dev)
	_ok("no two seats share a device", clash, false)

	# One person per robot means driver and operator are the same device; two
	# means they are different.
	var split_ok := true
	for r in main.robots:
		if r.ai_driver:
			continue
		var want_split: bool = int(opts.get("per_robot", 1)) > 1
		var is_split: bool = r.device != r.op_device
		if want_split != is_split and r.device > DriverInput.NONE:
			split_ok = false
	_ok("controls split matches the setting", split_ok, true)

	for r in main.robots:
		if r.ai_driver:
			_ok("  %s has no controller" % r.driver_label,
				r.device <= DriverInput.NONE, true)

func _nectar() -> void:
	print("  intake option:")
	main._on_menu_start(BB.Mode.FREE_PRACTICE, BB.Alliance.RED, 1,
		{"robots": 1, "per_robot": 1, "opponents": 0, "takes_nectar": false})
	await get_tree().create_timer(1.4).timeout
	_ok("POLLEN ONLY leaves nectar alone", main.robot.takes_nectar, false)
	var got_pollen := await _try_collect(BB.Kind.POLLEN)
	_ok("  and still collects POLLEN", got_pollen, true)
	var got_nectar := await _try_collect(BB.Kind.NECTAR)
	_ok("  and refuses NECTAR", got_nectar, false)

	main._on_menu_start(BB.Mode.FREE_PRACTICE, BB.Alliance.RED, 1,
		{"robots": 1, "per_robot": 1, "opponents": 0, "takes_nectar": true})
	await get_tree().create_timer(1.4).timeout
	_ok("POLLEN + NECTAR is set", main.robot.takes_nectar, true)
	var both_n := await _try_collect(BB.Kind.NECTAR)
	_ok("  and NECTAR goes in", both_n, true)
	var both_p := await _try_collect(BB.Kind.POLLEN)
	_ok("  and POLLEN still does", both_p, true)

## Drop one element in front of the robot and see whether it ends up aboard.
func _try_collect(kind: int) -> bool:
	var r: Robot = main.robot
	r.auto_drive = true
	r.set_drive(0, 0, 0)
	for e in r.hopper:
		(e as GameElement).queue_free()
	r.hopper.clear()
	r.teleport(Transform3D(Basis(Vector3.UP, -PI * 0.5), BB.fp(-40.0, -50.0, 0.0)))
	await get_tree().physics_frame
	var el := GameElement.make(kind, BB.Alliance.RED)
	main.add_child(el)
	el.global_position = r.to_global(Vector3(0, BB.m(3.0), -BB.m(6.0)))
	await get_tree().create_timer(1.6).timeout
	var aboard := r.hopper.size() > 0
	el.queue_free()
	return aboard
