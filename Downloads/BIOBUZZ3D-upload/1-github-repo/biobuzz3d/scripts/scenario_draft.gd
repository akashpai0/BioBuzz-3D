class_name ScenarioDraft
extends RefCounted
##
## THE THING THE EDITOR EDITS.
##
## A draft is a saved-situation snapshot — the SAME versioned format the
## checkpoint system already writes — plus the operations the editor needs to
## change it safely. Nothing in the editor's UI touches the dictionary
## directly: every change comes through a method here, which is what keeps
## undo, validation and the object graph honest.
##
## UNDO IS A STACK OF WHOLE SNAPSHOTS. A situation is about twelve kilobytes,
## so fifty of them is nothing, and a full copy cannot half-apply the way a
## hand-written inverse operation can. Every mutation calls `_push()` first.
##
## Positions are in FIELD INCHES throughout this class — the manual's frame,
## the same numbers the rest of the project talks in — and converted to metres
## only when they go into the snapshot.
##

const MAX_HISTORY := 60
## Roster limits the game actually supports.
const MAX_OURS := 2
const MAX_FOES := 2

var data: Dictionary = {}
var name := "New situation"
var note := ""
## The library id this draft came from, "" for a brand new one.
var source_id := ""
var dirty := false

var _history: Array = []
var _future: Array = []

# ================================================================== making ===

static func from_snapshot(d: Dictionary, nm := "", nt := "", id := "") -> ScenarioDraft:
	var draft := ScenarioDraft.new()
	draft.data = d.duplicate(true)
	draft.data.erase("meta")
	var meta: Dictionary = d.get("meta", {})
	draft.name = nm if nm != "" else String(meta.get("name", "New situation"))
	draft.note = nt if nt != "" else String(meta.get("note", ""))
	draft.source_id = id
	return draft

## A staged field: exactly what a match starts from.
static func staged(main: Node) -> ScenarioDraft:
	var draft := from_snapshot(Snapshot.capture(main), "New situation", "")
	draft.set_scenario("phase", BB.Phase.PRE)
	draft.set_scenario("time_left", 0.0)
	draft.clear_history()
	return draft

## An empty practice field: the walls, HIVES and FLOWERS stay, every loose ball
## goes, and one player robot remains so there is something to drive.
static func empty_field(main: Node) -> ScenarioDraft:
	var draft := from_snapshot(Snapshot.capture(main), "Empty practice field", "")
	draft.data["elements"] = []
	for r in draft.data.get("robots", []):
		r["hopper"] = []
	var m: Dictionary = draft.data.get("match", {})
	m["human_queue"] = {"0": [], "1": []}
	m["human_pool"] = {"0": [], "1": []}
	m["control"] = []
	draft.data["match"] = m
	draft.keep_only_player_robot()
	draft.set_scenario("phase", BB.Phase.PRE)
	draft.set_scenario("time_left", 0.0)
	draft.clear_history()
	return draft

func clear_history() -> void:
	_history.clear()
	_future.clear()
	dirty = false

# ================================================================== undo =====

func _push() -> void:
	_history.append(data.duplicate(true))
	if _history.size() > MAX_HISTORY:
		_history.pop_front()
	_future.clear()
	dirty = true

func can_undo() -> bool:
	return not _history.is_empty()

func can_redo() -> bool:
	return not _future.is_empty()

func undo() -> bool:
	if _history.is_empty():
		return false
	_future.append(data.duplicate(true))
	data = _history.pop_back()
	dirty = true
	return true

func redo() -> bool:
	if _future.is_empty():
		return false
	_history.append(data.duplicate(true))
	data = _future.pop_back()
	dirty = true
	return true

# ================================================================ reading ====

func elements() -> Array:
	return data.get("elements", [])

func robots() -> Array:
	return data.get("robots", [])

func setup() -> Dictionary:
	return data.get("setup", {})

## The practice objective. A scenario without one is free practice, and an old
## scenario saved before objectives existed simply has no key — so this fills
## in a blank rather than failing.
func objective() -> Dictionary:
	if not data.has("objective"):
		data["objective"] = Objective.blank()
	return data["objective"]

func set_objective(key: String, value: Variant) -> void:
	_push()
	var o := objective()
	o[key] = value
	if key == "kind":
		# a goal can only be measured against the targets it can honestly be
		# measured against, so switching kind fixes the target too
		var allowed := Objective.targets_for(int(value))
		if not allowed.has(int(o.get("target", 0))):
			o["target"] = allowed[0]

func set_area(key: String, value: float) -> void:
	_push()
	var a: Dictionary = objective().get("area", {"x": 0.0, "y": 0.0, "r": 18.0})
	a[key] = value
	objective()["area"] = a

func match_block() -> Dictionary:
	return data.get("match", {})

## One object by selection id: "e0007" for an element, "robot:1" for a robot,
## "hive:0" for a HIVE.
func find(id: String) -> Dictionary:
	if id.begins_with("robot:"):
		var i := int(id.trim_prefix("robot:"))
		for r in robots():
			if int(r.get("index", -1)) == i:
				return r
	elif id.begins_with("hive:"):
		var a := int(id.trim_prefix("hive:"))
		for h in data.get("hives", []):
			if int(h.get("alliance", -1)) == a:
				return h
	else:
		for e in elements():
			if String(e.get("id", "")) == id:
				return e
	return {}

func kind_of(id: String) -> String:
	if id.begins_with("robot:"):
		return "robot"
	if id.begins_with("hive:"):
		return "hive"
	return "element" if id != "" else ""

## Where an object is, in field inches (x, y, height).
func position_of(id: String) -> Vector3:
	var o := find(id)
	if o.is_empty():
		return Vector3.ZERO
	return BB.to_field(Snapshot.unpack_v3(o.get("origin", [])))

## Heading in degrees, field frame.
func yaw_of(id: String) -> float:
	var o := find(id)
	if o.is_empty():
		return 0.0
	var b := Snapshot.unpack_basis(o.get("basis", []))
	return rad_to_deg(b.get_euler().y)

func is_held(e: Dictionary) -> bool:
	return String(e.get("held", "")) != ""

# ================================================================ writing ====

func set_position(id: String, p: Vector3, stop_motion := true) -> void:
	var o := find(id)
	if o.is_empty():
		return
	_push()
	o = find(id)
	o["origin"] = Snapshot.pack_v3(BB.fp(p.x, p.y, p.z))
	if stop_motion:
		o["lin"] = [0.0, 0.0, 0.0]
		o["ang"] = [0.0, 0.0, 0.0]

func set_yaw(id: String, deg: float) -> void:
	var o := find(id)
	if o.is_empty():
		return
	_push()
	o = find(id)
	o["basis"] = Snapshot.pack_basis(Basis(Vector3.UP, deg_to_rad(deg)))

func set_velocity(id: String, lin: Vector3) -> void:
	var o := find(id)
	if o.is_empty():
		return
	_push()
	o = find(id)
	o["lin"] = Snapshot.pack_v3(lin)

## Drop a new ball on the field. Returns its id.
func add_element(kind: int, alliance: int, p: Vector3) -> String:
	_push()
	var id := _next_element_id()
	elements().append({
		"id": id, "kind": kind, "alliance": alliance, "held": "", "launcher": -1,
		"basis": Snapshot.pack_basis(Basis.IDENTITY),
		"origin": Snapshot.pack_v3(BB.fp(p.x, p.y, p.z)),
		"lin": [0.0, 0.0, 0.0], "ang": [0.0, 0.0, 0.0],
	})
	return id

## Rest height for a kind of ball, in inches: its radius, so it sits ON the
## tiles rather than half buried in them.
static func rest_height(kind: int) -> float:
	return (BB.NECTAR_DIA if kind == BB.Kind.NECTAR else BB.POLLEN_DIA) * 0.5

func duplicate_object(id: String) -> String:
	var o := find(id)
	if o.is_empty():
		return ""
	if kind_of(id) == "element":
		_push()
		var copy: Dictionary = o.duplicate(true)
		copy["id"] = _next_element_id()
		copy["held"] = ""
		var p := BB.to_field(Snapshot.unpack_v3(copy.get("origin", [])))
		copy["origin"] = Snapshot.pack_v3(BB.fp(p.x + 4.0, p.y + 4.0, p.z))
		elements().append(copy)
		return String(copy["id"])
	if kind_of(id) == "robot":
		return add_robot(int(o.get("alliance", BB.Alliance.RED)),
			bool(o.get("ai", false)))
	return ""

## Remove a ball, or a robot the roster can spare.
func remove_object(id: String) -> String:
	var what := kind_of(id)
	if what == "hive":
		return "HIVEs are part of the field and cannot be removed."
	if what == "element":
		_push()
		var arr := elements()
		for i in arr.size():
			if String(arr[i].get("id", "")) == id:
				arr.remove_at(i)
				break
		_forget_element(id)
		return ""
	if what == "robot":
		var idx := int(id.trim_prefix("robot:"))
		var mine := _player_robots()
		var o := find(id)
		if not bool(o.get("ai", false)) and o.get("alliance", 0) == _our_alliance() \
				and mine.size() <= 1:
			return "This is the robot you drive. Add another player robot first, or switch this one to AI."
		_push()
		var arr := robots()
		for i in arr.size():
			if int(arr[i].get("index", -1)) == idx:
				for eid in arr[i].get("hopper", []):
					_free_element(String(eid))
				arr.remove_at(i)
				break
		_renumber()
		return ""
	return "Nothing selected."

## Add a robot to one alliance. Returns the new selection id, or "" if the
## roster is already as big as the game supports.
## The opponent settings of an AI robot, as a live dictionary inside the draft
## (so edits go through set_opponent and are undoable). Legacy robots with no
## brain block get one here, read through the compatibility path.
##
## READING never converts. A legacy robot is shown through the compatibility
## path as a detached copy, so merely selecting it in the editor cannot change
## the file — or the practice-comparison group — of a situation nobody edited.
func opponent(id: String) -> Dictionary:
	var r := find(id)
	if r.is_empty():
		return {}
	var br: Variant = r.get("brain")
	if br is Dictionary and (br as Dictionary).has("config"):
		return (br as Dictionary)["config"]
	return OpponentConfig.from_brain(br if br is Dictionary else {})

## Only an EDIT turns a legacy brain into a configured one.
func _materialize_opponent(id: String) -> Dictionary:
	var r := find(id)
	var br: Variant = r.get("brain")
	if not (br is Dictionary) or not (br as Dictionary).has("config"):
		r["brain"] = {"behavior": OpponentConfig.Behavior.COLLECT,
			"config": OpponentConfig.from_brain(br if br is Dictionary else {})}
	return (r["brain"] as Dictionary)["config"]

## Change one opponent setting, undoably. Changing the BEHAVIOR resets the
## robot's runtime state, since a half-finished route means nothing to a
## defender; changing a setting keeps it.
func set_opponent(id: String, key: String, value: Variant) -> void:
	if find(id).is_empty():
		return
	_push()
	var cfg := _materialize_opponent(id)
	var r := find(id)
	if key == "behavior":
		var fresh := OpponentConfig.blank(int(value))
		fresh["waypoints"] = cfg.get("waypoints", [])
		fresh["area"] = cfg.get("area", {"x": 0.0, "y": 0.0})
		fresh["target"] = cfg.get("target", 0)
		r["brain"] = {"behavior": int(value), "config": fresh}
	elif key == "preset":
		OpponentConfig.apply_preset(cfg, String(value))
		(r["brain"] as Dictionary).erase("wp")
	else:
		cfg[key] = value
	# any edit invalidates saved mid-behavior state: it was for other settings
	for k in ["wp", "dir", "wait_left", "done", "attempts", "blocked_wait",
			"home", "home_yaw", "react_left", "seen", "seen_left", "status"]:
		(r["brain"] as Dictionary).erase(k)
	(r["brain"] as Dictionary)["behavior"] = int(cfg.get("behavior", 0)) \
		if key != "behavior" else int(value)
	dirty = true

func add_robot(alliance: int, ai: bool) -> String:
	var ours := 0
	var foes := 0
	for r in robots():
		if int(r.get("alliance", 0)) == _our_alliance():
			ours += 1
		else:
			foes += 1
	if alliance == _our_alliance() and ours >= MAX_OURS:
		return ""
	if alliance != _our_alliance() and foes >= MAX_FOES:
		return ""
	_push()
	var template: Dictionary = robots()[0].duplicate(true) if not robots().is_empty() \
		else {}
	var p := Vector3(-60.0 if alliance == BB.Alliance.RED else 60.0,
		-30.0 + 24.0 * float(ours + foes), 0.0)
	var spec := {
		"index": robots().size(),
		"alliance": alliance,
		"intakes": int(template.get("intakes", 1)),
		"ai": ai,
		"label": "AI" if ai else "P%d" % (ours + 1),
		"takes_nectar": bool(template.get("takes_nectar", false)),
		"basis": Snapshot.pack_basis(Basis(Vector3.UP,
			-PI * 0.5 if alliance == BB.Alliance.RED else PI * 0.5)),
		"origin": Snapshot.pack_v3(BB.fp(p.x, p.y, 0.0)),
		"lin": [0.0, 0.0, 0.0], "ang": [0.0, 0.0, 0.0],
		"start_basis": Snapshot.pack_basis(Basis.IDENTITY),
		"start_origin": Snapshot.pack_v3(BB.fp(p.x, p.y, 0.0)),
		"turret_yaw": 0.0, "hood_deg": 55.0,
		"launch_speed": BB.LAUNCH_SPEED_DEFAULT,
		"battery_v": BB.BATTERY_NOMINAL, "open_circuit": BB.BATTERY_NOMINAL,
		"field_centric": true, "auto_aim": true, "intake_on": true,
		"has_left": false, "turret_faults": 0, "enabled": false,
		"cooldown": 0.0, "manual_left": 0.0, "hopper": [],
	}
	if ai:
		# a new opponent starts as the one this game has always had
		spec["brain"] = {"behavior": OpponentConfig.Behavior.COLLECT,
			"config": OpponentConfig.blank(OpponentConfig.Behavior.COLLECT)}
	robots().append(spec)
	_renumber()
	return "robot:%d" % int(spec["index"])

## Keep exactly one player robot and drop everyone else — the empty-field start.
func keep_only_player_robot() -> void:
	var keep: Dictionary = {}
	for r in robots():
		if not bool(r.get("ai", false)):
			keep = r
			break
	if keep.is_empty() and not robots().is_empty():
		keep = robots()[0]
	if keep.is_empty():
		return
	keep["ai"] = false
	keep["hopper"] = []
	data["robots"] = [keep]
	_renumber()
	var s := setup()
	s["robots"] = 1
	s["opponents"] = 0
	s["mate_is_ai"] = false
	var m := match_block()
	m["control"] = []

## Set one property on a selected object. Everything the properties panel
## writes goes through here, so undo and the dirty flag cannot be forgotten.
func set_prop(id: String, key: String, value: Variant) -> void:
	var o := find(id)
	if o.is_empty():
		return
	_push()
	o = find(id)
	o[key] = value
	if key == "alliance" and kind_of(id) == "robot":
		_renumber()

## Scenario-wide settings: phase, clock, roster shape, description.
func set_scenario(key: String, value: Variant) -> void:
	_push()
	match key:
		"phase", "time_left":
			match_block()[key] = value
		"mode":
			setup()["mode"] = value
			match_block()["mode"] = value
		"alliance", "intakes", "takes_nectar", "auto_routine":
			setup()[key] = value
		_:
			setup()[key] = value

# ------------------------------------------------------------- hopper ------

## Move a loose ball into a robot's hopper, or back out onto the field.
##
## An element is EITHER in a hopper or loose on the tiles, never both: that is
## the invariant the restore depends on, so it is enforced here rather than
## hoped for.
func put_in_hopper(element_id: String, robot_index: int) -> String:
	var e := find(element_id)
	if e.is_empty():
		return "That ball is not on the field any more."
	var r := find("robot:%d" % robot_index)
	if r.is_empty():
		return "That robot is not in the roster."
	var hop: Array = r.get("hopper", [])
	if hop.size() >= BB.HOPPER_MAX:
		return "A hopper holds at most %d." % BB.HOPPER_MAX
	if int(e.get("kind", 0)) == BB.Kind.NECTAR and not bool(r.get("takes_nectar", false)):
		return "This robot's intake does not take NECTAR. Turn on pollen + nectar first."
	_push()
	_free_element(element_id)
	e = find(element_id)
	r = find("robot:%d" % robot_index)
	(r["hopper"] as Array).append(element_id)
	e["held"] = "robot:%d" % robot_index
	e["lin"] = [0.0, 0.0, 0.0]
	e["ang"] = [0.0, 0.0, 0.0]
	return ""

func take_from_hopper(element_id: String) -> void:
	var e := find(element_id)
	if e.is_empty():
		return
	_push()
	_free_element(element_id)
	e = find(element_id)
	e["held"] = ""

## Put a fresh ball straight into a hopper slot.
func fill_hopper_slot(robot_index: int, kind: int, alliance: int) -> String:
	var r := find("robot:%d" % robot_index)
	if r.is_empty():
		return "That robot is not in the roster."
	if (r.get("hopper", []) as Array).size() >= BB.HOPPER_MAX:
		return "A hopper holds at most %d." % BB.HOPPER_MAX
	var p := BB.to_field(Snapshot.unpack_v3(r.get("origin", [])))
	var id := add_element(kind, alliance, Vector3(p.x, p.y, 6.0))
	var err := put_in_hopper(id, robot_index)
	if err != "":
		remove_object(id)
	return err

# ------------------------------------------------------------- internals ----

## Detach an element from whoever holds it, wherever that is.
func _free_element(id: String) -> void:
	for r in robots():
		var hop: Array = r.get("hopper", [])
		for i in range(hop.size() - 1, -1, -1):
			if String(hop[i]) == id:
				hop.remove_at(i)

## Drop every reference to a deleted element.
func _forget_element(id: String) -> void:
	_free_element(id)
	for r in robots():
		if r.has("brain") and String((r["brain"] as Dictionary).get("target", "")) == id:
			(r["brain"] as Dictionary)["target"] = ""
	var m := match_block()
	for key in ["human_queue"]:
		var q: Dictionary = m.get(key, {})
		for a in q.keys():
			var arr: Array = q[a]
			for i in range(arr.size() - 1, -1, -1):
				if String(arr[i][0]) == id:
					arr.remove_at(i)
	var pool: Dictionary = m.get("human_pool", {})
	for a in pool.keys():
		var arr2: Array = pool[a]
		for i in range(arr2.size() - 1, -1, -1):
			if String(arr2[i]) == id:
				arr2.remove_at(i)

func _next_element_id() -> String:
	var top := 0
	for e in elements():
		var n := int(String(e.get("id", "e0000")).substr(1))
		top = maxi(top, n)
	return "e%04d" % (top + 1)

func _our_alliance() -> int:
	return int(setup().get("alliance", BB.Alliance.RED))

func _player_robots() -> Array:
	var out: Array = []
	for r in robots():
		if not bool(r.get("ai", false)):
			out.append(r)
	return out

## Roster order is ours first, then the other alliance, and the indices have to
## match: hopper ids, the G407 bookkeeping and the restore all address robots by
## position in this array.
func _renumber() -> void:
	var ours: Array = []
	var foes: Array = []
	for r in robots():
		if int(r.get("alliance", 0)) == _our_alliance():
			ours.append(r)
		else:
			foes.append(r)
	var ordered: Array = ours + foes
	var remap := {}
	for i in ordered.size():
		remap[int(ordered[i].get("index", i))] = i
	for i in ordered.size():
		ordered[i]["index"] = i
		if not bool(ordered[i].get("ai", false)):
			ordered[i]["label"] = "P%d" % (i + 1)
	data["robots"] = ordered
	# A DEFENDER'S TARGET IS A ROSTER INDEX, so it has to follow the robot it
	# names through the reorder. A target whose robot was removed becomes -1,
	# which the validator reports beside the setting.
	for r2 in ordered:
		var br: Variant = r2.get("brain")
		if br is Dictionary and (br as Dictionary).has("config"):
			var cfg: Dictionary = (br as Dictionary)["config"]
			if cfg.has("target"):
				cfg["target"] = int(remap.get(int(cfg["target"]), -1))
	# hopper ownership tags follow their robot
	for r in ordered:
		for eid in r.get("hopper", []):
			var e := find(String(eid))
			if not e.is_empty():
				e["held"] = "robot:%d" % int(r["index"])
	# and so does the G407 bookkeeping
	var m := match_block()
	var control: Array = m.get("control", [])
	for st in control:
		st["robot"] = int(remap.get(int(st.get("robot", -1)), -1))
	for i in range(control.size() - 1, -1, -1):
		if int(control[i].get("robot", -1)) < 0:
			control.remove_at(i)
	# the roster shape the restore rebuilds from
	var s := setup()
	var mate_ai := false
	var n_ours := 0
	for r in ordered:
		if int(r.get("alliance", 0)) == _our_alliance():
			n_ours += 1
			if n_ours == 2 and bool(r.get("ai", false)):
				mate_ai = true
	s["robots"] = maxi(1, n_ours)
	s["opponents"] = ordered.size() - n_ours
	s["mate_is_ai"] = mate_ai

# ============================================================== validation ===

## Problems with this draft, as [{severity, where, id, msg}].
## "error" blocks saving and testing; "warning" is an unusual setup, not a
## broken one, and never blocks anything.
func check() -> Array:
	return Snapshot.check_draft(data)

func errors() -> Array:
	var out: Array = []
	for p in check():
		if String(p.get("severity", "")) == "error":
			out.append(p)
	return out

## The snapshot to hand to the library or to a test run.
func to_snapshot() -> Dictionary:
	var d := data.duplicate(true)
	d["saved"] = Time.get_datetime_string_from_system(true)
	# Who drives each robot follows the robots' own AI flags, which is what the
	# editor edits; a mask carried in from an older capture must not override
	# a change made here.
	var setup: Dictionary = d.get("setup", {})
	var mask: Array = []
	var rs: Array = d.get("robots", [])
	for i in rs.size():
		var ai := false
		for r in rs:
			if int(r.get("index", -1)) == i:
				ai = bool(r.get("ai", false))
		mask.append(ai)
	setup["ai_mask"] = mask
	d["setup"] = setup
	return d
