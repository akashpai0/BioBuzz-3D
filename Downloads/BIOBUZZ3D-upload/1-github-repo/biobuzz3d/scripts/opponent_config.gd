class_name OpponentConfig
extends RefCounted
##
## WHAT A PRACTICE OPPONENT IS TOLD TO DO.
##
## Four behaviors, each with settings that mean something you can see on the
## field. There is deliberately NO difficulty number: "Challenging" is a name
## for a set of visible values — drive faster, react sooner, stand closer —
## and every one of those values is shown next to it and can be changed.
##
## WHAT DIFFICULTY IS NEVER ALLOWED TO BE. Nothing here touches the robot's
## grip, motor power, top speed, battery, launcher accuracy or what it can
## see. An opponent's `pace` is a fraction of the command a human could send
## the same robot; its `reaction` is how long it waits before acting on a
## change. It uses the same drivetrain, the same intake, the same launcher
## and the same aim solver as you do, and knows only what it could observe.
##
## Stored inside the robot's `brain` block in a situation snapshot, next to the
## runtime state that lets it resume mid-route. A brain with no `behavior` key
## is a legacy collect-and-score opponent from before this existed, and is read
## as exactly that — see `from_brain()`.
##

enum Behavior { COLLECT, STATIONARY, ROUTE, DEFEND }
enum RouteMode { LOOP, BACK_AND_FORTH, STOP }

const NAMES := ["Collect and score", "Stationary", "Follow a route", "Defend an area"]
const ROUTE_MODES := ["Loop", "Back and forth", "Stop at end"]

## What each behavior does, in one or two sentences, for the editor.
const HELP := [
	"Drives to the nearest loose POLLEN, collects up to four with its own intake, then drives to a shooting spot and fires them at its alliance's CELL with the ordinary launcher and aim. It never creates balls or scores anything it did not physically put in. If there is nothing it can collect, it waits and checks again.",
	"Holds where it was placed using its ordinary drivetrain. It does not collect or shoot. It is a real robot, not a wall: push it and it moves, then drives itself back.",
	"Drives through the waypoints you place, in order, at the pace you set, and can wait at each one. It uses normal driving and collisions and does not collect or shoot. If something is in the way it tries a short recovery, then waits and tries again. It never jumps past an obstruction.",
	"Stays inside a circular area and tries to put itself in the way of one of your robots while that robot is in or near the area. When your robot leaves, it goes back to its area. It does not chase across the field, and it does not collect or shoot.",
]

## The only restrictions the game actually enforces on an opponent. Shown in
## the editor so nobody mistakes this defender for a rule-checked one.
const DEFEND_RULES_NOTE := ("This game does not model pinning, trapping or "
	+ "other defensive-contact rules, so this defender is NOT checked against "
	+ "them. It does stop in the transition period (G403) like every robot.")

const AREA_NOTE := ("The area is judged by the robot's ground-plane centre: a "
	+ "robot is inside when the centre of its footprint is within the circle. "
	+ "A 18 in robot can therefore overhang the edge by up to 9 in, and "
	+ "collisions can shove it further for a moment.")

## A target robot counts as in the defended area while its centre is within
## the radius plus this much. Lets the defender meet a robot at the edge rather
## than only once it is already inside.
const ENGAGE_MARGIN := 12.0

## ---------------------------------------------------------- the settings ---
## key -> [default, min, max, label, help, unit]. Only keys a behavior USES are
## ever shown for it (see KEYS); a setting that does nothing is not offered.
const FIELDS := {
	"pace":       [0.55, 0.20, 1.00, "Driving pace",
		"How hard it drives, as a share of what this same robot could do with a full stick. It does not make the robot any faster than yours could be.", "%"],
	"reaction":   [0.25, 0.00, 1.50, "Reaction delay",
		"How long it waits before acting on a change — a ball appearing, your robot moving, being pushed.", "s"],
	"hold_heading": [1.0, 0.0, 1.0, "Keep that heading",
		"Turn back to the heading after being bumped. Off: it keeps whatever way it ends up facing.", ""],
	"tolerance":  [6.0, 2.0, 24.0, "Arrival tolerance",
		"How close its centre must get to a waypoint to count as having reached it.", "in"],
	"route_mode": [0.0, 0.0, 2.0, "At the last waypoint",
		"Loop back to the first, reverse along the route, or stop.", ""],
	"radius":     [30.0, 12.0, 72.0, "Area radius",
		"Size of the circle it defends.", "in"],
	"standoff":   [20.0, 10.0, 48.0, "How close it stands",
		"How far from your robot it tries to position itself, on the side towards the middle of its area.", "in"],
	"collect_r":  [0.0, 0.0, 72.0, "Collection area radius",
		"Only go for balls within this distance of the area centre. 0 means the whole field.", "in"],
}

const KEYS := {
	Behavior.COLLECT:    ["pace", "reaction", "collect_r"],
	# The held heading is the robot's own placed heading, edited on the
	# robot itself — one number, not a second one that could disagree with it.
	Behavior.STATIONARY: ["pace", "reaction", "hold_heading"],
	Behavior.ROUTE:      ["pace", "tolerance", "route_mode"],
	Behavior.DEFEND:     ["pace", "reaction", "radius", "standoff"],
}

## -------------------------------------------------------------- presets ---
## Named combinations of VISIBLE values, nothing more. Standard for Collect is
## the opponent this game has always had: 55% pace, a decision every 0.25 s.
const PRESETS := {
	Behavior.COLLECT: {
		"Gentle":      {"pace": 0.35, "reaction": 0.80},
		"Standard":    {"pace": 0.55, "reaction": 0.25},
		"Challenging": {"pace": 0.80, "reaction": 0.10},
	},
	Behavior.STATIONARY: {
		"Gentle":      {"pace": 0.30, "reaction": 0.80},
		"Standard":    {"pace": 0.50, "reaction": 0.40},
		"Challenging": {"pace": 0.80, "reaction": 0.15},
	},
	Behavior.ROUTE: {
		"Gentle":      {"pace": 0.35, "tolerance": 8.0},
		"Standard":    {"pace": 0.55, "tolerance": 6.0},
		"Challenging": {"pace": 0.80, "tolerance": 4.0},
	},
	Behavior.DEFEND: {
		"Gentle":      {"pace": 0.40, "reaction": 0.80, "standoff": 30.0},
		"Standard":    {"pace": 0.60, "reaction": 0.40, "standoff": 20.0},
		"Challenging": {"pace": 0.85, "reaction": 0.15, "standoff": 12.0},
	},
}
const PRESET_ORDER := ["Gentle", "Standard", "Challenging"]

# ================================================================ defaults ==

static func blank(behavior: int = Behavior.COLLECT) -> Dictionary:
	var cfg := {"behavior": behavior}
	for k: String in FIELDS:
		cfg[k] = float(FIELDS[k][0])
	cfg["waypoints"] = []
	cfg["area"] = {"x": 0.0, "y": 0.0}
	cfg["target"] = 0
	apply_preset(cfg, "Standard")
	return cfg

static func apply_preset(cfg: Dictionary, name: String) -> void:
	var b := int(cfg.get("behavior", Behavior.COLLECT))
	var set_: Dictionary = (PRESETS.get(b, {}) as Dictionary).get(name, {})
	for k: String in set_:
		cfg[k] = float(set_[k])

## The preset these values ARE, or "Custom". Computed, never stored, so a label
## can never claim a preset whose numbers have since been edited.
static func preset_name(cfg: Dictionary) -> String:
	var b := int(cfg.get("behavior", Behavior.COLLECT))
	var table: Dictionary = PRESETS.get(b, {})
	for name in PRESET_ORDER:
		var set_: Dictionary = table.get(name, {})
		var all_match := true
		for k: String in set_:
			if not is_equal_approx(float(cfg.get(k, -999.0)), float(set_[k])):
				all_match = false
				break
		if all_match:
			return String(name)
	return "Custom"

static func get_f(cfg: Dictionary, key: String) -> float:
	var spec: Array = FIELDS.get(key, [0.0, 0.0, 1.0])
	var v: Variant = cfg.get(key, spec[0])
	if not (v is float or v is int) or not is_finite(float(v)):
		return float(spec[0])
	return clampf(float(v), float(spec[1]), float(spec[2]))

# ============================================================ compatibility ==

## THE COMPATIBILITY PATH for situations saved before opponents were
## configurable. Their brain block holds only the collect AI's runtime state
## (mode, target, stuck timers...). Without a `behavior` key it is read as
## Collect and score at the Standard preset — which is precisely what that
## opponent always was — and its runtime state is left for the brain to use.
static func from_brain(brain: Dictionary) -> Dictionary:
	if not brain.has("behavior"):
		return blank(Behavior.COLLECT)
	return sanitize(brain.get("config", brain))

static func is_legacy(brain: Variant) -> bool:
	return not (brain is Dictionary) or not (brain as Dictionary).has("behavior")

## EVERY VALUE CHECKED. Numbers are clamped, a waypoint that is not two finite
## numbers inside the field is dropped, and an unknown behavior falls back to
## Collect. Never crashes on a hand-edited file.
static func sanitize(raw: Variant) -> Dictionary:
	if not (raw is Dictionary):
		return blank()
	var src: Dictionary = raw
	var b := int(src.get("behavior", Behavior.COLLECT)) \
		if (src.get("behavior") is int or src.get("behavior") is float) else Behavior.COLLECT
	if b < 0 or b > Behavior.DEFEND:
		b = Behavior.COLLECT
	var out := blank(b)
	for k: String in FIELDS:
		if src.has(k):
			out[k] = get_f(src, k)
	out["route_mode"] = float(clampi(int(round(float(out["route_mode"]))), 0, 2))
	out["hold_heading"] = 1.0 if float(out["hold_heading"]) >= 0.5 else 0.0
	var wps: Array = []
	var raw_wps: Variant = src.get("waypoints", [])
	if raw_wps is Array:
		for w in raw_wps:
			if not (w is Dictionary):
				continue
			var x: Variant = (w as Dictionary).get("x")
			var y: Variant = (w as Dictionary).get("y")
			if not ((x is float or x is int) and (y is float or y is int)):
				continue
			if not (is_finite(float(x)) and is_finite(float(y))):
				continue
			if absf(float(x)) > BB.FIELD_HALF or absf(float(y)) > BB.FIELD_HALF:
				continue
			var wait: Variant = (w as Dictionary).get("wait", 0.0)
			var ws := float(wait) if (wait is float or wait is int) \
				and is_finite(float(wait)) else 0.0
			wps.append({"x": float(x), "y": float(y), "wait": clampf(ws, 0.0, 30.0)})
			if wps.size() >= MAX_WAYPOINTS:
				break
	out["waypoints"] = wps
	var ar: Variant = src.get("area", {})
	if ar is Dictionary:
		var ax: Variant = (ar as Dictionary).get("x", 0.0)
		var ay: Variant = (ar as Dictionary).get("y", 0.0)
		if (ax is float or ax is int) and (ay is float or ay is int) \
				and is_finite(float(ax)) and is_finite(float(ay)):
			out["area"] = {"x": clampf(float(ax), -BB.FIELD_HALF, BB.FIELD_HALF),
				"y": clampf(float(ay), -BB.FIELD_HALF, BB.FIELD_HALF)}
	var t: Variant = src.get("target", 0)
	out["target"] = int(t) if (t is int or t is float) else 0
	return out

const MAX_WAYPOINTS := 12

# ================================================================ checking ==

## Problems, in the shape check_draft() uses, each tagged with the SETTING it
## is about so the editor can show it beside that setting.
static func check(cfg: Dictionary, robot_index: int, draft_robots: Array) -> Array:
	var out: Array = []
	var b := int(cfg.get("behavior", Behavior.COLLECT))
	var me := {}
	for r in draft_robots:
		if int(r.get("index", -1)) == robot_index:
			me = r
	match b:
		Behavior.ROUTE:
			var wps: Array = cfg.get("waypoints", [])
			if wps.size() < 2:
				out.append(_p("error", "waypoints",
					"A route needs at least two waypoints. Use Add waypoint, then click the field."))
			for i in wps.size():
				var w: Dictionary = wps[i]
				if absf(float(w["x"])) < 29.0 and absf(float(w["y"])) < 24.0:
					out.append(_p("warning", "waypoints",
						"Waypoint %d is inside the HIVE footprint; the robot cannot reach it." % (i + 1)))
		Behavior.DEFEND:
			var t := int(cfg.get("target", -1))
			var found := {}
			for r2 in draft_robots:
				if int(r2.get("index", -1)) == t:
					found = r2
			if found.is_empty():
				out.append(_p("error", "target",
					"Pick which of your robots it should defend against."))
			elif not me.is_empty() and int(found.get("alliance", -1)) \
					== int(me.get("alliance", -2)):
				out.append(_p("error", "target",
					"That robot is on the same alliance. A defender defends against the other side."))
			# the HIVE footprint is solid; a defender cannot stand inside it
			var a: Dictionary = cfg.get("area", {})
			var cx := float(a.get("x", 0.0))
			var cy := float(a.get("y", 0.0))
			var nx := clampf(cx, -29.0, 29.0)
			var ny := clampf(cy, -24.0, 24.0)
			if Vector2(cx - nx, cy - ny).length() < get_f(cfg, "radius"):
				out.append(_p("warning", "radius",
					"Part of this area is inside the HIVE structure, where the defender cannot stand. It will stay on the open side."))
	return out

static func _p(sev: String, setting: String, msg: String) -> Dictionary:
	return {"severity": sev, "where": "opponent", "setting": setting, "msg": msg}

# =============================================================== comparing ==

## What makes two opponents the same PRACTICE CONDITION, for personal bests.
## Everything that changes how it behaves is in; the preset NAME is not,
## because the name is computed from the values that are.
static func canon(cfg: Dictionary) -> Dictionary:
	var c := sanitize(cfg)
	var out := {"b": int(c["behavior"])}
	for k: String in KEYS.get(int(c["behavior"]), []):
		out[k] = snappedf(float(c[k]), 0.01)
	match int(c["behavior"]):
		Behavior.ROUTE:
			var w: Array = []
			for p in c["waypoints"]:
				w.append("%.1f,%.1f,%.1f" % [float(p["x"]), float(p["y"]), float(p["wait"])])
			out["w"] = w
		Behavior.DEFEND:
			out["a"] = "%.1f,%.1f" % [float(c["area"]["x"]), float(c["area"]["y"])]
			out["t"] = int(c["target"])
		Behavior.COLLECT:
			if float(c["collect_r"]) > 0.0:
				out["a"] = "%.1f,%.1f" % [float(c["area"]["x"]), float(c["area"]["y"])]
	return out

static func describe(cfg: Dictionary) -> String:
	var b := int(cfg.get("behavior", Behavior.COLLECT))
	return "%s · %s · %.0f%% pace" % [String(NAMES[b]), preset_name(cfg),
		get_f(cfg, "pace") * 100.0]
