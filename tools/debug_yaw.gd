extends Node
##
## TIGHT TURNING.
##
## Three numbers decide whether a robot feels precise or vague:
##
##   OVERSHOOT   degrees it keeps turning after the stick is centred. This is
##               the one that makes aiming feel like wrestling — you stop on
##               the CELL and the robot carries fifteen degrees past it.
##   SWAY        degrees the heading wanders over the next few seconds while
##               you are doing nothing. Should be ~0.
##   DRIFT       degrees of unintended rotation while driving in a straight
##               line, which is what makes a long approach curve.
##
var main: Node3D
var robot: Robot
var t := 0.0
var phase := 0
var fails := 0
var mark := 0.0
var overshoot := 0.0
var sway := 0.0
var settle := 0.0
var straight_drift := 0.0
var gentle_overshoot := 0.0
var buzz := 0.0
var rest_mark := 0.0
var _quiet := 0.0
var strafe_drift := 0.0

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	main.menu.close()
	# Pin the STOCK drivetrain: robot settings persist to disk, so
	# whatever the last harness saved would otherwise be what this one
	# measures.
	RobotShop.source = RobotShop.Source.STOCK
	await get_tree().create_timer(1.5).timeout
	main._on_menu_start(BB.Mode.FREE_PRACTICE, BB.Alliance.RED, 1,
		{"robots": 1, "per_robot": 1, "opponents": 0})
	await get_tree().create_timer(2.0).timeout
	robot = main.robot
	robot.auto_drive = true
	_centre()
	print("\n--- TURNING PRECISION ---")
	phase = 1
	t = 0.0

func _centre() -> void:
	# NOT field centre: the HIVE tower stands there, and a robot strafing into
	# it spins off it, which an earlier version of this harness recorded as 131
	# degrees of "drift".
	robot.teleport(Transform3D(Basis(Vector3.UP, 0.0), BB.fp(-40.0, -40.0, 0.0)))
	robot.set_drive(0, 0, 0)

func _deg() -> float:
	return rad_to_deg(robot.global_rotation.y)

func _ok(label: String, got, want) -> void:
	var good: bool = got == want
	if not good:
		fails += 1
	print("  %s %-48s got %s   want %s" % ["PASS" if good else "FAIL", label, str(got), str(want)])

func _physics_process(d: float) -> void:
	if robot == null:
		return
	t += d
	match phase:
		1:      # spin up for a second, then let go
			robot.set_drive(0, 1, 0)
			if t > 1.0:
				mark = _deg()
				robot.set_drive(0, 0, 0)
				phase = 2
				t = 0.0
		2:      # how far does it carry past the release point?
			# The rate has to stay low, not just touch zero. Steering BACK to
			# the release heading means reversing, and the instant it reverses
			# the rate passes through zero — an exit test without a dwell
			# catches that instant and records the robot as "stopped" 30
			# degrees from where it actually settles. That is what made this
			# harness alternate between 2 deg and 31 deg run to run.
			# Settled means ON THE BEARING, not momentarily slow. Rate alone
			# cannot say it: the controller's residual hunt is bigger than any
			# sensible rate threshold, so a rate test either exits during the
			# reversal or never exits at all.
			if absf(wrapf(_deg() - rad_to_deg(robot._hold_yaw), -180.0, 180.0)) < 2.0:
				_quiet += d
			else:
				_quiet = 0.0
			if _quiet > 0.2 or t > 3.0:
				overshoot = absf(wrapf(_deg() - mark, -180.0, 180.0))
				settle = t
				mark = _deg()
				phase = 3
				t = 0.0
		3:      # and does it then stay put?
			# Measured against where it CAME TO REST, which is the heading the
			# controller latched — not against where the stick was released.
			# Those are 30 degrees apart after a full-speed stop, and comparing
			# to the wrong one made a rock-steady hold look like 31 deg of sway.
			# Give it half a second to finish arriving before judging how well
			# it SITS. Sampling from the first frame measures the tail of the
			# stop, not the hold.
			if t < 0.5:
				rest_mark = _deg()
			else:
				sway = maxf(sway, absf(wrapf(_deg() - rest_mark, -180.0, 180.0)))
				buzz = maxf(buzz, absf(rad_to_deg(robot.angular_velocity.y)))
			if t > 4.0:
				_centre()
				phase = 31
				t = 0.0
		31:     # a GENTLE turn, which is how you actually aim
			robot.set_drive(0, 0.30, 0)
			if t > 1.0:
				mark = _deg()
				robot.set_drive(0, 0, 0)
				phase = 32
				t = 0.0
		32:
			if absf(robot.angular_velocity.y) < deg_to_rad(6.0) or t > 2.0:
				gentle_overshoot = absf(wrapf(_deg() - mark, -180.0, 180.0))
				_centre()
				phase = 4
				t = 0.0
		4:      # straight line, 2 s
			robot.set_drive(0, 0, 1)
			straight_drift = maxf(straight_drift, absf(wrapf(_deg(), -180.0, 180.0)))
			if t > 1.8:
				_centre()
				phase = 5
				t = 0.0
		5:      # pure strafe, 2 s
			robot.set_drive(1, 0, 0)
			strafe_drift = maxf(strafe_drift, absf(wrapf(_deg(), -180.0, 180.0)))
			if t > 1.8:
				robot.set_drive(0, 0, 0)
				_report()
				phase = 6

func _report() -> void:
	# Dropping the stick from a FULL 460 deg/s cannot beat the drivetrain's own
	# braking limit, which is about 37 degrees. Easing off is the technique, so
	# the gentle case is the one that has to be tight.
	# Honest bars, from what the drivetrain can actually do.
	#
	# Dropping the stick from a full 460 deg/s cannot beat the drivetrain's own
	# braking limit: it sheds the rate in about 0.15 s and carries roughly 30
	# degrees doing it. What the heading controller buys is that it then STOPS
	# there and stays, instead of coasting on and wandering. The number that
	# matters for aiming is the gentle one, because easing off is the
	# technique.
	# The controller does two things after a full-speed release: it sheds the
	# rate in about 0.15 s, then steers back to the heading you let go on,
	# which takes another half second. The second part is why the overshoot
	# ends up at two degrees rather than the thirty the drivetrain coasts.
	_ok("full-speed release comes back within 6 deg", overshoot < 6.0, true)
	_ok("and is done inside a second", settle < 1.0, true)
	_ok("a GENTLE turn stops within 6 deg", gentle_overshoot < 6.0, true)
	_ok("then holds where it stopped, within 1 deg", sway < 1.0, true)
	_ok("residual hunt stays small", buzz < 15.0, true)
	_ok("drives straight without curving", straight_drift < 2.0, true)
	_ok("strafes square without spinning up", strafe_drift < 3.0, true)
	print("\n  overshoot: full speed %.1f deg in %.2f s   gentle %.1f deg" % [
		overshoot, settle, gentle_overshoot])
	print("  sway %.2f deg   residual rate %.1f deg/s" % [sway, buzz])
	print("  drift: straight %.2f deg   strafe %.2f deg" % [straight_drift, strafe_drift])
	print("  %s  (%d failures)" % [
		"TURNING IS TIGHT" if fails == 0 else "TURNING IS VAGUE", fails])
	get_tree().quit(1 if fails > 0 else 0)
