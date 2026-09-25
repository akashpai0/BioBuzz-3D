class_name ControlProfile
extends RefCounted
##
## A NAMED SET OF CONTROLLER BINDINGS AND FEEL SETTINGS.
##
## Kept deliberately separate from three things it is often confused with:
##
##   * the DEVICE. A controller's id is whatever number Godot handed it this
##     session, and two identical pads have the same GUID. A profile is not a
##     controller; it is how you like a controller to behave.
##   * the SEAT. Robot 1 Driver is a job, not a person and not a pad. A seat
##     points at a profile; it does not own one.
##   * the ROBOT. Nothing here changes what the robot can physically do. The
##     top speed and turn rate are the robot's; these settings only shape how
##     far your thumb has to move to ask for them.
##
## Stored as JSON in its own file so that damaging it cannot take the keyboard
## bindings or any other preference down with it.
##

const PATH := "user://control_profiles.json"
const STOCK_ID := "stock"

## Feel settings, each [default, min, max]. The screen builds itself from this.
const TUNING := {
	"move_deadzone":   [0.12, 0.00, 0.40],
	"turn_deadzone":   [0.12, 0.00, 0.40],
	"move_curve":      [1.00, 0.50, 3.00],
	"turn_curve":      [1.00, 0.50, 3.00],
	"invert_move_x":   [0.0, 0.0, 1.0],
	"invert_move_y":   [0.0, 0.0, 1.0],
	"invert_turn":     [0.0, 0.0, 1.0],
	"precision_scale": [0.40, 0.10, 1.00],
}

## One line each, shown under the control. Written to be read by someone who
## has never heard the word "deadzone".
const TUNING_HELP := {
	"move_deadzone": "How far the stick must move before the robot does. Raise it if the robot creeps while you are not touching the stick.",
	"turn_deadzone": "The same, for the turning stick.",
	"move_curve": "A gentler centre makes small stick movements ask for less, so you can make fine corrections. Full stick still reaches full speed either way.",
	"turn_curve": "A gentler centre makes small stick movements turn less, for lining up a shot. Full stick still reaches the robot's full turn rate.",
	"invert_move_x": "Swap left and right on the driving stick.",
	"invert_move_y": "Swap forward and back on the driving stick.",
	"invert_turn": "Swap which way the turning stick turns you.",
	"precision_scale": "How slow the robot goes while you hold precision mode.",
}

const TUNING_LABEL := {
	"move_deadzone": "Movement deadzone",
	"turn_deadzone": "Turning deadzone",
	"move_curve": "Movement response",
	"turn_curve": "Turning response",
	"invert_move_x": "Invert strafe",
	"invert_move_y": "Invert forward/back",
	"invert_turn": "Invert turning",
	"precision_scale": "Precision-mode speed",
}

var id := ""
var name := "New profile"
## action -> {"buttons": [int], "axis": [axis_id, direction]}. Only actions the
## player has changed appear here; everything else falls through to BB.ACTIONS.
var bindings: Dictionary = {}
var tuning: Dictionary = {}

func _init(profile_name := "New profile") -> void:
	name = profile_name
	for k: String in TUNING:
		tuning[k] = float(TUNING[k][0])

# ================================================================== reading ==

func get_tuning(key: String) -> float:
	var spec: Array = TUNING.get(key, [0.0, 0.0, 1.0])
	return clampf(float(tuning.get(key, float(spec[0]))),
		float(spec[1]), float(spec[2]))

func is_on(key: String) -> bool:
	return get_tuning(key) >= 0.5

func set_tuning(key: String, v: float) -> void:
	if not TUNING.has(key):
		return
	var spec: Array = TUNING[key]
	tuning[key] = clampf(v, float(spec[1]), float(spec[2]))

func reset_tuning() -> void:
	for k: String in TUNING:
		tuning[k] = float(TUNING[k][0])

## What this profile binds `action` to, falling back to the stock layout in
## BB.ACTIONS for anything it has not changed.
func spec_for(action: String) -> Dictionary:
	if bindings.has(action):
		return bindings[action]
	var stock: Dictionary = BB.ACTIONS.get(action, {})
	var out := {}
	if stock.has("buttons"):
		out["buttons"] = (stock["buttons"] as Array).duplicate()
	if stock.has("axis"):
		out["axis"] = (stock["axis"] as Array).duplicate()
	return out

## True when the player has moved this action off the stock layout.
func is_custom(action: String) -> bool:
	return bindings.has(action)

# ================================================================ rebinding ==

## Which OTHER actions already use this input. Context-sharing is allowed for
## the pairs in SHARED below, because "Start before a match, Pause during one"
## is one button doing one obvious thing, not a conflict.
const SHARED := [["start_match", "pause"]]

static func may_share(a: String, b: String) -> bool:
	for pair in SHARED:
		if (pair as Array).has(a) and (pair as Array).has(b):
			return true
	return false

func conflicts(action: String, input: Dictionary) -> Array:
	var out: Array = []
	for other: String in BB.ACTIONS:
		if other == action or may_share(action, other):
			continue
		var s := spec_for(other)
		if input.has("button") and (s.get("buttons", []) as Array).has(int(input["button"])):
			out.append(other)
		elif input.has("axis") and s.has("axis"):
			var ax: Array = s["axis"]
			if int(ax[0]) == int(input["axis"]) \
					and signf(float(ax[1])) == signf(float(input["dir"])):
				out.append(other)
	return out

## Point `action` at a pressed button or a pushed axis.
func bind(action: String, input: Dictionary) -> void:
	var spec := {}
	if input.has("button"):
		spec["buttons"] = [int(input["button"])]
	elif input.has("axis"):
		spec["axis"] = [int(input["axis"]), signf(float(input["dir"]))]
	else:
		return
	bindings[action] = spec

func clear_binding(action: String) -> void:
	bindings.erase(action)

## Drop every remapping and go back to the stock pad layout.
func reset_bindings() -> void:
	bindings.clear()

## How this action reads on screen. Names the physical control, because "button
## 0" is not something anybody can find with their thumb.
func label_for(action: String) -> String:
	var s := spec_for(action)
	var bits: Array[String] = []
	for b in s.get("buttons", []):
		bits.append(BB.pad_button_name(int(b)))
	if s.has("axis"):
		var ax: Array = s["axis"]
		bits.append(BB.pad_axis_name(int(ax[0]), float(ax[1])))
	return " / ".join(bits) if not bits.is_empty() else "—"

# ============================================================== the library ==

## Every profile on this computer, newest last. Always contains the stock one.
static func all() -> Array:
	var out: Array = []
	var raw := _read_file()
	for d in raw.get("profiles", []):
		var p := from_dict(d)
		if p != null:
			out.append(p)
	if _find(out, STOCK_ID) == null:
		var stock := ControlProfile.new("Standard gamepad")
		stock.id = STOCK_ID
		out.insert(0, stock)
	return out

static func _find(list: Array, want_id: String) -> ControlProfile:
	for p in list:
		if (p as ControlProfile).id == want_id:
			return p
	return null

static func get_one(want_id: String) -> ControlProfile:
	var list := all()
	var p := _find(list, want_id)
	return p if p != null else _find(list, STOCK_ID)

static func save_all(list: Array) -> void:
	var rows: Array = []
	for p in list:
		rows.append((p as ControlProfile).to_dict())
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"version": 1, "profiles": rows}, "\t"))
	f.close()

static func save_one(p: ControlProfile) -> void:
	var list := all()
	var found := false
	for i in list.size():
		if (list[i] as ControlProfile).id == p.id:
			list[i] = p
			found = true
	if not found:
		list.append(p)
	save_all(list)

## Create a profile, optionally copying another. Returns the new one, saved.
static func create(new_name: String, copy_from := "") -> ControlProfile:
	var p := ControlProfile.new(new_name)
	p.id = "cp-%d-%04d" % [Time.get_unix_time_from_system(), randi() % 10000]
	if copy_from != "":
		var src := get_one(copy_from)
		if src != null:
			p.bindings = src.bindings.duplicate(true)
			p.tuning = src.tuning.duplicate(true)
	save_one(p)
	return p

static func delete_one(want_id: String) -> bool:
	if want_id == STOCK_ID:
		return false                 # the stock layout is the floor to fall to
	var list := all()
	var out: Array = []
	for p in list:
		if (p as ControlProfile).id != want_id:
			out.append(p)
	save_all(out)
	return out.size() < list.size()

static func rename_to(want_id: String, new_name: String) -> void:
	var clean := new_name.strip_edges()
	if clean == "":
		return
	var list := all()
	for p in list:
		if (p as ControlProfile).id == want_id:
			(p as ControlProfile).name = clean.substr(0, 40)
	save_all(list)

# ========================================================= reading the file ==

## A damaged or half-written file must lose controller settings and NOTHING
## else, and must never take the game down with it.
static func _read_file() -> Dictionary:
	if not FileAccess.file_exists(PATH):
		return {}
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	if not (parsed is Dictionary):
		push_warning("control_profiles.json is not readable; using defaults")
		return {}
	return parsed as Dictionary

func to_dict() -> Dictionary:
	return {"id": id, "name": name, "bindings": bindings.duplicate(true),
		"tuning": tuning.duplicate(true)}

## EVERY VALUE IS CHECKED. A hand-edited or truncated file gives back a working
## profile with defaults in place of whatever was wrong, rather than a crash or
## a deadzone of 1e9.
static func from_dict(d: Variant) -> ControlProfile:
	if not (d is Dictionary):
		return null
	var raw: Dictionary = d
	var p := ControlProfile.new(String(raw.get("name", "Recovered profile")))
	p.id = String(raw.get("id", ""))
	if p.id == "":
		return null
	p.name = p.name.strip_edges().substr(0, 40)
	if p.name == "":
		p.name = "Recovered profile"
	var t: Variant = raw.get("tuning", {})
	if t is Dictionary:
		for k: String in TUNING:
			if (t as Dictionary).has(k):
				var v: Variant = (t as Dictionary)[k]
				if (v is float or v is int) and is_finite(float(v)):
					p.set_tuning(k, float(v))
	var b: Variant = raw.get("bindings", {})
	if b is Dictionary:
		for a: String in (b as Dictionary):
			if not BB.ACTIONS.has(a):
				continue                 # an action this build no longer has
			var spec: Variant = (b as Dictionary)[a]
			if not (spec is Dictionary):
				continue
			var clean := {}
			var btns: Variant = (spec as Dictionary).get("buttons", [])
			if btns is Array:
				var ok: Array = []
				for x in btns:
					if (x is float or x is int) and int(x) >= 0 and int(x) < 32:
						ok.append(int(x))
				if not ok.is_empty():
					clean["buttons"] = ok
			var ax: Variant = (spec as Dictionary).get("axis", [])
			if ax is Array and (ax as Array).size() == 2:
				var a0: Variant = (ax as Array)[0]
				var a1: Variant = (ax as Array)[1]
				if (a0 is float or a0 is int) and int(a0) >= 0 and int(a0) < 10 \
						and (a1 is float or a1 is int) and absf(float(a1)) > 0.0:
					clean["axis"] = [int(a0), signf(float(a1))]
			if not clean.is_empty():
				p.bindings[a] = clean
	return p
