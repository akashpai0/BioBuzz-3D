extends Node
##
## G407 by DRAGGING, the hard intake cap, and rapid fire.
##
## The intake now stops at the legal four, so the only way to be over the limit
## is the way the manual describes: carrying four and herding more along with
## you. This fills the hopper, then drives through a line of loose POLLEN and
## checks that the balls travelling with the robot are counted as CONTROL —
## while confirming the hopper itself never takes a fifth.
##
## Then it holds the trigger and times how long the whole load takes to leave.
##
var main: Node3D
var robot: Robot
var mm: MatchManager
var t := 0.0
var fails := 0
var peak_hopper := 0
var peak_control := 0
var peak_herd := 0
var saw_warning := false
var stuck := -1
var fire_start := -1.0
var fire_done := -1.0
var phase := 0

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	main.menu.close()
	main.mm.mode = BB.Mode.FREE_PRACTICE
	await get_tree().create_timer(1.8).timeout
	robot = main.robot
	mm = main.mm
	mm.start()
	robot.auto_drive = true
	robot.field_centric = false
	robot.auto_aim = false                       # keep the turret still for timing
	robot.teleport(Transform3D(Basis.IDENTITY, BB.fp(-45.0, -62.0, 0.0)))
	# a long lane of POLLEN: the first few get collected, the rest get herded
	for i in 14:
		var e := GameElement.make(BB.Kind.POLLEN)
		main.add_child(e)
		e.global_position = BB.fp(-45.0 + float(i % 2) * 4.0, -52.0 + float(i) * 4.0, 2.0)
	await get_tree().create_timer(0.5).timeout
	robot.set_drive(0.0, 0.0, 0.5)
	print("\n--- G407 BY DRAGGING, AND RAPID FIRE ---")

func _ok(label: String, got, want) -> void:
	var good: bool = got == want
	if not good:
		fails += 1
	print("  %s %-50s got %s   want %s" % ["PASS" if good else "FAIL", label, str(got), str(want)])

func _physics_process(d: float) -> void:
	if robot == null:
		return
	t += d
	peak_hopper = maxi(peak_hopper, robot.hopper.size())
	peak_herd = maxi(peak_herd, robot.herded_count())
	peak_control = maxi(peak_control, robot.controlled_count())
	if mm.control_warning != "":
		saw_warning = true

	if phase == 0 and t > 9.0:
		phase = 1
		robot.set_drive(0.0, 0.0, 0.0)
	# drive clear, then check nothing is left wedged underneath
	if phase == 1 and t > 11.0:
		phase = 2
		robot.set_drive(0.0, 0.0, -0.8)
	if phase == 2 and t > 13.5:
		phase = 3
		robot.set_drive(0.0, 0.0, 0.0)
		stuck = 0
		for e in get_tree().get_nodes_in_group("element"):
			var el: GameElement = e
			if el.held_by != null:
				continue
			var loc := robot.to_local(el.global_position)
			if absf(loc.x) < Robot.HALF * BB.IN and absf(loc.z) < Robot.HALF * BB.IN \
					and loc.y < BB.m(BB.ROBOT_BODY_H):
				stuck += 1
		# top the hopper back up and time a full-auto dump
		while robot.hopper.size() < BB.HOPPER_CAP:
			var ne := GameElement.make(BB.Kind.POLLEN)
			main.add_child(ne)
			ne.global_position = robot.to_global(Vector3(0, BB.m(6.0), 0))
			robot._take(ne)
		robot.hood_deg = 35.0
		fire_start = t

	# hold the trigger: fire() paces itself
	if phase == 3 and fire_start > 0.0:
		if robot.hopper.is_empty():
			if fire_done < 0.0:
				fire_done = t
				_report()
		else:
			robot.fire()
	if phase == 3 and fire_start > 0.0 and t - fire_start > 4.0 and fire_done < 0.0:
		fire_done = t
		_report()

func _report() -> void:
	_ok("intake never took a fifth ball", peak_hopper <= BB.HOPPER_CAP, true)
	_ok("hopper filled to the legal four", peak_hopper, BB.HOPPER_CAP)
	_ok("dragged balls were detected", peak_herd >= 1, true)
	_ok("CONTROL went over four by dragging", peak_control > BB.HOPPER_CAP, true)
	_ok("G407 warned the driver", saw_warning, true)
	_ok("G407 logged an instance", mm.control_instances >= 1, true)
	_ok("nothing wedged under the robot", stuck, 0)
	var dump := fire_done - fire_start
	_ok("whole hopper empties in about half a second", dump < 0.75, true)
	print("\n  peak hopper %d   peak dragged %d   peak CONTROL %d   G407 instances %d" % [
		peak_hopper, peak_herd, peak_control, mm.control_instances])
	print("  full-auto dump of %d balls took %.2f s" % [BB.HOPPER_CAP, dump])
	print("  %s  (%d failures)" % ["RULES OK" if fails == 0 else "PROBLEMS", fails])
	get_tree().quit(1 if fails > 0 else 0)
