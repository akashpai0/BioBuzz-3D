class_name Attempt
extends Node
##
## ONE GO AT AN OBJECTIVE.
##
##   Ready -> Running -> Succeeded / Failed / Abandoned
##
## The clock starts when control and simulation actually begin, and stops for
## pause menus, loading and the editor: `_process` only advances while the
## match is genuinely being played.
##
## EVERY MEASUREMENT IS A DELTA FROM A BASELINE taken the moment the attempt
## starts, so a situation that already has 100 points, three old tips and a
## ball sitting in a CELL starts every objective at zero. Nothing that was
## already true can satisfy a new goal.
##
## The attempt finishes EXACTLY ONCE. Retry, exits, repeated signals, reopening
## the results screen and restoring the snapshot all route through `finish()`,
## which ignores everything after the first call.
##

signal finished(record: Dictionary)

enum State { READY, RUNNING, SUCCEEDED, FAILED, ABANDONED }

var main: Node3D
var objective: Dictionary = {}
var state: int = State.READY
var elapsed := 0.0
var attempt_no := 1
## Where the attempt came from, for the history: a library id, or "" for a
## draft being tested in the editor.
var scenario_id := ""
var scenario_name := ""
var signature := ""
var from_editor := false

var progress := 0
var goal := 1
var fouls_gained := 0
var reason := ""

var _base := {}
var _hold := 0.0                     # points must hold before they count
## When the provisional score first reached the goal, in attempt seconds.
## -1 means it never has. A result that became eligible BEFORE the deadline is
## still allowed to finish confirming after it; new progress is not.
var _eligible_since := -1.0
## Progress is latched once the deadline passes: nothing done afterwards adds
## qualifying progress.
var _latched := false
var _dwell := 0.0                    # time inside a reach area
## How many balls were already in the air at the starting instant. Reported,
## never used to alter scoring — see Objective.FLIGHT_RULE_POINTS/SHOTS.
var airborne_at_start := 0
var _done := false
var _area_node: Node3D

## Float slack on the deadline comparison. This is NOT a grace period: it is
## there so that a clock accumulated from 1/180 s steps still counts a limit
## that lands exactly on a tick boundary as "at the limit".
const TICK_EPS := 1.0e-6

# ==================================================================== start ==

## Take the baseline and arm. Called once the field is restored and the match
## is about to be handed back to the player.
func begin(world: Node3D, obj: Dictionary, meta: Dictionary) -> void:
	main = world
	objective = obj.duplicate(true)
	attempt_no = int(meta.get("attempt_no", 1))
	scenario_id = String(meta.get("scenario_id", ""))
	scenario_name = String(meta.get("scenario_name", ""))
	signature = String(meta.get("signature", ""))
	from_editor = bool(meta.get("from_editor", false))
	goal = maxi(1, int(objective.get("amount", 1)))
	state = State.RUNNING
	elapsed = 0.0
	progress = 0
	_hold = 0.0
	_eligible_since = -1.0
	_latched = false
	_dwell = 0.0
	_done = false
	airborne_at_start = _count_airborne()
	_base = _read_world()
	_show_area()
	if main.mm and not main.mm.finished.is_connected(_on_match_finished):
		main.mm.finished.connect(_on_match_finished)

## Everything the objective might measure, right now.
func _read_world() -> Dictionary:
	var a := _our_alliance()
	var mm = main.mm
	var prov: Dictionary = mm.scoring.breakdown(main.field, false)
	var made := 0
	var shots := 0
	for r in _targets():
		var sm: Dictionary = main.stats.summary(r) if main.stats else {}
		if not sm.is_empty():
			made += int(sm.get("made", 0))
			shots += int(sm.get("shots", 0))
	return {
		"points": int(prov.get(a, {}).get("total", 0)),
		"tips": int(mm.scoring.tips[a]),
		"fouls": int(mm.scoring.fouls_against[a]),
		"made": made,
		"shots": shots,
	}

func _our_alliance() -> int:
	return main.robot.alliance if is_instance_valid(main.robot) else BB.Alliance.RED

## BALLS ALREADY IN THE AIR WHEN THIS ATTEMPT BEGAN.
##
## They are counted so the result can say so, and for nothing else. The rule
## they follow is structural rather than special-cased:
##
##   SHOTS  — a made shot is a ball a robot LAUNCHED during this attempt, and
##            MatchStats only has a pending entry for balls it saw leave a
##            launcher. Restoring a snapshot re-stages the robots and clears
##            those entries, so a ball restored in mid-air has no launch behind
##            it and can never be credited. No code here is needed for that.
##   POINTS — the scoreboard is the match's own. If one of these lands in a
##            CELL the score genuinely rises, and it counts. The game will not
##            keep a second scoreboard to subtract it back out.
func _count_airborne() -> int:
	var n := 0
	for node in main.get_tree().get_nodes_in_group("element"):
		var e: GameElement = node
		if not is_instance_valid(e) or e.held_by != null or e.freeze:
			continue
		if e.linear_velocity.length() > Objective.IN_FLIGHT_SPEED:
			n += 1
	return n

## The robots this objective is measured over.
func _targets() -> Array:
	var out: Array = []
	if int(objective.get("target", Objective.Target.ALLIANCE)) == Objective.Target.ROBOT:
		var i := int(objective.get("robot", 0))
		if i >= 0 and i < main.robots.size() and is_instance_valid(main.robots[i]):
			out.append(main.robots[i])
		return out
	for r in main.robots:
		if is_instance_valid(r) and r.alliance == _our_alliance() and not r.ai_driver:
			out.append(r)
	return out

# ==================================================================== clock ==

## The attempt is only running when the game is: not paused, not loading, not
## in a menu, and in a phase where the robots are live.
func _live() -> bool:
	if state != State.RUNNING or main == null or main.mm == null:
		return false
	if BB.frozen() or BB.halted or main.mm.paused:
		return false
	return main.mm.phase == BB.Phase.AUTO or main.mm.phase == BB.Phase.TELEOP

## THE ATTEMPT RUNS ON THE PHYSICS TICK, NOT ON RENDERED FRAMES.
##
## It used to run in _process, which meant the deadline resolution was the
## frame time: an independent review found a single frame spanning 9.95 to
## 10.05 s counted in full against a ten-second limit, so a slow machine got a
## 50 ms grace on every objective and a fast one got 3 ms. The same objective
## has to mean the same thing on every machine, so it is measured against the
## simulation, which is a fixed 180 Hz.
func _physics_process(delta: float) -> void:
	if not _live():
		return
	elapsed += delta
	_evaluate(delta, false)

# ================================================================= scoring ===

## PROGRESS AND CONSTRAINTS ARE DECIDED TOGETHER, then committed once.
##
## The old rule gave ties to the player. That was wrong: a run that picks up a
## foul on the same step it finishes did not meet a "without a foul"
## objective, and calling it a success would be the game flattering the driver.
## So the whole step is measured first and then judged:
##
##   1. measure progress — but only while the attempt is still INSIDE its
##      deadline. Once the deadline has passed, progress is LATCHED: driving
##      on afterwards cannot add qualifying progress.
##   2. a broken constraint FAILS the attempt, even on the step that would
##      otherwise have completed it.
##   3. otherwise, reaching the goal SUCCEEDS — including exactly on the
##      deadline step, which counts.
##   4. otherwise, a passed deadline FAILS on time.
##
## THE ONE THING THAT MAY CROSS THE DEADLINE is confirmation. A points total
## that became eligible before the deadline is allowed to finish settling
## afterwards, because that is the game confirming a result the player had
## already earned — not new progress. If it drops back below the goal while
## settling, the attempt fails on time.
func _evaluate(delta: float, final_scoring: bool) -> void:
	if _done:
		return
	var now := _read_world()
	fouls_gained = int(now["fouls"]) - int(_base["fouls"])
	var kind := int(objective.get("kind", Objective.Kind.NONE))
	if kind == Objective.Kind.NONE:
		return

	var limit := float(objective.get("time_limit", 0.0))
	var timed := limit > 0.0
	# THE BOUNDARY RULE, in one line, on simulation time:
	#
	#   a tick counts if the simulation clock AT THE END OF IT is at or before
	#   the limit.
	#
	# `elapsed` only advances in _physics_process, so at 180 Hz the boundary is
	# exact to 5.6 ms and — the part that matters — identical on every machine.
	# The previous rule asked whether the START of the step was before the
	# limit, which let a whole rendered frame across the line and made the
	# grace period a function of the frame rate.
	var inside := (not timed) or elapsed <= limit + TICK_EPS
	if timed and not inside:
		_latched = true

	# ---- 1. measure
	var reached := false
	match kind:
		Objective.Kind.POINTS:
			var delta_points := 0
			if final_scoring:
				var fin: Dictionary = main.mm.scoring.breakdown(main.field, true)
				delta_points = int(fin.get(_our_alliance(), {}).get("total", 0)) \
					- int(_base["points"])
			else:
				delta_points = int(now["points"]) - int(_base["points"])
			if inside:
				progress = delta_points
			if final_scoring:
				# THE FINAL SCORE IS THE ANSWER, and latched progress is not a
				# substitute for it. Latched progress records what the
				# provisional scoreboard once showed; it is not evidence that
				# the points are still on the field. An independent review
				# reached an eight-point goal, removed the elements before the
				# buzzer, and was told it had succeeded with six. The match
				# scores the field at rest, and so does this.
				progress = delta_points
				reached = delta_points >= goal
			elif delta_points >= goal:
				if _eligible_since < 0.0:
					_eligible_since = elapsed
				_hold += delta
				reached = _hold >= BB.SETTLE_S
			else:
				# it fell back below the goal: nothing is being confirmed any more
				_hold = 0.0
				_eligible_since = -1.0
		Objective.Kind.TIPS:
			if inside:
				progress = int(now["tips"]) - int(_base["tips"])
			reached = progress >= goal
		Objective.Kind.SHOTS:
			if inside:
				progress = int(now["made"]) - int(_base["made"])
			reached = progress >= goal
		Objective.Kind.REACH:
			if inside:
				_dwell = (_dwell + delta) if _robot_in_area() else 0.0
				progress = 1 if _dwell >= Objective.DWELL_S else 0
			reached = progress >= 1

	# ---- 2. a broken constraint fails, even on a completing step
	if bool(objective.get("no_foul", false)) and fouls_gained > 0:
		finish(State.FAILED, "foul")
		return

	# ---- 3. the goal, including exactly on the deadline
	if reached:
		finish(State.SUCCEEDED, "completed")
		return

	# ---- 4. out of time, unless an already-eligible result is still settling
	if timed and not inside:
		if kind == Objective.Kind.POINTS and _eligible_since >= 0.0 \
				and _eligible_since <= limit:
			return
		finish(State.FAILED, "timeout")

func _robot_in_area() -> bool:
	var area: Dictionary = objective.get("area", {})
	var t := _targets()
	if t.is_empty():
		return false
	var p := BB.to_field((t[0] as Robot).global_position)
	return Vector2(p.x - float(area.get("x", 0.0)),
		p.y - float(area.get("y", 0.0))).length() <= float(area.get("r", 18.0))

## The match ran out. Score-based goals get the FINAL numbers, after the
## settling the game already does; everything else is decided on what it has.
func _on_match_finished(_result: Dictionary) -> void:
	if _done or state != State.RUNNING:
		return
	_evaluate(0.0, true)
	if not _done:
		finish(State.FAILED, "match_ended")

# =================================================================== ending ==

## Gave up part way. Recorded honestly as abandoned — never as a quiet success
## and never as an ordinary completed attempt.
func abandon(why := "abandoned") -> void:
	if _done or state != State.RUNNING:
		return
	finish(State.ABANDONED, why)

func finish(new_state: int, why: String) -> void:
	if _done:
		return
	_done = true
	state = new_state
	reason = why
	_hide_area()
	if main.mm and main.mm.finished.is_connected(_on_match_finished):
		main.mm.finished.disconnect(_on_match_finished)
	finished.emit(record())

func is_done() -> bool:
	return _done

func succeeded() -> bool:
	return state == State.SUCCEEDED

# ================================================================== reading ==

## What the HUD shows while it runs.
func status_text() -> String:
	match int(objective.get("kind", Objective.Kind.NONE)):
		Objective.Kind.POINTS: return "%d / %d points" % [maxi(0, progress), goal]
		Objective.Kind.TIPS: return "%d / %d tips" % [maxi(0, progress), goal]
		Objective.Kind.SHOTS: return "%d / %d shots" % [maxi(0, progress), goal]
		Objective.Kind.REACH:
			if _dwell > 0.0:
				return "in the area — %.1f s" % _dwell
			return "not in the area"
	return ""

func time_text() -> String:
	var limit := float(objective.get("time_limit", 0.0))
	if limit > 0.0:
		return "%.1f s left" % maxf(0.0, limit - elapsed)
	return "%.1f s" % elapsed

## True while a points goal is met on the provisional score but not yet
## confirmed, so the HUD can say so rather than pretending.
func pending_confirmation() -> bool:
	return int(objective.get("kind", Objective.Kind.NONE)) == Objective.Kind.POINTS \
		and _hold > 0.0 and not _done

## The row that goes in the history.
func record() -> Dictionary:
	var now := _read_world()
	var made := int(now["made"]) - int(_base["made"])
	var shots := int(now["shots"]) - int(_base["shots"])
	var fin: Dictionary = main.mm.scoring.breakdown(main.field, true)
	return {
		"rev": BB.RULES_REV,
		"scenario": scenario_id,
		"name": scenario_name,
		"signature": signature,
		"from_editor": from_editor,
		"objective": objective.duplicate(true),
		"state": ["ready", "running", "succeeded", "failed", "abandoned"][state],
		"reason": reason,
		"progress": progress,
		"goal": goal,
		"elapsed": elapsed,
		"points": int(fin.get(_our_alliance(), {}).get("total", 0))
			- int(_base["points"]),
		"made": made,
		"shots": shots,
		"fouls": fouls_gained,
		"airborne_at_start": airborne_at_start,
		"attempt_no": attempt_no,
		"when": Time.get_datetime_string_from_system(true),
	}

# ============================================================== the marker ===

## The target circle, drawn flat on the tiles. No collision shape, so it can
## never push a robot or catch a ball.
func _show_area() -> void:
	_hide_area()
	if int(objective.get("kind", Objective.Kind.NONE)) != Objective.Kind.REACH:
		return
	_area_node = Objective_area(objective.get("area", {}))
	main.add_child(_area_node)
	place_area(_area_node, objective.get("area", {}))

func _hide_area() -> void:
	if is_instance_valid(_area_node):
		_area_node.queue_free()
	_area_node = null

## Shared with the editor, so the circle you place is the circle you drive to.
static func Objective_area(area: Dictionary) -> Node3D:
	var holder := Node3D.new()
	var r := float(area.get("r", 18.0))
	var disc := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = BB.m(r)
	cyl.bottom_radius = BB.m(r)
	cyl.height = 0.004
	disc.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(Gui.ACCENT.r, Gui.ACCENT.g, Gui.ACCENT.b, 0.18)
	disc.material_override = mat
	holder.add_child(disc)

	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = BB.m(r) * 0.97
	torus.outer_radius = BB.m(r)
	ring.mesh = torus
	var rm := StandardMaterial3D.new()
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.albedo_color = Gui.ACCENT
	ring.material_override = rm
	ring.position.y = 0.006
	holder.add_child(ring)

	# LOCAL position: this node has not entered the tree yet, and setting a
	# global transform on a detached node is an engine error. Callers place it
	# with `place_area()` once it has a parent.
	holder.position = BB.fp(float(area.get("x", 0.0)),
		float(area.get("y", 0.0)), 0.01)
	return holder

## Put an already-attached marker where the objective says, in world space, so
## the circle drawn and the circle measured cannot drift apart.
static func place_area(node: Node3D, area: Dictionary) -> void:
	if node == null or not is_instance_valid(node) or not node.is_inside_tree():
		return
	node.global_position = BB.fp(float(area.get("x", 0.0)),
		float(area.get("y", 0.0)), 0.01)
