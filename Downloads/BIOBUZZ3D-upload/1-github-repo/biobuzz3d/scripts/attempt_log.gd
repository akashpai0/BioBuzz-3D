class_name AttemptLog
extends RefCounted
##
## LOCAL PRACTICE HISTORY AND PERSONAL BESTS.
##
## Kept in `user://attempts.json`, which is NOT the match history and NOT the
## leaderboard: an objective attempt starts from the middle of a saved
## situation, so its score is not comparable with anyone's full match and it
## never touches either of those.
##
## COMPARING LIKE WITH LIKE. Every attempt carries a SIGNATURE: a hash of the
## things that change how hard the objective is — the objective itself, the
## starting field, the roster, the robot's profile and the scoring rules'
## revision. Change any of those and attempts fall into a new group, so a best
## time set on an easier field never stands as the record for a harder one.
## The signature deliberately does NOT include the name or the description, so
## renaming a scenario or fixing a typo keeps its history.
##

const PATH := "user://attempts.json"
const MAX_ROWS := 500

# ================================================================= reading ===

static func all() -> Array:
	if not FileAccess.file_exists(PATH):
		return []
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		return []
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Array else []

## Every attempt in one comparison group, newest first.
static func group(sig: String) -> Array:
	var out: Array = []
	for r in all():
		if String(r.get("signature", "")) == sig:
			out.append(r)
	out.reverse()
	return out

## Every attempt at one scenario, whatever the comparison group — so the
## library can say how much practice has gone into it.
static func for_scenario(id: String) -> Array:
	var out: Array = []
	for r in all():
		if String(r.get("scenario", "")) == id:
			out.append(r)
	out.reverse()
	return out

## THE PERSONAL BEST: the fastest SUCCESSFUL attempt in the group.
##
## Failed and abandoned attempts can never hold the record, whatever their
## elapsed time — finishing quickly by giving up is not a best.
static func best(sig: String) -> Dictionary:
	var top := {}
	for r in group(sig):
		if String(r.get("state", "")) != "succeeded":
			continue
		if top.is_empty() or float(r.get("elapsed", 1e9)) < float(top.get("elapsed", 1e9)):
			top = r
	return top

## The numbers the library and the results screen show.
##
## SUCCESS RATE IS SUCCESSES OVER EVERY ATTEMPT, abandoned ones included.
## Counting only finished attempts would let someone restart the moment a run
## went wrong and show a perfect record for it.
static func summary(sig: String) -> Dictionary:
	var rows := group(sig)
	var ok := 0
	var failed := 0
	var quit := 0
	for r in rows:
		match String(r.get("state", "")):
			"succeeded": ok += 1
			"failed": failed += 1
			_: quit += 1
	return {
		"attempts": rows.size(),
		"succeeded": ok,
		"failed": failed,
		"abandoned": quit,
		"rate": (float(ok) / float(rows.size()) * 100.0) if not rows.is_empty() else 0.0,
		"best": best(sig),
	}

# ================================================================= writing ===

static func add(rec: Dictionary) -> bool:
	var rows := all()
	rows.append(rec)
	while rows.size() > MAX_ROWS:
		rows.pop_front()
	return _write_atomic(rows)

## Same safe write the situation library uses: a complete file is built beside
## the real one and only then swapped in.
static func _write_atomic(rows: Array) -> bool:
	var tmp := PATH + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(rows))
	f.close()
	var check := FileAccess.open(tmp, FileAccess.READ)
	if check == null:
		return false
	var back: Variant = JSON.parse_string(check.get_as_text())
	check.close()
	if not (back is Array):
		DirAccess.remove_absolute(tmp)
		return false
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(PATH)
	return DirAccess.rename_absolute(tmp, PATH) == OK

static func clear() -> void:
	DirAccess.remove_absolute(PATH)

# ============================================================== signatures ===

## What makes two attempts comparable.
##
## Everything that changes the difficulty is in here; nothing that does not is.
## Positions are rounded to a tenth of an inch so float noise cannot split a
## group, and the whole thing is hashed so a record is one short string.
static func signature(snapshot: Dictionary, objective: Dictionary) -> String:
	var setup: Dictionary = snapshot.get("setup", {})
	var m: Dictionary = snapshot.get("match", {})
	var canon := {
		"rev": BB.RULES_REV,
		"obj": _canon_objective(objective),
		"mode": int(setup.get("mode", 0)),
		"alliance": int(setup.get("alliance", 0)),
		"robots": int(setup.get("robots", 1)),
		"opponents": int(setup.get("opponents", 0)),
		"mate_ai": bool(setup.get("mate_is_ai", false)),
		"per_robot": int(setup.get("per_robot", 1)),
		"profile": int(setup.get("profile", 0)),
		"specs": _canon_specs(setup.get("specs", {})),
		"phase": int(m.get("phase", 0)),
		"time": snappedf(float(m.get("time_left", 0.0)), 0.1),
		"score": m.get("scoring", {}),
		"field": _canon_field(snapshot),
	}
	# OPPONENT CONDITIONS ARE PART OF THE SETUP. A best time earned against a
	# Gentle defender is not comparable with one against a Challenging one, so
	# changing any opponent setting starts a new comparison group.
	#
	# Added ONLY when some robot has a configured behavior. A situation saved
	# before opponents were configurable has none, hashes exactly as it always
	# did, and keeps its practice history.
	var opp := _canon_opponents(snapshot)
	if not opp.is_empty():
		canon["opponents_cfg"] = opp
	return JSON.stringify(canon).sha256_text().substr(0, 24)

static func _canon_opponents(snapshot: Dictionary) -> Array:
	var rows: Array = []
	for r in snapshot.get("robots", []):
		var br: Variant = (r as Dictionary).get("brain")
		if OpponentConfig.is_legacy(br):
			continue
		var cfg := OpponentConfig.from_brain(br)
		var row := OpponentConfig.canon(cfg)
		row["i"] = int(r.get("index", 0))
		# initial runtime state that changes what happens first: which
		# waypoint it is heading for, and any wait already under way
		row["wp"] = int((br as Dictionary).get("wp", 0))
		row["wl"] = snappedf(float((br as Dictionary).get("wait_left", 0.0)), 0.1)
		rows.append(row)
	return rows

static func _canon_objective(o: Dictionary) -> Dictionary:
	if not Objective.is_set(o):
		return {"kind": 0}
	var area: Dictionary = o.get("area", {})
	return {
		"kind": int(o.get("kind", 0)),
		"target": int(o.get("target", 0)),
		"robot": int(o.get("robot", 0)),
		"amount": int(o.get("amount", 1)),
		"time": snappedf(float(o.get("time_limit", 0.0)), 0.1),
		"no_foul": bool(o.get("no_foul", false)),
		"area": [snappedf(float(area.get("x", 0.0)), 0.1),
			snappedf(float(area.get("y", 0.0)), 0.1),
			snappedf(float(area.get("r", 0.0)), 0.1)],
	}

static func _canon_specs(s: Dictionary) -> Array:
	var keys: Array = s.keys()
	keys.sort()
	var out: Array = []
	for k in keys:
		out.append([String(k), snappedf(float(s[k]), 0.001)])
	return out

## The starting field: what is on it and where, to a tenth of an inch.
static func _canon_field(snapshot: Dictionary) -> Array:
	var rows: Array = []
	for e in snapshot.get("elements", []):
		var p := Snapshot.unpack_v3(e.get("origin", []))
		rows.append("e%d:%d:%s:%.1f,%.1f,%.1f" % [
			int(e.get("kind", 0)), int(e.get("alliance", -1)),
			String(e.get("held", "")),
			p.x / BB.IN, p.y / BB.IN, p.z / BB.IN])
	for r in snapshot.get("robots", []):
		var p2 := Snapshot.unpack_v3(r.get("origin", []))
		var b := Snapshot.unpack_basis(r.get("basis", []))
		rows.append("r%d:%d:%d:%d:%.1f,%.1f:%.0f:%d:%.2f" % [
			int(r.get("index", 0)), int(r.get("alliance", 0)),
			1 if bool(r.get("ai", false)) else 0, int(r.get("intakes", 1)),
			p2.x / BB.IN, -p2.z / BB.IN, rad_to_deg(b.get_euler().y),
			(r.get("hopper", []) as Array).size(),
			float(r.get("battery_v", 0.0))])
	for h in snapshot.get("hives", []):
		rows.append("h%d:%d:%d" % [int(h.get("alliance", 0)),
			int(h.get("stable_sign", 1)), int(h.get("tip_count", 0))])
	rows.sort()
	return rows

# ================================================================ wording ====

## A FACTUAL line comparing this attempt with the best one before it. Built
## only from recorded numbers — it never guesses why a shot missed or whether
## a route was good.
static func compare_line(rec: Dictionary, previous_best: Dictionary) -> String:
	if String(rec.get("state", "")) != "succeeded":
		match String(rec.get("reason", "")):
			"foul": return "Attempt ended after a new foul."
			"timeout": return "Ran out of objective time."
			"match_ended": return "The match ended before the objective was met."
			"abandoned": return "Attempt abandoned."
		return "Attempt not completed."
	if previous_best.is_empty():
		return "First successful attempt at this setup — %s is the time to beat." \
			% _secs(float(rec.get("elapsed", 0.0)))
	var d := float(previous_best.get("elapsed", 0.0)) - float(rec.get("elapsed", 0.0))
	if absf(d) < 0.05:
		return "Matched your best time of %s." % _secs(float(previous_best.get("elapsed", 0.0)))
	if d > 0.0:
		return "Completed %s faster than your previous best." % _secs(d)
	return "%s slower than your best of %s." % [_secs(-d),
		_secs(float(previous_best.get("elapsed", 0.0)))]

static func _secs(t: float) -> String:
	return "%.1f s" % t
