extends Node
##
## TURRET RELIABILITY.
##
## Three things that used to leave the launcher useless mid-match:
##   1. a manual nudge switched auto-aim OFF permanently — one brush of the
##      D-pad and nothing hit for the rest of the run
##   2. the turret was aimed by assigning one component of its GLOBAL Euler, so
##      any roll or pitch of the robot got folded into the turret's own basis
##      and skewed it a little more every frame
##   3. nothing checked the turret was still in a sane state
##
## This drives the robot hard, corrupts the turret on purpose, and checks it
## recovers and still scores.
##
var main: Node3D
var robot: Robot
var hive: Hive
var t := 0.0
var fails := 0
var stage := 0
var fired := 0
var hits_before := 0
var hits_after := 0
var faults_seen := 0
var manual_resumed := false
var worst_det := 0.0

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	main.menu.close()
	main.mm.mode = BB.Mode.FREE_PRACTICE
	await get_tree().create_timer(1.8).timeout
	robot = main.robot
	hive = main.field.hives[BB.Alliance.RED]
	main.mm.start()
	robot.auto_drive = true
	robot.field_centric = false
	worst_det = 1.0
	print("\n--- TURRET RELIABILITY ---")
	_place()

func _ok(label: String, got, want) -> void:
	var good: bool = got == want
	if not good:
		fails += 1
	print("  %s %-52s got %s   want %s" % ["PASS" if good else "FAIL", label, str(got), str(want)])

func _place() -> void:
	robot.set_drive(0, 0, 0)
	robot.teleport(Transform3D(Basis.IDENTITY, BB.fp(-12.75, -52.0, 0.0)))
	for e in hive.up_cell_elements():
		e.queue_free()
	while robot.hopper.size() < BB.HOPPER_CAP:
		var e := GameElement.make(BB.Kind.POLLEN)
		main.add_child(e)
		e.global_position = robot.to_global(Vector3(0, BB.m(6.0), 0))
		robot._take(e)
	fired = 0
	t = 0.0

func _physics_process(d: float) -> void:
	if robot == null:
		return
	t += d
	worst_det = minf(worst_det, absf(robot.turret.transform.basis.determinant()))
	faults_seen = maxi(faults_seen, robot.turret_faults)

	match stage:
		0:      # baseline: does it score at all
			if fired < 4 and robot.aim_locked and robot.can_fire():
				robot.fire(); fired += 1
			elif t > 6.0:
				hits_before = hive.up_cell_elements().size()
				stage = 1
				# --- abuse it: spin hard and shove it about while aiming
				robot.set_drive(0.6, 1.0, 0.4)
				t = 0.0
		1:
			if t > 4.0:
				# --- now corrupt the turret outright
				robot.turret.transform.basis = Basis.IDENTITY.scaled(Vector3(3, 3, 3))
				robot.hood_deg = NAN
				robot.launch_speed_in_s = 99999.0
				stage = 2
				t = 0.0
		2:
			if t > 0.5:
				_ok("watchdog caught the broken turret", robot.turret_faults >= 1, true)
				_ok("hood angle is sane again", is_finite(robot.hood_deg) \
					and robot.hood_deg >= 0.0 and robot.hood_deg <= 90.0, true)
				_ok("flywheel speed is sane again",
					robot.launch_speed_in_s <= BB.LAUNCH_SPEED_MAX, true)
				_ok("turret basis is a rotation again",
					absf(robot.turret.transform.basis.determinant() - 1.0) < 0.01, true)
				# --- manual nudge must not disable auto-aim forever
				robot.manual_until = robot._now() + BB.MANUAL_AIM_HOLD
				stage = 3
				t = 0.0
		3:
			if t > BB.MANUAL_AIM_HOLD + 0.6:
				manual_resumed = not robot.manual_aim() and robot.auto_aim
				stage = 4
				_place()
		4:      # can it still score after all that
			if fired < 4 and robot.aim_locked and robot.can_fire():
				robot.fire(); fired += 1
			elif t > 6.0:
				hits_after = hive.up_cell_elements().size()
				_report()

func _report() -> void:
	_ok("scored before the abuse", hits_before, 4)
	_ok("auto-aim resumed after a manual nudge", manual_resumed, true)
	_ok("scored again after recalibration", hits_after, 4)
	print("\n  turret recalibrations: %d   worst basis determinant seen: %.3f" % [
		faults_seen, worst_det])
	print("  %s  (%d failures)" % ["TURRET RELIABLE" if fails == 0 else "PROBLEMS", fails])
	get_tree().quit(1 if fails > 0 else 0)
