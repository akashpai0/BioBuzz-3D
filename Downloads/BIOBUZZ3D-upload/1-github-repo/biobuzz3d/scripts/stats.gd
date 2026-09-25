class_name MatchStats
extends Node
##
## WHAT ACTUALLY HAPPENED, PER ROBOT.
##
## The score says who won. It does not say why, and it is useless for practice:
## a driver who scored 40 by taking 9 shots is in a completely different place
## from one who scored 40 by taking 31. These are the numbers a team argues
## about between matches — accuracy, cycle time, how long you sat on a full
## hopper doing nothing — collected as the match runs and frozen at the buzzer.
##
## Nothing in here affects scoring. If this file were deleted the match would
## play identically.
##

## A launched element reached a CELL within MADE_WINDOW of leaving `r`'s
## launcher — the one definition of a "successful shot" the game has. It is
## NOT a promise that the points survive to the final score.
signal shot_made(r: Robot, e: GameElement)

## Per robot. Keyed by the Robot node itself.
var per: Dictionary = {}
var field: Field
var mm: MatchManager

## A shot is credited as MADE if its element reaches a CELL within this long of
## being launched. Longer than any real arc, short enough that a ball nudged in
## by hand three cycles later is not quietly counted as a made shot.
const MADE_WINDOW := 6.0

func track(r: Robot) -> void:
	if per.has(r):
		return
	per[r] = {
		"label": r.driver_label, "alliance": r.alliance, "intakes": r.intakes,
		"shots": 0, "made": 0, "collected": 0, "ejected": 0,
		"tips": 0, "out_of_field": 0,
		"distance_in": 0.0, "top_speed": 0.0,
		"t_moving": 0.0, "t_full": 0.0, "t_empty": 0.0, "t_over": 0.0,
		"shot_dist_total": 0.0,
		"score_times": [],           # match clock at each made shot
		"cycles": [],                # seconds between consecutive made shots
		"_last_pos": Vector3.ZERO, "_have_pos": false,
		"_pending": [],              # [element, launched_at] awaiting a CELL
	}
	# `per` is cleared on every re-stage, so the has() guard above does not stop
	# a robot that survives the restage from being wired up a second time.
	# Godot then errors once per signal per stage, forever.
	if not r.launched.is_connected(_on_launched):
		r.launched.connect(_on_launched.bind(r))
	if not r.picked_up.is_connected(_on_picked):
		r.picked_up.connect(_on_picked.bind(r))

func hook_field() -> void:
	for a in field.hives:
		var h: Hive = field.hives[a]
		h.element_entered.connect(_on_cell_entry)
		h.tipped.connect(_on_tip.bind(h))

# ================================================================= events ====

func _on_launched(e: GameElement, r: Robot) -> void:
	# A robot the stats were never told about (a harness, a roster mid-
	# rebuild) has no row. `per.get(r)` is then null, and assigning null to a
	# typed Dictionary is a script error rather than a false test.
	var d: Dictionary = per.get(r, {})
	if d.is_empty():
		return
	d["shots"] += 1
	var target := _nearest_own_hive(r)
	if target != null:
		d["shot_dist_total"] += r.global_position.distance_to(target.aim_point()) / BB.IN
	(d["_pending"] as Array).append([e, _now()])

func _on_picked(_e: GameElement, r: Robot) -> void:
	if BB.frozen():
		return
	var d: Dictionary = per.get(r, {})
	if not d.is_empty():
		d["collected"] += 1

## An element landed in a CELL. Whoever launched it, recently enough, gets it.
func _on_cell_entry(e: GameElement, h: Hive) -> void:
	if BB.frozen():
		return
	h.set_meta("last_feeder", e.last_launcher)
	for key in per:
		var d: Dictionary = per[key]
		var pend: Array = d["_pending"]
		for i in pend.size():
			if pend[i][0] != e:
				continue
			if _now() - float(pend[i][1]) <= MADE_WINDOW:
				d["made"] += 1
				var t := _clock()
				var times: Array = d["score_times"]
				if not times.is_empty():
					(d["cycles"] as Array).append(t - float(times[-1]))
				times.append(t)
				if key is Robot and is_instance_valid(key):
					shot_made.emit(key, e)
			pend.remove_at(i)
			return

## Credit the TIP to whoever last fed that hive.
func _on_tip(_a: int, _hv: Hive, h: Hive) -> void:
	# get_meta() with a null default still errors on a missing key, and a hive
	# can tip with nobody having fed it (knocked over by a robot).
	var who = h.get_meta("last_feeder") if h.has_meta("last_feeder") else null
	if who != null and per.has(who):
		per[who]["tips"] += 1

# ================================================================ sampling ===

func _process(delta: float) -> void:
	if BB.frozen():
		return
	if mm == null or (mm.phase != BB.Phase.AUTO and mm.phase != BB.Phase.TELEOP):
		return
	for key in per:
		var r: Robot = key
		if not is_instance_valid(r):
			continue
		var d: Dictionary = per[r]
		var p: Vector3 = r.global_position
		if bool(d["_have_pos"]):
			d["distance_in"] = float(d["distance_in"]) \
				+ (p - (d["_last_pos"] as Vector3)).length() / BB.IN
		d["_last_pos"] = p
		d["_have_pos"] = true

		var sp: float = r.speed_in_s()
		d["top_speed"] = maxf(float(d["top_speed"]), sp)
		if sp > 4.0:
			d["t_moving"] = float(d["t_moving"]) + delta
		var n: int = r.hopper.size()
		if n >= BB.HOPPER_CAP:
			d["t_full"] = float(d["t_full"]) + delta
		elif n == 0:
			d["t_empty"] = float(d["t_empty"]) + delta
		if r.controlled_count() > BB.HOPPER_CAP:
			d["t_over"] = float(d["t_over"]) + delta

		# drop stale pending shots so a miss is never counted later
		var pend: Array = d["_pending"]
		while not pend.is_empty() and _now() - float(pend[0][1]) > MADE_WINDOW:
			pend.pop_front()

# ================================================================== report ===

## One robot's numbers, derived and rounded, ready to print. Keys here are what
## the results screen and the saved history both read.
func summary(r: Robot) -> Dictionary:
	var d: Dictionary = per.get(r, {})
	if d.is_empty():
		return {}
	var shots := int(d["shots"])
	var made := int(d["made"])
	var cycles: Array = d["cycles"]
	var cyc_avg := 0.0
	var cyc_best := 0.0
	if not cycles.is_empty():
		var tot := 0.0
		cyc_best = 9999.0
		for c in cycles:
			tot += float(c)
			cyc_best = minf(cyc_best, float(c))
		cyc_avg = tot / float(cycles.size())
	return {
		"label": d["label"], "alliance": d["alliance"], "intakes": d["intakes"],
		"shots": shots, "made": made,
		"accuracy": (float(made) / float(shots) * 100.0) if shots > 0 else 0.0,
		"avg_shot_in": (float(d["shot_dist_total"]) / float(shots)) if shots > 0 else 0.0,
		"collected": int(d["collected"]),
		"tips": int(d["tips"]),
		"cycle_avg": cyc_avg, "cycle_best": cyc_best, "cycle_count": cycles.size(),
		"distance_ft": float(d["distance_in"]) / 12.0,
		"top_speed": float(d["top_speed"]),
		"t_moving": float(d["t_moving"]),
		"t_full": float(d["t_full"]), "t_empty": float(d["t_empty"]),
		"t_over": float(d["t_over"]),
	}

## The rows the results screen prints, in order, as [label, value, hint].
## `hint` is the "so what" — a number without one is just a number.
static func rows(s: Dictionary) -> Array:
	if s.is_empty():
		return []
	return [
		["Shots taken", "%d" % s["shots"], ""],
		["Shots made", "%d" % s["made"], ""],
		["Accuracy", "%.0f%%" % s["accuracy"],
			"every miss is a ball someone has to fetch"],
		["Average shot", "%.0f in" % s["avg_shot_in"], "distance to the CELL"],
		["Elements collected", "%d" % s["collected"], ""],
		["HIVE tips fed", "%d" % s["tips"], ""],
		["Scoring cycles", "%d" % s["cycle_count"], ""],
		["Average cycle", _secs(s["cycle_avg"]), "buzzer to buzzer between scores"],
		["Best cycle", _secs(s["cycle_best"]), ""],
		["Distance driven", "%.0f ft" % s["distance_ft"], ""],
		["Top speed", "%.1f in/s" % s["top_speed"], ""],
		["Time moving", _secs(s["t_moving"]), ""],
		["Time with a full hopper", _secs(s["t_full"]),
			"balls you were carrying instead of scoring"],
		["Time empty", _secs(s["t_empty"]), "nothing to shoot"],
		["Time over the G407 limit", _secs(s["t_over"]),
			"seconds spent one ball from a foul"],
	]

static func _secs(v: float) -> String:
	if v <= 0.0 or v > 9000.0:
		return "—"
	return "%.1f s" % v

# ================================================================== helpers ==

## SIMULATION time, not the wall clock: a shot's attribution window must not
## expire while the player is reading a pause menu.
func _now() -> float:
	return BB.sim_now()

## Elapsed match time, so cycle gaps read the way a driver counts them.
func _clock() -> float:
	if mm == null:
		return _now()
	return (BB.TELEOP_S - mm.time_left) if mm.phase == BB.Phase.TELEOP else 0.0

func _nearest_own_hive(r: Robot) -> Hive:
	var best: Hive = null
	var bd := 1e9
	for a in field.hives:
		var h: Hive = field.hives[a]
		if h.alliance != r.alliance:
			continue
		var d := r.global_position.distance_to(h.aim_point())
		if d < bd:
			bd = d
			best = h
	return best
