extends Node
## Fires ONE aim-assisted shot at the raised red CELL and logs its position and
## every body it touches, tick by tick.
var main: Node3D
var robot: Robot
var shot: GameElement
var t := 0.0
var started := false

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	main.menu.close()
	main.mm.mode = BB.Mode.FREE_PRACTICE
	await get_tree().create_timer(1.5).timeout
	robot = main.robot
	robot.enabled = true
	for f in main.field.flowers:
		var fl: Flower = f
		var hs: Array = []
		for e in get_tree().get_nodes_in_group("pollen"):
			var el: GameElement = e
			if Vector2(el.global_position.x - fl.global_position.x,
					el.global_position.z - fl.global_position.z).length() < BB.m(6.0):
				hs.append("%.1f" % el.fz())
		hs.sort()
		print("%s pollen heights: %s   (scoring volume %.2f..%.1f)" % [
			fl.id, str(hs), BB.FLOWER_SCORE_LO, BB.FLOWER_SCORE_HI])
	var hive: Hive = main.field.hives[BB.Alliance.RED]
	var target := hive.aim_point()
	print("robot at (%.1f, %.1f)   cell target (%.1f, %.1f, %.1f)" % [
		robot.fx(), robot.fy(), target.x / BB.IN, -target.z / BB.IN, target.y / BB.IN])
	robot.aim_at(target)
	print("aim: yaw %.1f deg, hood %.1f deg, speed %.0f in/s" % [
		rad_to_deg(robot.turret.global_rotation.y), robot.hood_deg, robot.launch_speed_in_s])
	print("muzzle at (%.1f, %.1f, %.1f)" % [
		robot.muzzle.global_position.x / BB.IN, -robot.muzzle.global_position.z / BB.IN,
		robot.muzzle.global_position.y / BB.IN])
	shot = robot.fire()
	started = true

func _physics_process(d: float) -> void:
	if not started or shot == null:
		return
	t += d
	if t < 1.2:
		var hits := ""
		for b in shot.get_colliding_bodies():
			var n: Node = b
			hits += " HIT:" + str(n.name) + "<" + str(n.get_parent().name) + ">"
		for c in shot.get_contact_count() if false else []:
			pass
		print("t=%.2f  (%6.1f,%6.1f,%6.1f)  v=%5.1f in/s%s" % [
			t, shot.fx(), shot.fy(), shot.fz(), shot.linear_velocity.length() / BB.IN, hits])
	if t > 1.3:
		get_tree().quit()
