extends Node
##
## EVERY ADJUSTABLE THING, IN ONE PLACE.
##
## Autoloaded as `Settings`. Holds the values, writes them to user://settings.cfg,
## and knows how to APPLY each one to the live game — so the settings screen is
## only a set of widgets bound to keys here, and nothing else in the project has
## to remember to re-read a preference.
##
## Applying is idempotent and safe to call every time something changes, which
## is what the screen does: drag a slider, hear the difference immediately.
##

const PATH := "user://settings.cfg"

## key -> [default, min, max]. The screen builds itself from this, so adding a
## setting here is most of the work of adding a setting.
const SPEC := {
	"audio/master":      [0.85, 0.0, 1.0],
	"audio/sfx":         [0.90, 0.0, 1.0],
	"audio/crowd":       [0.45, 0.0, 1.0],
	"game/fov":          [62.0, 50.0, 85.0],
	# RETIRED, kept only so an old settings.cfg still loads and can be migrated
	# once into a profile's turn response curve. Nothing reads it for gameplay.
	# See migrate_turn_sens().
	"game/turn_sens":    [1.00, 0.40, 1.80],
	"game/turn_sens_migrated": [0.0, 0.0, 1.0],
	"game/colorblind":   [0.0, 0.0, 1.0],
	"game/show_hud":     [1.0, 0.0, 1.0],
	# route, defense area and live status of each practice opponent, drawn on
	# the field. Off by default so an ordinary run is not cluttered.
	"game/opponent_overlay": [0.0, 0.0, 1.0],
	"video/fullscreen":  [0.0, 0.0, 1.0],
	"video/vsync":       [1.0, 0.0, 1.0],
	"video/msaa":        [2.0, 0.0, 3.0],
	"video/shadows":     [1.0, 0.0, 1.0],
	# 0 low, 1 high, 2 ultra — only matters while video/shadows is on
	"video/shadow_quality": [1.0, 0.0, 2.0],
	# index into RENDER_SCALES. Above 100% the 3D view is drawn bigger than the
	# screen and shrunk to fit (supersampling): the sharpest edges there are.
	"video/render_scale": [1.0, 0.0, 3.0],
	# the preset last picked on the Graphics page; 4 = custom
	"video/quality":     [2.0, 0.0, 4.0],
}

const RENDER_SCALES := [0.75, 1.0, 1.5, 2.0]
const QUALITY_NAMES := ["Low", "Medium", "High", "Max"]

## What each quality preset sets. Max on the desktop uses 8x MSAA and a bigger
## shadow map; browsers top out lower, so there it stays at 4x.
func preset_values(q: int) -> Dictionary:
	var web := OS.has_feature("web")
	match q:
		0: return {"video/render_scale": 0.0, "video/msaa": 0.0,
			"video/shadows": 0.0, "video/shadow_quality": 0.0}
		1: return {"video/render_scale": 1.0, "video/msaa": 1.0,
			"video/shadows": 1.0, "video/shadow_quality": 0.0}
		3: return {"video/render_scale": 3.0, "video/msaa": 2.0 if web else 3.0,
			"video/shadows": 1.0, "video/shadow_quality": 2.0}
	return {"video/render_scale": 1.0, "video/msaa": 2.0,
		"video/shadows": 1.0, "video/shadow_quality": 1.0}

func apply_preset(q: int) -> void:
	var vals := preset_values(q)
	for k: String in vals:
		values[k] = float(vals[k])
	set_value("video/quality", float(q))

## The preset the current values match, or 4 (custom) if none does.
func matching_preset() -> int:
	for q in 4:
		var vals := preset_values(q)
		var same := true
		for k: String in vals:
			if not is_equal_approx(get_value(k), float(vals[k])):
				same = false
		if same:
			return q
	return 4

var values: Dictionary = {}
## action -> physical keycode, for anything the player has rebound.
var keys: Dictionary = {}
## SEAT -> DEVICE, for anyone who has picked their own controller.
##
## Seats are numbered in the order they are filled: robot 1 driver, robot 1
## operator, robot 2 driver, robot 2 operator. Empty means "give this seat
## whatever comes next", which is what it did before anyone touched it.
var seats: Dictionary = {}
## SEAT -> PROFILE ID. A profile is how you like a controller to behave; it
## outlives the session and the device number, which do not.
var seat_profiles: Dictionary = {}

signal changed
## A device in use vanished mid-play. Carries the seat that lost it.
signal device_lost(seat: int, label: String)

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for k: String in SPEC:
		values[k] = float(SPEC[k][0])
	load_from_disk()
	migrate_turn_sens()
	Input.joy_connection_changed.connect(_on_joy_changed)
	# the viewport is not up on the first frame of an autoload
	call_deferred("apply_all")

func get_value(key: String) -> float:
	return float(values.get(key, float(SPEC.get(key, [0.0])[0])))

func is_on(key: String) -> bool:
	return get_value(key) >= 0.5

func set_value(key: String, v: float, save := true) -> void:
	var spec: Array = SPEC.get(key, [0.0, 0.0, 1.0])
	values[key] = clampf(v, float(spec[1]), float(spec[2]))
	apply_all()
	if save:
		save_to_disk()
	changed.emit()

# ====================================================== migrating turn_sens ==

## THE ONE-TIME MOVE FROM `game/turn_sens` TO A TURN RESPONSE CURVE.
##
## The old setting multiplied the turn COMMAND: `turn = clamp(turn * sens)`.
## Below 1.0 that capped what the robot could reach - at 0.4 a driver holding
## the stick fully over was asking for 40% turn and could not ask for more,
## which is not a sensitivity, it is a speed limit nobody agreed to.
##
## The replacement is an exponent on the response curve, which changes how far
## the stick travels for a given command and leaves the maximum at full:
##
##     curve = 1 / turn_sens       0.4 -> 2.50 (gentle centre)
##                                 1.0 -> 1.00 (unchanged)
##                                 1.8 -> 0.56 (sharp centre)
##
## THE BEHAVIOUR CHANGE, stated plainly: a player who had turn sensitivity
## below 1.0 will find full stick now reaches the robot's full turn rate. The
## feel near centre is preserved; the ceiling that was never intended is not.
##
## Runs once, writes into the STOCK profile, and sets a flag. After it, nothing
## reads turn_sens for gameplay, so the old multiply and the new curve can
## never both apply.
func migrate_turn_sens() -> void:
	if is_on("game/turn_sens_migrated"):
		return
	var old_sens := get_value("game/turn_sens")
	values["game/turn_sens_migrated"] = 1.0
	if not is_equal_approx(old_sens, 1.0) and old_sens > 0.01:
		var p := ControlProfile.get_one(ControlProfile.STOCK_ID)
		p.set_tuning("turn_curve", clampf(1.0 / old_sens, 0.5, 3.0))
		ControlProfile.save_one(p)
		DriverInput.refresh_profiles()
	save_to_disk()

## A controller appeared or vanished. Losing one that is IN USE stops the run
## and says which seat is affected; reconnecting deliberately does not resume,
## because the player has to pick the pad back up first.
func _on_joy_changed(device: int, connected: bool) -> void:
	DriverInput.refresh_profiles()
	if connected:
		DriverInput.require_neutral(device)
		changed.emit()
		return
	seat_profiles.erase(-1)
	var seat := -1
	for i in _live_seats:
		if int(_live_seats[i]) == device:
			seat = int(i)
			break
	DriverInput.forget()
	changed.emit()
	if seat >= 0:
		device_lost.emit(seat, seat_label(seat))

## seat -> device, as the running game actually handed them out. Set by main
## when it builds the roster, so a disconnect can name the seat that lost its
## controller rather than guessing.
var _live_seats: Dictionary = {}
var _live_labels: Dictionary = {}

func note_live_seats(plan: Array, devices: Array) -> void:
	_live_seats.clear()
	_live_labels.clear()
	for entry in plan:
		if bool(entry.get("ai", false)):
			continue
		var i := int(entry["seat"])
		if i >= 0 and i < devices.size():
			_live_seats[i] = int(devices[i])
		_live_labels[i] = "Robot %d %s" % [int(entry["robot"]),
			String(entry["role"]).to_lower()]

func seat_label(seat: int) -> String:
	return String(_live_labels.get(seat, "Seat %d" % (seat + 1)))

## The profile a seat is using. Unset means the stock layout.
func seat_profile(seat: int) -> String:
	return String(seat_profiles.get(seat, ControlProfile.STOCK_ID))

func set_seat_profile(seat: int, profile_id: String) -> void:
	seat_profiles[seat] = profile_id
	save_to_disk()
	DriverInput.refresh_profiles()
	changed.emit()

## Hand every live seat's profile to the input layer, keyed by the device that
## seat is holding. Called whenever the roster or an assignment changes.
func push_profiles(plan: Array, devices: Array) -> void:
	for entry in plan:
		if bool(entry.get("ai", false)):
			continue
		var i := int(entry["seat"])
		if i >= 0 and i < devices.size():
			DriverInput.set_profile(int(devices[i]), seat_profile(i))

func reset_to_defaults() -> void:
	for k: String in SPEC:
		values[k] = float(SPEC[k][0])
	keys.clear()
	seats.clear()
	seat_profiles.clear()
	BB.key_override.clear()
	BB.rebuild_input_map()
	apply_all()
	save_to_disk()
	changed.emit()

# ================================================================= applying ==

func apply_all() -> void:
	SFX.set_volume("Master", get_value("audio/master"))
	SFX.set_volume(SFX.BUS_SFX, get_value("audio/sfx"))
	SFX.set_volume(SFX.BUS_AMB, get_value("audio/crowd"))

	DisplayServer.window_set_mode(
		DisplayServer.WINDOW_MODE_FULLSCREEN if is_on("video/fullscreen")
		else DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if is_on("video/vsync")
		else DisplayServer.VSYNC_DISABLED)

	apply_graphics()
	for n in get_tree().get_nodes_in_group("player_cam"):
		if n is Camera3D:
			(n as Camera3D).fov = get_value("game/fov")

	BB.colorblind = is_on("game/colorblind")

## Picture quality: resolution, anti-aliasing, texture filtering, shadows.
## Main calls this again once the sun exists.
func apply_graphics() -> void:
	var web := OS.has_feature("web")
	var vp := get_viewport()
	var q := int(get_value("video/quality"))
	if vp:
		var msaa := int(get_value("video/msaa"))
		if web:
			msaa = mini(msaa, 2)      # WebGL 2 guarantees 4 samples, not 8
		vp.msaa_3d = [Viewport.MSAA_DISABLED, Viewport.MSAA_2X,
			Viewport.MSAA_4X, Viewport.MSAA_8X][msaa]
		var sc: float = RENDER_SCALES[int(get_value("video/render_scale"))]
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		vp.scaling_3d_scale = sc
		# Sharp floor lines at a grazing angle. Cheap on any GPU, so only Low
		# turns it down.
		vp.anisotropic_filtering_level = (Viewport.ANISOTROPY_4X if q == 0
			else Viewport.ANISOTROPY_16X)
	var sq := int(get_value("video/shadow_quality"))
	var atlas: int = [4096, 4096, 4096 if web else 8192][sq]
	RenderingServer.directional_shadow_atlas_set_size(atlas, true)
	RenderingServer.directional_soft_shadow_filter_set_quality(
		[RenderingServer.SHADOW_QUALITY_SOFT_LOW,
		RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM,
		RenderingServer.SHADOW_QUALITY_SOFT_HIGH if web
			else RenderingServer.SHADOW_QUALITY_SOFT_ULTRA][sq])
	for n in get_tree().get_nodes_in_group("sunlight"):
		if n is DirectionalLight3D:
			(n as DirectionalLight3D).shadow_enabled = is_on("video/shadows")

# ================================================================ persistence =

func load_from_disk() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	for k: String in SPEC:
		var parts := k.split("/")
		if cfg.has_section_key(parts[0], parts[1]):
			values[k] = float(cfg.get_value(parts[0], parts[1]))
	if cfg.has_section("keys"):
		for a in cfg.get_section_keys("keys"):
			keys[a] = int(cfg.get_value("keys", a))
	if cfg.has_section("seats"):
		for a in cfg.get_section_keys("seats"):
			seats[int(a)] = int(cfg.get_value("seats", a))
	if cfg.has_section("seat_profiles"):
		for a in cfg.get_section_keys("seat_profiles"):
			seat_profiles[int(a)] = String(cfg.get_value("seat_profiles", a))
	BB.key_override = keys.duplicate()
	BB.rebuild_input_map()

func save_to_disk() -> void:
	var cfg := ConfigFile.new()
	for k: String in SPEC:
		var parts := k.split("/")
		cfg.set_value(parts[0], parts[1], values[k])
	for a in keys:
		cfg.set_value("keys", a, keys[a])
	for st in seats:
		cfg.set_value("seats", str(st), seats[st])
	for sp in seat_profiles:
		cfg.set_value("seat_profiles", str(sp), seat_profiles[sp])
	cfg.save(PATH)

# ================================================================== rebinding =

## Point `action` at a new physical key. Returns false if that key is already
## doing something else, because two actions on one key is not a setting, it is
## a bug the player cannot see.
func rebind(action: String, keycode: int) -> bool:
	for a: String in BB.ACTIONS:
		if a == action:
			continue
		if BB.keys_for(a).has(keycode):
			return false
	keys[action] = keycode
	BB.key_override = keys.duplicate()
	BB.rebuild_input_map()
	save_to_disk()
	changed.emit()
	return true

func clear_binding(action: String) -> void:
	keys.erase(action)
	BB.key_override = keys.duplicate()
	BB.rebuild_input_map()
	save_to_disk()
	changed.emit()

# ============================================================ seat devices ===

## WHO HOLDS WHAT, for a whole roster at once.
##
## Two passes, because a pinned seat and an automatic one can want the same
## controller and only one of them can have it:
##
##   1. Seats the player pinned claim their device, in seat order. A pin to a
##      controller that is not plugged in is ignored — unplugging a pad should
##      not kill the seat, it should fall back.
##   2. Everything left takes the next free device, pads first, keyboard last.
##
## A seat that ends with NONE is DEAD and says so on screen. That is the point:
## silently giving two people the same controller means two robots moving as
## one and no clue why, which is exactly the bug this replaced.
func allocate_devices(n_seats: int, pool: Array) -> Array:
	var out: Array = []
	var taken: Array = []
	var resolved: Array = []
	for i in n_seats:
		out.append(DriverInput.NONE)
		resolved.append(false)
	for i in n_seats:
		if not seats.has(i):
			continue
		var want: int = int(seats[i])
		if not pool.has(want):
			continue                      # that controller is gone: fall back
		resolved[i] = true
		if taken.has(want):
			continue                      # someone earlier already has it
		out[i] = want
		taken.append(want)
	for i in n_seats:
		if resolved[i]:
			continue
		for dv in pool:
			if not taken.has(dv):
				out[i] = dv
				taken.append(dv)
				break
	return out

## Pin a seat to a device, or pass DriverInput.NONE to go back to automatic.
func set_seat_device(i: int, dev: int) -> void:
	if dev <= DriverInput.NONE:
		seats.erase(i)
	else:
		seats[i] = dev
	save_to_disk()
	changed.emit()

## How the seats are laid out for a given roster, as
## [{seat, robot, role, ai}], so the settings screen and the roster builder
## cannot disagree about who sits where.
static func seat_plan(robots_n: int, mate_ai: bool, per_robot: int) -> Array:
	var out: Array = []
	var seat := 0
	for i in robots_n:
		if mate_ai and i == 1:
			out.append({"seat": -1, "robot": i + 1, "role": "AI teammate", "ai": true})
			continue
		if per_robot > 1:
			out.append({"seat": seat, "robot": i + 1, "role": "Driver", "ai": false})
			seat += 1
			out.append({"seat": seat, "robot": i + 1, "role": "Operator", "ai": false})
			seat += 1
		else:
			out.append({"seat": seat, "robot": i + 1, "role": "Driver", "ai": false})
			seat += 1
	return out
