extends Node
##
## DOES THE ROBOT START AT SPEC AND FADE A LITTLE?
##
## The contract: a match begins at the full 68 in/s and 460 deg/s on a fresh
## pack, and by the end of two and a half minutes of hard driving you are down
## roughly ten percent - felt, not fought.
##
## This is worth a harness because the failure is silent. An earlier battery
## model keyed power to the SAGGING terminal voltage, so flooring it dropped the
## robot to 57% on the very first frame and the drivetrain never once reached
## the numbers written on the tin. Nothing errored; it just felt wrong.
##
var main: Node3D
var robot: Robot
var t := 0.0
var phase := 0
var v_start := 0.0
var v_end := 0.0
var spin_start := 0.0
var spin_end := 0.0
var pf_start := 0.0
var pf_end := 0.0
var fails := 0

## How long a full match's worth of driving is, in seconds.
const MATCH_S := 150.0

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
	_recentre()
	print("\n--- BATTERY AND DRIVE FADE ---")
	phase = 1
	t = 0.0

## Back to the middle of the field, pointing down its long axis, stopped.
func _recentre() -> void:
	robot.teleport(Transform3D(Basis(Vector3.UP, PI * 0.5), BB.fp(0.0, 0.0, 0.0)))
	robot.linear_velocity = Vector3.ZERO
	robot.angular_velocity = Vector3.ZERO

func _ok(label: String, got, want) -> void:
	var good: bool = got == want
	if not good:
		fails += 1
	print("  %s %-46s got %s   want %s" % ["PASS" if good else "FAIL", label, str(got), str(want)])

func _physics_process(d: float) -> void:
	if robot == null:
		return
	t += d
	match phase:
		1:      # straight line on a fresh pack
			robot.set_drive(0, 0, 1)
			# PEAK speed, not the speed at the end of the window: 68 in/s eats
			# the 144 in field in about two seconds, and an earlier version of
			# this harness was measuring a robot already pinned against a wall.
			v_start = maxf(v_start, robot.speed_in_s())
			if t > 1.6:
				pf_start = robot.power_factor()
				phase = 2
				t = 0.0
				_recentre()
		2:      # spin on a fresh pack
			robot.set_drive(0, 1, 0)
			spin_start = maxf(spin_start, absf(rad_to_deg(robot.angular_velocity.y)))
			if t > 1.6:
				phase = 3
				t = 0.0
				_recentre()
		3:      # drive it hard for a match
			robot.set_drive(0.0, sin(t * 0.7) * 0.5, 1.0)
			# keep it off the walls without letting off the throttle
			if absf(robot.fx()) > 55.0 or absf(robot.fy()) > 55.0:
				robot.teleport(Transform3D(robot.global_transform.basis, BB.fp(0, 0, 0)))
			if t > MATCH_S:
				phase = 4
				t = 0.0
				# a match of hard driving leaves it wherever it left it, quite
				# possibly leaning on a wall — measure from the middle again
				_recentre()
		4:      # same two measurements on a worn pack
			robot.set_drive(0, 0, 1)
			v_end = maxf(v_end, robot.speed_in_s())
			if t > 1.6:
				pf_end = robot.power_factor()
				phase = 5
				t = 0.0
				_recentre()
		5:
			robot.set_drive(0, 1, 0)
			spin_end = maxf(spin_end, absf(rad_to_deg(robot.angular_velocity.y)))
			if t > 1.6:
				phase = 6
				_report()

func _report() -> void:
	var fade := (1.0 - v_end / maxf(v_start, 0.01)) * 100.0
	_ok("starts at 68 in/s (fresh pack, full throttle)", v_start > 65.0 and v_start < 70.0, true)
	_ok("starts at 460 deg/s", spin_start > 440.0 and spin_start < 485.0, true)
	_ok("fresh pack is essentially full power", pf_start > 0.995, true)
	_ok("it DOES fade over a match", v_end < v_start - 2.0, true)
	_ok("but not by much (under 15%)", fade < 15.0, true)
	_ok("rotation fades with it", spin_end < spin_start and spin_end > spin_start * 0.82, true)
	print("\n  fresh   %.1f in/s   %.0f deg/s   power %.3f" % [v_start, spin_start, pf_start])
	print("  worn    %.1f in/s   %.0f deg/s   power %.3f   (%.1f%% down)" % [
		v_end, spin_end, pf_end, fade])
	print("  %s  (%d failures)" % [
		"DRIVE FEEL CORRECT" if fails == 0 else "DRIVE FEEL WRONG", fails])
	get_tree().quit(1 if fails > 0 else 0)
