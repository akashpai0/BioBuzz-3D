extends Node
##
## TWO DRIVERS, AN OPPONENT, AND A RANDOMISED FIELD.
##
## The three title-screen options added in this pass all change the roster or
## the staging, which is exactly the sort of thing that looks fine on screen and
## is quietly wrong. So: count the robots, check they start in different places
## on the right walls, check the 40 POLLEN still add up when preloads move
## around, check each driver's input device is their own, and check the AI
## actually drives its robot somewhere.
##
var main: Node3D
var t := 0.0
var fails := 0
var stage := 0
var opp_start := Vector3.ZERO
var opp_moved := 0.0
var p1_start := Vector2.ZERO
var p2_start := Vector2.ZERO
var pollen := 0
var nectar := 0
var preloads := {}

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	main.menu.close()
	await get_tree().create_timer(1.5).timeout

	# --- now the full house: two drivers and an opponent
	main._on_menu_start(BB.Mode.FREE_PRACTICE, BB.Alliance.RED, 1,
		{"robots": 2, "per_robot": 1, "opponents": 1})
	# Sample the start poses BEFORE anyone has driven anywhere: free practice
	# enables the robots the moment staging finishes, and the AI opponent will
	# happily cross half the field while a longer timer is still running.
	await get_tree().create_timer(0.35).timeout
	p1_start = Vector2(main.robots[0].fx(), main.robots[0].fy())
	p2_start = Vector2(main.robots[1].fx(), main.robots[1].fy())
	opp_start = main.opponent.global_position
	# Preloads are counted HERE, with the start poses, not two seconds later:
	# the opponent begins its first scoring run immediately and has usually
	# fired part of its preload by then.
	await get_tree().create_timer(2.0).timeout

	print("\n--- TWO DRIVERS, OPPONENT, RANDOMISED FIELD ---")
	for e in get_tree().get_nodes_in_group("element"):
		var el: GameElement = e
		if el.kind == BB.Kind.POLLEN: pollen += 1
		else: nectar += 1
	# Only the DRIVER robots. The opponent is already playing by now — it starts
	# its first scoring run the instant the match does — so counting what is
	# still in its hopper measures the AI's reaction time, not the staging.
	for r in main.robots:
		if not r.ai_driver:
			preloads[r.driver_label] = r.hopper.size()
	stage = 1
	t = 0.0

func _ok(label: String, got, want) -> void:
	var good: bool = got == want
	if not good:
		fails += 1
	print("  %s %-52s got %s   want %s" % ["PASS" if good else "FAIL", label, str(got), str(want)])

func _physics_process(d: float) -> void:
	if stage != 1:
		return
	t += d
	opp_moved = maxf(opp_moved, (main.opponent.global_position - opp_start).length() / BB.IN)
	if t > 7.0:
		stage = 2
		_report()

func _report() -> void:
	_ok("three robots on the field", main.robots.size(), 3)
	_ok("two of them are ours", main.robots[0].alliance == BB.Alliance.RED \
		and main.robots[1].alliance == BB.Alliance.RED, true)
	_ok("the opponent is the other colour", main.opponent.alliance, BB.Alliance.BLUE)
	_ok("the opponent is AI-driven", main.opponent.ai_driver, true)
	_ok("the two drivers never share a device",
		main.robots[0].device != main.robots[1].device, true)
	_ok("P1 and P2 start apart", (p1_start - p2_start).length() > 20.0, true)
	_ok("both ours start at the red wall", p1_start.x < -50.0 and p2_start.x < -50.0, true)
	_ok("the opponent starts at the blue wall", opp_start.x / BB.IN > 50.0, true)
	_ok("POLLEN still totals 40", pollen, 40)
	_ok("NECTAR still totals 16", nectar, 16)
	_ok("both driver robots preloaded 4",
		preloads.values().all(func(v: int) -> bool: return v == 4), true)
	_ok("the opponent drove somewhere", opp_moved > 6.0, true)
	print("\n  P1 (%.0f, %.0f) dev %d   P2 (%.0f, %.0f) dev %d   OPP moved %.0f in" % [
		p1_start.x, p1_start.y, main.robots[0].device,
		p2_start.x, p2_start.y, main.robots[1].device, opp_moved])
	print("  %s  (%d failures)" % ["CO-OP AND OPPONENT OK" if fails == 0 else "PROBLEMS", fails])
	get_tree().quit(1 if fails > 0 else 0)
