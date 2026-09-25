extends Node
##
## YOUR ROBOT: SPECS, MODEL, AND HOW IT HAS BEEN DOING.
##
## Autoloaded as `RobotShop`. Three things live here because they are three
## views of the same object:
##
##   SPECS    real hardware — motor, gear ratio, wheel diameter, weight — turned
##            into the drivetrain numbers the sim actually uses. Driving your
##            own code or your own auto against someone else's drivetrain
##            proves nothing, so this comes first.
##   MODEL    a CAD file, used as the robot's appearance.
##   HISTORY  every finished match this configuration has played, so you can
##            see whether a change to the robot made you faster or just
##            different.
##
## Persisted to user://robot.cfg and user://robot_history.json.
##

const CFG := "user://robot.cfg"
const HISTORY := "user://robot_history.json"
const MODEL_DIR := "user://models"

## Catalogue figures for the motors FTC teams actually use. `rpm` is free speed
## at the output shaft, `stall` is stall torque in N·m. These are the published
## nominal numbers, not measured ones — a real motor on a real battery is a few
## percent off, which is what the battery model is already doing to you.
const MOTORS := [
	{"name": "goBILDA 5203 435 RPM", "rpm": 435.0, "stall": 1.83},
	{"name": "goBILDA 5203 312 RPM", "rpm": 312.0, "stall": 2.38},
	{"name": "goBILDA 5203 223 RPM", "rpm": 223.0, "stall": 3.33},
	{"name": "goBILDA 5203 1150 RPM", "rpm": 1150.0, "stall": 0.69},
	{"name": "REV HD Hex 20:1", "rpm": 300.0, "stall": 2.10},
	{"name": "REV HD Hex 40:1", "rpm": 150.0, "stall": 4.20},
	{"name": "NeveRest 40", "rpm": 160.0, "stall": 2.47},
]

## key -> [default, min, max]. The customisation screen builds itself from this.
const SPEC := {
	"motor":        [0.0, 0.0, 6.0],
	"ratio":        [1.0, 0.33, 4.0],      # EXTERNAL reduction after the motor
	"wheel_dia":    [4.0, 2.0, 6.0],       # in
	"weight_lb":    [30.0, 12.0, 42.0],
	"track_in":     [14.0, 8.0, 17.5],     # left-right wheel centres
	"wheelbase_in": [13.0, 8.0, 17.5],     # front-back wheel centres
	"launch_in_s":  [175.0, 120.0, 260.0], # flywheel exit speed

	# --- MEASURED FROM THE REAL ROBOT.
	#
	# These are not guesses about hardware, they are stopwatch-and-tape-measure
	# numbers off your own robot, and they take priority over anything derived
	# from motor catalogue figures. Defaults are a middling FTC mecanum robot,
	# so the wizard is usable before anyone has measured anything.
	"meas_fwd":     [55.0, 20.0, 90.0],    # in/s, top speed down the field
	"meas_strafe":  [44.0, 10.0, 90.0],    # in/s, top speed sideways
	"meas_accel":   [0.90, 0.20, 3.00],    # s, standstill to top speed
	"meas_stop":    [11.0, 1.0, 48.0],     # in, full speed to stopped
	"meas_turn":    [300.0, 90.0, 700.0],  # deg/s
}

## Where the drivetrain numbers come from. HARDWARE (deriving speed from motor
## catalogue figures) was dropped: it asked teams for gear ratios to PREDICT
## numbers they could simply go and measure, and the measured path is both
## easier and more accurate. The enum value is kept so older saved files still
## load; it is folded into STOCK below.
enum Source { STOCK, HARDWARE, MEASURED }

var specs: Dictionary = {}
var robot_name := "Our Robot"
## Absolute user:// path of an imported CAD model, or "" for the built-in one.
var model_path := ""
var model_scale := 1.0
## How the imported model is turned, in degrees: x tips it forward/back, y
## turns it left/right, z rolls it side to side (applied in that order: tip,
## roll, then turn). CAD files disagree about which way is up and which way is
## the front, so any orientation has to be reachable.
var model_rot := Vector3.ZERO
## True when the drivetrain should come from SPECS rather than the stock numbers.
## Kept as a bool for the saved files that already exist; `source` is what the
## rest of the code reads.
var use_specs := false
var source: int = Source.STOCK

signal changed

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for k: String in SPEC:
		specs[k] = float(SPEC[k][0])
	DirAccess.make_dir_recursive_absolute(MODEL_DIR)
	load_cfg()

func get_spec(k: String) -> float:
	return float(specs.get(k, float(SPEC.get(k, [0.0])[0])))

func set_spec(k: String, v: float) -> void:
	var s: Array = SPEC.get(k, [0.0, 0.0, 1.0])
	specs[k] = clampf(v, float(s[1]), float(s[2]))
	save_cfg()
	changed.emit()

func motor() -> Dictionary:
	return MOTORS[clampi(int(get_spec("motor")), 0, MOTORS.size() - 1)]

# ================================================== hardware -> drivetrain ===

## Free speed at the wheel, in/s.
##
##   wheel rpm = motor rpm / external ratio
##   in/s      = rpm/60 x pi x diameter
##
## This is the no-load number. What you actually see on the field is lower,
## because the battery model and the traction limit both bite — which is the
## point of deriving it rather than typing a speed in.
func free_speed_in_s() -> float:
	var wheel_rpm: float = float(motor()["rpm"]) / maxf(get_spec("ratio"), 0.01)
	return wheel_rpm / 60.0 * PI * get_spec("wheel_dia")

## Usable force at one wheel, N. Stall torque through the external reduction,
## divided by the wheel radius, then derated: nothing runs at stall, and a
## mecanum roller puts only part of its force where you asked.
func wheel_force() -> float:
	var torque: float = float(motor()["stall"]) * get_spec("ratio")
	var radius_m := get_spec("wheel_dia") * 0.5 * BB.IN
	return torque / maxf(radius_m, 0.001) * 0.45

## Spin rate a mecanum chassis of this size can reach at free speed, deg/s.
## The turning radius of a mecanum drive is half the diagonal of the wheel
## rectangle, so a long robot turns slower than a square one at the same speed.
func yaw_rate() -> float:
	var r := sqrt(pow(get_spec("track_in"), 2.0) + pow(get_spec("wheelbase_in"), 2.0)) * 0.5
	return rad_to_deg(free_speed_in_s() / maxf(r, 1.0))

func mass_kg() -> float:
	return get_spec("weight_lb") * BB.LB

## Push the derived numbers onto a robot. Called whenever one is built and
## whenever the specs change, so a slider moves and the next drive feels it.
func apply(r: Robot) -> void:
	if r == null or not is_instance_valid(r):
		return
	match source:
		Source.STOCK:
			# The number everyone is measured on, so the leaderboard means
			# something.
			r.max_speed_in_s = Menu.DRIVE_SPEED
			r.yaw_rate_max = Menu.TURN_RATE
			r.mass = BB.ROBOT_MASS
			r.wheel_force_max = 26.0
			r.strafe_factor = 1.0
			r.brake_decel = 0.0
			r.launch_speed_in_s = BB.LAUNCH_SPEED_DEFAULT
		Source.HARDWARE:
			r.max_speed_in_s = free_speed_in_s()
			r.yaw_rate_max = yaw_rate()
			r.mass = mass_kg()
			r.wheel_force_max = wheel_force()
			r.strafe_factor = 0.82         # mecanum rollers lose some sideways
			r.brake_decel = 0.0
			r.launch_speed_in_s = get_spec("launch_in_s")
		Source.MEASURED:
			_apply_measured(r)

## MEASURED NUMBERS -> SIM PARAMETERS.
##
## No solver and no fitting loop: each measurement maps to exactly one
## parameter by the physics that produced it, which is why a wizard of five
## stopwatch numbers is enough.
##
##   top speed    IS the speed cap, directly
##   strafe speed is a fraction of it (mecanum rollers waste some sideways)
##   0-to-full    gives acceleration, and F = m*a gives the force per wheel
##   stopping     gives deceleration by v^2 = 2*a*d, and its own force limit
##   turn rate    IS the yaw cap, directly
##
## The stopping number is the one drivers feel. A robot in brake mode stops in
## a few inches; one in float coasts a foot and a half, and that difference is
## the whole skill of lining up on a CELL without overshooting it.
func _apply_measured(r: Robot) -> void:
	var m := mass_kg()
	r.mass = m
	r.max_speed_in_s = get_spec("meas_fwd")
	r.yaw_rate_max = get_spec("meas_turn")
	r.strafe_factor = clampf(
		get_spec("meas_strafe") / maxf(get_spec("meas_fwd"), 1.0), 0.2, 1.0)
	r.launch_speed_in_s = get_spec("launch_in_s")

	var v := BB.m(get_spec("meas_fwd"))                 # m/s
	var a_up := v / maxf(get_spec("meas_accel"), 0.05)  # m/s^2
	r.wheel_force_max = m * a_up / 4.0 * BB.ACCEL_TRIM

	var stop_m := BB.m(get_spec("meas_stop"))
	var a_dn := v * v / (2.0 * maxf(stop_m, 0.01))
	r.brake_decel = a_dn * BB.BRAKE_TRIM

## What the measured numbers imply, for the wizard to show back.
func measured_rows() -> Array:
	var m := mass_kg()
	var v := BB.m(get_spec("meas_fwd"))
	var a_up := v / maxf(get_spec("meas_accel"), 0.05)
	var a_dn := v * v / (2.0 * maxf(BB.m(get_spec("meas_stop")), 0.01))
	return [
		["Acceleration", "%.1f in/s²" % (a_up / BB.IN),
			"from %.1f in/s in %.2f s" % [get_spec("meas_fwd"), get_spec("meas_accel")]],
		["Drive force", "%.1f N per wheel" % (m * a_up / 4.0 * BB.ACCEL_TRIM),
			"F = m a over four wheels, corrected for the 45 deg rollers"],
		["Braking", "%.1f in/s²" % (a_dn / BB.IN),
			"stopping in %.0f in from full speed" % get_spec("meas_stop")],
		["Braking force", "%.0f N total" % (m * a_dn * BB.BRAKE_TRIM),
			"less than drive force means it coasts"],
		["Strafe penalty", "%.0f%% of forward" % (
			get_spec("meas_strafe") / maxf(get_spec("meas_fwd"), 1.0) * 100.0),
			"mecanum rollers waste some of it"],
	]

## THE NUMBERS THE MENUS SHOW.
##
## Never hardcode 68 / 460 on a screen: a robot on MEASURED specs is whatever
## its owner measured, and the Garage and Play both have to say so.
func top_speed_in_s() -> float:
	if source == Source.MEASURED:
		return get_spec("meas_fwd")
	return BB.DRIVE_SPEED_IN_S

func turn_deg_s() -> float:
	if source == Source.MEASURED:
		return get_spec("meas_turn")
	return BB.TURN_RATE_DEG_S

## What to call this configuration in one short line.
func profile_name() -> String:
	return "Stock mecanum" if source == Source.STOCK else "Measured profile"

## Everything the specs page prints, as [label, value, note].
func derived_rows() -> Array:
	return [
		["Free speed", "%.1f in/s" % free_speed_in_s(),
			"%.0f RPM at the motor, %.2f:1 external, %.1f in wheels" % [
				float(motor()["rpm"]), get_spec("ratio"), get_spec("wheel_dia")]],
		["Turn rate", "%.0f deg/s" % yaw_rate(),
			"falls as the chassis gets bigger"],
		["Force per wheel", "%.1f N" % wheel_force(),
			"stall torque through the reduction, derated to what you can use"],
		["Mass", "%.1f kg" % mass_kg(), "%.0f lb" % get_spec("weight_lb")],
		["Launcher", "%.0f in/s" % get_spec("launch_in_s"), "flywheel exit speed"],
	]

# ================================================================= history ===

## Record a finished match against the current robot configuration.
func log_match(result: Dictionary, summaries: Array, mode: int) -> void:
	if summaries.is_empty():
		return
	var b: Dictionary = result.get("breakdown", {})
	var s: Dictionary = summaries[0]
	var a := int(s.get("alliance", BB.Alliance.RED))
	var rows := _read_history()
	rows.append({
		"when": Time.get_datetime_string_from_system(true),
		"robot": robot_name,
		"mode": "FULL MATCH" if mode == BB.Mode.FULL_MATCH else "TELEOP",
		"specs": _spec_signature(),
		"score": int(b.get(a, {}).get("total", 0)),
		"shots": int(s.get("shots", 0)), "made": int(s.get("made", 0)),
		"accuracy": float(s.get("accuracy", 0.0)),
		"cycle_avg": float(s.get("cycle_avg", 0.0)),
		"tips": int(s.get("tips", 0)),
		"distance_ft": float(s.get("distance_ft", 0.0)),
	})
	while rows.size() > 200:
		rows.pop_front()
	var f := FileAccess.open(HISTORY, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(rows))
		f.close()
	changed.emit()

func history() -> Array:
	return _read_history()

## Averages over the last `n` matches, plus how they compare to the ones before
## — "getting better" is the only question this page has to answer.
func trend(n := 5) -> Dictionary:
	var rows := _read_history()
	if rows.is_empty():
		return {}
	var recent := rows.slice(maxi(0, rows.size() - n))
	var older := rows.slice(0, maxi(0, rows.size() - n))
	return {
		"count": rows.size(),
		"recent": _mean(recent),
		"older": _mean(older),
	}

func _mean(rows: Array) -> Dictionary:
	if rows.is_empty():
		return {}
	var out := {"score": 0.0, "accuracy": 0.0, "cycle_avg": 0.0, "tips": 0.0}
	var cyc_n := 0
	for r in rows:
		out["score"] += float(r.get("score", 0))
		out["accuracy"] += float(r.get("accuracy", 0.0))
		out["tips"] += float(r.get("tips", 0))
		if float(r.get("cycle_avg", 0.0)) > 0.0:
			out["cycle_avg"] += float(r["cycle_avg"])
			cyc_n += 1
	for k in ["score", "accuracy", "tips"]:
		out[k] /= float(rows.size())
	out["cycle_avg"] = out["cycle_avg"] / float(cyc_n) if cyc_n > 0 else 0.0
	return out

func clear_history() -> void:
	DirAccess.remove_absolute(HISTORY)
	changed.emit()

func _read_history() -> Array:
	if not FileAccess.file_exists(HISTORY):
		return []
	var f := FileAccess.open(HISTORY, FileAccess.READ)
	if f == null:
		return []
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Array else []

## A short fingerprint of the current specs, so history rows can be grouped by
## "which robot was this". Changing a wheel size starts a new line of results.
func _spec_signature() -> String:
	if source == Source.STOCK:
		return "stock"
	if source == Source.MEASURED:
		return "measured %.0f/%.0f/%.2f/%.0f" % [
			get_spec("meas_fwd"), get_spec("meas_strafe"),
			get_spec("meas_accel"), get_spec("meas_stop")]
	return "%d/%.2f/%.1f/%.0f" % [
		int(get_spec("motor")), get_spec("ratio"),
		get_spec("wheel_dia"), get_spec("weight_lb")]

# ============================================================= persistence ===

func load_cfg() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CFG) != OK:
		return
	for k: String in SPEC:
		if cfg.has_section_key("specs", k):
			specs[k] = float(cfg.get_value("specs", k))
	robot_name = String(cfg.get_value("robot", "name", robot_name))
	use_specs = bool(cfg.get_value("robot", "use_specs", false))
	source = int(cfg.get_value("robot", "source", Source.STOCK))
	if source == Source.HARDWARE:
		source = Source.STOCK
	model_path = String(cfg.get_value("model", "path", ""))
	model_scale = float(cfg.get_value("model", "scale", 1.0))
	if cfg.has_section_key("model", "rot"):
		var r: Variant = cfg.get_value("model", "rot")
		model_rot = r if r is Vector3 else Vector3.ZERO
	else:
		# older saves: an up axis plus a turn
		var up := String(cfg.get_value("model", "up", ""))
		if not up in ["x", "y", "z"]:
			up = CadImport.default_up(model_path)
		model_rot = CadImport.up_rotation(up) + Vector3(0, float(cfg.get_value("model", "yaw", 0.0)), 0)
	if model_path != "" and not FileAccess.file_exists(model_path):
		model_path = ""

func save_cfg() -> void:
	var cfg := ConfigFile.new()
	for k: String in SPEC:
		cfg.set_value("specs", k, specs[k])
	cfg.set_value("robot", "name", robot_name)
	cfg.set_value("robot", "use_specs", source != Source.STOCK)
	cfg.set_value("robot", "source", source)
	cfg.set_value("model", "path", model_path)
	cfg.set_value("model", "scale", model_scale)
	cfg.set_value("model", "rot", model_rot)
	cfg.save(CFG)

## True when the player's robots are drawn from their own CAD file.
func has_model() -> bool:
	return model_path != ""
