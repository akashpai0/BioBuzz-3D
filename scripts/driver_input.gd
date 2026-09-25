class_name DriverInput
extends RefCounted
##
## Reads controls FOR ONE DRIVER, and shapes them.
##
## `Input.get_action_strength()` is global — it answers "is anyone pressing
## this", which is exactly wrong once two people are driving two robots on one
## computer. This resolves bindings against ONE device:
##
##   device = -2   NOTHING. A second driver with no device left to give them
##                 sits still rather than mirroring player one's keyboard.
##   device = -1   the keyboard, and only the keyboard
##   device >= 0   that joypad, and only that joypad
##
## ── WHAT SHAPING MEANS, AND WHAT IT DOES NOT ──────────────────────────────
## Everything here happens between the stick and the command. It NEVER touches
## what the robot can physically do: `max_speed_in_s` and `yaw_rate_max` are
## the robot's and are not scaled from this file. Full deflection always asks
## for full command, whatever the tuning says — a response curve changes how
## far your thumb has to travel to ask for half, not what the maximum is.
##
## It also applies ONLY to human input. `Robot.set_drive()` — which is how the
## AI drivers and saved autonomous routines move — is downstream of all of it.
##

## No device at all — see the note above.
const NONE := -2

## Anything below this on a raw axis is treated as untouched when deciding
## whether a device has returned to NEUTRAL. Separate from a profile's
## deadzone, which is a feel setting the player owns.
const NEUTRAL_EPS := 0.25

## NETWORK SEATS. In an online room the server's robots are driven by
## players on other computers. Each robot gets two virtual devices — driver
## (VIRTUAL + 2r) and operator (VIRTUAL + 2r + 1) — whose readings are
## whatever the room last accepted from the player holding that seat. The
## player's own profile (deadzone, curve, inversion) was applied on THEIR
## computer before sending, so nothing here reshapes it; their physical
## device id never leaves their machine.
const VIRTUAL := 1000

## dev -> {move, turn, precision, held: {action: bool}, edges: {action: n}}
static var _virtual: Dictionary = {}

static func is_virtual(device: int) -> bool:
	return device >= VIRTUAL

static func set_virtual(device: int, mv: Vector2, trn: float, precision: float,
		held: Dictionary) -> void:
	var v: Dictionary = _virtual.get(device, {"edges": {}})
	v["move"] = mv
	v["turn"] = trn
	v["precision"] = precision
	v["held"] = held.duplicate()
	_virtual[device] = v

## A discrete press (outtake, aim assist, …) that the robot will see as one
## just_pressed() per press, however the packets carrying it were grouped.
static func add_virtual_presses(device: int, action: String, n: int) -> void:
	if n <= 0:
		return
	var v: Dictionary = _virtual.get(device, {"edges": {}})
	var e: Dictionary = v.get("edges", {})
	e[action] = int(e.get(action, 0)) + n
	v["edges"] = e
	_virtual[device] = v

## Neutral: nothing held, no stick, no queued presses.
static func clear_virtual(device: int) -> void:
	_virtual.erase(device)

static func clear_all_virtual() -> void:
	_virtual.clear()

static func virtual_state(device: int) -> Dictionary:
	return _virtual.get(device, {})

static var _prev: Dictionary = {}
## device -> true while every input on it must return to neutral before any
## action is accepted again.
static var _gated: Dictionary = {}
## device -> profile id. Set by whoever assigns seats; unset means stock.
static var _profiles: Dictionary = {}
static var _cache: Dictionary = {}

# ================================================================= profiles ==

static func set_profile(device: int, profile_id: String) -> void:
	if device <= NONE:
		return
	_profiles[device] = profile_id
	_cache.erase(device)

static func profile_id(device: int) -> String:
	return String(_profiles.get(device, ControlProfile.STOCK_ID))

## The profile shaping this device, cached because it is read every frame for
## every axis of every driver.
static func profile(device: int) -> ControlProfile:
	var pid := profile_id(device)
	var hit: Variant = _cache.get(device)
	if hit is ControlProfile and (hit as ControlProfile).id == pid:
		return hit
	var p := ControlProfile.get_one(pid)
	_cache[device] = p
	return p

## Forget cached profiles so an edit on the settings screen is felt at once.
static func refresh_profiles() -> void:
	_cache.clear()

# ================================================================== shaping ==

## THE DEADZONE, DONE CONTINUOUSLY.
##
## The old rule was a threshold: below 0.18 the axis read zero, and at 0.181 it
## read 0.181 — so the robot went from nothing to nearly a fifth of full speed
## across one hair of stick travel, and there was no way to ask for 5%.
##
## This rescales instead. Output is zero inside the deadzone, leaves it at
## zero, rises smoothly, and reaches exactly 1.0 at full deflection:
##
##     t = (magnitude - deadzone) / (1 - deadzone)     continuous at both ends
##     out = t ^ curve                                 1.0 = straight line
##
## `curve` above 1 gives a gentler centre — small movements ask for less — and
## below 1 a sharper one. Neither changes the maximum: t is 1 at full stick, so
## out is 1 whatever the exponent.
static func shape(magnitude: float, deadzone: float, curve: float) -> float:
	var m := clampf(magnitude, 0.0, 1.0)
	if m <= deadzone:
		return 0.0
	var span := maxf(1.0 - deadzone, 0.0001)
	var t := clampf((m - deadzone) / span, 0.0, 1.0)
	return pow(t, maxf(curve, 0.01))

## THE DRIVING STICK IS ONE STICK, not two axes that happen to be near each
## other. Treating it as two independent axes gives a square deadzone — a
## diagonal nudge of (0.15, 0.15) reads as nothing on both axes even though the
## thumb has moved 0.21 — and lets a full diagonal ask for 1.41x full speed.
##
## So the magnitude is shaped once, radially, and the DIRECTION is preserved.
## The result is bounded by 1.0 in every direction, including the corners.
static func shape_vector(v: Vector2, deadzone: float, curve: float) -> Vector2:
	var m := v.length()
	if m <= 0.00001:
		return Vector2.ZERO
	var out := shape(minf(m, 1.0), deadzone, curve)
	return (v / m) * out

# =================================================================== reading =

## Raw, unshaped, for the diagnostics display: what the hardware is sending.
static func raw_move(device: int) -> Vector2:
	if device <= NONE:
		return Vector2.ZERO
	if device >= VIRTUAL:
		return _virtual.get(device, {}).get("move", Vector2.ZERO)
	if device < 0:
		return Vector2(_key_axis(device, "strafe_right", "strafe_left"),
			_key_axis(device, "drive_fwd", "drive_back"))
	return Vector2(Input.get_joy_axis(device, JOY_AXIS_LEFT_X),
		-Input.get_joy_axis(device, JOY_AXIS_LEFT_Y))

static func raw_turn(device: int) -> float:
	if device <= NONE:
		return 0.0
	if device >= VIRTUAL:
		return float(_virtual.get(device, {}).get("turn", 0.0))
	if device < 0:
		return _key_axis(device, "turn_right", "turn_left")
	return Input.get_joy_axis(device, JOY_AXIS_RIGHT_X)

## Shaped: what the robot is actually asked for. x = strafe, y = forward.
static func move(device: int) -> Vector2:
	if device >= VIRTUAL:
		return raw_move(device)          # shaped on the player's own computer
	if device <= NONE or is_gated(device):
		return Vector2.ZERO
	var p := profile(device)
	var v := raw_move(device)
	if p.is_on("invert_move_x"):
		v.x = -v.x
	if p.is_on("invert_move_y"):
		v.y = -v.y
	return shape_vector(v, p.get_tuning("move_deadzone"),
		p.get_tuning("move_curve"))

static func turn(device: int) -> float:
	if device >= VIRTUAL:
		return raw_turn(device)
	if device <= NONE or is_gated(device):
		return 0.0
	var p := profile(device)
	var raw := raw_turn(device)
	if p.is_on("invert_turn"):
		raw = -raw
	return signf(raw) * shape(absf(raw), p.get_tuning("turn_deadzone"),
		p.get_tuning("turn_curve"))

## How much the robot slows while precision mode is held.
static func precision_scale(device: int) -> float:
	if device <= NONE:
		return 1.0
	if device >= VIRTUAL:
		return clampf(float(_virtual.get(device, {}).get("precision", 1.0)), 0.1, 1.0)
	return profile(device).get_tuning("precision_scale")

static func _key_axis(device: int, plus: String, minus: String) -> float:
	return _key_down(device, plus) - _key_down(device, minus)

static func _key_down(device: int, action: String) -> float:
	for k: int in BB.keys_for(action):
		if Input.is_physical_key_pressed(k):
			return 1.0
	return 0.0

## Button-style reading, for everything that is not a driving axis. Triggers
## read as an analogue strength so a half-pull is a half-pull.
static func strength(device: int, action: String) -> float:
	if device <= NONE or is_gated(device):
		return 0.0
	return raw_strength(device, action)

## The same reading WITHOUT the neutral gate, for diagnostics: the preview has
## to show a held trigger even while the gate is refusing to act on it.
static func raw_strength(device: int, action: String) -> float:
	if device <= NONE:
		return 0.0
	if device >= VIRTUAL:
		var held: Dictionary = _virtual.get(device, {}).get("held", {})
		return 1.0 if bool(held.get(action, false)) else 0.0
	if device < 0:
		return _key_down(device, action)
	var spec := profile(device).spec_for(action)
	var v := 0.0
	for b: int in spec.get("buttons", []):
		if Input.is_joy_button_pressed(device, b):
			v = 1.0
	if spec.has("axis"):
		var ax: Array = spec["axis"]
		var raw: float = Input.get_joy_axis(device, int(ax[0])) * float(ax[1])
		# a trigger's own small deadzone: resting travel must not count as held
		if raw > 0.12:
			v = maxf(v, minf(raw, 1.0))
	return v

static func pressed(device: int, action: String) -> bool:
	return strength(device, action) > 0.5

## Edge detection, per device, so two drivers' toggles do not interfere.
static func just_pressed(device: int, action: String) -> bool:
	if device >= VIRTUAL:
		# presses arrive as counted events, not as a level to edge-detect
		var v: Dictionary = _virtual.get(device, {})
		var e: Dictionary = v.get("edges", {})
		var n := int(e.get(action, 0))
		if n <= 0:
			return false
		e[action] = n - 1
		return true
	var key := "%d:%s" % [device, action]
	var now := pressed(device, action)
	var was: bool = _prev.get(key, false)
	_prev[key] = now
	return now and not was

# ============================================================ THE NEUTRAL GATE

## NOTHING HELD ACROSS A CHANGE COUNTS AS A FRESH PRESS.
##
## After a rebind, a profile load, a reconnect or a restored situation, the
## player's hands are in an unknown state and the game's idea of "was this down
## last frame" belongs to a different world. A trigger that was held while the
## menu was open would fire the moment control came back; a stick left pushed
## by a rebinding dialog would drive away.
##
## So the device is GATED: every reading returns zero and no edge is detected
## until the hardware is seen at rest. Then it opens by itself, with no press
## having been consumed and none invented.
static func require_neutral(device: int) -> void:
	if device <= NONE:
		return
	_gated[device] = true
	for key in _prev.keys():
		if String(key).begins_with("%d:" % device):
			_prev[key] = false

static func gate_all() -> void:
	for d in devices():
		require_neutral(d)

static func is_gated(device: int) -> bool:
	if device >= VIRTUAL:
		return false                     # the room keeps its own neutral gate
	if not bool(_gated.get(device, false)):
		return false
	if at_neutral(device):
		_gated.erase(device)
		return false
	return true

## Is everything on this device at rest? Sticks centred, triggers released, no
## button down. Read raw, because the gate cannot ask the gated reader.
static func at_neutral(device: int) -> bool:
	if device <= NONE:
		return true
	if device < 0:
		for a: String in BB.ACTIONS:
			if _key_down(device, a) > 0.0:
				return false
		return true
	for b in 32:
		if Input.is_joy_button_pressed(device, b):
			return false
	for ax in [JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y, JOY_AXIS_RIGHT_X,
			JOY_AXIS_RIGHT_Y, JOY_AXIS_TRIGGER_LEFT, JOY_AXIS_TRIGGER_RIGHT]:
		if absf(Input.get_joy_axis(device, ax)) > NEUTRAL_EPS:
			return false
	return true

# ================================================================== devices ==

## Which devices are available to drive with, best first. A keyboard is always
## last so that plugging in one controller gives it to player one.
static func devices() -> Array:
	var out: Array = []
	for id in Input.get_connected_joypads():
		out.append(id)
	out.append(-1)
	return out

static func device_name(device: int) -> String:
	if device <= NONE:
		return "NO DEVICE"
	if device < 0:
		return "KEYBOARD"
	return Input.get_joy_name(device)

## A controller's hardware identity. NOT unique: two identical pads report the
## same GUID and the same name, which is exactly why seats cannot be matched on
## it alone. See Settings.identify_seat().
static func device_guid(device: int) -> String:
	if device < 0:
		return "keyboard"
	return Input.get_joy_guid(device)

## True when more than one CONNECTED controller is indistinguishable from this
## one, so anything that tries to recognise it by hardware alone is guessing.
static func is_ambiguous(device: int) -> bool:
	if device < 0:
		return false
	var me := device_guid(device)
	var n := 0
	for d in Input.get_connected_joypads():
		if device_guid(d) == me:
			n += 1
	return n > 1

## Drop every remembered button state.
##
## just_pressed() works off the previous frame's reading. After a situation is
## restored the previous frame belongs to a different world, and a button that
## was down when the snapshot was taken would read as a fresh press the moment
## play resumes — a robot firing or toggling field-centric on its own.
static func forget() -> void:
	_prev.clear()
	gate_all()
