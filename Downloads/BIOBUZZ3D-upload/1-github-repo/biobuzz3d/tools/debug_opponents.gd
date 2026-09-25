extends Node
## PRACTICE OPPONENTS, TESTED AS BEHAVIOUR ON THE REAL FIELD.
##
## Every case builds its situation through the ordinary Scenario Creator
## draft, runs it through the ordinary Test path (snapshot -> restore -> play),
## and then watches the real robot on the real field. Nothing here drives an
## opponent directly or reads a number the opponent computed about itself
## without also checking where the robot physically went.
##
## Two phases, as two processes, so that "a saved opponent resumes mid-wait"
## is proved across a real restart:
##   -- write   everything, and saves a situation captured mid-wait
##   -- read    cold start: loads it and checks the wait carried over

var main: Node3D
var fails := 0
var _me_goal := Vector2.INF
var _me_speed := 0.5
const SAVED := "opponent harness mid-wait"
const B := OpponentConfig.Behavior

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(2.5).timeout
	var args := OS.get_cmdline_user_args()
	if args.size() > 0 and String(args[0]) == "read":
		await _read_phase()
	else:
		await _stationary()
		await _route_order_and_waits()
		await _route_modes()
		await _pace()
		await _blocked_never_teleports()
		await _defend()
		await _collect()
		await _pause_freezes()
		await _save_and_retry()
		await _editor_draft_untouched()
		await _records_split()
		await _old_files()
		await _no_human_input()
	print("  %s  (%d failure%s)" % [
		"OPPONENTS BEHAVE" if fails == 0 else "OPPONENTS BROKEN",
		fails, "" if fails == 1 else "s"])
	get_tree().quit(1 if fails > 0 else 0)

# ================================================================= fixtures ==

## Author a situation the way a player would, and start it through Test.
## `me_at` places robot 1; `tweak` edits the opponent's settings dictionary.
func _spawn(b: int, tweak: Callable, at: Vector2, me_at := Vector2(-62, 4),
		staged := false, yaw := 90.0) -> AIDriver:
	await main._create_scenario("staged" if staged else "empty")
	var d: ScenarioDraft = main.editor.draft
	d.set_scenario("mode", BB.Mode.TELEOP_ONLY)
	d.set_scenario("phase", BB.Phase.TELEOP)
	d.set_scenario("time_left", 120.0)
	d.set_position("robot:0", Vector3(me_at.x, me_at.y, 0.0))
	var a := int(d.setup().get("alliance", BB.Alliance.RED))
	var foe := BB.Alliance.BLUE if a == BB.Alliance.RED else BB.Alliance.RED
	var id := d.add_robot(foe, true)
	d.set_position(id, Vector3(at.x, at.y, 0.0))
	d.set_yaw(id, yaw)
	d.set_opponent(id, "behavior", b)
	tweak.call(d.opponent(id))
	var errs := Snapshot.check_draft(d.to_snapshot()).filter(
		func(p: Dictionary) -> bool: return String(p["severity"]) == "error")
	if not errs.is_empty():
		print("    fixture problems: ", errs)
	await main._test_scenario(d.to_snapshot())
	await get_tree().create_timer(0.25).timeout
	for br in main.ais:
		if is_instance_valid(br) and br.robot.alliance == foe:
			return br
	_ok("the fixture produced an opponent", false, true)
	return null

func _secs(t: float) -> void:
	await get_tree().create_timer(t).timeout

## Drive robot 1 toward a field point each physics tick, like a scripted
## sparring partner. INF stops it.
func _physics_process(_d: float) -> void:
	if main == null or not is_instance_valid(main.robot) or _me_goal == Vector2.INF:
		return
	var me: Robot = main.robot
	me.auto_drive = true
	var loc := me.to_local(BB.fp(_me_goal.x, _me_goal.y, 0.0))
	var f := Vector2(loc.x, loc.z)
	if f.length() > BB.m(2.0):
		f = f.normalized() * _me_speed
		me.set_drive(f.x, 0.0, -f.y)
	else:
		me.set_drive(0, 0, 0)

func _stop_me() -> void:
	_me_goal = Vector2.INF
	if is_instance_valid(main.robot):
		main.robot.set_drive(0, 0, 0)

func _here(r: Robot) -> Vector2:
	return Vector2(r.fx(), r.fy())

# =============================================================== STATIONARY ==

func _stationary() -> void:
	print("\n--- STATIONARY ---")
	var br := await _spawn(B.STATIONARY, func(_c: Dictionary) -> void: pass,
		Vector2(45, -45))
	if br == null:
		return
	var r: Robot = br.robot
	var home := _here(r)
	await _secs(2.0)
	_ok("it holds its position", _here(r).distance_to(home) < 1.0, true)
	_ok("  and says so", br.status, "Holding position")
	_ok("  with its intake off: it does not collect", r.intake_on, false)
	_ok("  and nothing in its hopper", r.hopper.size(), 0)

	# A REAL ROBOT, NOT A WALL: an impulse moves it
	r.apply_central_impulse(Vector3(r.mass * 1.2, 0.0, 0.0))
	await _secs(0.25)
	var shoved := _here(r).distance_to(home)
	_ok("a shove moves it (it is not an immovable wall)", shoved > 4.0, true)
	print("    shoved %.1f in" % shoved)
	await _secs(0.15)
	_ok("  and it notices", br.status.begins_with("Returning")
		or br.status.begins_with("Holding position (pushed"), true)
	await _secs(4.0)
	_ok("  then drives itself back to within %.0f in" % br.HOLD_TOL,
		_here(r).distance_to(home) <= br.HOLD_TOL + 0.5, true)
	print("    back to %.1f in from home" % _here(r).distance_to(home))
	_ok("  using its drivetrain, not a reset: it was never frozen", r.freeze, false)

# ==================================================================== ROUTE ==

func _route_order_and_waits() -> void:
	print("\n--- ROUTE: ORDER AND WAITS ---")
	var br := await _spawn(B.ROUTE, func(c: Dictionary) -> void:
		c["waypoints"] = [{"x": 45.0, "y": -50.0, "wait": 1.5},
			{"x": 58.0, "y": 0.0, "wait": 0.0}, {"x": 45.0, "y": 50.0, "wait": 0.0}]
		c["route_mode"] = float(OpponentConfig.RouteMode.STOP), Vector2(45, -66))
	if br == null:
		return
	var seen: Array[int] = []
	var waited := 0.0
	var t := 0.0
	while t < 12.0 and not br._done:
		await get_tree().physics_frame
		t += 1.0 / 180.0
		if seen.is_empty() or seen[-1] != br._wp:
			seen.append(br._wp)
		if br.status.begins_with("Waiting"):
			waited += 1.0 / 180.0
	_ok("waypoints are driven in order", str(seen), "[0, 1, 2]")
	_ok("  it waited at waypoint 1 for its 1.5 s", absf(waited - 1.5) < 0.1, true)
	print("    measured wait %.2f s" % waited)
	_ok("  Stop at end stops", br._done, true)
	_ok("  and says so", br.status, "Route complete")
	# it arrives moving and brakes like any robot; judge it once settled
	await _secs(1.0)
	var last := _here(br.robot)
	await _secs(1.5)
	_ok("  and, once it has braked, stays stopped",
		_here(br.robot).distance_to(last) < 0.5, true)
	_ok("  near the last waypoint",
		_here(br.robot).distance_to(Vector2(45, 50)) <= 7.0, true)

func _route_modes() -> void:
	print("\n--- ROUTE: TRAVERSAL MODES ---")
	for spec in [[OpponentConfig.RouteMode.LOOP, "[0, 1, 2, 0, 1]"],
			[OpponentConfig.RouteMode.BACK_AND_FORTH, "[0, 1, 2, 1, 0]"]]:
		var br := await _spawn(B.ROUTE, func(c: Dictionary) -> void:
			c["waypoints"] = [{"x": 45.0, "y": -50.0, "wait": 0.0},
				{"x": 58.0, "y": 0.0, "wait": 0.0}, {"x": 45.0, "y": 50.0, "wait": 0.0}]
			c["route_mode"] = float(spec[0]), Vector2(45, -66))
		if br == null:
			return
		var seen: Array[int] = []
		var t := 0.0
		while t < 16.0 and seen.size() < 5:
			await get_tree().physics_frame
			t += 1.0 / 180.0
			if seen.is_empty() or seen[-1] != br._wp:
				seen.append(br._wp)
		_ok("%s visits waypoints %s" % [OpponentConfig.ROUTE_MODES[int(spec[0])],
			String(spec[1])], str(seen), String(spec[1]))

## PACE CAPS THE COMMAND, and the command is what moves the robot.
func _pace() -> void:
	print("\n--- PACE ---")
	var speeds := {}
	for pace in [0.3, 0.8]:
		var br := await _spawn(B.ROUTE, func(c: Dictionary) -> void:
			c["pace"] = pace
			c["waypoints"] = [{"x": 45.0, "y": -50.0, "wait": 0.0},
				{"x": 45.0, "y": 50.0, "wait": 0.0}]
			c["route_mode"] = float(OpponentConfig.RouteMode.STOP), Vector2(45, -52))
		if br == null:
			return
		await _secs(1.2)                   # up to speed, mid-leg
		var p0 := _here(br.robot)
		await _secs(0.6)
		speeds[pace] = _here(br.robot).distance_to(p0) / 0.6
		print("    pace %.0f%%  ->  %.1f in/s" % [pace * 100.0, float(speeds[pace])])
	var top: float = main.robot.max_speed_in_s
	_ok("30% pace is well under full speed", float(speeds[0.3]) < top * 0.4, true)
	_ok("  80% pace is much faster than 30%",
		float(speeds[0.8]) > float(speeds[0.3]) * 2.0, true)
	_ok("  and never exceeds what a full stick could do",
		float(speeds[0.8]) <= top * 1.02, true)

## BLOCKED: a wall across the whole field. It must stop, say so, try a
## bounded recovery, and never pass through or jump.
func _blocked_never_teleports() -> void:
	print("\n--- BLOCKED ---")
	var br := await _spawn(B.ROUTE, func(c: Dictionary) -> void:
		c["waypoints"] = [{"x": 45.0, "y": -55.0, "wait": 0.0},
			{"x": 45.0, "y": 40.0, "wait": 0.0}]
		c["route_mode"] = float(OpponentConfig.RouteMode.STOP), Vector2(45, -58))
	if br == null:
		return
	var wall := StaticBody3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(BB.m(150.0), BB.m(20.0), BB.m(2.0))
	var col := CollisionShape3D.new()
	col.shape = shape
	wall.add_child(col)
	wall.set_collision_layer_value(BB.LAYER_WORLD, true)
	main.add_child(wall)
	wall.global_position = BB.fp(0.0, -20.0, 10.0)
	var worst_jump := 0.0
	var max_y := -999.0
	var saw_blocked := false
	var saw_recover := false
	var prev := _here(br.robot)
	var t := 0.0
	while t < 12.0:
		await get_tree().physics_frame
		t += 1.0 / 180.0
		var p := _here(br.robot)
		worst_jump = maxf(worst_jump, p.distance_to(prev))
		prev = p
		max_y = maxf(max_y, p.y)
		if br.status.begins_with("Blocked — waiting"):
			saw_blocked = true
		if br.status == "Blocked — recovering":
			saw_recover = true
	_ok("a blocked robot tries a recovery", saw_recover, true)
	_ok("  then waits, saying it is blocked", saw_blocked, true)
	_ok("  it never gets past the wall", max_y < -20.0, true)
	_ok("  and never jumps: largest move in one tick %.2f in" % worst_jump,
		worst_jump < 1.0, true)
	wall.queue_free()

# =================================================================== DEFEND ==

func _defend() -> void:
	print("\n--- DEFEND ---")
	var c := Vector2(45, -40)
	var radius := 30.0
	var br := await _spawn(B.DEFEND, func(cfg: Dictionary) -> void:
		cfg["area"] = {"x": c.x, "y": c.y}
		cfg["radius"] = radius
		cfg["target"] = 0, c, Vector2(-55, -40))
	if br == null:
		return
	_ok("it defends against robot 1", br.defended_robot() == main.robot, true)
	await _secs(0.8)
	_ok("with robot 1 far away it holds its area", br.status, "Holding area")

	var worst := 0.0
	var engaged_ok := false
	var legs := [[Vector2(20, -40), 3.0], [Vector2(45, -20), 3.0],
		[Vector2(60, -60), 3.0], [Vector2(62, 55), 5.0]]
	for leg in legs:
		_me_goal = leg[0]
		var t := 0.0
		while t < float(leg[1]):
			await get_tree().physics_frame
			t += 1.0 / 180.0
			worst = maxf(worst, _here(br.robot).distance_to(c))
			if br.status.begins_with("Defending"):
				# between robot 1 and the middle of its area
				var me := _here(main.robot)
				if _here(br.robot).distance_to(c) < me.distance_to(c):
					engaged_ok = true
	_stop_me()
	_ok("it put itself between robot 1 and the middle of its area",
		engaged_ok, true)
	_ok("  it went back when robot 1 left",
		br.status == "Holding area" or br.status == "Returning to area", true)
	_ok("  its centre never left the area by more than 12 in (documented tolerance)",
		worst <= radius + 12.0, true)
	print("    furthest from the centre: %.1f in (radius %.0f)" % [worst, radius])
	_ok("  it does not chase: robot 1 is %.0f in away" % _here(main.robot).distance_to(c),
		_here(br.robot).distance_to(c) <= radius + 1.0, true)

# ================================================================== COLLECT ==

func _collect() -> void:
	print("\n--- COLLECT AND SCORE ---")
	var br := await _spawn(B.COLLECT, func(_c: Dictionary) -> void: pass,
		Vector2(50, -30), Vector2(-62, 4), true)
	if br == null:
		return
	br.robot.takes_nectar = true             # even an intake that COULD take nectar
	var over_cap := false
	var shots0: int = int(main.stats.summary(br.robot).get("shots", 0))
	var t := 0.0
	while t < 24.0:
		await get_tree().physics_frame
		t += 1.0 / 180.0
		if br.robot.hopper.size() > BB.HOPPER_CAP:
			over_cap = true
	var nectar_held := 0
	for e in br.robot.hopper:
		if is_instance_valid(e) and (e as GameElement).kind == BB.Kind.NECTAR:
			nectar_held += 1
	var shots: int = int(main.stats.summary(br.robot).get("shots", 0)) - shots0
	_ok("it never holds more than the hopper allows", over_cap, false)
	_ok("  never goes for NECTAR, even with an intake that takes it",
		br._target == null or br._target.kind == BB.Kind.POLLEN, true)
	_ok("  it shot with the ordinary launcher (%d shots)" % shots, shots > 0, true)

	# nothing compatible on the field: it waits and keeps checking
	var idle := await _spawn(B.COLLECT, func(_c: Dictionary) -> void: pass,
		Vector2(50, -30))
	if idle == null:
		return
	var p0 := _here(idle.robot)
	await _secs(1.5)
	_ok("with nothing to collect it waits", idle.status,
		"Waiting: no compatible elements")
	_ok("  and does not wander", _here(idle.robot).distance_to(p0) < 2.0, true)
	var e2: GameElement = main._spawn_pollen(BB.fp(50.0, 10.0, 1.4))
	# one second of SIMULATION, not of wall clock: on a loaded machine a
	# wall-clock second can hold fewer ticks than the brain's check interval,
	# which made this check fail intermittently without anything being wrong
	var s0 := BB.sim_now()
	while BB.sim_now() - s0 < 1.0:
		await get_tree().physics_frame
	_ok("  a ball appearing is noticed on its next check", idle.status, "Collecting")
	e2.queue_free()

# ==================================================================== PAUSE ==

func _pause_freezes() -> void:
	print("\n--- PAUSE ---")
	var br := await _spawn(B.ROUTE, func(c: Dictionary) -> void:
		c["waypoints"] = [{"x": 45.0, "y": -50.0, "wait": 5.0},
			{"x": 45.0, "y": 40.0, "wait": 0.0}], Vector2(45, -52))
	if br == null:
		return
	var t := 0.0
	while t < 3.0 and br._wait_left <= 0.0:
		await get_tree().physics_frame
		t += 1.0 / 180.0
	await _secs(0.5)
	var w0: float = br._wait_left
	var p0 := _here(br.robot)
	var s0: String = br.status
	main._open_pause_menu()
	await _secs(1.5)
	_ok("paused mid-wait, the remaining wait does not move",
		"%.3f" % br._wait_left, "%.3f" % w0)
	_ok("  nor does the robot", _here(br.robot).distance_to(p0) < 0.01, true)
	_ok("  nor its decision", br.status, s0)
	main._resume_match()
	await _secs(0.5)
	_ok("  resuming carries the wait on from where it was",
		br._wait_left < w0 and br._wait_left > w0 - 0.8, true)

	# a travelling opponent freezes mid-drive too
	await _secs(max(0.0, br._wait_left) + 1.0)
	var p1 := _here(br.robot)
	main.goto("Settings")
	await _secs(1.0)
	_ok("paused mid-drive via Settings, it does not move",
		_here(br.robot).distance_to(p1) < 0.01, true)
	main._resume_match()
	for s in [main.menu, main.settings_menu]:
		if s != null and s.is_open():
			s.close()

# ============================================================ SAVE / RETRY ===

func _save_and_retry() -> void:
	print("\n--- SAVE, LOAD AND RETRY MID-WAIT ---")
	var br := await _spawn(B.ROUTE, func(c: Dictionary) -> void:
		c["waypoints"] = [{"x": 45.0, "y": -50.0, "wait": 4.0},
			{"x": 58.0, "y": 0.0, "wait": 0.0}, {"x": 45.0, "y": 40.0, "wait": 0.0}]
		c["route_mode"] = float(OpponentConfig.RouteMode.BACK_AND_FORTH),
		Vector2(45, -52))
	if br == null:
		return
	var t := 0.0
	while t < 3.0 and br._wait_left <= 0.0:
		await get_tree().physics_frame
		t += 1.0 / 180.0
	await _secs(1.0)
	main.mm.pause()
	var wait_saved: float = br._wait_left
	var wp_saved: int = br._wp
	var snap := Snapshot.capture(main)
	var id := ScenarioLibrary.save(snap, SAVED, "saved mid-wait by debug_opponents")
	_ok("a situation was captured mid-wait (%.2f s left)" % wait_saved,
		wait_saved > 0.5 and wait_saved < 3.5, true)

	# load it: this restores the ORIGINAL opponent conditions, not a default one
	await main.play_situation(id)
	main.mm.pause()
	var nb := _foe_brain()
	print("    saved wait %.3f   loaded wait %.3f" % [wait_saved, nb._wait_left if nb else -1.0])
	_ok("loading resumes at the same waypoint", nb._wp if nb else -1, wp_saved)
	_ok("  with the remaining wait, not a fresh one",
		nb != null and absf(nb._wait_left - wait_saved) < 0.05, true)
	_ok("  and the same behavior and settings",
		nb != null and nb.behavior() == B.ROUTE
		and int(nb.config["route_mode"]) == OpponentConfig.RouteMode.BACK_AND_FORTH, true)

	# let it run on, then retry: back to the SAVED state, not where it got to
	main.mm.resume()
	await _secs(3.5)
	var moved_on: int = nb._wp if nb else -1
	await main.retry_situation()
	main.mm.pause()
	var rb := _foe_brain()
	_ok("it had moved on before the retry", moved_on != wp_saved, true)
	_ok("retry restores the saved waypoint", rb._wp if rb else -1, wp_saved)
	_ok("  and the saved remaining wait",
		rb != null and absf(rb._wait_left - wait_saved) < 0.05, true)
	main.mm.resume()

func _foe_brain() -> AIDriver:
	for b in main.ais:
		if is_instance_valid(b) and b.robot.alliance != main.robot.alliance:
			return b
	return null

## TEST -> RETRY -> RETURN must leave the draft exactly as it was.
func _editor_draft_untouched() -> void:
	print("\n--- TEST, RETRY, RETURN ---")
	await main._create_scenario("empty")
	var d: ScenarioDraft = main.editor.draft
	var a := int(d.setup().get("alliance", BB.Alliance.RED))
	var id := d.add_robot(BB.Alliance.BLUE if a == BB.Alliance.RED else BB.Alliance.RED, true)
	d.set_position(id, Vector3(45, -50, 0))
	d.set_opponent(id, "behavior", B.ROUTE)
	var cfg := d.opponent(id)
	cfg["waypoints"] = [{"x": 45.0, "y": -50.0, "wait": 2.0}, {"x": 45.0, "y": 40.0, "wait": 0.0}]
	var before := _content(d.to_snapshot())
	await main._test_scenario(d.to_snapshot())
	await _secs(2.5)
	await main.retry_situation()
	await _secs(1.5)
	await main.return_to_editor()
	await get_tree().create_timer(0.3).timeout
	var after := _content(main.editor.draft.to_snapshot())
	if after != before:
		var a0: Dictionary = JSON.parse_string(before)
		var a1: Dictionary = JSON.parse_string(after)
		for k in a0:
			if JSON.stringify(a0[k]) != JSON.stringify(a1.get(k)):
				print("    differs in: ", k)
				if k == "robots":
					for i in (a0[k] as Array).size():
						for kk in (a0[k][i] as Dictionary):
							if JSON.stringify(a0[k][i][kk]) != JSON.stringify(a1[k][i].get(kk)):
								print("      robot %d.%s: %s  ->  %s" % [i, kk,
									JSON.stringify(a0[k][i][kk]).substr(0, 90),
									JSON.stringify(a1[k][i].get(kk)).substr(0, 90)])
	_ok("after test, retry and return the draft content is unchanged",
		after == before, true)
	main.editor.draft.dirty = false
	main.editor._try_close()
	await get_tree().create_timer(0.3).timeout

## Everything in a draft except `saved`, which to_snapshot() stamps with the
## wall-clock time on every call and so differs between any two calls.
func _content(d: Dictionary) -> String:
	var c := d.duplicate(true)
	c.erase("saved")
	return JSON.stringify(c)

## A BEST EARNED AGAINST A GENTLE OPPONENT IS NOT A BEST AGAINST A HARD ONE.
func _records_split() -> void:
	print("\n--- PRACTICE RECORDS ---")
	await main._create_scenario("empty")
	var d: ScenarioDraft = main.editor.draft
	var obj := {"kind": Objective.Kind.REACH, "area": {"x": 50.0, "y": 0.0, "r": 18.0},
		"target": Objective.Target.ROBOT, "robot": 0, "amount": 1}
	var a := int(d.setup().get("alliance", BB.Alliance.RED))
	var id := d.add_robot(BB.Alliance.BLUE if a == BB.Alliance.RED else BB.Alliance.RED, true)
	d.set_opponent(id, "behavior", B.DEFEND)
	d.set_opponent(id, "preset", "Gentle")
	var s_gentle := AttemptLog.signature(d.to_snapshot(), obj)
	d.set_opponent(id, "preset", "Challenging")
	var s_hard := AttemptLog.signature(d.to_snapshot(), obj)
	_ok("changing the opponent preset starts a new comparison group",
		s_gentle != s_hard, true)
	d.set_opponent(id, "radius", 45.0)
	_ok("  so does changing a setting outside the preset (area size)",
		AttemptLog.signature(d.to_snapshot(), obj) != s_hard, true)
	_ok("  which leaves the preset label alone, because size is not difficulty",
		OpponentConfig.preset_name(d.opponent(id)), "Challenging")
	d.set_opponent(id, "pace", 0.70)
	_ok("  editing a preset value makes the label Custom",
		OpponentConfig.preset_name(d.opponent(id)), "Custom")
	d.set_opponent(id, "radius", 30.0)
	d.set_opponent(id, "preset", "Challenging")
	_ok("  setting it back rejoins the original group",
		AttemptLog.signature(d.to_snapshot(), obj), s_hard)
	main.editor.draft.dirty = false
	main.editor._try_close()
	await get_tree().create_timer(0.3).timeout

## Situations from before this feature must load, read as the opponent they
## always had, and keep their practice history.
func _old_files() -> void:
	print("\n--- OLD SCENARIOS ---")
	await main._create_scenario("staged")
	var d: ScenarioDraft = main.editor.draft
	var a := int(d.setup().get("alliance", BB.Alliance.RED))
	var id := d.add_robot(BB.Alliance.BLUE if a == BB.Alliance.RED else BB.Alliance.RED, true)
	var snap := d.to_snapshot()
	main.editor.draft.dirty = false
	main.editor._try_close()
	await get_tree().create_timer(0.3).timeout
	# rewrite it the way an old file looked: the collect AI's fields only
	for r in snap["robots"]:
		if bool(r.get("ai", false)):
			r["brain"] = {"mode": 0, "target": "", "stuck": 0.0, "best_dist": 1e9,
				"unstick_side": 1.0, "unstick": 0.0, "think": 0.1}
	var sig_old := AttemptLog.signature(snap, {})
	var legacy_copy: Dictionary = snap.duplicate(true)
	for r2 in legacy_copy["robots"]:
		r2.erase("brain")
	_ok("an old file's comparison group is unchanged by this feature",
		sig_old, AttemptLog.signature(legacy_copy, {}))
	_ok("  it still validates", Snapshot.validate(snap), "")
	var lid := ScenarioLibrary.save(snap, "opponent harness legacy", "old format")
	await main.play_situation(lid)
	await _secs(0.4)
	var br := _foe_brain()
	_ok("  it loads, and its opponent is Collect and score",
		br != null and br.behavior() == B.COLLECT, true)
	_ok("  at the Standard preset — the opponent it always was",
		OpponentConfig.preset_name(br.config) if br else "", "Standard")
	ScenarioLibrary.delete_one(lid)

	# malformed opponent data must not crash anything
	var bad := OpponentConfig.sanitize({"behavior": 99, "pace": "fast",
		"waypoints": [{"x": 1e20, "y": 3}, "nonsense", {"x": 10, "y": 10, "wait": -4}],
		"target": "robot one", "area": {"x": NAN}})
	_ok("an unknown behavior falls back to Collect", int(bad["behavior"]), B.COLLECT)
	_ok("  a non-numeric pace falls back to the default",
		"%.2f" % OpponentConfig.get_f(bad, "pace"), "0.55")
	_ok("  malformed waypoints are dropped, good ones kept",
		(bad["waypoints"] as Array).size(), 1)
	_ok("  and a negative wait is clamped to zero",
		"%.1f" % float((bad["waypoints"] as Array)[0]["wait"]), "0.0")
	var probs := OpponentConfig.check({"behavior": B.DEFEND, "target": 7}, 1,
		[{"index": 0, "alliance": 0}, {"index": 1, "alliance": 1}])
	_ok("a defender with a missing target is reported, beside that setting",
		not probs.is_empty() and String(probs[0]["setting"]) == "target", true)

## Opponents drive through set_drive(), which is downstream of every human
## input setting, and they never sit in a controller seat.
func _no_human_input() -> void:
	print("\n--- OPPONENTS AND THE CONTROLLER SYSTEM ---")
	var stock := ControlProfile.get_one(ControlProfile.STOCK_ID)
	var dz := stock.get_tuning("move_deadzone")
	stock.set_tuning("move_deadzone", 0.40)
	stock.set_tuning("invert_move_y", 1.0)
	ControlProfile.save_one(stock)
	DriverInput.refresh_profiles()
	var br := await _spawn(B.ROUTE, func(c: Dictionary) -> void:
		c["waypoints"] = [{"x": 45.0, "y": -50.0, "wait": 0.0},
			{"x": 45.0, "y": 50.0, "wait": 0.0}]
		c["route_mode"] = float(OpponentConfig.RouteMode.STOP), Vector2(45, -52))
	if br != null:
		_ok("an opponent holds no controller", br.robot.device, DriverInput.NONE)
		_ok("  and no operator device", br.robot.op_device, DriverInput.NONE)
		var y0 := br.robot.fy()
		await _secs(1.5)
		_ok("  a huge deadzone and inverted Y on the human profile do not affect it",
			br.robot.fy() > y0 + 20.0, true)
		var seats := Settings.seat_plan(1, false, 1)
		_ok("  and the seat plan still has exactly one human seat", seats.size(), 1)
	stock.set_tuning("move_deadzone", dz)
	stock.set_tuning("invert_move_y", 0.0)
	ControlProfile.save_one(stock)
	DriverInput.refresh_profiles()

# ===================================================================== read ==

func _read_phase() -> void:
	print("\n--- COLD START: THE SAVED MID-WAIT OPPONENT ---")
	var found := ""
	for e in ScenarioLibrary.list_all():
		if String(e["name"]) == SAVED:
			found = String(e["id"])
	_ok("the mid-wait situation survived a restart", found != "", true)
	if found == "":
		return
	var entry := ScenarioLibrary.load_one(found)
	var saved_wait := 0.0
	for r in (entry["data"] as Dictionary).get("robots", []):
		var br: Variant = (r as Dictionary).get("brain")
		if br is Dictionary and (br as Dictionary).has("wait_left"):
			saved_wait = float((br as Dictionary)["wait_left"])
	await main.play_situation(found)
	main.mm.pause()
	var b := _foe_brain()
	_ok("  its opponent resumes with the saved remaining wait",
		b != null and absf(b._wait_left - saved_wait) < 0.1, true)
	_ok("  still a route opponent", b != null and b.behavior() == B.ROUTE, true)
	ScenarioLibrary.delete_one(found)

func _ok(what: String, got: Variant, want: Variant) -> void:
	var pass_: bool = str(got) == str(want)
	if not pass_:
		fails += 1
	print("  %s %-62s got %s   want %s" % [
		"PASS" if pass_ else "FAIL", what, str(got), str(want)])
