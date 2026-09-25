extends Node
##
## END-TO-END TEST. Loads the real game scene, checks the staging against
## S10.3.1, then plays: spins up, aims at the raised CELL and launches until the
## HIVE goes over, and confirms the score moves. Run:
##   godot --headless --path . tools/smoke_match.tscn
##

var main: Node3D
var robot: Robot
var t := 0.0
var fired := 0
var locked_when_firing := false
var fails := 0
var done := false
var _shots: Array = []
var _trace := 0.0

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	main.menu.close()
	main.mm.mode = BB.Mode.TELEOP_ONLY
	await get_tree().create_timer(1.5).timeout
	_check_staging()
	robot = main.robot
	# start the match properly: a TIP only scores while a MATCH is running, so
	# enabling the robot by hand without starting would silently drop the credit
	main.mm.start()
	robot.enabled = true
	robot.launch_speed_in_s = 175.0
	# Red's raised CELL faces SOUTH and its mouth is its only opening, so a shot
	# from the red starting wall hits the back of the box. Put the robot on the
	# open side, the way a driver would have to, and let the game's own
	# auto-targeting find the shot from there.
	robot.teleport(Transform3D(Basis.IDENTITY, BB.fp(-12.75, -52.0, 0.0)))

func _ok(label: String, got, want) -> void:
	var good: bool = got == want
	if not good:
		fails += 1
	print("  %s %-42s got %s   want %s" % ["PASS" if good else "FAIL", label, str(got), str(want)])

func _check_staging() -> void:
	print("\n--- STAGING (S10.3.1) ---")
	var tree := get_tree()
	_ok("POLLEN on the field", tree.get_nodes_in_group("pollen").size(), 40)
	_ok("NECTAR on the field", tree.get_nodes_in_group("nectar").size(), 16)
	_ok("robot pre-load (G304.G)", main.robot.hopper.size(), 4)
	for a in main.field.hives:
		var h: Hive = main.field.hives[a]
		_ok("NECTAR in the raised %s CELL" % BB.alliance_name(a), h.up_cell_elements().size(), 3)
	var in_flowers := 0
	for f: Flower in main.field.flowers:
		in_flowers += f.scoring_elements().size()
	# 4 POLLEN are staged in each FLOWER but the bottom one rests below the
	# middle ring, inside the retrieval opening, which is outside the scoring
	# volume of S10.5.2. So 3 of 4 score in each flower.
	_ok("POLLEN scoring inside the 4 FLOWERS", in_flowers, 12)
	var b: Dictionary = main.mm.scoring.breakdown(main.field, false)
	_ok("GARDEN points, red", b[BB.Alliance.RED]["garden"], 4)
	_ok("GARDEN points, blue", b[BB.Alliance.BLUE]["garden"], 4)
	# S10.5.C: what is sitting in a CELL is not on the board until the match is
	# over. Three NECTAR are staged in each raised cell, so this is a real test.
	_ok("CELL contents score NOTHING mid-match", b[BB.Alliance.RED]["cell"], 0)
	var bf: Dictionary = main.mm.scoring.breakdown(main.field, true)
	_ok("CELL contents DO score once final", bf[BB.Alliance.RED]["cell"], 6)

func _process(d: float) -> void:
	if robot == null or done:
		return
	t += d
	var hive: Hive = main.field.hives[BB.Alliance.RED]
	var target := hive.aim_point()

	if t > 1.2 and fired < 4 and robot.can_fire() and robot.aim_locked:
		if true:
			locked_when_firing = true
			var e := robot.fire()
			if e:
				_shots.append(e)
			fired += 1
			print("  shot %d at %.0f in/s, hood %.1f deg, target %.1f in up / %.1f in out" % [
				fired, robot.launch_speed_in_s, robot.hood_deg,
				target.y / BB.IN, Vector2(target.x - robot.global_position.x,
					target.z - robot.global_position.z).length() / BB.IN])

	_trace += d
	if _trace > 1.0:
		_trace = 0.0
		var line := "  t=%4.1f cell=%d tips=%d  pos(%.0f,%.0f) auto=%s lock=%s blocked=%s dist=%.0f rise=%.0f |" % [
			t, hive.up_cell_elements().size(), hive.tip_count,
			robot.fx(), robot.fy(), str(robot.auto_aim), str(robot.aim_locked),
			str(robot.aim_blocked),
			Vector2(target.x - robot.global_position.x, target.z - robot.global_position.z).length() / BB.IN,
			(target.y - robot.muzzle.global_position.y) / BB.IN]
		for e in _shots:
			var el: GameElement = e
			line += " (%5.1f,%5.1f,%5.1f)" % [el.fx(), el.fy(), el.fz()]
		print(line)

	if t > 14.0:
		done = true
		print("\n--- PLAY ---")
		# checked at FIRING time, not at the end: once the hive has tipped, the
		# raised cell is the other one and it faces the other way, so losing the
		# lock afterwards is correct behaviour rather than a failure
		_ok("auto-aim was locked when firing", locked_when_firing, true)
		_ok("shots taken", fired, 4)
		_ok("HIVE TIPPED by launched POLLEN", hive.tip_count >= 1, true)
		# Table 10-2: a HIVE TIP is worth 20, in AUTO and in TELEOP alike, for
		# every tip. Check the arithmetic, not just that a tip happened.
		var b2: Dictionary = main.mm.scoring.breakdown(main.field)
		var n_tips: int = main.mm.scoring.tips[BB.Alliance.RED]
		_ok("every TIP is worth 20", b2[BB.Alliance.RED]["tips"], n_tips * 20)
		_ok("at least one TIP counted", n_tips >= 1, true)
		_ok("robot still upright", robot.global_transform.basis.y.dot(Vector3.UP) > 0.8, true)
		print("\n%s  (%d failures)" % ["ALL CHECKS PASSED" if fails == 0 else "FAILURES PRESENT", fails])
		get_tree().quit(1 if fails > 0 else 0)
