extends Node
## PAUSE MUST STOP THE WORLD, NOT JUST THE CLOCK.
##
## Ported from the independent review's pause probe, which found a ball moving
## 19.47 inches during a one-second pause while the attempt clock stood still
## and the hopper statistics kept accruing.
##
## The rule this asserts: between opening a menu and resuming, NOTHING about
## the run changes — not a body, not a score, not a statistic, not a timer.
## The pause menu says exactly that in words; this is the check that it is true.
##
## Every route to the pause menu is tested, because the last defect in this
## area was one route forgetting to do what the others did.

var main: Node3D
var fails := 0

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(2.5).timeout
	await _setup()
	await _freeze_through("the pause menu", func() -> void: main._open_pause_menu())
	await _freeze_through("the nav bar", func() -> void: main.goto("Settings"))
	await _nothing_else_is_running()
	await _auto_routines_hold()
	await _diagnostics_run_while_frozen()
	await _timers_hold()
	await _resume_is_seamless()
	_teardown()
	print("  %s  (%d failure%s)" % [
		"PAUSE STOPS THE WORLD" if fails == 0 else "PAUSE LEAKS",
		fails, "" if fails == 1 else "s"])
	get_tree().quit(1 if fails > 0 else 0)

## Setup that could not be completed is not a test result. Say what failed,
## put the fixture away, and exit NON-ZERO instead of carrying on and
## dereferencing whatever is missing.
func _bail(why: String) -> void:
	fails += 1
	print("  SETUP FAILED: %s" % why)
	_teardown()
	print("  PAUSE TEST COULD NOT RUN  (%d failure%s)" % [
		fails, "" if fails == 1 else "s"])
	get_tree().quit(1)

var _fixture_id := ""
const FIXTURE := "pause harness fixture"

## A FIXTURE THIS HARNESS BUILDS, not whatever happens to be first on the shelf.
##
## It used to load `ScenarioLibrary.list_all()[0]`. In a fresh profile that
## picked "Recover from the corner", which is an empty-field drill with no
## loose balls, so `_stir()` found nothing and the run died dereferencing null
## — and reported that as a pause failure, which it was not.
##
## The fixture is authored here from a staged field, so it always has loose
## balls, a robot and an objective, and it is referenced by the id that saving
## it returned. Shelf order, starter-drill names and anything the player has
## saved or renamed are all irrelevant to it.
func _setup() -> void:
	for e in ScenarioLibrary.list_all():
		if String(e["name"]) == FIXTURE:
			ScenarioLibrary.delete_one(String(e["id"]))

	await main._create_scenario("staged")
	if main.editor == null or main.editor.draft == null:
		_bail("the editor did not open a staged draft")
		return
	var d: ScenarioDraft = main.editor.draft
	d.name = FIXTURE
	d.set_scenario("mode", BB.Mode.TELEOP_ONLY)
	d.set_scenario("phase", BB.Phase.TELEOP)
	d.set_scenario("time_left", 90.0)
	d.set_objective("kind", Objective.Kind.SHOTS)
	d.set_objective("target", Objective.Target.ALLIANCE)
	d.set_objective("amount", 99)          # never reachable: the attempt stays live
	var snap := d.to_snapshot()
	var loose := 0
	for e in snap.get("elements", []):
		if String(e.get("held", "")) == "":
			loose += 1
	if loose < 1:
		_bail("the staged fixture has no loose balls to move (%d elements)"
			% (snap.get("elements", []) as Array).size())
		return
	_fixture_id = ScenarioLibrary.save(snap, d.name, "built by debug_pause")
	d.source_id = _fixture_id
	d.dirty = false
	main.editor._try_close()
	await get_tree().create_timer(0.4).timeout
	if _fixture_id == "":
		_bail("the fixture could not be saved to the library")
		return

	await main.play_situation(_fixture_id)
	await get_tree().create_timer(0.4).timeout

	# ---- the fixture is what is loaded, and it is not index 0 by luck
	_ok("the harness loaded the fixture it built", main.scenario_id, _fixture_id)
	_ok("  resolved by id, not by shelf position",
		String((main.scenario_source.get("meta", {}) as Dictionary)
			.get("name", "")), FIXTURE)
	if main.attempt == null:
		_bail("no attempt was armed by the fixture")
		return
	if not is_instance_valid(main.robot):
		_bail("the fixture produced no robot to drive")
		return
	if _find_ball() == null:
		_bail("the fixture produced no loose ball on the field")
		return
	_ok("the fixture has a robot, a loose ball and a live attempt", true, true)

func _teardown() -> void:
	if _fixture_id != "":
		ScenarioLibrary.delete_one(_fixture_id)
		_fixture_id = ""

func _find_ball() -> GameElement:
	for e in get_tree().get_nodes_in_group("element"):
		var el: GameElement = e
		if is_instance_valid(el) and el.held_by == null and not el.freeze:
			return el
	return null

## Put the world in motion: a ball in flight, a swinging CELL, a driving robot.
func _stir() -> GameElement:
	var ball := _find_ball()
	if ball == null:
		_bail("no loose ball on the field to set moving")
		return null
	ball.global_position = BB.fp(40.0, 40.0, 40.0)
	ball.linear_velocity = Vector3(1.4, 0.0, -0.9)
	ball.angular_velocity = Vector3(3.0, 0.0, 1.0)
	if is_instance_valid(main.robot):
		main.robot.auto_drive = true
		main.robot.set_drive(0.0, 0.0, 1.0)
	var hv: Hive = main.field.hives[main.robot.alliance]
	hv.swing.angular_velocity = Vector3(0.0, 0.0, 0.4)
	return ball

## THE CORE CHECK. Stir the world, pause by `route`, wait a real second, and
## insist that not one measurable thing moved.
func _freeze_through(route_name: String, route: Callable) -> void:
	main.mm.resume()
	await get_tree().create_timer(0.3).timeout
	var ball := _stir()
	await get_tree().physics_frame
	await get_tree().physics_frame
	_ok("%s: the world is moving before the pause" % route_name,
		ball != null and ball.linear_velocity.length() > 0.1, true)

	route.call()
	await get_tree().process_frame
	var p0: Vector3 = ball.global_position
	var r0: Vector3 = main.robot.global_position
	var hv: Hive = main.field.hives[main.robot.alliance]
	var a0: float = hv.angle()
	var clock0: float = main.mm.time_left
	var att0: float = main.attempt.elapsed if main.attempt else 0.0
	var s0: Dictionary = main.stats.summary(main.robot)
	var score0: Dictionary = main.mm.scoring.breakdown(main.field, false)

	await get_tree().create_timer(1.0).timeout

	var s1: Dictionary = main.stats.summary(main.robot)
	var score1: Dictionary = main.mm.scoring.breakdown(main.field, false)
	_ok("  the match is paused", main.mm.paused, true)
	_ok("  the ball has not moved (in)",
		"%.4f" % (ball.global_position.distance_to(p0) / BB.IN), "0.0000")
	_ok("  the robot has not moved (in)",
		"%.4f" % (main.robot.global_position.distance_to(r0) / BB.IN), "0.0000")
	_ok("  the CELL has not swung (deg)",
		"%.4f" % absf(hv.angle() - a0), "0.0000")
	_ok("  the match clock has not moved",
		absf(main.mm.time_left - clock0) < 0.0001, true)
	_ok("  the attempt clock has not moved",
		absf((main.attempt.elapsed if main.attempt else 0.0) - att0) < 0.0001, true)
	_ok("  hopper-full time has not accrued",
		"%.4f" % absf(float(s1["t_full"]) - float(s0["t_full"])), "0.0000")
	_ok("  hopper-empty time has not accrued",
		"%.4f" % absf(float(s1["t_empty"]) - float(s0["t_empty"])), "0.0000")
	_ok("  time-moving has not accrued",
		"%.4f" % absf(float(s1["t_moving"]) - float(s0["t_moving"])), "0.0000")
	_ok("  distance driven has not accrued",
		"%.4f" % absf(float(s1["distance_ft"]) - float(s0["distance_ft"])), "0.0000")
	_ok("  the score has not changed",
		int(score1[main.robot.alliance]["total"]),
		int(score0[main.robot.alliance]["total"]))
	main.robot.auto_drive = false
	main.robot.set_drive(0.0, 0.0, 0.0)
	for s in [main.menu, main.settings_menu]:
		if s != null and s.is_open():
			s.close()

## NOTHING UNDER THE WORLD ROOT MAY STILL BE PROCESSING WHILE HALTED.
##
## The generic version of the defect that produced this suite twice. The first
## pass held down a list of simulation nodes and forgot `auto_player`; a review
## found it recording thirty frames behind the pause menu. A list of things to
## stop will always be one short of the tree.
##
## So this walks the LIVE tree instead of trusting a list: while halted, every
## node under `main` that can still process must be one the game explicitly
## declared as always-running (a menu, the HUD, the camera, input) or a child
## of one. Anything else is simulation that is still moving.
func _nothing_else_is_running() -> void:
	main.mm.resume()
	await get_tree().create_timer(0.3).timeout
	_stir()
	main._open_pause_menu()
	await get_tree().process_frame

	var allowed: Array[Node] = main.always_running()
	var leaking: Array[String] = []
	# Start from the root's CHILDREN. `main` is itself always-running (it has
	# to keep taking input), so scanning from it would match on the first node
	# and skip the entire world — which is exactly what the first version of
	# this check did, and why it passed against a build that was leaking.
	for child in main.get_children():
		_scan(child, allowed, leaking)
	if not leaking.is_empty():
		print("    still processing: %s" % ", ".join(leaking))
	_ok("no simulation node is still processing while halted",
		leaking.is_empty(), true)
	_ok("  and the scan actually reached the world",
		main.get_child_count() > 5, true)
	main._resume_match()
	await get_tree().create_timer(0.05).timeout

func _scan(n: Node, allowed: Array[Node], out: Array[String]) -> void:
	if allowed.has(n):
		return                       # this node and its subtree may run
	if n.can_process() and (n.has_method("_process")
			or n.has_method("_physics_process")):
		out.append("%s (%s)" % [n.name, n.get_class()])
	for c in n.get_children():
		_scan(c, allowed, out)

## AN AUTONOMOUS ROUTINE IS A TIMELINE, and a pause must not move the playhead.
##
## Reported by the follow-up review: with the pause menu up, recording inserted
## 30 new frames and playback consumed a full second of the routine, so coming
## back from the menu resumed somewhere the driver had never been.
func _auto_routines_hold() -> void:
	for route in [["the pause menu", func() -> void: main._open_pause_menu()],
			["Settings", func() -> void: main.goto("Settings")]]:
		await _auto_holds_through(String(route[0]), route[1] as Callable, 1.0)
	# a LONG pause is the same rule, and the one a real player actually takes
	await _auto_holds_through("a long pause",
		func() -> void: main._open_pause_menu(), 3.0)
	await _playback_resumes_where_it_stopped()

func _auto_holds_through(route_name: String, route: Callable, hold_s: float) -> void:
	main.mm.resume()
	await get_tree().create_timer(0.3).timeout

	# ---- recording
	main.auto_player.begin_record(main.robot)
	await get_tree().create_timer(0.25).timeout
	route.call()
	await get_tree().process_frame
	var frames0: int = main.auto_player.routine.frames.size()
	var sub0: float = main.auto_player._t
	await get_tree().create_timer(hold_s).timeout
	_ok("%s: recording captures no samples while halted" % route_name,
		main.auto_player.routine.frames.size() - frames0, 0)
	_ok("  and the sub-tick accumulator does not creep",
		absf(main.auto_player._t - sub0) < 0.0001, true)
	_ok("  the recording is still armed", main.auto_player.recording, true)
	main._resume_match()
	await get_tree().create_timer(0.25).timeout
	_ok("  and it captures again once play resumes",
		main.auto_player.routine.frames.size() > frames0, true)
	main.auto_player.stop_record()
	for s2 in [main.menu, main.settings_menu]:
		if s2 != null and s2.is_open():
			s2.close()

	# ---- playback
	main.mm.resume()
	await get_tree().create_timer(0.2).timeout
	main.auto_player.begin_play(main.robot, _canned())
	await get_tree().create_timer(0.25).timeout
	route.call()
	await get_tree().process_frame
	var head0: float = main.auto_player._t
	var drive0: Vector3 = main.robot.drive_command()
	var intake0: bool = main.robot.intake_on
	var aim0: bool = main.robot.auto_aim
	await get_tree().create_timer(hold_s).timeout
	_ok("  playback does not advance the playhead",
		"%.4f" % absf(main.auto_player._t - head0), "0.0000")
	_ok("  it is still playing", main.auto_player.playing, true)
	_ok("  the pending drive command is unchanged",
		main.robot.drive_command().distance_to(drive0) < 0.0001, true)
	_ok("  the intake flag is unchanged", main.robot.intake_on, intake0)
	_ok("  the aim flag is unchanged", main.robot.auto_aim, aim0)
	main.auto_player.stop_play()
	main._resume_match()
	await get_tree().create_timer(0.05).timeout
	for s3 in [main.menu, main.settings_menu]:
		if s3 != null and s3.is_open():
			s3.close()

## Resume has to continue the routine, not restart or skip it.
func _playback_resumes_where_it_stopped() -> void:
	main.mm.resume()
	await get_tree().create_timer(0.3).timeout
	main.auto_player.begin_play(main.robot, _canned())
	await get_tree().create_timer(0.4).timeout
	var head0: float = main.auto_player._t
	_ok("playback has started", head0 > 0.05, true)
	main._open_pause_menu()
	await get_tree().create_timer(1.0).timeout
	main._resume_match()
	await get_tree().create_timer(0.4).timeout
	var moved: float = main.auto_player._t - head0
	_ok("  resuming carries on from the same point",
		moved > 0.15 and moved < 0.8, true)
	_ok("  it did not restart from the beginning",
		main.auto_player._t > head0, true)
	main.auto_player.stop_play()

## A routine long enough that nothing below can run off the end of it.
func _canned() -> AutoRoutine:
	var rt := AutoRoutine.new()
	rt.start_recording()
	for i in 600:
		rt.capture(Vector3(0.0, 0.0, 0.5), false, false, false, true)
	return rt

## THE CONTROLLER DIAGNOSTICS MUST BE LIVE WHILE THE WORLD IS NOT.
##
## Settings is PROCESS_MODE_ALWAYS, so the Controls page keeps redrawing the
## live input preview with a match frozen behind it. The thing that must NOT
## happen is gameplay being woken up to make that work: the preview reads the
## hardware directly and sends nothing to the robot.
func _diagnostics_run_while_frozen() -> void:
	main.mm.resume()
	await get_tree().create_timer(0.3).timeout
	var ball := _stir()
	if ball == null:
		return
	await get_tree().physics_frame

	main.goto("Settings", 3)                       # straight to Controls
	await get_tree().process_frame
	_ok("opening Controls mid-match halts the world", BB.halted, true)
	var p0: Vector3 = ball.global_position
	var r0: Vector3 = main.robot.global_position
	var drive0: Vector3 = main.robot.drive_command()

	var sm = main.settings_menu
	_ok("  the settings screen keeps processing", sm.can_process(), true)
	_ok("  and the robot does not", main.robot.can_process(), false)
	var ticks := 0
	for i in 30:
		await get_tree().process_frame
		sm._process(0.016)                         # the live preview, by hand
		ticks += 1
	_ok("  the preview ran %d times while halted" % ticks, ticks, 30)
	_ok("  and nothing on the field moved",
		"%.4f" % (ball.global_position.distance_to(p0) / BB.IN), "0.0000")
	_ok("  the robot did not move",
		"%.4f" % (main.robot.global_position.distance_to(r0) / BB.IN), "0.0000")
	_ok("  and no command reached it",
		main.robot.drive_command().distance_to(drive0) < 0.0001, true)
	main.robot.auto_drive = false
	main.robot.set_drive(0.0, 0.0, 0.0)
	if sm.is_open():
		sm.close()
	main._resume_match()
	await get_tree().create_timer(0.05).timeout

## FREEZING BODIES IS NOT ENOUGH. A timer measured against the wall clock keeps
## running through a pause and silently expires behind the menu.
func _timers_hold() -> void:
	main.mm.resume()
	await get_tree().create_timer(0.3).timeout
	var r: Robot = main.robot
	var e: GameElement = main._spawn_pollen(BB.fp(0.0, 20.0, 14.0))
	await get_tree().physics_frame
	main.stats._on_launched(e, r)
	var made0: int = int(main.stats.per[r]["made"])
	r.manual_until = BB.sim_now() + BB.MANUAL_AIM_HOLD
	_ok("a manual-aim hold is running", r.manual_aim(), true)

	main._open_pause_menu()
	await get_tree().create_timer(BB.MANUAL_AIM_HOLD + 0.6).timeout
	_ok("  a wall-clock hold does not expire behind the menu",
		r.manual_aim(), true)
	main._resume_match()
	await get_tree().create_timer(0.05).timeout

	# the shot window must also have survived: this ball is still "in flight"
	main.stats._on_cell_entry(e, main.field.hives[r.alliance])
	_ok("  a shot in flight is still credited after a long pause",
		int(main.stats.per[r]["made"]) - made0, 1)
	e.queue_free()
	await get_tree().process_frame

## Resuming has to hand the world back exactly as it was, still moving.
func _resume_is_seamless() -> void:
	main.mm.resume()
	await get_tree().create_timer(0.3).timeout
	var ball := _stir()
	await get_tree().physics_frame
	# READ THE VELOCITY ONCE THE WORLD IS HALTED, not before. The first version
	# read it a frame before pausing with a 0.05 m/s tolerance — and one
	# physics step of gravity is 0.054 m/s, so it passed only when the pause
	# happened to land on the very next tick. The invariant is exact: what it
	# had when it stopped is what it has when it starts again.
	main._open_pause_menu()
	await get_tree().process_frame
	var v0: Vector3 = ball.linear_velocity
	await get_tree().create_timer(0.5).timeout
	_ok("while halted the ball's velocity is held exactly",
		ball.linear_velocity.distance_to(v0) < 0.0001, true)
	main._resume_match()
	# synchronously, before any physics step has run
	_ok("resuming hands back exactly the velocity it stopped with",
		ball.linear_velocity.distance_to(v0) < 0.0001, true)
	await get_tree().create_timer(0.3).timeout
	_ok("  and the world starts moving again", ball.linear_velocity.length() > 0.1, true)
	_ok("  and the attempt clock runs again",
		main.attempt == null or main.attempt.elapsed > 0.0, true)

func _ok(what: String, got: Variant, want: Variant) -> void:
	var pass_: bool = str(got) == str(want)
	if not pass_:
		fails += 1
	print("  %s %-56s got %s   want %s" % [
		"PASS" if pass_ else "FAIL", what, str(got), str(want)])
