class_name Robot
extends RigidBody3D
##
## An 18 in cube (R102) on a mecanum drivetrain, with an intake, a 4-element
## hopper (G407) and a turret launcher.
##
## THE DRIVETRAIN IS NOT KINEMATIC. Each of the four wheels is a raycast
## suspension that produces a real normal force, and each wheel may only push
## along its own 45 deg roller-force direction, clamped by mu * N. So weight
## transfer, wheel lift, traction loss on one corner, getting shoved by another
## robot and tipping over a POLLEN all come out of the physics rather than out
## of a movement script. That is the whole reason this is a rebuild and not a
## port of the 2D sim.
##

signal launched(element: GameElement)
signal picked_up(element: GameElement)

var alliance: int = BB.Alliance.RED

# ---- tuning (all in manual inches / seconds unless noted) -------------------
@export var max_speed_in_s := BB.DRIVE_SPEED_IN_S   # free speed of the drivetrain
@export var yaw_rate_max := BB.TURN_RATE_DEG_S      # deg/s on the spot
@export var wheel_force_max := 26.0       # N per wheel, i.e. the motor limit
## How much of forward speed the robot manages sideways. Mecanum rollers waste
## some of it; 1.0 would be a robot that strafes as fast as it drives, which
## nothing does.
@export var strafe_factor := 1.0
## How hard the robot pulls itself down when the driver asks for nothing, in
## m/s^2. Commanded directly rather than left to fall out of wheel forces and
## drag, because stopping distance is a number teams MEASURE and the promise of
## the calibration page is that it comes back out.
##
## Weakening the brakes alone could not produce a long coast: incidental drag
## put a floor of about 15 inches under it however little force the wheels
## used. So while coasting the incidental terms step aside and this is the
## deceleration, which makes any measured distance reachable.
## Zero means "use the old wheel-force behaviour".
@export var brake_decel := 0.0
@export var traction_mu := 0.95           # mecanum rollers on foam tiles
## An FTC robot has no suspension, but modelling one as perfectly rigid makes
## the four normal forces statically indeterminate: the chassis rocks, wheels
## lift, and the robot spins out on any diagonal. These give about 0.4 in of
## static sag, which is enough travel to keep all four wheels loaded while
## still feeling rigid, and still lets a corner unload over a bump.
@export var susp_k := 1700.0              # N/m
@export var susp_c := 185.0
@export var launch_speed_in_s := BB.LAUNCH_SPEED_DEFAULT
@export var hood_deg := 55.0
@export var field_centric := true
## Turn off for a pure arcade feel; on by default because it is the point.
@export var realistic_power := true

# ---- battery and drivetrain lag ---------------------------------------------
var battery_v := BB.BATTERY_NOMINAL
var _open_circuit := BB.BATTERY_NOMINAL
var _cmd_log: Array = []            # [time, drive] pairs, for control latency
var _ramped := Vector3.ZERO

# ---- state -----------------------------------------------------------------
var hopper: Array[GameElement] = []
var turret: Node3D
var hood: Node3D
var muzzle: Marker3D
var intake_area: Area3D
var start_pose: Transform3D
var has_left := false
var intake_on := true                      # the intake runs constantly
var auto_aim := true
var aim_locked := false                    # auto-aim found a solution this frame
var aim_blocked := false                   # on the wrong side of the CELL mouth
var aim_dist_in := 0.0                     # to the current target, for the HUD
## Manual turret input SUSPENDS auto-aim rather than switching it off. An
## earlier version set auto_aim = false on any nudge, so one accidental brush of
## the D-pad killed auto-aim for the rest of the match with no obvious way back
## — which reads exactly like the turret breaking.
var manual_until := 0.0
var turret_faults := 0
## 1 or 2. Cosmetic only: the intake volume already reaches under the whole
## chassis, so a two-intake robot collects exactly the same as a one-intake one.
var intakes := 1
## Draw this robot from the team's imported CAD (our robots only: opponents
## keep the stock look, which is how the alliances stay easy to tell apart).
var team_cad := false
## True when the CAD is what is drawn: the stock wheels and launcher are hidden.
var shows_cad := false
## Which input device drives this robot: -1 keyboard, >= 0 that joypad,
## DriverInput.NONE for nobody. An AI-driven robot ignores it entirely.
var device := -1
## Which device works the MECHANISMS — intake, turret, hood, launcher.
##
## Most teams run two people on a robot: one drives, one operates. Setting this
## to a second controller splits the robot exactly that way. Left equal to
## `device` (the default) one person has the whole robot, which is how a solo
## driver practises.
var op_device := -1
## Whether the intake will take NECTAR as well as POLLEN. Off by default
## because a 3.6 in NECTAR does not fit through a real POLLEN intake; on, it
## collects both and changes nothing else about either.
var takes_nectar := false
var ai_driver := false
var driver_label := "P1"
## Whether this robot's motors are heard. Set by main.gd for whichever robot the
## camera is on; the opponent and the second robot stay silent so the mix is not
## three drivetrains deep.
var audible := true

signal recalibrated(reason: String)
var _cooldown := 0.0
var _wheels: Array = []
## Drive command in the ROBOT's own frame: x = strafe right, y = turn right,
## z = forward (+z is toward the nose, NOT Godot's -Z convention — the mixer
## below reads it as a signed wheel command, not as a direction).
var _drive := Vector3.ZERO
var _wheel_load := [0.0, 0.0, 0.0, 0.0]
var _wheel_slip := [0.0, 0.0, 0.0, 0.0]
## Last full speed+angle solve, so the 2D search only reruns when the shot has
## actually changed. Without this it runs every frame and costs more than the
## rest of the sim put together.
var _aim_cache := {"dist": -1.0, "rise": 0.0, "speed": -1.0, "prefer": 0.0}
## And the same for shots that do NOT fit. Re-running the search every frame
## while parked somewhere with no shot costs more than the whole rest of the
## sim, so a miss is remembered until the geometry changes.
var _aim_miss := {"dist": -1.0, "rise": 0.0}
## Hard throttle on the expensive search. Whatever the caches do, the full
## speed+aperture solve runs at most a few times a second; between those the
## turret keeps tracking and only the hood angle is refreshed. A driver cannot
## tell, and it keeps the solver off the frame budget.
var _aim_next_full := 0.0
## element -> seconds it has been travelling along with the robot. Used for
## G407: what the robot is CONTROLLING is what it carries plus what it drags.
var _herd: Dictionary = {}
var enabled := false                       # the driver station "enabled" flag
var auto_drive := false                    # drive from set_drive() instead of the keyboard

const HALF := BB.ROBOT_CUBE * 0.5

static func make(a: int, intake_count := 1, team_cad := false) -> Robot:
	var r := Robot.new()
	r.alliance = a
	r.intakes = clampi(intake_count, 1, 2)
	r.team_cad = team_cad
	r.name = "Robot" + BB.alliance_name(a)
	r._build()
	return r

func _build() -> void:
	mass = BB.ROBOT_MASS
	continuous_cd = true
	can_sleep = false
	linear_damp = 0.05
	angular_damp = 0.55
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, BB.m(2.0), 0)      # low, like a real drivetrain
	add_to_group("robot")
	# collide with the guard shells around fiddly structures, and with elements
	set_collision_mask_value(BB.LAYER_GUARD, true)
	set_collision_mask_value(BB.LAYER_ELEMENT, true)
	set_collision_layer_value(BB.LAYER_WORLD, true)

	var pm := PhysicsMaterial.new()
	pm.friction = 0.45
	pm.bounce = 0.12
	physics_material_override = pm

	# The chassis box: R102's 18 inch footprint, 9 inches tall, sitting on top
	# of the wheels. Fixed, not data-driven — the editable shape list is gone,
	# and leaving collision keyed to a saved list meant a stale entry in
	# user://robot.cfg could silently give someone a robot with no collision
	# at all.
	var body_h := BB.ROBOT_BODY_H
	var sh := BoxShape3D.new()
	sh.size = Vector3(BB.ROBOT_CUBE, body_h, BB.ROBOT_CUBE) * BB.IN
	var cs := CollisionShape3D.new()
	cs.shape = sh
	cs.position = Vector3(0, (BB.WHEEL_R + body_h * 0.5) * BB.IN, 0)
	add_child(cs)

	# ---- visuals, shared with the little model on the title screen so the
	# robot you pick there is the robot you drive
	shows_cad = RobotBody.build(self, alliance, intakes, false, false, team_cad)

	_build_wheels()
	_build_intake()
	_build_launcher()
	if shows_cad:
		# the model IS the robot: the wheels and launcher still work (they are
		# the physics), they are just not drawn over the team's own design
		for w in _wheels:
			(w["mesh"] as Node3D).visible = false
		for n in turret.get_children():
			if n is MeshInstance3D:
				(n as Node3D).visible = false
		for n in hood.get_children():
			if n is MeshInstance3D:
				(n as Node3D).visible = false

## Four raycast wheels. Roller-force directions form the mecanum X pattern:
## FL and BR push along (right + forward), FR and BL along (left + forward).
## A drawn-only box. Collision comes from the R102 cube, not from these.
func _shell(pos: Vector3, size_in: Vector3, mat: StandardMaterial3D) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size_in * BB.IN
	mi.mesh = bm
	mi.position = pos
	mi.material_override = mat
	add_child(mi)

func _build_wheels() -> void:
	var s := 1.0 / sqrt(2.0)
	var specs := [
		{"n": "FL", "p": Vector3(-1, 0, -1), "d": Vector3(1, 0, -1) * s},
		{"n": "FR", "p": Vector3(1, 0, -1), "d": Vector3(-1, 0, -1) * s},
		{"n": "BL", "p": Vector3(-1, 0, 1), "d": Vector3(-1, 0, -1) * s},
		{"n": "BR", "p": Vector3(1, 0, 1), "d": Vector3(1, 0, -1) * s},
	]
	for spec in specs:
		var mount: Vector3 = Vector3(
			spec["p"].x * (HALF - 1.1), BB.WHEEL_R * 2.0, spec["p"].z * (HALF - 3.0)) * BB.IN
		var ray := RayCast3D.new()
		ray.name = "Ray" + spec["n"]
		ray.position = mount
		ray.target_position = Vector3(0, -(BB.WHEEL_R * 2.0 + 0.75) * BB.IN, 0)
		ray.enabled = true
		ray.exclude_parent = true
		# World only. If a wheel ray can hit a POLLEN, driving over one reads as
		# a huge spring compression and throws the robot into the air.
		ray.collision_mask = 0
		ray.set_collision_mask_value(BB.LAYER_WORLD, true)
		add_child(ray)

		var mi := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = BB.WHEEL_R * BB.IN
		cm.bottom_radius = cm.top_radius
		cm.height = 2.0 * BB.IN
		mi.mesh = cm
		mi.position = mount + Vector3(0, -BB.WHEEL_R * BB.IN, 0)
		mi.rotation.z = PI * 0.5
		mi.material_override = BB.mat(Color(0.14, 0.14, 0.15), 0.6)
		add_child(mi)

		_wheels.append({"ray": ray, "dir": spec["d"], "at": Vector3(mount.x, 0.0, mount.z),
			"rest": BB.WHEEL_R * 2.0 * BB.IN, "mesh": mi})

func _build_intake() -> void:
	intake_area = Area3D.new()
	intake_area.name = "Intake"
	# The intake volume reaches from a few inches in FRONT of the bumper all the
	# way back UNDER the chassis. A ball that gets shoved under the robot used
	# to sit there wedged and unreachable; now it is either collected or, if the
	# robot is already full, actively pushed back out (see _service_intake).
	#
	# A TWO-INTAKE robot extends the same reach past the REAR bumper as well, so
	# it collects from either end without turning around. Both variants stop at
	# the same four elements; the difference is which way you have to face.
	var reach := BB.INTAKE_REACH
	var two := intakes >= 2
	var depth := BB.ROBOT_CUBE + reach * (2.0 if two else 1.0)
	var box := BoxShape3D.new()
	box.size = Vector3(BB.ROBOT_CUBE - 1.0, 7.0, depth) * BB.IN
	var cs := CollisionShape3D.new()
	cs.shape = box
	cs.position = Vector3(0, 2.6 * BB.IN, (0.0 if two else -reach * 0.5) * BB.IN)
	intake_area.add_child(cs)
	intake_area.monitorable = false
	intake_area.collision_mask = 0
	intake_area.set_collision_mask_value(BB.LAYER_ELEMENT, true)
	add_child(intake_area)

func _build_launcher() -> void:
	turret = Node3D.new()
	turret.name = "Turret"
	turret.position = Vector3(0, (BB.WHEEL_R + BB.ROBOT_BODY_H + 1.0) * BB.IN, 0)
	add_child(turret)

	var base := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 3.0 * BB.IN
	cm.bottom_radius = 3.4 * BB.IN
	cm.height = 2.0 * BB.IN
	base.mesh = cm
	base.material_override = BB.mat(Color(0.25, 0.26, 0.28), 0.4, 0.5)
	turret.add_child(base)

	hood = Node3D.new()
	hood.name = "Hood"
	hood.position = Vector3(0, 1.8 * BB.IN, 0)
	turret.add_child(hood)

	var barrel := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(4.0, 2.8, 8.0) * BB.IN
	barrel.mesh = bm
	barrel.position = Vector3(0, 0, -4.5 * BB.IN)
	barrel.material_override = BB.mat(BB.alliance_colour(alliance), 0.35, 0.4)
	hood.add_child(barrel)

	muzzle = Marker3D.new()
	muzzle.name = "Muzzle"
	muzzle.position = Vector3(0, 0, -9.5 * BB.IN)
	hood.add_child(muzzle)

# ================================================================== driving ==

func _physics_process(delta: float) -> void:
	# Nothing runs while a saved situation is being unpacked: the intake would
	# grab whatever ball was placed next to it, the suspension would fight the
	# pose being written in, and the turret would start hunting.
	if BB.frozen():
		return
	_cooldown = maxf(0.0, _cooldown - delta)
	if auto_drive:
		pass                       # _drive comes from set_drive(): AUTO routines, tests
	elif enabled:
		_read_input(delta)
	else:
		_drive = Vector3.ZERO
	_update_battery(delta)
	_apply_wheels(delta)
	_service_intake(delta)
	_track_herding(delta)
	_hold_hopper()
	_check_leave()
	_keep_in_bounds()
	_check_turret()
	_sound(delta)

func _read_input(delta: float) -> void:
	# Everything is read through DriverInput against THIS robot's device, so two
	# drivers on two controllers do not drive each other's robot.
	var d := device
	# Mechanisms read from the OPERATOR's device, which is the same device
	# unless two people are sharing this robot.
	var o := op_device
	# THE DRIVING STICK IS READ AS ONE STICK. DriverInput.move() applies the
	# seat's profile — radial deadzone, response curve, inversion — and hands
	# back a vector bounded by 1.0 in every direction, diagonals included.
	#
	# The old `turn * Settings.get_value("game/turn_sens")` multiply is GONE.
	# It scaled the command rather than the response, so a sensitivity below
	# 1.0 silently capped the robot's reachable turn rate: at 0.4 a full stick
	# could only ever ask for 40% turn. That setting is migrated once into the
	# profile's turn response curve, which changes how far the thumb travels
	# for a given command and leaves the maximum alone. See
	# Settings.migrate_turn_sens().
	var stick := DriverInput.move(d)
	var strafe := stick.x
	var fwd := stick.y
	var turn := DriverInput.turn(d)
	var scale := DriverInput.precision_scale(d) \
		if DriverInput.pressed(d, "slow") else 1.0

	if field_centric:
		# Interpret the sticks in the DRIVER's frame and rotate that into the
		# robot's. The red driver station looks down +x, so "forward" for a red
		# driver is manual +x and "right" is manual -y (Godot +Z). Blue stands
		# at the other end, so both axes flip.
		var side := 1.0 if alliance == BB.Alliance.RED else -1.0
		var world := Vector3(fwd * side, 0.0, strafe * side)
		var local := global_transform.basis.inverse() * world
		_drive = Vector3(local.x, turn, -local.z) * scale
	else:
		_drive = Vector3(strafe, turn, fwd) * scale

	# The intake is always running unless the driver holds it off, so POLLEN is
	# picked up just by driving over it.
	intake_on = not DriverInput.pressed(o, "intake_off")
	if DriverInput.pressed(o, "turret_left"):
		turret.rotate_y(deg_to_rad(120.0) * delta)
		manual_until = _now() + BB.MANUAL_AIM_HOLD
	if DriverInput.pressed(o, "turret_right"):
		turret.rotate_y(-deg_to_rad(120.0) * delta)
		manual_until = _now() + BB.MANUAL_AIM_HOLD
	if DriverInput.pressed(o, "hood_up"):
		hood_deg = minf(hood_deg + 45.0 * delta, 80.0)
	if DriverInput.pressed(o, "hood_down"):
		hood_deg = maxf(hood_deg - 45.0 * delta, 5.0)
	if DriverInput.pressed(o, "power_up"):
		launch_speed_in_s = minf(launch_speed_in_s + 90.0 * delta, BB.LAUNCH_SPEED_MAX)
	if DriverInput.pressed(o, "power_down"):
		launch_speed_in_s = maxf(launch_speed_in_s - 90.0 * delta, 40.0)
	hood.rotation.x = deg_to_rad(hood_deg)

	# per-driver buttons, so player two's toggles are player two's alone
	if DriverInput.just_pressed(o, "outtake"):
		eject()
	if DriverInput.just_pressed(d, "field_centric"):
		field_centric = not field_centric
	if DriverInput.just_pressed(o, "aim_assist"):
		auto_aim = not auto_aim
		if auto_aim:
			recalibrate("auto-aim re-engaged")
	if DriverInput.just_pressed(o, "recalibrate"):
		recalibrate("driver asked")
	if DriverInput.pressed(o, "fire"):
		fire()

## Battery model.
##
## Open-circuit voltage declines slowly across a match and drops further under
## load; the delivered voltage is what scales drive power. The effect a driver
## notices is real: by endgame the robot is meaningfully slower than it was at
## the buzzer, and flooring it from a standstill sags harder than cruising.
func _update_battery(delta: float) -> void:
	if not realistic_power:
		battery_v = BB.BATTERY_NOMINAL
		return
	if enabled:
		_open_circuit = maxf(BB.BATTERY_FLOOR + 0.6,
			_open_circuit - BB.BATTERY_DRAIN_PER_S * delta)
	var demand := absf(_drive.x) + absf(_drive.z) + absf(_drive.y) * 0.8
	var draw := demand * wheel_force_max * 4.0
	var target := _open_circuit - draw * BB.BATTERY_SAG_PER_N
	battery_v = clampf(lerpf(battery_v, target, 1.0 - pow(0.02, delta)),
		BB.BATTERY_FLOOR, BB.BATTERY_NOMINAL)

## How much of the drivetrain you actually have right now, 0.85 .. 1.0.
##
## Keyed to OPEN-CIRCUIT voltage — how empty the pack is — and deliberately not
## to the sagging terminal voltage. Flooring it drops `battery_v` for the HUD
## and recovers; only real discharge takes your top speed away. A fresh pack
## returns exactly 1.0, so a match starts at the full 68 in/s and 460 deg/s.
func power_factor() -> float:
	if not realistic_power:
		return 1.0
	var spent := BB.BATTERY_NOMINAL - _open_circuit
	return clampf(1.0 - spent * BB.BATTERY_POWER_LOSS_PER_V, BB.BATTERY_POWER_MIN, 1.0)

## A fresh pack. Called whenever the field is re-staged, because every match
## starts on a charged battery.
func reset_battery() -> void:
	_open_circuit = BB.BATTERY_NOMINAL
	battery_v = BB.BATTERY_NOMINAL

## Per-wheel suspension + traction. This is the heart of the drivetrain.
func _apply_wheels(delta: float) -> void:
	# Exact mecanum inverse kinematics. Rather than mixing three commands into a
	# wheel number and normalising, this asks for a body velocity and a yaw rate
	# and works out what each wheel's contact point should be doing. The yaw rate
	# is then its own tunable instead of falling out of the mix, which is what
	# lets the robot turn quickly without driving quickly.
	# CONTROL LATENCY and MOTOR RAMP: the wheels act on a command from ~70 ms
	# ago, ramped rather than stepped. Together with battery sag this is most of
	# what separates a real robot from a game object.
	var cmd := _drive
	if realistic_power:
		var now := _now()
		_cmd_log.append([now, _drive])
		while _cmd_log.size() > 2 and float(_cmd_log[0][0]) < now - BB.CONTROL_LATENCY:
			_cmd_log.pop_front()
		cmd = _cmd_log[0][1]
		_ramped = _ramped.move_toward(cmd, BB.MOTOR_RAMP * delta)
		cmd = _ramped

	var power := power_factor()
	var vmax_local := BB.m(max_speed_in_s) * power
	var v_body := Vector3(cmd.x * strafe_factor, 0.0, -cmd.z) * vmax_local
	var omega := -cmd.y * deg_to_rad(yaw_rate_max) * power
	omega = _heading_target(omega, absf(_drive.y) > BB.YAW_DEADBAND)

	for i in _wheels.size():
		var wheel: Dictionary = _wheels[i]
		var ray: RayCast3D = wheel["ray"]
		_wheel_load[i] = 0.0
		_wheel_slip[i] = 0.0
		if not ray.is_colliding():
			continue

		var hit: Vector3 = ray.get_collision_point()
		var mount: Vector3 = ray.global_position
		var compress: float = wheel["rest"] - mount.distance_to(hit)
		if compress <= 0.0:
			continue

		var arm := hit - global_position
		var point_vel := linear_velocity + angular_velocity.cross(arm)

		# --- suspension: normal force, which is what limits traction
		var n_force: float = clampf(susp_k * compress - susp_c * point_vel.y, 0.0, 4000.0)
		_wheel_load[i] = n_force
		apply_force(Vector3.UP * n_force, arm)

		# --- traction along this wheel's roller-force direction only
		var d_local: Vector3 = wheel["dir"]
		var d: Vector3 = (global_transform.basis * d_local).normalized()
		# what this contact point should be doing, in the robot's own frame
		var r_local: Vector3 = wheel["at"]
		var want := v_body + Vector3(0.0, omega, 0.0).cross(r_local)
		var target: float = want.dot(d_local)
		var err: float = target - point_vel.dot(d)
		# The driver asking for nothing while the robot is still moving is the
		# STOPPING case, and it gets its own law: a commanded deceleration
		# rather than whatever the velocity controller and drag happen to
		# produce between them.
		var coasting := v_body.length() < 0.02 and absf(omega) < 0.05
		var f_max := wheel_force_max * power
		var f: float = clampf(err * 900.0, -f_max, f_max)
		if coasting and brake_decel > 0.0:
			var v_flat := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
			if v_flat.length() > 0.02:
				# share the stopping force over the four contact patches
				f = -v_flat.normalized().dot(d) * mass * brake_decel * 0.25
		var grip: float = traction_mu * n_force
		_wheel_slip[i] = maxf(0.0, absf(f) - grip)
		f = clampf(f, -grip, grip)
		apply_force(d * f, arm)

		# --- rolling resistance along the free roller axis, small but not zero.
		# Stands down while coasting: with it, incidental drag alone stopped the
		# robot in about 15 inches no matter what the team measured.
		if not (coasting and brake_decel > 0.0):
			var side: Vector3 = d.cross(Vector3.UP).normalized()
			var side_v: float = point_vel.dot(side)
			apply_force(side * clampf(-side_v * 9.0, -grip * 0.12, grip * 0.12), arm)

		var mesh: MeshInstance3D = wheel["mesh"]
		mesh.position.y = ray.position.y - (wheel["rest"] - compress)

## Command the drivetrain directly, in ROBOT-relative units of -1..1. Used by
## autonomous routines and by the headless drivetrain tests.
func set_drive(strafe: float, turn: float, forward: float) -> void:
	_drive = Vector3(strafe, turn, forward)

# =================================================================== intake ==

func _service_intake(_delta: float) -> void:
	var full := hopper.size() >= BB.HOPPER_MAX
	for b in intake_area.get_overlapping_bodies():
		if not (b is GameElement):
			continue
		var e: GameElement = b
		if e.held_by != null:
			continue
		# Nothing may stay wedged under the robot. If it cannot be collected —
		# intake off, or already carrying the maximum — it gets pushed back out
		# the front instead of grinding around under the chassis.
		var local := to_local(e.global_position)
		# a two-intake robot pulls toward whichever end the ball is nearest
		var rear := intakes >= 2 and local.z > 0.0
		var mouth := to_global(Vector3(0, BB.m(3.0), (HALF - 2.0) * BB.IN * (1.0 if rear else -1.0)))
		var under := absf(local.x) < HALF * BB.IN and absf(local.z) < HALF * BB.IN
		if full or not intake_on:
			if under:
				var out_dir := (-global_transform.basis.z) if local.z < 0.0 else global_transform.basis.z
				e.apply_central_force(out_dir * 3.0 + Vector3.UP * 0.6)
			continue
		# a one-intake robot does not collect from behind itself
		if intakes < 2 and local.z > (HALF - 1.0) * BB.IN:
			continue
		# POLLEN only, unless the team has said their intake takes both. A real
		# 3.6 in NECTAR does not fit through a POLLEN intake, which is why the
		# default is off — but plenty of robots are built to handle both, and
		# turning it on changes nothing else about either element.
		if e.kind != BB.Kind.POLLEN and not takes_nectar:
			continue
		var to_mouth := mouth - e.global_position
		if to_mouth.length() < BB.m(5.5):
			_take(e)
			if hopper.size() >= BB.HOPPER_MAX:
				return
		else:
			# stronger pull, and a nudge upward so a ball riding under the
			# chassis is lifted into the collection point rather than dragged
			e.apply_central_force(to_mouth.normalized() * 4.0 + Vector3.UP * 0.8)

func _take(e: GameElement) -> void:
	e.set_held(self)
	hopper.append(e)
	SFX.play_at("intake_grab", global_position, -9.0, randf_range(0.92, 1.10))
	picked_up.emit(e)

## Work out which loose elements are being DRAGGED along.
##
## The manual is explicit that a ball merely in the robot's path — "bulldozing"
## — is not CONTROL, while corralling one is. The difference is whether it
## travels WITH you: so a ball only starts counting once the robot is actually
## moving and the ball is moving with it, and it has to keep that up for longer
## than a moment before it counts against G407.
func _track_herding(delta: float) -> void:
	var v := linear_velocity
	var speed := v.length()
	var moving := speed > BB.m(BB.HERD_MIN_SPEED)
	var seen := {}
	if moving:
		var heading := v.normalized()
		for b in intake_area.get_overlapping_bodies():
			if not (b is GameElement):
				continue
			var e: GameElement = b
			if e.held_by != null:
				continue
			# is it going where we are going, at something like our speed?
			var ev := e.linear_velocity
			if ev.length() < BB.m(BB.HERD_MIN_SPEED * 0.5):
				continue
			if ev.normalized().dot(heading) < 0.55:
				continue
			seen[e] = true
			_herd[e] = float(_herd.get(e, 0.0)) + delta
	for k in _herd.keys():
		if not seen.has(k) or not is_instance_valid(k):
			_herd[k] = float(_herd[k]) - delta * 2.0    # forget quickly
			if float(_herd[k]) <= 0.0:
				_herd.erase(k)

## How many loose elements the robot is dragging along right now.
func herded_count() -> int:
	var n := 0
	for k in _herd:
		if is_instance_valid(k) and float(_herd[k]) >= BB.HERD_TIME:
			n += 1
	return n

## Everything the robot CONTROLS for G407: carried plus dragged.
func controlled_count() -> int:
	return hopper.size() + herded_count()

## Keep held elements parked in their slots.
func _hold_hopper() -> void:
	# A ball can be freed by anything — a field reset, a situation being put
	# back — and a hopper holding a ghost writes transforms to a freed object
	# every physics frame. Prune first, hold second.
	for i in range(hopper.size() - 1, -1, -1):
		if not is_instance_valid(hopper[i]):
			hopper.remove_at(i)
	for i in hopper.size():
		var e: GameElement = hopper[i]
		# inside the chassis, between the frame posts, where they are visible
		var slot := Vector3(0, (BB.WHEEL_R + 3.2 + float(i / 4) * 3.1) * BB.IN,
			(-4.8 + float(i % 4) * 3.2) * BB.IN)
		e.global_transform = Transform3D(Basis.IDENTITY, to_global(slot))

## Spit the front element out gently — for GARDEN placement and for pulling
## POLLEN out of a FLOWER's retrieval opening.
func eject() -> void:
	if hopper.is_empty():
		return
	var e: GameElement = hopper.pop_front()
	var t := Transform3D(Basis.IDENTITY, to_global(Vector3(0, BB.m(3.0), -(HALF + 3.0) * BB.IN)))
	var dir := -global_transform.basis.z
	e.release(t, (dir * BB.m(22.0) + linear_velocity) * e.mass)

# ================================================================== launcher =

## ACCESSORS FOR THE AUTO RECORDER.
##
## Recording reads the command the driver actually produced, after precision
## mode and field-centric have been applied, so a replay reproduces what they
## meant rather than what their fingers did.
func drive_command() -> Vector3:
	return _drive

func wants_fire() -> bool:
	return DriverInput.pressed(op_device, "fire")

func wants_outtake() -> bool:
	return DriverInput.pressed(op_device, "outtake")

## Spit one out. Named for the recorder, which does not know about `eject`.
func eject_one() -> void:
	eject()

func can_fire() -> bool:
	return _cooldown <= 0.0 and not hopper.is_empty()

func fire() -> GameElement:
	if not can_fire():
		return null
	var e: GameElement = hopper.pop_front()
	_cooldown = BB.FIRE_INTERVAL
	_open_circuit = maxf(BB.BATTERY_FLOOR + 0.6, _open_circuit - BB.BATTERY_SHOT_COST)
	var t := muzzle.global_transform
	var dir := -t.basis.z
	var v := BB.m(launch_speed_in_s)
	e.release(Transform3D(Basis.IDENTITY, t.origin), (dir * v + linear_velocity) * e.mass)
	e.last_launcher = self
	# recoil, because it is a real impulse
	apply_central_impulse(-dir * v * e.mass * 0.6)
	# pitch tracks launcher power, so a soft close-range shot sounds like one
	SFX.play_at("shot", t.origin, -4.0,
		0.80 + launch_speed_in_s / BB.LAUNCH_SPEED_MAX * 0.45)
	launched.emit(e)
	return e

## CLOSED-LOOP YAW.
##
## Wheel traction alone leaves the chassis carrying its own momentum: release
## the stick and it coasts past where you meant to stop, then drifts. Every
## decent FTC robot fixes this the same way, with an IMU and a heading
## controller, so that is what this models.
##
## It does it by CORRECTING THE RATE THE WHEELS ARE ASKED FOR, not by adding a
## torque of its own. That matters. An earlier version applied its own torque on
## top of the wheels, which left two rate loops arguing at 180 Hz and put the
## chassis into a permanent +/- 9 deg/s buzz. One loop, driven through the
## wheels, is both better behaved and more honest: the correction is limited by
## traction, exactly like the real thing.
##
## While the stick is off centre the wheels get the rate you asked for. The
## moment it centres, the heading is latched and the wheels are asked for
## whatever rate steers the error out — so the robot parks on a bearing.
var _hold_yaw := 0.0
var _holding := false
func _heading_target(want_omega: float, steering: bool) -> float:
	if steering:
		_holding = false
		return want_omega
	if not _holding:
		_holding = true
		_hold_yaw = global_rotation.y
	var err := wrapf(_hold_yaw - global_rotation.y, -PI, PI)
	# omega is the body rate about +Y, and global_rotation.y increases with it,
	# so a positive heading error wants a positive rate. (Getting this backwards
	# does not wobble — it spins the robot up to 400 deg/s and never stops.)
	if absf(err) < BB.YAW_HOLD_DEAD:
		return 0.0
	return clampf(err * BB.YAW_HOLD_P, -deg_to_rad(yaw_rate_max),
		deg_to_rad(yaw_rate_max))

## MECHANISM NOISE.
##
## Three continuous voices, all driven by what the mechanisms are actually
## doing rather than triggered as events: the drivetrain rises with ground
## speed, the intake runs whenever the rollers do and loads up as the hopper
## fills, and the flywheel tracks commanded launcher power. Only the robot the
## camera is following is audible, or a three-robot field is a wall of motors.
func _sound(_delta: float) -> void:
	var key := str(get_instance_id())
	if not audible:
		SFX.stop_loop(key + ":drive")
		SFX.stop_loop(key + ":intake")
		SFX.stop_loop(key + ":fly")
		return

	var speed := speed_in_s() / maxf(max_speed_in_s, 1.0)
	SFX.set_loop(key + ":drive", "drive",
		-40.0 if speed < 0.04 else lerpf(-26.0, -13.0, minf(speed, 1.0)),
		0.75 + speed * 0.75)

	var running := intake_on and enabled
	# a full hopper means the rollers are pushing against a stack: lower and
	# louder, the way a loaded intake actually sounds
	var load := float(hopper.size()) / float(BB.HOPPER_MAX)
	SFX.set_loop(key + ":intake", "intake",
		-40.0 if not running else lerpf(-24.0, -19.0, load),
		1.10 - load * 0.22)

	var spin: float = clampf(launch_speed_in_s / BB.LAUNCH_SPEED_MAX, 0.0, 1.0)
	SFX.set_loop(key + ":fly", "flywheel",
		-40.0 if not enabled else lerpf(-30.0, -17.0, spin),
		0.70 + spin * 0.70)

## Ballistic solution, IN A VACUUM — kept because it is the closed form and it
## makes a good first guess, but the sim's elements have linear damping, so the
## real solver below is the one aim assist uses.
static func solve_hood(dist: float, rise: float, speed: float, high_arc := true) -> float:
	var g := BB.GRAV
	var v2 := speed * speed
	var disc := v2 * v2 - g * (g * dist * dist + 2.0 * rise * v2)
	if disc < 0.0:
		return NAN
	var root := sqrt(disc)
	var t := (v2 + root) / (g * dist) if high_arc else (v2 - root) / (g * dist)
	return rad_to_deg(atan(t))

## Height of a shot when it has travelled `dist` horizontally, WITH the linear
## damping the elements actually have. Closed form for exponential drag:
##     v(t) = (v0 + g/L) e^-Lt - g/L
## Returns -INF when the shot cannot reach that far at all.
static func rise_at(dist: float, speed: float, theta: float, damp: float) -> float:
	var lam := maxf(damp, 0.0001)
	var vx := speed * cos(theta)
	if vx <= 0.01:
		return -INF
	var k := dist * lam / vx
	if k >= 0.999:
		return -INF                      # terminal horizontal range is short of it
	var t := -log(1.0 - k) / lam
	var g := BB.GRAV
	return (speed * sin(theta) + g / lam) * (1.0 - exp(-lam * t)) / lam - (g / lam) * t

## EVERY hood angle that puts a damped shot through (dist, rise) — normally two,
## a flat one and a lobbed one. Scans for sign changes in (predicted rise -
## wanted rise) and bisects each bracket. Empty if nothing reaches at this speed.
static func solve_hood_all(dist: float, rise: float, speed: float, damp: float) -> Array:
	var out: Array = []
	var lo := deg_to_rad(8.0)
	var hi := deg_to_rad(84.0)
	var steps := 30
	var prev_a := hi
	var prev_e := rise_at(dist, speed, hi, damp) - rise
	for i in range(1, steps + 1):
		var a: float = hi - (hi - lo) * float(i) / float(steps)
		var e := rise_at(dist, speed, a, damp) - rise
		if is_inf(e) or is_inf(prev_e):
			prev_a = a
			prev_e = e
			continue
		if signf(e) != signf(prev_e):
			var a0 := prev_a
			var a1 := a
			for _j in 24:
				var mid := (a0 + a1) * 0.5
				if signf(rise_at(dist, speed, mid, damp) - rise) == signf(prev_e):
					a0 = mid
				else:
					a1 = mid
			out.append(rad_to_deg((a0 + a1) * 0.5))
		prev_a = a
		prev_e = e
	return out

## Elevation the shot is travelling at WHEN IT ARRIVES, in degrees; negative is
## descending. This is what decides whether a ball goes into a CELL: the mouth
## is a tilted window, and a shot dropping in near-vertically clips its lip no
## matter how exactly the aim point is hit.
static func arrival_elev(dist: float, speed: float, theta_deg: float, damp: float) -> float:
	var lam := maxf(damp, 0.0001)
	var th := deg_to_rad(theta_deg)
	var vx := speed * cos(th)
	if vx <= 0.01:
		return -90.0
	var k := dist * lam / vx
	if k >= 0.999:
		return -90.0
	var t := -log(1.0 - k) / lam
	var decay := exp(-lam * t)
	var g := BB.GRAV
	return rad_to_deg(atan2((speed * sin(th) + g / lam) * decay - g / lam, vx * decay))

## Backwards-compatible single answer: the lobbed arc.
static func solve_hood_drag(dist: float, rise: float, speed: float, damp: float) -> float:
	var all := solve_hood_all(dist, rise, speed, damp)
	return all[0] if not all.is_empty() else NAN

## Aim the turret and hood at a world point, spinning the flywheel up if the
## point is out of reach at the current speed.
##
## `prefer_elev` is the arrival elevation the target wants, in degrees. A HIVE
## CELL's mouth is a window tilted 30 deg from vertical, so a shot has to come
## in on a fairly flat path — the steep lob that a FLOWER wants would hit the
## lip. Passing the target's preference here, instead of always taking one arc,
## is what makes both scoring routes work with one launcher.
##
## Iterated three times, because moving the hood MOVES THE MUZZLE, which changes
## the problem that was just solved.
func aim_at(target: Vector3, prefer_elev := -55.0, ap: Dictionary = {}) -> bool:
	var damp := BB.ELEMENT_LINEAR_DAMP
	var solved := false
	var speed := -1.0
	for iter in 3:
		var from := muzzle.global_position
		var flat := Vector3(target.x - from.x, 0.0, target.z - from.z)
		var dist := flat.length()
		if dist < 0.01:
			return false
		_point_turret(flat)
		var rise := target.y - from.y
		if iter == 0 and _aim_miss["dist"] > 0.0 \
				and absf(_aim_miss["dist"] - dist) < BB.m(1.5) \
				and absf(_aim_miss["rise"] - rise) < BB.m(1.5):
			return false

		var now := _now()
		var may_search := now >= _aim_next_full
		if iter == 0 and (not may_search) and _aim_cache["speed"] > 0.0:
			speed = _aim_cache["speed"]
			launch_speed_in_s = speed
			var opts_t := solve_hood_all(dist, rise, BB.m(speed), damp)
			if opts_t.is_empty():
				return solved
			hood_deg = clampf(_pick(opts_t, dist, speed, damp, prefer_elev), 5.0, 84.0)
			hood.rotation.x = deg_to_rad(hood_deg)
			solved = true
			continue
		if iter == 0 and _aim_fresh(dist, rise, prefer_elev):
			speed = _aim_cache["speed"]
			launch_speed_in_s = speed
			var opts0 := solve_hood_all(dist, rise, BB.m(speed), damp)
			if opts0.is_empty():
				_aim_cache["speed"] = -1.0
				return false
			hood_deg = clampf(_pick(opts0, dist, speed, damp, prefer_elev), 5.0, 84.0)
		elif iter == 0:
			# Search SPEED as well as angle. Picking the angle alone is not
			# enough: close to the CELL the only solutions at full power are
			# near-vertical lobs, and a near-vertical ball clips the mouth lip
			# instead of going in. Backing the flywheel off puts a flatter arc
			# back on the menu, which is exactly what a driver would do.
			# Score every (speed, angle) pair by whether it FITS through the
			# opening, and only fall back to arrival angle when no aperture was
			# supplied. A shot that fits by a wide margin beats a shot that is
			# theoretically on target but clips the roof.
			_aim_next_full = now + 0.2
			var best_err := INF
			var best_speed := -1.0
			var best_angle := 0.0
			var best_clear := -1.0
			var bearing := flat / dist
			var v := 45.0
			while v <= BB.LAUNCH_SPEED_MAX + 0.1:
				for o in solve_hood_all(dist, rise, BB.m(v), damp):
					var clear := shot_clearance(dist, rise, BB.m(v), o, damp,
						from, bearing, ap, BB.POLLEN_DIA * 0.5)
					if not ap.is_empty():
						if clear > best_clear:
							best_clear = clear
							best_speed = v
							best_angle = o
						continue
					var err: float = absf(arrival_elev(dist, BB.m(v), o, damp) - prefer_elev)
					if err < best_err:
						best_err = err
						best_speed = v
						best_angle = o
				v += 15.0
			if not ap.is_empty() and best_clear < 0.0:
				_aim_cache["speed"] = -1.0
				_aim_miss = {"dist": dist, "rise": rise}
				return false          # nothing fits: too close, or no line
			_aim_miss = {"dist": -1.0, "rise": 0.0}
			if best_speed < 0.0:
				return false
			speed = best_speed
			launch_speed_in_s = speed
			hood_deg = clampf(best_angle, 5.0, 84.0)
			_aim_cache = {"dist": dist, "rise": rise, "speed": speed, "prefer": prefer_elev}
		else:
			# muzzle moved with the hood, so re-solve the angle at the chosen
			# speed rather than starting the whole search again
			var opts := solve_hood_all(dist, rise, BB.m(speed), damp)
			if opts.is_empty():
				return solved
			hood_deg = clampf(_pick(opts, dist, speed, damp, prefer_elev), 5.0, 84.0)
		hood.rotation.x = deg_to_rad(hood_deg)
		solved = true
	if solved:
		_apply_lead(target)
	return solved

## LEAD FOR THE ROBOT'S OWN MOTION.
##
## fire() gives the ball the muzzle velocity PLUS the robot's, which is correct
## physics and is why a shot taken on the move used to drift. The ballistic
## solve above works out the world velocity the ball needs; this then points the
## turret along that velocity MINUS the robot's, so that once the robot's motion
## is added back in the ball leaves along exactly the solved arc. Shots taken
## while driving land where a stationary shot would.
func _apply_lead(target: Vector3) -> void:
	var v_robot := linear_velocity
	if v_robot.length() < BB.m(1.5):
		return                                   # standing still: nothing to do
	var from := muzzle.global_position
	var flat := Vector3(target.x - from.x, 0.0, target.z - from.z)
	if flat.length() < 0.01:
		return
	var bearing := flat.normalized()
	var sp := BB.m(launch_speed_in_s)
	var th := deg_to_rad(hood_deg)
	# the world velocity the solved arc calls for ...
	var v_des := bearing * (sp * cos(th)) + Vector3.UP * (sp * sin(th))
	# ... minus what the robot is already contributing
	var v_corr := v_des - v_robot
	var horiz := Vector3(v_corr.x, 0.0, v_corr.z)
	if horiz.length() < 0.01:
		return
	var want_speed := v_corr.length() / BB.IN
	if want_speed > BB.LAUNCH_SPEED_MAX or want_speed < 30.0:
		return                                   # cannot be corrected; leave the aim alone
	_point_turret(horiz)
	hood_deg = clampf(rad_to_deg(atan2(v_corr.y, horiz.length())), 5.0, 84.0)
	hood.rotation.x = deg_to_rad(hood_deg)
	launch_speed_in_s = want_speed

## Does this arc actually FIT THROUGH the mouth?
##
## A CELL is a closed box. Aiming at a point inside it is not enough: a steep
## enough arc comes down onto the ROOF, and no amount of aiming fixes that. This
## walks the trajectory, finds where it crosses the plane of the opening, and
## checks it is inside the 20 x 14 window with room for the ball. Returns the
## clearance in inches, or -1 if the shot never gets in — which is how the HUD
## can honestly say "too close, back up" instead of claiming a lock.
static func shot_clearance(dist: float, rise: float, speed: float, theta_deg: float,
		damp: float, from: Vector3, bearing: Vector3, ap: Dictionary, ball_r: float) -> float:
	if ap.is_empty():
		return 0.0
	var lam := maxf(damp, 0.0001)
	var th := deg_to_rad(theta_deg)
	var vx := speed * cos(th)
	if vx <= 0.01:
		return -1.0
	var k := dist * lam / vx
	if k >= 0.999:
		return -1.0
	var t_end := -log(1.0 - k) / lam * 1.25
	var inv: Transform3D = (ap["xform"] as Transform3D).affine_inverse()
	var dirz: float = ap["dir"]
	var plane: float = dirz * (float(ap["d"]) * 0.5) * BB.IN
	var half_w: float = (float(ap["w"]) * 0.5 - ball_r) * BB.IN
	var lo_y: float = (-float(ap["h"]) * 0.5 + ball_r) * BB.IN
	var hi_y: float = (float(ap["h"]) * 0.5 - ball_r) * BB.IN

	var steps := 26
	var prev := inv * from
	for i in range(1, steps + 1):
		var t := t_end * float(i) / float(steps)
		var decay := exp(-lam * t)
		var horiz := vx * (1.0 - decay) / lam
		var h := (speed * sin(th) + BB.GRAV / lam) * (1.0 - decay) / lam - (BB.GRAV / lam) * t
		var world := from + bearing * horiz + Vector3.UP * h
		var loc := inv * world
		# crossing the plane of the opening, moving inward
		var crossed := (prev.z - plane) * (loc.z - plane) <= 0.0
		if crossed and absf(loc.z - prev.z) > 1e-9:
			var f: float = (plane - prev.z) / (loc.z - prev.z)
			var hit := prev.lerp(loc, f)
			if absf(hit.x) > half_w or hit.y < lo_y or hit.y > hi_y:
				return -1.0
			return minf(half_w - absf(hit.x), minf(hit.y - lo_y, hi_y - hit.y)) / BB.IN
		prev = loc
	return -1.0

## Aim the turret along a world-space direction.
##
## Deliberately sets the turret's LOCAL yaw, not `global_rotation.y`. Assigning
## a single component of a global Euler rebuilds the whole basis from the
## decomposed angles, so any roll or pitch the robot has — driving over a ball,
## being shoved, tipping onto two wheels — gets folded back into the turret's
## own orientation, and repeating that every frame skews it. Near steep pitch it
## can flip the turret outright. Yaw in the robot's frame is what a real turret
## does anyway: it rotates about the chassis, not about the world.
func _point_turret(world_dir: Vector3) -> void:
	if not _finite(world_dir) or world_dir.length() < 0.001:
		return
	var local := global_transform.basis.inverse() * world_dir
	var flat := Vector2(local.x, local.z)
	if flat.length() < 0.0001:
		return
	turret.rotation.y = atan2(-local.x, -local.z)

## SIMULATION time. Every hold, latency queue and cooldown on this robot is
## measured against it, so a pause menu suspends them instead of letting them
## run out behind it.
func _now() -> float:
	return BB.sim_now()

static func _finite(v: Vector3) -> bool:
	return is_finite(v.x) and is_finite(v.y) and is_finite(v.z)

## TURRET WATCHDOG.
##
## Checks every frame that the turret is in a state it could actually have got
## into legitimately, and puts it back to a known-good one if not. Covers a
## non-finite transform, a basis that has stopped being a rotation, and hood or
## flywheel values outside their mechanical range. Cheap, and it means a single
## bad frame cannot leave the launcher pointing nowhere for the rest of a match.
func _check_turret() -> void:
	var why := ""
	var tb := turret.transform.basis
	var hb := hood.transform.basis
	if not (_finite(tb.x) and _finite(tb.y) and _finite(tb.z) \
			and _finite(hb.x) and _finite(hb.y) and _finite(hb.z) \
			and _finite(turret.position) and _finite(hood.position)):
		why = "turret transform went non-finite"
	elif absf(tb.determinant() - 1.0) > 0.05 or absf(hb.determinant() - 1.0) > 0.05:
		why = "turret basis stopped being a rotation"
	elif not is_finite(hood_deg) or hood_deg < 0.0 or hood_deg > 90.0:
		why = "hood angle out of range"
	elif not is_finite(launch_speed_in_s) \
			or launch_speed_in_s < 20.0 or launch_speed_in_s > BB.LAUNCH_SPEED_MAX + 1.0:
		why = "flywheel speed out of range"
	if why != "":
		recalibrate(why)

## Put the launcher back to a known-good state and forget every cached aim.
func recalibrate(reason := "manual") -> void:
	turret_faults += 1
	turret.transform = Transform3D(Basis.IDENTITY, turret.position)
	hood.transform = Transform3D(Basis.IDENTITY, hood.position)
	hood_deg = 55.0
	hood.rotation.x = deg_to_rad(hood_deg)
	launch_speed_in_s = BB.LAUNCH_SPEED_DEFAULT
	_aim_cache = {"dist": -1.0, "rise": 0.0, "speed": -1.0, "prefer": 0.0}
	_aim_miss = {"dist": -1.0, "rise": 0.0}
	_aim_next_full = 0.0
	manual_until = 0.0
	aim_locked = false
	recalibrated.emit(reason)

## Is the driver currently steering the turret by hand?
func manual_aim() -> bool:
	return _now() < manual_until

## Is the cached speed still the right answer for this shot?
func _aim_fresh(dist: float, rise: float, prefer: float) -> bool:
	return _aim_cache["speed"] > 0.0 \
		and absf(_aim_cache["prefer"] - prefer) < 0.5 \
		and absf(_aim_cache["dist"] - dist) < BB.m(1.5) \
		and absf(_aim_cache["rise"] - rise) < BB.m(1.5)

## Of several hood angles, the one whose arrival elevation best suits the target.
func _pick(opts: Array, dist: float, speed: float, damp: float, prefer: float) -> float:
	var best: float = opts[0]
	var best_e := INF
	for o in opts:
		var e: float = absf(arrival_elev(dist, BB.m(speed), o, damp) - prefer)
		if e < best_e:
			best_e = e
			best = o
	return best

# ==================================================================== status =

func wheel_loads() -> Array:
	return _wheel_load

func total_slip() -> float:
	var s := 0.0
	for v in _wheel_slip:
		s += v
	return s

func speed_in_s() -> float:
	return linear_velocity.length() / BB.IN

func fx() -> float:
	return global_position.x / BB.IN

func fy() -> float:
	return -global_position.z / BB.IN

## Anti-glitch backstop. A robot should never end up outside the perimeter or
## under the tiles; if a deep penetration or a bad reset ever puts it there,
## set it back on the field upright instead of letting it fall out of the world.
func _keep_in_bounds() -> void:
	var p := global_position
	var lim := BB.m(BB.FIELD_HALF - HALF * 0.5)
	var out := absf(p.x) > lim or absf(p.z) > lim or p.y < BB.m(-6.0) or p.y > BB.m(60.0)
	if not out:
		return
	var yaw := global_rotation.y
	global_transform = Transform3D(Basis(Vector3.UP, yaw), Vector3(
		clampf(p.x, -lim, lim), BB.m(1.0), clampf(p.z, -lim, lim)))
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO

## LEAVE (T10-2): no longer contacting the perimeter wall, assessed at end of AUTO.
func _check_leave() -> void:
	if has_left:
		return
	var margin := BB.FIELD_HALF - HALF - 1.0
	if absf(fx()) < margin and absf(fy()) < margin:
		has_left = true

## PARK: at least partially in the LOADING ZONE. Tested with the four corners of
## the 18 in footprint plus the centre, so a rotated robot is handled.
func in_loading_zone() -> bool:
	var rect := BB.loading_zone(alliance)
	if BB.rect_has(rect, fx(), fy()):
		return true
	for c in [Vector3(-HALF, 0, -HALF), Vector3(HALF, 0, -HALF),
			Vector3(-HALF, 0, HALF), Vector3(HALF, 0, HALF)]:
		var p := to_global(c * BB.IN)
		if BB.rect_has(rect, p.x / BB.IN, -p.z / BB.IN):
			return true
	return false

## Move the robot without disturbing what it is carrying. reset_to() empties the
## hopper on purpose (it is a field reset); this is for repositioning.
func teleport(t: Transform3D) -> void:
	freeze = true
	global_transform = t
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	freeze = false
	BB.snap_visuals(self)
	# Drop any latched heading. Without this the controller tries to steer back
	# to the bearing the robot had BEFORE it was moved, which looks exactly like
	# the robot fighting the driver.
	_holding = false

func reset_to(t: Transform3D) -> void:
	# A hopper can hold a GHOST — a ball freed by a field reset or by a
	# situation being restored. Calling release() on a freed instance is not a
	# script error, it takes the whole engine down, so check first.
	for e in hopper:
		if is_instance_valid(e):
			e.release(Transform3D(Basis.IDENTITY,
				to_global(Vector3(0, BB.m(2.0), 0))), Vector3.ZERO)
	hopper.clear()
	freeze = true
	global_transform = t
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	freeze = false
	has_left = false
	turret.rotation = Vector3.ZERO
	hood_deg = 55.0
	_holding = false
	reset_battery()
	BB.snap_visuals(self)

# ============================================================== snapshots ====

## THE ROBOT AS DATA.
##
## Pose, motion, mechanism and battery — everything that makes this robot this
## robot at this instant. What is NOT here on purpose: the input device. A seat
## is handed a controller when the roster is built, from whatever is plugged in
## at the time, so restoring a device id from a file saved on another machine
## (or before someone unplugged a pad) would quietly hand robot 2 the wrong
## controller. The snapshot restores the ROSTER SHAPE and lets the normal seat
## allocation do the rest.
##
## Every timer here is REMAINING time, not a deadline: `manual_until` is stored
## as "how much longer is the driver steering by hand", because the absolute
## value is measured from when the process started and means nothing tomorrow.
func save_state(element_id: Callable) -> Dictionary:
	var held: Array = []
	for e in hopper:
		if is_instance_valid(e):
			held.append(element_id.call(e))
	return {
		"alliance": alliance,
		"intakes": intakes,
		"ai": ai_driver,
		"label": driver_label,
		"takes_nectar": takes_nectar,
		"basis": Snapshot.pack_basis(global_transform.basis),
		"origin": Snapshot.pack_v3(global_transform.origin),
		"lin": Snapshot.pack_v3(linear_velocity),
		"ang": Snapshot.pack_v3(angular_velocity),
		"start_basis": Snapshot.pack_basis(start_pose.basis),
		"start_origin": Snapshot.pack_v3(start_pose.origin),
		"turret_yaw": turret.rotation.y if turret else 0.0,
		"hood_deg": hood_deg,
		"launch_speed": launch_speed_in_s,
		"battery_v": battery_v,
		"open_circuit": _open_circuit,
		"field_centric": field_centric,
		"auto_aim": auto_aim,
		"intake_on": intake_on,
		"has_left": has_left,
		"turret_faults": turret_faults,
		"enabled": enabled,
		"cooldown": _cooldown,
		"manual_left": maxf(0.0, manual_until - _now()),
		"hopper": held,
	}

## Put the robot back. Called with the physics frozen and BB.restoring set, so
## nothing here counts as a pickup, a score or a foul.
func apply_state(d: Dictionary) -> void:
	alliance = int(d.get("alliance", alliance))
	takes_nectar = bool(d.get("takes_nectar", takes_nectar))
	driver_label = String(d.get("label", driver_label))
	start_pose = Transform3D(
		Snapshot.unpack_basis(d.get("start_basis", [])),
		Snapshot.unpack_v3(d.get("start_origin", [])))

	# Placed FROZEN and left that way. The restore waits a couple of physics
	# frames before handing control back, and an unfrozen body spends those
	# frames falling, settling and drifting off the pose it was just given —
	# which is exactly how a "restored" robot ends up an inch from where it
	# was saved. `release_from_restore()` puts the motion back at the end.
	freeze = true
	global_transform = Transform3D(
		Snapshot.unpack_basis(d.get("basis", [])),
		Snapshot.unpack_v3(d.get("origin", [])))
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO

	if turret:
		turret.rotation.y = float(d.get("turret_yaw", 0.0))
	hood_deg = float(d.get("hood_deg", 55.0))
	if hood:
		hood.rotation.x = deg_to_rad(hood_deg)
	launch_speed_in_s = float(d.get("launch_speed", BB.LAUNCH_SPEED_DEFAULT))
	battery_v = float(d.get("battery_v", BB.BATTERY_NOMINAL))
	_open_circuit = float(d.get("open_circuit", battery_v))
	field_centric = bool(d.get("field_centric", true))
	auto_aim = bool(d.get("auto_aim", true))
	intake_on = bool(d.get("intake_on", true))
	has_left = bool(d.get("has_left", false))
	turret_faults = int(d.get("turret_faults", 0))
	_cooldown = float(d.get("cooldown", 0.0))
	manual_until = _now() + maxf(0.0, float(d.get("manual_left", 0.0)))
	clear_inputs()

## Unfreeze and hand the motion back, on the frame play resumes.
func release_from_restore(lin: Vector3, ang: Vector3) -> void:
	freeze = false
	sleeping = false
	linear_velocity = lin
	angular_velocity = ang

## Forget what any driver was holding down.
##
## Without this a robot restored while its driver had the stick forward carries
## the ramped command, the latched heading and the control-latency log across
## the load and drives off on its own the moment the match resumes.
func clear_inputs() -> void:
	_drive = Vector3.ZERO
	_ramped = Vector3.ZERO
	_cmd_log.clear()
	_holding = false
	_hold_yaw = 0.0
	_herd.clear()
	aim_locked = false
	aim_blocked = false
	_aim_cache = {"dist": -1.0, "rise": 0.0, "speed": -1.0, "prefer": 0.0}
	_aim_miss = {"dist": -1.0, "rise": 0.0}
	_aim_next_full = 0.0

## Put an element straight into the hopper with no pickup sound and no
## picked_up signal — the restore path, not the intake path.
func adopt(e: GameElement) -> void:
	if e == null or not is_instance_valid(e) or hopper.has(e):
		return
	e.set_held(self)
	hopper.append(e)
