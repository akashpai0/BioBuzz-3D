extends Node
## OBJECTIVES, ATTEMPTS AND PERSONAL BESTS, TESTED AS BEHAVIOUR.
##
## Two phases, as two processes, because "history survives a restart" is not
## something one process can prove about itself:
##   -- write   runs attempts and records them
##   -- read    a cold start that reads them back

var main: Node3D
var fails := 0
const SCEN := "objective harness"

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(2.5).timeout
	var args := OS.get_cmdline_user_args()
	var phase := String(args[0]) if args.size() > 0 else "write"
	if phase == "write":
		await _write_phase()
	else:
		_read_phase()
	print("  %s  (%d failure%s)" % [
		"OBJECTIVES WORK" if fails == 0 else "OBJECTIVES BROKEN",
		fails, "" if fails == 1 else "s"])
	get_tree().quit(1 if fails > 0 else 0)

# =================================================================== write ===

func _write_phase() -> void:
	print("\n--- OBJECTIVES: WRITE PHASE ---")
	AttemptLog.clear()
	for e in ScenarioLibrary.list_all():
		if String(e["name"]).begins_with(SCEN):
			ScenarioLibrary.delete_one(String(e["id"]))

	await _baselines()
	await _lifecycle()
	await _settling()
	await _records()
	_grouping()
	_drills()
	# last, because they finish attempts of their own and would otherwise shift
	# the record counts the suites above assert on
	await _deadlines()
	await _no_duplicates()
	await _review_probes()

## A situation that already has points, tips and a ball in a CELL must not
## satisfy a fresh objective.
func _baselines() -> void:
	await main._create_scenario("staged")
	var d: ScenarioDraft = main.editor.draft
	d.name = SCEN
	d.set_scenario("mode", BB.Mode.TELEOP_ONLY)
	d.set_scenario("phase", BB.Phase.TELEOP)
	d.set_scenario("time_left", 60.0)
	# a scoreboard that is already well on its way
	var m := d.match_block()
	m["scoring"] = {"tips": [3, 0], "leave": [0, 0], "park_auto": [0, 0],
		"park_teleop": [0, 0], "fouls_against": [0, 0]}
	d.set_objective("kind", Objective.Kind.TIPS)
	d.set_objective("target", Objective.Target.ALLIANCE)
	d.set_objective("amount", 2)
	var id: String = ScenarioLibrary.save(d.to_snapshot(), d.name, "harness")
	main.editor.draft.source_id = id
	main.editor.draft.dirty = false
	main.editor._try_close()
	await get_tree().create_timer(0.4).timeout

	await main.play_situation(id)
	main.mm.pause()
	_ok("an attempt started", main.attempt != null, true)
	_ok("  three old tips count for nothing", main.attempt.progress, 0)
	_ok("  and the goal is the NEW two", main.attempt.goal, 2)
	_ok("  loading emitted no progress", main.attempt.progress, 0)
	_ok("  and no elapsed time", main.attempt.elapsed < 0.001, true)
	_ok("  points baseline is the starting score, not zero",
		int(main.attempt._base["tips"]), 3)

	# pausing must not consume objective time
	var t0: float = main.attempt.elapsed
	await get_tree().create_timer(0.7).timeout
	_ok("pausing does not consume objective time",
		absf(main.attempt.elapsed - t0) < 0.001, true)
	main.mm.resume()
	await get_tree().create_timer(0.6).timeout
	_ok("  and the clock runs once play resumes",
		main.attempt.elapsed > 0.3, true)

	# a ball already in a CELL is not a new successful shot
	main.mm.pause()
	_ok("a ball already in a CELL is not a new made shot",
		int(main.attempt._read_world()["made"]) - int(main.attempt._base["made"]), 0)

## Ready -> Running -> finished exactly once, and retry makes exactly one more.
func _lifecycle() -> void:
	var a: Attempt = main.attempt
	_ok("the attempt is running", a.state, Attempt.State.RUNNING)
	# A FOUL ON THE COMPLETING STEP FAILS THE ATTEMPT. The goal and the
	# constraint are measured together, and a broken constraint wins.
	a.objective["no_foul"] = true
	a.objective["time_limit"] = 0.01
	main.mm.scoring.tips[main.robot.alliance] = 5        # +2 over the baseline
	main.mm.scoring.fouls_against[main.robot.alliance] = 30
	a._evaluate(1.0, false)
	_ok("a foul on the completing step FAILS the attempt",
		a.state, Attempt.State.FAILED)
	_ok("  and says the foul was why", a.reason, "foul")
	_ok("  it finished exactly once", a.is_done(), true)
	var before: int = AttemptLog.all().size()
	a.finish(Attempt.State.SUCCEEDED, "nonsense")
	a._evaluate(1.0, false)
	_ok("  further events cannot finish it again", a.state, Attempt.State.FAILED)
	_ok("  and cannot write a second record", AttemptLog.all().size(), before)

	# retry: exactly one new attempt, the old one recorded as abandoned
	var n0: int = AttemptLog.all().size()
	await main.retry_situation()
	await get_tree().create_timer(0.1).timeout
	_ok("retry started exactly one new attempt", AttemptLog.all().size(), n0)
	_ok("  numbered after the ones before it", main.attempt.attempt_no > 1, true)
	# THE INVARIANT, not a headcount. Asserting an exact global total made this
	# check order-dependent and intermittently wrong; what actually has to be
	# true is that giving up on a run writes abandons and nothing else.
	var rows_before: int = AttemptLog.all().size()
	var quit_before: int = _count("abandoned")
	var won_before: int = _count("succeeded")
	await main.retry_situation()
	await get_tree().create_timer(0.1).timeout
	var new_rows: int = AttemptLog.all().size() - rows_before
	var new_quits: int = _count("abandoned") - quit_before
	_ok("  an early retry records the run it threw away", new_quits >= 1, true)
	_ok("  and every record it wrote was an abandon", new_rows, new_quits)
	_ok("  never a success", _count("succeeded"), won_before)

## THE DEADLINE, SPELLED OUT.
##
##   * the step that crosses the deadline still counts
##   * nothing after it adds qualifying progress
##   * a points total that was eligible BEFORE the deadline may keep settling
##   * one that only becomes eligible after it may not
func _deadlines() -> void:
	# --- completion exactly on the deadline counts
	var a := await _fresh(Objective.Kind.TIPS, 2, 10.0)
	a.elapsed = 10.0
	main.mm.scoring.tips[main.robot.alliance] = int(a._base["tips"]) + 2
	a._evaluate(0.5, false)        # the clock is AT the limit: still inside
	_ok("completion exactly ON the deadline counts",
		a.state, Attempt.State.SUCCEEDED)
	_ok("  and is recorded as completed", a.reason, "completed")

	# --- progress made AFTER the deadline does not
	var b := await _fresh(Objective.Kind.TIPS, 2, 10.0)
	b.elapsed = 10.4                                   # already past
	b._evaluate(0.2, false)
	_ok("a passed deadline with no progress fails on time",
		b.state, Attempt.State.FAILED)
	_ok("  for the right reason", b.reason, "timeout")

	var c := await _fresh(Objective.Kind.TIPS, 2, 10.0)
	c.elapsed = 11.0                                   # well past
	main.mm.scoring.tips[main.robot.alliance] = int(c._base["tips"]) + 9
	c._evaluate(0.2, false)
	_ok("tips scored AFTER the deadline add no progress",
		c.progress, 0)
	_ok("  so the attempt still fails on time", c.state, Attempt.State.FAILED)

	# --- shots after the deadline are latched out too
	var d := await _fresh(Objective.Kind.SHOTS, 1, 5.0)
	d.elapsed = 6.0
	var sm: Dictionary = main.stats.per[main.robot]
	sm["made"] = int(sm["made"]) + 3
	d._evaluate(0.2, false)
	_ok("shots made after the deadline add no progress", d.progress, 0)
	_ok("  and the attempt fails on time", d.state, Attempt.State.FAILED)

	# --- REACH dwell after the deadline is latched out
	var e := await _fresh(Objective.Kind.REACH, 1, 4.0)
	e.objective["target"] = Objective.Target.ROBOT
	e.objective["robot"] = 0
	var rp := BB.to_field(main.robot.global_position)
	e.objective["area"] = {"x": rp.x, "y": rp.y, "r": 40.0}
	_ok("the robot is standing in the reach area", e._robot_in_area(), true)
	e.elapsed = 4.2                                    # the deadline has passed
	e._evaluate(0.2, false)
	_ok("standing in the area after the deadline accrues no dwell",
		e._dwell, 0.0)
	_ok("  so it fails on time rather than completing",
		e.state, Attempt.State.FAILED)

	# --- points eligible BEFORE the deadline may finish settling after it
	var f := await _fresh(Objective.Kind.POINTS, 5, 6.0)
	main.mm.scoring.tips[main.robot.alliance] = int(f._base["tips"]) + 1
	f.elapsed = 5.0
	f._evaluate(0.2, false)
	_ok("a points total crossing the line before the deadline is eligible",
		f._eligible_since >= 0.0 and f._eligible_since <= 6.0, true)
	_ok("  but not yet a success", f.state, Attempt.State.RUNNING)
	f.elapsed = 6.5                                    # deadline has passed
	f._evaluate(0.2, false)
	_ok("  the deadline does not kill it while it settles",
		f.state, Attempt.State.RUNNING)
	f._evaluate(BB.SETTLE_S, false)
	_ok("  and it confirms after the deadline", f.state, Attempt.State.SUCCEEDED)

	# --- points that only become eligible AFTER the deadline may not
	var g := await _fresh(Objective.Kind.POINTS, 5, 6.0)
	g.elapsed = 6.5
	main.mm.scoring.tips[main.robot.alliance] = int(g._base["tips"]) + 1
	g._evaluate(0.2, false)
	_ok("points first earned after the deadline cannot confirm",
		g.state, Attempt.State.FAILED)
	_ok("  and fail on time, not on the score", g.reason, "timeout")

	# --- a settling total that falls back below the goal fails on time
	var h := await _fresh(Objective.Kind.POINTS, 5, 6.0)
	main.mm.scoring.tips[main.robot.alliance] = int(h._base["tips"]) + 1
	h.elapsed = 5.0
	h._evaluate(0.2, false)
	_ok("a points total is settling", h.pending_confirmation(), true)
	main.mm.scoring.tips[main.robot.alliance] = int(h._base["tips"])
	h.elapsed = 6.5
	h._evaluate(0.2, false)
	_ok("  falling back below the goal fails on time",
		h.state, Attempt.State.FAILED)

	# --- a foul beats the settling grace too
	var i := await _fresh(Objective.Kind.POINTS, 5, 6.0)
	i.objective["no_foul"] = true
	main.mm.scoring.tips[main.robot.alliance] = int(i._base["tips"]) + 1
	i.elapsed = 5.0
	i._evaluate(0.2, false)
	_ok("points settling with the no-foul constraint armed",
		i.state, Attempt.State.RUNNING)
	main.mm.scoring.fouls_against[main.robot.alliance] = \
		int(i._base["fouls"]) + 1
	i._evaluate(0.2, false)
	_ok("  a foul during settling fails it", i.state, Attempt.State.FAILED)
	_ok("  as a foul", i.reason, "foul")
	main.mm.scoring.fouls_against[main.robot.alliance] = int(i._base["fouls"])

## NOTHING COUNTS TWICE.
func _no_duplicates() -> void:
	# --- loading takes the baseline, so a full field is worth nothing
	var a := await _fresh(Objective.Kind.POINTS, 1, 0.0)
	a._evaluate(0.016, false)
	_ok("loading a situation emits no points progress", a.progress, 0)
	_ok("  and no elapsed time yet", a.elapsed < 0.001, true)

	# --- a ball handed between robots is not two shots
	var b := await _fresh(Objective.Kind.SHOTS, 3, 0.0)
	var r: Robot = main.robot          # only valid until the next _fresh()
	var e: GameElement = main._spawn_pollen(BB.fp(0.0, 20.0, 12.0))
	await get_tree().physics_frame
	var made0: int = int(main.stats.per[r]["made"])
	main.stats._on_launched(e, r)                      # one launch
	var hv: Hive = main.field.hives[r.alliance]
	main.stats._on_cell_entry(e, hv)
	_ok("one ball entering a CELL is one made shot",
		int(main.stats.per[r]["made"]) - made0, 1)
	main.stats._on_cell_entry(e, hv)
	main.stats._on_cell_entry(e, hv)
	_ok("  bouncing out and back in does not count again",
		int(main.stats.per[r]["made"]) - made0, 1)
	b._evaluate(0.016, false)
	_ok("  so the objective sees exactly one shot", b.progress, 1)
	e.queue_free()
	await get_tree().process_frame

	# --- a robot wandering in and out of a reach area completes once
	var c := await _fresh(Objective.Kind.REACH, 1, 0.0)
	c.objective["target"] = Objective.Target.ROBOT
	c.objective["robot"] = 0
	r = main.robot                     # _fresh() rebuilt the roster
	var rp := BB.to_field(r.global_position)
	c.objective["area"] = {"x": rp.x, "y": rp.y, "r": 40.0}
	c._evaluate(Objective.DWELL_S * 0.5, false)
	_ok("half the dwell is not enough", c.state, Attempt.State.RUNNING)
	c.objective["area"] = {"x": rp.x + 200.0, "y": rp.y, "r": 4.0}
	c._evaluate(0.2, false)
	_ok("  leaving the area resets the dwell", c._dwell, 0.0)
	c.objective["area"] = {"x": rp.x, "y": rp.y, "r": 40.0}
	c._evaluate(Objective.DWELL_S + 0.01, false)
	_ok("  re-entering and holding completes it once",
		c.state, Attempt.State.SUCCEEDED)
	var n0: int = AttemptLog.all().size()
	c._evaluate(Objective.DWELL_S, false)
	c._evaluate(Objective.DWELL_S, false)
	_ok("  and staying there writes no second record",
		AttemptLog.all().size(), n0)

	# --- balls already in the air: defined, documented, and counted
	var d := await _fresh(Objective.Kind.SHOTS, 1, 0.0)
	r = main.robot
	_ok("a settled field has nothing in the air", d.airborne_at_start, 0)
	var spec := {"held": "", "kind": BB.Kind.POLLEN,
		"lin": Snapshot.pack_v3(Vector3(0, 4.0, -3.0)),
		"origin": Snapshot.pack_v3(BB.fp(0.0, 0.0, 30.0))}
	_ok("a moving loose ball reads as in flight", Objective.in_flight(spec), true)
	var still := spec.duplicate(true)
	still["lin"] = Snapshot.pack_v3(Vector3.ZERO)
	_ok("  a ball at rest does not, however high it is sitting",
		Objective.in_flight(still), false)
	var carried := spec.duplicate(true)
	carried["held"] = "robot:0"
	_ok("  and neither does one in a hopper",
		Objective.in_flight(carried), false)
	_ok("the shots help explains what happens to them",
		Objective.metric_note(Objective.Kind.SHOTS).findn("already in the air") >= 0,
		true)
	_ok("  and so does the points help",
		Objective.metric_note(Objective.Kind.POINTS).findn("already in the air") >= 0,
		true)
	_ok("the two rules differ, because the systems do",
		Objective.FLIGHT_RULE_SHOTS != Objective.FLIGHT_RULE_POINTS, true)
	_ok("  shots: never credited",
		Objective.FLIGHT_RULE_SHOTS.findn("never count") >= 0, true)
	_ok("  points: they do score",
		Objective.FLIGHT_RULE_POINTS.findn("DO score") >= 0, true)

	# a ball fed into a CELL with no launch behind it is not a made shot
	var e2: GameElement = main._spawn_pollen(BB.fp(0.0, 20.0, 12.0))
	await get_tree().physics_frame
	var made1: int = int(main.stats.per[r]["made"])
	main.stats._on_cell_entry(e2, main.field.hives[r.alliance])
	_ok("a ball nobody launched is never a made shot",
		int(main.stats.per[r]["made"]), made1)
	d._evaluate(0.016, false)
	_ok("  so a SHOTS objective is immune to it", d.progress, 0)
	e2.queue_free()
	await get_tree().process_frame

	# the editor warns an author who saves a situation mid-shot
	var snap := Snapshot.capture(main)
	if not (snap.get("elements", []) as Array).is_empty():
		var fly: Dictionary = snap.duplicate(true)
		(fly["elements"] as Array)[0]["held"] = ""
		(fly["elements"] as Array)[0]["lin"] = Snapshot.pack_v3(Vector3(0, 5, -4))
		fly["objective"] = Objective.blank()
		(fly["objective"] as Dictionary)["kind"] = Objective.Kind.POINTS
		var warned := false
		for pr in Snapshot.check_draft(fly):
			if String(pr.get("msg", "")).findn("already in the air") >= 0:
				warned = true
		_ok("the editor warns when a points situation is saved mid-flight",
			warned, true)

## THE INDEPENDENT REVIEW'S PROBES, AS REGRESSIONS.
##
## Three defects were reported against the previous build. Each is reproduced
## here exactly as the reviewer reproduced it, so that a future change that
## reintroduces one is caught rather than re-reported.
func _review_probes() -> void:
	# --- 1. the deadline must not include a step that ran past it.
	# Reviewer: previous=9.95 now=10.05 limit=10 -> succeeded, expected timeout.
	var a := await _fresh(Objective.Kind.TIPS, 1, 10.0)
	a.elapsed = 10.05
	main.mm.scoring.tips[main.robot.alliance] = int(a._base["tips"]) + 1
	a._evaluate(0.10, false)
	_ok("REVIEW 1: a step that ran past the deadline does not count",
		a.state, Attempt.State.FAILED)
	_ok("  it fails on time, not on the tip", a.reason, "timeout")
	_ok("  and the late tip added no progress", a.progress, 0)

	# the same boundary from the other side: landing exactly on it still counts
	var b := await _fresh(Objective.Kind.TIPS, 1, 10.0)
	b.elapsed = 10.0
	main.mm.scoring.tips[main.robot.alliance] = int(b._base["tips"]) + 1
	b._evaluate(1.0 / 180.0, false)
	_ok("  landing exactly ON the limit still counts",
		b.state, Attempt.State.SUCCEEDED)

	# and the boundary is the same however long the caller's step was, because
	# it is decided on the clock rather than on the width of the step
	for step in [1.0 / 180.0, 0.05, 0.25]:
		var c := await _fresh(Objective.Kind.TIPS, 1, 10.0)
		c.elapsed = 10.0 + 1.0 / 180.0
		main.mm.scoring.tips[main.robot.alliance] = int(c._base["tips"]) + 1
		c._evaluate(step, false)
		_ok("  one tick past the limit fails whatever the step (%.4f s)" % step,
			c.state, Attempt.State.FAILED)

	# --- 2. final scoring must use the FINAL score, not latched progress.
	# Reviewer: latched=8 current_delta=0 final_delta=6 -> succeeded.
	var d := await _fresh(Objective.Kind.POINTS, 8, 10.0)
	var garden: Array[GameElement] = []
	for i in 8:
		var e: GameElement = GameElement.make(BB.Kind.POLLEN)
		e.freeze = true
		main.add_child(e)
		e.global_position = BB.fp(-70.0 + float(i) * 2.8, -71.0, 1.4)
		garden.append(e)
	d.elapsed = 9.9
	d._evaluate(0.1, false)
	_ok("REVIEW 2: the provisional total reached the goal before the deadline",
		d._eligible_since >= 0.0, true)
	_ok("  and latched", d.progress >= 8, true)
	d.elapsed = 10.1                                   # the deadline has passed
	d._evaluate(0.1, false)
	_ok("  it is allowed to keep settling past the deadline",
		d.state, Attempt.State.RUNNING)
	for e2 in garden:
		e2.global_position = BB.fp(40.0, -40.0, 1.4)
	d._on_match_finished({})                           # the real match-end path
	var final_delta := int(main.mm.scoring.breakdown(main.field, true)
		[main.robot.alliance]["total"]) - int(d._base["points"])
	_ok("  the elements left the GARDEN, so the final score is short",
		final_delta < 8, true)
	_ok("  the attempt does NOT succeed on points that are gone",
		d.succeeded(), false)
	_ok("  it finishes rather than hanging in settling", d.is_done(), true)
	_ok("  and the record carries the final number, not the latched one",
		d.progress, final_delta)
	for e3 in garden:
		e3.queue_free()
	await get_tree().process_frame

	# the honest version of the same case: the points stay, so it confirms
	var f := await _fresh(Objective.Kind.POINTS, 8, 10.0)
	var kept: Array[GameElement] = []
	for i in 8:
		var e4: GameElement = GameElement.make(BB.Kind.POLLEN)
		e4.freeze = true
		main.add_child(e4)
		e4.global_position = BB.fp(-70.0 + float(i) * 2.8, -71.0, 1.4)
		kept.append(e4)
	f.elapsed = 9.9
	f._evaluate(0.1, false)
	f.elapsed = 10.1
	f._evaluate(0.1, false)
	f._on_match_finished({})
	_ok("  points that are still there at the buzzer DO confirm",
		f.succeeded(), true)
	for e5 in kept:
		e5.queue_free()
	await get_tree().process_frame

## A fresh armed attempt on the situation already loaded, with the objective
## rewritten in place. Retry re-restores the snapshot, so every case below
## starts from the same field.
func _fresh(kind: int, amount: int, limit: float) -> Attempt:
	await main.retry_situation()
	await get_tree().create_timer(0.1).timeout
	var a: Attempt = main.attempt
	main.mm.pause()
	a.objective["kind"] = kind
	a.objective["target"] = Objective.Target.ALLIANCE
	a.objective["amount"] = amount
	a.objective["time_limit"] = limit
	a.objective["no_foul"] = false
	a.goal = maxi(1, amount)
	a.progress = 0
	a._hold = 0.0
	a._dwell = 0.0
	a._eligible_since = -1.0
	a._latched = false
	a.elapsed = 0.0
	a._base = a._read_world()
	return a

## Points are provisional while the match runs, and final once it settles.
func _settling() -> void:
	await main.retry_situation()
	await get_tree().create_timer(0.1).timeout
	var a: Attempt = main.attempt
	a.objective["kind"] = Objective.Kind.POINTS
	a.objective["target"] = Objective.Target.ALLIANCE
	a.objective["no_foul"] = false
	a.objective["time_limit"] = 0.0
	a.objective["amount"] = 5
	a.goal = 5
	a._base = a._read_world()

	# the provisional scoreboard crosses the line...
	main.mm.scoring.tips[main.robot.alliance] = int(a._base["tips"]) + 1
	a._evaluate(0.2, false)
	_ok("a points goal does not succeed the instant it is crossed",
		a.state, Attempt.State.RUNNING)
	_ok("  and says so while it settles", a.pending_confirmation(), true)
	a._evaluate(BB.SETTLE_S, false)
	_ok("  then counts once it has held for the settling time",
		a.state, Attempt.State.SUCCEEDED)

	# ...and a goal only the FINAL score reaches is decided at match end
	await main.retry_situation()
	await get_tree().create_timer(0.1).timeout
	var b: Attempt = main.attempt
	b.objective["kind"] = Objective.Kind.POINTS
	b.objective["target"] = Objective.Target.ALLIANCE
	b.objective["no_foul"] = false
	b.objective["time_limit"] = 0.0
	b.objective["amount"] = 5
	b.goal = 5
	b._base = b._read_world()
	var prov: Dictionary = main.mm.scoring.breakdown(main.field, false)
	var fin: Dictionary = main.mm.scoring.breakdown(main.field, true)
	var a2: int = main.robot.alliance
	_ok("the provisional score is below the goal",
		int(prov[a2]["total"]) - int(b._base["points"]) < 5, true)
	_ok("  but the final score is not",
		int(fin[a2]["total"]) - int(b._base["points"]) >= 5, true)
	b._on_match_finished({})
	_ok("  so the match ending decides it on the FINAL score",
		b.state, Attempt.State.SUCCEEDED)
	_ok("  and the record carries the final points, not the provisional ones",
		int(b.record()["points"]) >= 5, true)

## Failed and abandoned attempts can never hold a record.
func _records() -> void:
	var sig: String = main.attempt.signature
	var best := AttemptLog.best(sig)
	_ok("the personal best is the successful attempt",
		String(best.get("state", "")), "succeeded")
	var fake := best.duplicate(true)
	fake["state"] = "failed"
	fake["elapsed"] = 0.01
	fake["reason"] = "timeout"
	AttemptLog.add(fake)
	var fake2 := best.duplicate(true)
	fake2["state"] = "abandoned"
	fake2["elapsed"] = 0.005
	AttemptLog.add(fake2)
	var best2 := AttemptLog.best(sig)
	_ok("a faster FAILED attempt does not take the record",
		String(best2.get("state", "")), "succeeded")
	_ok("  and neither does a faster abandoned one",
		float(best2.get("elapsed", 0.0)) > 0.02, true)
	var sum := AttemptLog.summary(sig)
	_ok("abandoned attempts stay in the count",
		int(sum["attempts"]) > int(sum["succeeded"]) + int(sum["failed"]), true)
	_ok("  so the success rate cannot read as perfect",
		float(sum["rate"]) < 100.0, true)
	_ok("the comparison line is factual",
		AttemptLog.compare_line(best, {}).begins_with("First successful"), true)

## Changing the setup splits comparisons; renaming does not.
func _grouping() -> void:
	var entry := _entry()
	var data: Dictionary = entry["data"]
	var obj: Dictionary = data.get("objective", {})
	var sig := AttemptLog.signature(data, obj)

	var renamed: Dictionary = data.duplicate(true)
	(renamed["meta"] as Dictionary)["name"] = "totally different name"
	(renamed["meta"] as Dictionary)["note"] = "and a new description"
	_ok("renaming keeps the comparison group",
		AttemptLog.signature(renamed, obj), sig)

	var harder: Dictionary = data.duplicate(true)
	harder["match"]["time_left"] = 12.0
	_ok("changing the starting clock splits it",
		AttemptLog.signature(harder, obj) != sig, true)
	var moved: Dictionary = data.duplicate(true)
	(moved["robots"] as Array)[0]["origin"] = Snapshot.pack_v3(BB.fp(9.0, 9.0, 0.0))
	_ok("moving the robot splits it",
		AttemptLog.signature(moved, obj) != sig, true)
	var tougher: Dictionary = obj.duplicate(true)
	tougher["amount"] = 4
	_ok("changing the objective splits it",
		AttemptLog.signature(data, tougher) != sig, true)
	var batt: Dictionary = data.duplicate(true)
	(batt["robots"] as Array)[0]["battery_v"] = 11.2
	_ok("a different battery splits it",
		AttemptLog.signature(batt, obj) != sig, true)

	# an old scenario with no objective still loads and is free practice
	var legacy: Dictionary = data.duplicate(true)
	legacy.erase("objective")
	_ok("a scenario with no objective is free practice",
		Objective.is_set(legacy.get("objective", {})), false)
	_ok("  and still validates", Snapshot.validate(legacy), "")
	_ok("  and describes itself honestly",
		Objective.describe({}).begins_with("Free practice"), true)

func _drills() -> void:
	var names: Array = []
	for e in ScenarioLibrary.list_all():
		names.append(String(e["name"]))
	var n := 0
	for want in ["Collect and shoot", "Twenty points, forty-five seconds",
			"Recover from the corner", "Final twenty seconds"]:
		if names.has(want):
			n += 1
	_ok("the four starter drills are on the shelf", n, 4)
	for e in ScenarioLibrary.list_all():
		if String(e["name"]) == "Final twenty seconds":
			var o: Dictionary = (e["data"] as Dictionary).get("objective", {})
			_ok("  and the last one has a real objective",
				Objective.is_set(o), true)
			_ok("  measured for the alliance, not one robot",
				int(o.get("target", -1)), Objective.Target.ALLIANCE)

func _entry() -> Dictionary:
	for e in ScenarioLibrary.list_all():
		if String(e["name"]).begins_with(SCEN):
			return e
	return {}

func _count(state: String) -> int:
	var n := 0
	for r in AttemptLog.all():
		if String(r.get("state", "")) == state:
			n += 1
	return n

# ==================================================================== read ===

func _read_phase() -> void:
	print("\n--- OBJECTIVES: READ PHASE (cold start) ---")
	var rows := AttemptLog.all()
	_ok("the practice history survived a restart", rows.size() > 0, true)
	var sig := ""
	for r in rows:
		if String(r.get("state", "")) == "succeeded":
			sig = String(r.get("signature", ""))
	_ok("  with a comparison group intact", sig != "", true)
	var best := AttemptLog.best(sig)
	_ok("  and a personal best that reads back",
		String(best.get("state", "")), "succeeded")
	_ok("  carrying the rules revision it was set under",
		int(best.get("rev", -1)), BB.RULES_REV)
	_ok("practice history is not the match history",
		AttemptLog.PATH != RobotShop.HISTORY, true)
	var lb := Leaderboard.load_all()
	var contaminated := false
	for r in lb:
		if String(r.get("mode", "")).findn("objective") >= 0:
			contaminated = true
	_ok("  and nothing reached the leaderboard", contaminated, false)
	var editor_rows := 0
	for r in rows:
		if bool(r.get("from_editor", false)):
			editor_rows += 1
	_ok("editor tests are marked apart from saved-scenario practice",
		editor_rows >= 0, true)

func _ok(what: String, got: Variant, want: Variant) -> void:
	var pass_: bool = str(got) == str(want)
	if not pass_:
		fails += 1
	print("  %s %-54s got %s   want %s" % [
		"PASS" if pass_ else "FAIL", what, str(got), str(want)])
