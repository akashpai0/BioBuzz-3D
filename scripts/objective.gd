class_name Objective
extends RefCounted
##
## WHAT A PRACTICE SITUATION ASKS YOU TO DO.
##
## One primary goal plus at most two constraints — deliberately not a scripting
## language. A scenario without one is FREE PRACTICE: it still works, and the
## game invents no success or failure for it.
##
## Everything here is measured from the AUTHORITATIVE game systems the match
## already uses: Scoring for points and tips, MatchStats for successful shots,
## the foul counter for constraints. There is no second scoring implementation
## and no second definition of a made shot.
##
## The definition lives inside the situation snapshot under "objective", so it
## travels with the scenario, survives the existing versioned save, and an old
## scenario with no objective simply has no key.
##

enum Kind { NONE, POINTS, TIPS, SHOTS, REACH }
enum Target { ALLIANCE, ROBOT }

## A successful shot is a ball YOU LAUNCHED that entered a CELL within
## MatchStats.MADE_WINDOW of leaving the launcher. That is the existing
## verified metric — it is not "points awarded at the end of the match", and
## it is not "a ball that is in a cell".
const SHOT_METRIC := "a ball you launched that entered a CELL"

## How long the robot's centre must stay inside a marked area.
const DWELL_S := 0.75

## A loose ball counts as IN FLIGHT at the saved starting instant if it is
## MOVING faster than this. Height is deliberately not part of the test: balls
## sit at rest inside FLOWERS and raised CELLs all match long, and calling
## those "in flight" would warn about every ordinary situation. Used only to
## warn the author and to report what happened — never to alter scoring.
const IN_FLIGHT_SPEED := 0.6          # m/s

## Is this saved element spec a ball that was already moving when the
## situation was captured?
static func in_flight(spec: Dictionary) -> bool:
	if String(spec.get("held", "")) != "":
		return false                  # carried, not flying
	return Snapshot.unpack_v3(spec.get("lin", [])).length() > IN_FLIGHT_SPEED

## How many balls were already in the air in a saved situation.
static func count_in_flight(d: Dictionary) -> int:
	var n := 0
	for e in d.get("elements", []):
		if in_flight(e):
			n += 1
	return n

## THE RULE FOR BALLS ALREADY IN THE AIR, in one place, quoted everywhere it
## matters: the editor warning, the objective help and the results screen.
##
## A shot is credited to the robot that LAUNCHED it during this attempt. A ball
## restored in mid-air was launched in some earlier run, or placed there by the
## author, so no launch belongs to it and it can never become a successful
## shot — not for you, not for anyone. SHOTS goals are therefore immune to it.
##
## Points are different, and deliberately so. The scoreboard is the match's
## own, read live; when a ball already in the air lands in a CELL the score
## really does go up, and the game will not run a second scoring system to
## pretend otherwise. So those points DO count towards a POINTS goal. That is
## worth knowing when you author a situation: if you save it a moment after a
## shot leaves the launcher, the next driver is handed those points.
const FLIGHT_RULE_SHOTS := ("Balls already in the air when the situation was "
	+ "saved can never count as successful shots: a shot belongs to the robot "
	+ "that launched it during the attempt, and nothing launched those.")
const FLIGHT_RULE_POINTS := ("Balls already in the air when the situation was "
	+ "saved DO score if they land in a CELL, because the scoreboard is the "
	+ "match's own and it really does go up. Save the situation before the "
	+ "shot, or after it lands, if you do not want to hand those points over.")

static func blank() -> Dictionary:
	return {
		"kind": Kind.NONE,
		"target": Target.ALLIANCE,
		"robot": 0,
		"amount": 1,
		"time_limit": 0.0,
		"no_foul": false,
		"area": {"x": 0.0, "y": 0.0, "r": 18.0},
	}

## WHICH TARGETS EACH GOAL CAN HONESTLY BE MEASURED AGAINST.
##
## Points and HIVE tips are alliance quantities. A tip is caused by the total
## mass in a CELL, and the game cannot say which robot's contribution tipped
## it — crediting whoever fired last would be a guess — so tip goals are
## alliance-level only. Successful shots are attributed per launcher, so they
## can be either. Reaching an area is obviously one robot.
static func targets_for(kind: int) -> Array:
	match kind:
		Kind.SHOTS: return [Target.ALLIANCE, Target.ROBOT]
		Kind.REACH: return [Target.ROBOT]
	return [Target.ALLIANCE]

static func kind_name(kind: int) -> String:
	return ["Free practice", "Score points", "Tip HIVEs", "Make shots",
		"Reach an area"][clampi(kind, 0, 4)]

# ============================================================== describing ===

## The objective as a sentence, the way it reads on the HUD and in the library.
static func describe(d: Dictionary, robot_label := "") -> String:
	if d.is_empty() or int(d.get("kind", Kind.NONE)) == Kind.NONE:
		return "Free practice — no objective"
	var who := _who(d, robot_label)
	var n := int(d.get("amount", 1))
	var main_text := ""
	match int(d.get("kind", Kind.NONE)):
		Kind.POINTS:
			main_text = "Score %d more point%s" % [n, "" if n == 1 else "s"]
		Kind.TIPS:
			main_text = "Cause %d more HIVE tip%s" % [n, "" if n == 1 else "s"]
		Kind.SHOTS:
			main_text = "Make %d successful shot%s" % [n, "" if n == 1 else "s"]
		Kind.REACH:
			var a: Dictionary = d.get("area", {})
			main_text = "Reach the marked area (%.0f in across)" \
				% (float(a.get("r", 18.0)) * 2.0)
	var bits: Array[String] = []
	var t := float(d.get("time_limit", 0.0))
	if t > 0.0:
		bits.append("within %s" % _secs(t))
	if bool(d.get("no_foul", false)):
		bits.append("without a foul")
	var tail := (" " + " ".join(bits)) if not bits.is_empty() else ""
	return "%s%s, %s" % [main_text, tail, who]

static func _who(d: Dictionary, robot_label: String) -> String:
	if int(d.get("target", Target.ALLIANCE)) == Target.ROBOT:
		return "as %s" % (robot_label if robot_label != "" else
			"robot %d" % (int(d.get("robot", 0)) + 1))
	return "as an alliance"

static func _secs(t: float) -> String:
	if t >= 60.0 and is_equal_approx(fmod(t, 60.0), 0.0):
		return "%d min" % int(t / 60.0)
	return "%.0f seconds" % t

## What the numbers mean, for the editor and the results screen.
static func metric_note(kind: int) -> String:
	match kind:
		Kind.POINTS:
			return ("Counted from the live scoreboard, which is provisional "
				+ "while the match runs. A points goal is only called a "
				+ "success once the total has held for the settling time the "
				+ "game already uses, or once the match ends and the final "
				+ "score confirms it.\n\n" + FLIGHT_RULE_POINTS)
		Kind.TIPS:
			return ("A tip is caused by the mass in a raised CELL, and the "
				+ "game cannot reliably say whose ball tipped it, so tip "
				+ "goals are measured for the whole alliance.")
		Kind.SHOTS:
			return ("A successful shot is %s. It is not the same as points "
				% SHOT_METRIC + "at the end of the match.\n\n"
				+ FLIGHT_RULE_SHOTS)
		Kind.REACH:
			return ("Completed when the robot's ground-plane centre is inside "
				+ "the circle for %.2f seconds. This is a practice target, "
				% DWELL_S + "not official PARK scoring.")
	return ""

# ============================================================== validating ==

## Problems with an objective, in the same shape check_draft() uses.
static func check(d: Dictionary, draft_robots: Array, our_alliance: int) -> Array:
	var out: Array = []
	if d.is_empty() or int(d.get("kind", Kind.NONE)) == Kind.NONE:
		return out
	var kind := int(d.get("kind", Kind.NONE))
	var target := int(d.get("target", Target.ALLIANCE))
	var n := int(d.get("amount", 1))

	if not targets_for(kind).has(target):
		out.append({"severity": "error", "where": "objective", "id": "",
			"msg": "%s cannot be measured for one robot on its own. %s"
				% [kind_name(kind), metric_note(kind)]})
	if kind != Kind.REACH and n < 1:
		out.append({"severity": "error", "where": "objective", "id": "",
			"msg": "The goal has to ask for at least one."})
	if kind == Kind.POINTS and n > 400:
		out.append({"severity": "error", "where": "objective", "id": "",
			"msg": "No realistic situation scores 400 more points."})
	if kind == Kind.TIPS and n > 8:
		out.append({"severity": "error", "where": "objective", "id": "",
			"msg": "There are only four HIVE CELLs; %d tips is not reachable." % n})

	var t := float(d.get("time_limit", 0.0))
	if t < 0.0 or not is_finite(t):
		out.append({"severity": "error", "where": "objective", "id": "",
			"msg": "The time limit is not a valid number."})

	if target == Target.ROBOT:
		var idx := int(d.get("robot", 0))
		var found := {}
		for r in draft_robots:
			if int(r.get("index", -1)) == idx:
				found = r
		if found.is_empty():
			out.append({"severity": "error", "where": "objective", "id": "",
				"msg": "The objective targets a robot that is not in the roster."})
		elif bool(found.get("ai", false)):
			out.append({"severity": "error", "where": "objective", "id": "",
				"msg": "The objective targets an AI robot. Pick one you drive."})
		elif int(found.get("alliance", 0)) != our_alliance:
			out.append({"severity": "error", "where": "objective", "id": "",
				"msg": "The objective targets an opponent robot."})

	if kind == Kind.REACH:
		var a: Dictionary = d.get("area", {})
		var r := float(a.get("r", 0.0))
		if r < 4.0:
			out.append({"severity": "error", "where": "objective", "id": "",
				"msg": "The target area is too small to drive into; make it at least 8 in across."})
		elif r > 72.0:
			out.append({"severity": "warning", "where": "objective", "id": "",
				"msg": "The target area covers most of the field."})
		if absf(float(a.get("x", 0.0))) > BB.FIELD_HALF \
				or absf(float(a.get("y", 0.0))) > BB.FIELD_HALF:
			out.append({"severity": "error", "where": "objective", "id": "",
				"msg": "The target area is outside the field."})

	# A shots goal with no time limit and no foul constraint is fine; a POINTS
	# goal that is already satisfied at the start is not, and that is checked
	# live rather than here, because the baseline is taken at attempt time.
	return out

static func is_set(d: Variant) -> bool:
	return d is Dictionary and int((d as Dictionary).get("kind", Kind.NONE)) != Kind.NONE
