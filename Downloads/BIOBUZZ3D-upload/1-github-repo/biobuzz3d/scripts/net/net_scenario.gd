class_name NetScenario
extends RefCounted
##
## SCENARIOS THAT ARRIVE OVER THE NETWORK ARE UNTRUSTED DATA.
##
## A room's scenario is an ordinary saved-situation snapshot, sent as JSON.
## Before the server simulates it or a client draws it, it is checked here:
##   - shape: only JSON types, bounded depth, counts, string lengths; every
##     number finite
##   - structure: known top-level keys only; roster, hives and element ids
##     the game can build; positions and speeds on or near the field
##   - meaning: Snapshot.validate() and every ERROR from check_draft()
##   - nothing that names a file is acted on: the autonomous routine (a file
##     on the sender's computer) is dropped, with a note saying so
## Scripts, resources and paths are never loaded from a scenario, because
## nothing in the format can express one.
##
## The robot HARDWARE PROFILE (drivetrain numbers) travels with the scenario
## and is what the server simulates. Custom CAD models do not travel: online,
## every robot is drawn with the built-in model, and the lobby says so.
##

const MAX_COMPRESSED := 512 * 1024
const MAX_RAW := 2 * 1024 * 1024
const MAX_ROBOTS := 4
const MAX_ELEMENTS := 96
const MAX_STRING := 300
const MAX_ARRAY := 400
const MAX_DEPTH := 10
const TOP_KEYS := ["format", "version", "saved", "setup", "match", "robots",
	"elements", "hives", "auto", "rng_seed", "objective", "meta", "origin"]
const SETUP_KEYS := ["mode", "alliance", "intakes", "robots", "mate_is_ai",
	"per_robot", "opponents", "takes_nectar", "robot_name", "profile", "specs",
	"auto_routine", "ai_mask"]

const STANDARD := {
	"2v2_teleop": {"name": "2 v 2 — Teleop only", "mode": BB.Mode.TELEOP_ONLY, "ours": 2, "foes": 2},
	"2v2_free": {"name": "2 v 2 — Free practice", "mode": BB.Mode.FREE_PRACTICE, "ours": 2, "foes": 2},
	"1v1_teleop": {"name": "1 v 1 — Teleop only", "mode": BB.Mode.TELEOP_ONLY, "ours": 1, "foes": 1},
	"2v0_free": {"name": "Two robots, one alliance — Free practice", "mode": BB.Mode.FREE_PRACTICE, "ours": 2, "foes": 0},
	"1v0_free": {"name": "One robot — Free practice", "mode": BB.Mode.FREE_PRACTICE, "ours": 1, "foes": 0},
}
const STANDARD_ORDER := ["2v2_teleop", "2v2_free", "1v1_teleop", "2v0_free", "1v0_free"]

# ================================================================ wire form ==

static func encode(d: Dictionary) -> Dictionary:
	var raw := JSON.stringify(d).to_utf8_buffer()
	return {"raw_len": raw.size(), "data": raw.compress(FileAccess.COMPRESSION_ZSTD)}

## Bytes off the wire -> {ok, data, error}
static func decode(raw_len: int, bytes: PackedByteArray) -> Dictionary:
	if raw_len <= 0 or raw_len > MAX_RAW or bytes.size() > MAX_COMPRESSED:
		return {"ok": false, "error": "The scenario is too large to share."}
	var raw := bytes.decompress(raw_len, FileAccess.COMPRESSION_ZSTD)
	if raw.size() != raw_len:
		return {"ok": false, "error": "The scenario data is damaged."}
	var j := JSON.new()
	if j.parse(raw.get_string_from_utf8()) != OK or not (j.data is Dictionary):
		return {"ok": false, "error": "The scenario data is not readable."}
	return check(j.data)

# ================================================================ checking ==

## {ok: bool, data: sanitised copy, error: "", notes: []}
static func check(src: Dictionary) -> Dictionary:
	var fail := func(msg: String) -> Dictionary:
		return {"ok": false, "error": msg, "data": {}, "notes": []}
	var budget := [20000]
	if not _shape_ok(src, 0, budget):
		return fail.call("The scenario has values the game cannot use (too deep, too long, or not a number).")
	var base := Snapshot.validate(src)
	if base != "":
		return fail.call(base)
	var notes: Array = []
	var d := {}
	for k in TOP_KEYS:
		if src.has(k):
			d[k] = (src[k] as Variant)
	d = d.duplicate(true)
	# ---- setup
	if not (d.get("setup") is Dictionary):
		return fail.call("The scenario has no setup.")
	var su: Dictionary = {}
	var s0: Dictionary = d["setup"]
	for k2 in SETUP_KEYS:
		if s0.has(k2):
			su[k2] = s0[k2]
	su["mode"] = clampi(_int(su.get("mode", 0)), 0, 2)
	su["alliance"] = clampi(_int(su.get("alliance", 0)), 0, 1)
	su["intakes"] = clampi(_int(su.get("intakes", 1)), 1, 2)
	su["robots"] = clampi(_int(su.get("robots", 1)), 1, 2)
	su["opponents"] = clampi(_int(su.get("opponents", 0)), 0, 2)
	su["per_robot"] = clampi(_int(su.get("per_robot", 1)), 1, 2)
	su["mate_is_ai"] = su.get("mate_is_ai") == true
	su["takes_nectar"] = su.get("takes_nectar") == true
	su["robot_name"] = _str(su.get("robot_name", "Robot"), 40)
	su["profile"] = clampi(_int(su.get("profile", 0)), 0, 2)
	su["specs"] = clean_specs(su.get("specs", {}))
	if String(su.get("auto_routine", "")) != "":
		notes.append("Its autonomous routine is a file on the sender's computer, so it is not used online.")
	su["auto_routine"] = ""
	d["setup"] = su
	d["auto"] = {"playing": false, "t": 0.0, "routine": ""}
	var n_robots: int = int(su["robots"]) + int(su["opponents"])
	# ---- robots
	var robots: Variant = d.get("robots")
	if not (robots is Array) or (robots as Array).is_empty() \
			or (robots as Array).size() > MAX_ROBOTS or (robots as Array).size() != n_robots:
		return fail.call("The scenario's robots do not match its roster.")
	var seen_idx := {}
	for r in robots:
		if not (r is Dictionary):
			return fail.call("A robot entry is not readable.")
		var rd: Dictionary = r
		var idx := _int(rd.get("index", -1))
		if idx < 0 or idx >= n_robots or seen_idx.has(idx):
			return fail.call("The scenario's robot numbering is broken.")
		seen_idx[idx] = true
		if not _pose_ok(rd, 3.5, 30.0):
			return fail.call("A robot is placed far outside the field or moving impossibly fast.")
		rd["label"] = _str(rd.get("label", "R%d" % (idx + 1)), 12)
		if rd.get("brain") is Dictionary:
			var br: Dictionary = rd["brain"]
			if not OpponentConfig.is_legacy(br):
				br["config"] = OpponentConfig.sanitize(OpponentConfig.from_brain(br))
			br["status"] = _str(br.get("status", ""), 80)
	# ai mask: which robots the server drives. Default = what the file says.
	var mask: Array = []
	var raw_mask: Variant = su.get("ai_mask")
	for i in n_robots:
		var ai := false
		if raw_mask is Array and i < (raw_mask as Array).size():
			ai = (raw_mask as Array)[i] == true
		else:
			for r2 in robots:
				if _int((r2 as Dictionary).get("index", -1)) == i:
					ai = (r2 as Dictionary).get("ai") == true
		mask.append(ai)
	su["ai_mask"] = mask
	# ---- elements
	var els: Variant = d.get("elements")
	if not (els is Array) or (els as Array).size() > MAX_ELEMENTS:
		return fail.call("The scenario has too many game elements.")
	var id_re := RegEx.create_from_string("^[A-Za-z0-9_:-]{1,16}$")
	for e in els:
		if not (e is Dictionary):
			return fail.call("A game element is not readable.")
		var ed: Dictionary = e
		if id_re.search(String(ed.get("id", ""))) == null:
			return fail.call("A game element has an id the game cannot use.")
		if not _pose_ok(ed, 4.0, 40.0):
			return fail.call("A game element is far outside the field or moving impossibly fast.")
		if _int(ed.get("kind", 0)) not in [BB.Kind.POLLEN, BB.Kind.NECTAR]:
			return fail.call("A game element is of an unknown kind.")
	# ---- hives
	var hv: Variant = d.get("hives")
	if not (hv is Array) or (hv as Array).size() != 2:
		return fail.call("The scenario must have both HIVES.")
	for h in hv:
		if not (h is Dictionary) or not _pose_ok(h, 3.0, 50.0):
			return fail.call("A HIVE entry is not readable.")
	# ---- match clock
	var m: Variant = d.get("match")
	if not (m is Dictionary):
		return fail.call("The scenario has no match state.")
	var md: Dictionary = m
	var ev: Array = []
	for line in md.get("events", []):
		if line is String and ev.size() < 12:
			ev.append(_str(line, 120))
	md["events"] = ev
	# ---- meta
	var meta: Dictionary = d.get("meta", {}) if d.get("meta") is Dictionary else {}
	d["meta"] = {"name": _str(meta.get("name", "Shared scenario"), 60),
		"note": _str(meta.get("note", ""), 200)}
	d.erase("origin")
	# ---- meaning: everything the offline editor refuses, this refuses too
	var errs: Array = []
	for p in Snapshot.check_draft(d):
		if String(p.get("severity", "")) == "error":
			errs.append(String(p.get("msg", "")))
	if not errs.is_empty():
		return fail.call("The scenario cannot be played: " + String(errs[0]))
	return {"ok": true, "error": "", "data": d, "notes": notes}

## Hardware numbers the drivetrain is built from: only known keys, each
## clamped to the range the Garage allows.
static func clean_specs(raw: Variant) -> Dictionary:
	var out := {}
	for k: String in RobotShop.SPEC:
		var lo: float = RobotShop.SPEC[k][1]
		var hi: float = RobotShop.SPEC[k][2]
		var v: float = RobotShop.SPEC[k][0]
		if raw is Dictionary and (raw as Dictionary).has(k):
			var x: Variant = (raw as Dictionary)[k]
			if (x is float or x is int) and is_finite(float(x)):
				v = float(x)
		out[k] = clampf(v, lo, hi)
	return out

static func _shape_ok(v: Variant, depth: int, budget: Array) -> bool:
	budget[0] = int(budget[0]) - 1
	if int(budget[0]) < 0 or depth > MAX_DEPTH:
		return false
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_INT:
			return true
		TYPE_FLOAT:
			return is_finite(v)
		TYPE_STRING:
			return (v as String).length() <= MAX_STRING
		TYPE_ARRAY:
			if (v as Array).size() > MAX_ARRAY:
				return false
			for x in v:
				if not _shape_ok(x, depth + 1, budget):
					return false
			return true
		TYPE_DICTIONARY:
			if (v as Dictionary).size() > 64:
				return false
			for k in v:
				if typeof(k) != TYPE_STRING or (k as String).length() > 40:
					return false
				if not _shape_ok((v as Dictionary)[k], depth + 1, budget):
					return false
			return true
	return false

static func _pose_ok(d: Dictionary, reach_m: float, speed: float) -> bool:
	var o := Snapshot.unpack_v3(d.get("origin", []))
	if absf(o.x) > reach_m or absf(o.z) > reach_m or o.y < -2.0 or o.y > 3.0:
		return false
	var basis: Variant = d.get("basis", [])
	if basis is Array and (basis as Array).size() >= 9:
		var bb := Snapshot.unpack_basis(basis)
		for axis in [bb.x, bb.y, bb.z]:
			if absf((axis as Vector3).length() - 1.0) > 0.05:
				return false
	for key in ["lin", "ang"]:
		if d.has(key) and Snapshot.unpack_v3(d.get(key)).length() > speed:
			return false
	return true

static func _int(v: Variant) -> int:
	if v is int:
		return v
	if v is float and is_finite(v):
		return int(v)
	return 0

static func _str(v: Variant, n: int) -> String:
	if not (v is String):
		return ""
	var out := ""
	for ch in (v as String):
		var c := ch.unicode_at(0)
		if c >= 32 and c != 127:
			out += ch
	return out.substr(0, n)

# ================================================================= summary ==

## What everyone is shown before they can press Ready.
static func summary(d: Dictionary, notes: Array = []) -> Dictionary:
	var m: Dictionary = d.get("match", {})
	var su: Dictionary = d.get("setup", {})
	var phase := int(m.get("phase", BB.Phase.TELEOP))
	var names := ["Pre-match", "Autonomous", "Transition", "Teleop", "Settling", "Finished"]
	var modes := ["Full match", "Teleop only", "Free practice"]
	var mask: Array = su.get("ai_mask", [])
	var robots: Array = []
	for r in d.get("robots", []):
		var idx := int(r.get("index", 0))
		var ai: bool = idx < mask.size() and bool(mask[idx])
		var beh := ""
		if ai:
			beh = OpponentConfig.describe(OpponentConfig.from_brain(r.get("brain", {}))) \
				if r.get("brain") is Dictionary else "Collect and score · Standard"
		robots.append({"index": idx, "label": String(r.get("label", "R%d" % (idx + 1))),
			"alliance": int(r.get("alliance", 0)), "ai": ai, "behavior": beh,
			"hopper": (r.get("hopper", []) as Array).size()})
	robots.sort_custom(func(a, b) -> bool: return int(a["index"]) < int(b["index"]))
	var obj: Dictionary = d.get("objective", {}) if d.get("objective") is Dictionary else {}
	var prof := int(su.get("profile", 0))
	var specs: Dictionary = su.get("specs", {})
	var hw := "Stock robot (the default drivetrain)"
	if prof == RobotShop.Source.MEASURED:
		hw = "Measured robot \"%s\": %.0f in/s forward, %.0f in/s strafe, %.0f°/s turn" % [
			String(su.get("robot_name", "")), float(specs.get("meas_fwd", 0)),
			float(specs.get("meas_strafe", 0)), float(specs.get("meas_turn", 0))]
	var out_notes: Array = notes.duplicate()
	out_notes.append("Online, every robot is drawn with the built-in model: custom CAD models are not shared. The simulated drivetrain is the profile above.")
	var flying := Objective.count_in_flight(d)
	if flying > 0:
		out_notes.append("%d ball%s already in the air at the start." % [flying, "" if flying == 1 else "s are"])
	return {
		"name": String(d.get("meta", {}).get("name", "Scenario")),
		"mode": modes[clampi(int(su.get("mode", 0)), 0, 2)],
		"phase": names[clampi(phase, 0, 5)],
		"clock": "no clock" if int(su.get("mode", 0)) == BB.Mode.FREE_PRACTICE
			else BB.clock_text(float(m.get("time_left", 0.0))),
		"robots": robots,
		"elements": (d.get("elements", []) as Array).size(),
		"objective": Objective.describe(obj) if Objective.is_set(obj) else "No objective",
		"hardware": hw,
		"notes": out_notes,
	}
