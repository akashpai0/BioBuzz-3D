extends Node
##
## DOES THE SIM ACTUALLY MATCH WHAT YOU MEASURED?
##
## The whole point of the calibration page is that a number you took off your
## own robot with a stopwatch comes back out of the simulator. If it does not,
## the page is worse than useless — it tells drivers to brake at a distance
## that is wrong for their robot.
##
## So: type in a set of measurements, drive the sim, and check it reproduces
## them. Tolerances are generous where the physics has a right to disagree
## (traction, the 70 ms control latency) and tight where it does not.
##
var main: Node3D
var robot: Robot
var t := 0.0
var phase := 0
var _boot := 0.0
var fails := 0

var got_fwd := 0.0
var got_strafe := 0.0
var got_turn := 0.0
var got_accel := 0.0
var got_stop := 0.0
var stop_from := Vector3.ZERO
var accel_mark := 0.0

## A deliberately un-stock robot, so a pass cannot come from the defaults.
const WANT_FWD := 48.0
const WANT_STRAFE := 33.0
const WANT_ACCEL := 0.70
const WANT_STOP := 20.0
const WANT_TURN := 240.0

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	main.menu.close()
	await get_tree().create_timer(1.5).timeout

	RobotShop.source = RobotShop.Source.MEASURED
	RobotShop.set_spec("meas_fwd", WANT_FWD)
	RobotShop.set_spec("meas_strafe", WANT_STRAFE)
	RobotShop.set_spec("meas_accel", WANT_ACCEL)
	RobotShop.set_spec("meas_stop", WANT_STOP)
	RobotShop.set_spec("meas_turn", WANT_TURN)
	RobotShop.set_spec("weight_lb", 32.0)

	main._on_menu_start(BB.Mode.FREE_PRACTICE, BB.Alliance.RED, 1,
		{"robots": 1, "per_robot": 1, "opponents": 0})
	await get_tree().create_timer(2.0).timeout
	robot = main.robot
	robot.auto_drive = true
	print("\n--- MATCHING A MEASURED ROBOT ---")
	print("  entered: %.0f in/s fwd, %.0f strafe, %.2f s to speed, %.0f in to stop, %.0f deg/s" % [
		WANT_FWD, WANT_STRAFE, WANT_ACCEL, WANT_STOP, WANT_TURN])
	print("  applied: max %.1f in/s  wheelF %.1f N  brake %.2f m/s2  strafe x%.2f  mass %.1f kg" % [
		robot.max_speed_in_s, robot.wheel_force_max, robot.brake_decel,
		robot.strafe_factor, robot.mass])
	_centre()
	phase = 1

## Start of a long clear runway: the far red end, down at y = -55 where there
## are no flowers, no gardens and no HIVE legs, pointing at +x with 118 inches
## in front of it. Getting this wrong is not subtle — an earlier version faced
## the robot at a wall 11 inches away and measured a "top speed" of 23 in/s.
func _centre() -> void:
	robot.teleport(Transform3D(Basis(Vector3.UP, -PI * 0.5), BB.fp(-58.0, -55.0, 0.0)))
	robot.set_drive(0, 0, 0)

func _ok(label: String, got: float, want: float, tol_pct: float) -> void:
	var good := absf(got - want) <= want * tol_pct * 0.01
	if not good:
		fails += 1
	print("  %s %-34s got %6.1f   want %6.1f  (+/- %.0f%%)" % [
		"PASS" if good else "FAIL", label, got, want, tol_pct])

func _physics_process(d: float) -> void:
	# A harness that hangs tells you nothing. If setup failed — a renamed
	# property, a missing node — say so and quit instead of spinning forever.
	_boot += d
	if robot == null:
		if _boot > 25.0:
			print("  FAIL setup never completed - the robot was never built")
			get_tree().quit(1)
		return
	t += d
	match phase:
		1:      # top speed, and the time it took to get there
			robot.set_drive(0, 0, 1)
			got_fwd = maxf(got_fwd, robot.speed_in_s())
			if fmod(t, 0.35) < d:
				print("     t=%.2f speed=%.1f pos=(%.0f,%.0f) power=%.2f" % [
					t, robot.speed_in_s(), robot.fx(), robot.fy(), robot.power_factor()])
			if accel_mark <= 0.0 and robot.speed_in_s() >= WANT_FWD * 0.95:
				accel_mark = t
			if t > 2.0:
				got_accel = accel_mark
				_centre()
				phase = 2
				t = 0.0
		2:      # stopping distance, from a FRESH run-up
			# Not from wherever phase 1 finished: that is nose-against-the-far-
			# wall, and an earlier version of this harness dutifully measured a
			# 2 inch "stopping distance" that was really a collision.
			robot.set_drive(0, 0, 1)
			if t > 1.3:
				stop_from = robot.global_position
				robot.set_drive(0, 0, 0)
				phase = 3
				t = 0.0
		3:
			if robot.speed_in_s() < 1.0 or t > 4.0:
				got_stop = (robot.global_position - stop_from).length() / BB.IN
				_centre()
				phase = 4
				t = 0.0
		4:      # strafe speed — LEFT, which is the direction with the runway
			robot.set_drive(-1, 0, 0)
			got_strafe = maxf(got_strafe, robot.speed_in_s())
			if t > 2.2:
				_centre()
				phase = 5
				t = 0.0
		5:      # turn rate
			robot.set_drive(0, 1, 0)
			got_turn = maxf(got_turn, absf(rad_to_deg(robot.angular_velocity.y)))
			if t > 2.0:
				robot.set_drive(0, 0, 0)
				_report()
				phase = 6

func _report() -> void:
	# Speeds and the turn rate are caps, so they should come back almost exactly.
	_ok("forward top speed (in/s)", got_fwd, WANT_FWD, 6.0)
	_ok("strafe top speed (in/s)", got_strafe, WANT_STRAFE, 10.0)
	_ok("turn rate (deg/s)", got_turn, WANT_TURN, 8.0)
	# Acceleration and braking run through traction and the control latency, so
	# they get more room — but they still have to be the right number, not a
	# number in the right general area.
	_ok("time to top speed (s x100)", got_accel * 100.0, WANT_ACCEL * 100.0, 15.0)
	_ok("stopping distance (in)", got_stop, WANT_STOP, 15.0)

	# And the whole point: a stock robot must NOT behave like this one.
	_ok("this is not just the stock robot", absf(got_fwd - Menu.DRIVE_SPEED),
		absf(WANT_FWD - Menu.DRIVE_SPEED), 25.0)
	# Put the saved robot back to stock. RobotShop persists to user://robot.cfg,
	# so a harness that leaves MEASURED behind silently changes the drivetrain
	# every OTHER harness then tests — which is exactly what happened.
	RobotShop.source = RobotShop.Source.STOCK
	RobotShop.use_specs = false
	RobotShop.save_cfg()
	print("  %s  (%d failures)" % [
		"THE SIM MATCHES THE MEASUREMENTS" if fails == 0 else "CALIBRATION IS OFF", fails])
	get_tree().quit(1 if fails > 0 else 0)
