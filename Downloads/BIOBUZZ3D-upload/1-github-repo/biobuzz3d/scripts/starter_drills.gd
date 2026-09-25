class_name StarterDrills
extends RefCounted
##
## FOUR DRILLS TO START FROM.
##
## Built with the same editor operations and written through the same library
## as anything a player makes, so they are ordinary situations: duplicate one,
## edit your copy, delete it, rename it. Nothing about them is special-cased.
##
## They only use behaviour the game actually has. The practice opponents are
## the four OpponentConfig behaviors, configured with ordinary editor
## operations, and every one of them is set to a named preset whose values are
## visible in the editor.
##

const TAG := "drill"

## Write the four if they are not already on the shelf. Runs once, quietly.
static func ensure(main: Node) -> void:
	var have := {}
	for e in ScenarioLibrary.list_all():
		var d: Dictionary = e.get("data", {})
		have[String((d.get("meta", {}) as Dictionary).get("drill", ""))] = true
	# Each drill is created only if it is missing, so adding the opponent drills
	# to an existing install writes those four and touches nothing else.
	var makers := {
		"shooting": _shooting, "timed": _timed, "recover": _recover,
		"final20": _final20,
		"opp_around": _around_stationary, "opp_traffic": _traffic,
		"opp_guarded": _guarded, "opp_compete": _compete,
	}
	for tag in makers:
		if not have.has(tag):
			_save((makers[tag] as Callable).call(main), String(tag))

static func _save(pair: Array, tag: String) -> void:
	var draft: ScenarioDraft = pair[0]
	var id := ScenarioLibrary.save(draft.to_snapshot(), draft.name, draft.note)
	if id == "":
		return
	# a quiet marker so the four are only ever created once
	var entry := ScenarioLibrary.load_one(id)
	if String(entry["error"]) != "":
		return
	var data: Dictionary = entry["data"]
	var meta: Dictionary = data.get("meta", {})
	meta["drill"] = tag
	data["meta"] = meta
	ScenarioLibrary._write_atomic(ScenarioLibrary.path_for(id), data)

# ------------------------------------------------------------------ drills --

## Collect and shoot: a full field, two minutes, eight made shots.
static func _shooting(main: Node) -> Array:
	var d := ScenarioDraft.staged(main)
	d.name = "Collect and shoot"
	d.note = "A normal field and a full teleop. Eight successful shots, no clock pressure."
	d.set_scenario("mode", BB.Mode.TELEOP_ONLY)
	d.set_scenario("phase", BB.Phase.TELEOP)
	d.set_scenario("time_left", BB.TELEOP_S)
	d.set_objective("kind", Objective.Kind.SHOTS)
	d.set_objective("target", Objective.Target.ROBOT)
	d.set_objective("robot", 0)
	d.set_objective("amount", 8)
	return [d]

## A clock: twenty more points in forty-five seconds.
static func _timed(main: Node) -> Array:
	var d := ScenarioDraft.staged(main)
	d.name = "Twenty points, forty-five seconds"
	d.note = "Score twenty more points before the timer runs out. Pick your cycle and commit."
	d.set_scenario("mode", BB.Mode.TELEOP_ONLY)
	d.set_scenario("phase", BB.Phase.TELEOP)
	d.set_scenario("time_left", BB.TELEOP_S)
	d.set_objective("kind", Objective.Kind.POINTS)
	d.set_objective("target", Objective.Target.ALLIANCE)
	d.set_objective("amount", 20)
	d.set_objective("time_limit", 45.0)
	return [d]

## An awkward start: parked in the far corner facing the wall, with a target
## to reach across the field.
static func _recover(main: Node) -> Array:
	var d := ScenarioDraft.empty_field(main)
	d.name = "Recover from the corner"
	d.note = "Nose in the corner, facing the wall. Get out and reach the marked area in fifteen seconds."
	d.set_scenario("mode", BB.Mode.FREE_PRACTICE)
	d.set_scenario("phase", BB.Phase.TELEOP)
	d.set_scenario("time_left", BB.TELEOP_S)
	d.set_position("robot:0", Vector3(-60.0, -60.0, 0.0))
	d.set_yaw("robot:0", 45.0)
	d.set_objective("kind", Objective.Kind.REACH)
	d.set_objective("target", Objective.Target.ROBOT)
	d.set_objective("robot", 0)
	d.set_area("x", 40.0)
	d.set_area("y", 40.0)
	d.set_area("r", 16.0)
	d.set_objective("time_limit", 15.0)
	return [d]

## The last twenty seconds, with an opponent in the way.
static func _final20(main: Node) -> Array:
	var d := ScenarioDraft.staged(main)
	d.name = "Final twenty seconds"
	d.note = "Twenty seconds left, one AI opponent on the field. Fifteen more points, cleanly."
	d.set_scenario("mode", BB.Mode.TELEOP_ONLY)
	d.set_scenario("phase", BB.Phase.TELEOP)
	d.set_scenario("time_left", 20.0)
	d.add_robot(BB.Alliance.BLUE, true)
	d.set_objective("kind", Objective.Kind.POINTS)
	d.set_objective("target", Objective.Target.ALLIANCE)
	d.set_objective("amount", 15)
	d.set_objective("time_limit", 20.0)
	d.set_objective("no_foul", true)
	return [d]

# ------------------------------------------------------- practice opponents --

## Where our robot starts in the opponent drills: the near-side lane, which is
## clear of the HIVE footprint (|y| < 24) all the way across.
const LANE_Y := -52.0

static func _foe(d: ScenarioDraft) -> String:
	var a := int(d.setup().get("alliance", BB.Alliance.RED))
	return d.add_robot(BB.Alliance.BLUE if a == BB.Alliance.RED else BB.Alliance.RED, true)

static func _reach(d: ScenarioDraft, x: float, y: float, r: float, t: float) -> void:
	d.set_objective("kind", Objective.Kind.REACH)
	d.set_objective("target", Objective.Target.ROBOT)
	d.set_objective("robot", 0)
	d.set_area("x", x)
	d.set_area("y", y)
	d.set_area("r", r)
	d.set_objective("time_limit", t)

## A robot parked in the straight line. Go round it, or push it — it is a real
## robot and it will drive itself back.
static func _around_stationary(main: Node) -> Array:
	var d := ScenarioDraft.empty_field(main)
	d.name = "Around a parked robot"
	d.note = "A stationary robot sits in the straight line to the target. Find the quicker way past it: round the open side, or through it."
	d.set_scenario("mode", BB.Mode.TELEOP_ONLY)
	d.set_scenario("phase", BB.Phase.TELEOP)
	d.set_scenario("time_left", BB.TELEOP_S)
	d.set_position("robot:0", Vector3(-58.0, -58.0, 0.0))
	d.set_yaw("robot:0", 90.0)
	var id := _foe(d)
	d.set_position(id, Vector3(4.0, -58.0, 0.0))
	d.set_yaw(id, 0.0)
	d.set_opponent(id, "behavior", OpponentConfig.Behavior.STATIONARY)
	d.set_opponent(id, "preset", "Standard")
	_reach(d, 56.0, -58.0, 14.0, 9.0)
	return [d]

## A looping robot crossing your lane. Time the gap.
static func _traffic(main: Node) -> Array:
	var d := ScenarioDraft.empty_field(main)
	d.name = "Crossing traffic"
	d.note = "An opponent drives a loop straight across your lane. Get to the far side without being held up — time the gap rather than forcing it."
	d.set_scenario("mode", BB.Mode.TELEOP_ONLY)
	d.set_scenario("phase", BB.Phase.TELEOP)
	d.set_scenario("time_left", BB.TELEOP_S)
	d.set_position("robot:0", Vector3(-58.0, LANE_Y, 0.0))
	d.set_yaw("robot:0", 90.0)
	var id := _foe(d)
	d.set_position(id, Vector3(12.0, -66.0, 0.0))
	d.set_opponent(id, "behavior", OpponentConfig.Behavior.ROUTE)
	d.set_opponent(id, "preset", "Standard")
	d.set_opponent(id, "route_mode", float(OpponentConfig.RouteMode.LOOP))
	d.set_opponent(id, "waypoints", [
		{"x": 12.0, "y": -64.0, "wait": 0.0}, {"x": 12.0, "y": -32.0, "wait": 0.0},
		{"x": 36.0, "y": -32.0, "wait": 0.0}, {"x": 36.0, "y": -64.0, "wait": 0.0}])
	_reach(d, 58.0, LANE_Y, 14.0, 10.0)
	return [d]

## The target sits inside a defended circle.
static func _guarded(main: Node) -> Array:
	var d := ScenarioDraft.empty_field(main)
	d.name = "Guarded target"
	d.note = "The target is inside an area a defender is holding. It gets between you and the middle of its area, and stays in its circle. Get in anyway."
	d.set_scenario("mode", BB.Mode.TELEOP_ONLY)
	d.set_scenario("phase", BB.Phase.TELEOP)
	d.set_scenario("time_left", BB.TELEOP_S)
	d.set_position("robot:0", Vector3(-58.0, LANE_Y, 0.0))
	d.set_yaw("robot:0", 90.0)
	var id := _foe(d)
	d.set_position(id, Vector3(48.0, LANE_Y, 0.0))
	d.set_yaw(id, -90.0)
	d.set_opponent(id, "behavior", OpponentConfig.Behavior.DEFEND)
	d.set_opponent(id, "preset", "Standard")
	d.set_opponent(id, "area", {"x": 48.0, "y": LANE_Y})
	d.set_opponent(id, "radius", 24.0)
	d.set_opponent(id, "target", 0)
	_reach(d, 54.0, LANE_Y, 12.0, 14.0)
	return [d]

## Another robot is taking the same loose POLLEN.
static func _compete(main: Node) -> Array:
	var d := ScenarioDraft.staged(main)
	d.name = "Competing for pollen"
	d.note = "An opponent is collecting the same loose POLLEN you need and shooting it at its own CELL. Score twenty more points in forty-five seconds before it takes them."
	d.set_scenario("mode", BB.Mode.TELEOP_ONLY)
	d.set_scenario("phase", BB.Phase.TELEOP)
	d.set_scenario("time_left", BB.TELEOP_S)
	var id := _foe(d)
	d.set_position(id, Vector3(56.0, -30.0, 0.0))
	d.set_opponent(id, "behavior", OpponentConfig.Behavior.COLLECT)
	d.set_opponent(id, "preset", "Standard")
	d.set_objective("kind", Objective.Kind.POINTS)
	d.set_objective("target", Objective.Target.ALLIANCE)
	d.set_objective("amount", 20)
	d.set_objective("time_limit", 45.0)
	return [d]
