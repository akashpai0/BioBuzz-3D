extends Node
##
## A FLOWER MUST NOT BE A ONE-WAY HOLE.
##
## Balls that go into a FLOWER and are not scored have to be gettable again
## through the retrieval opening, including the ones further up the stack once
## the ones below them have been taken. The failure this guards against is a
## flower that hands back the bottom two and keeps the rest forever.
##
## It also runs the case that looks like that bug and is not: a robot arriving
## with a part-full hopper can only take what G407 allows, so two stay behind.
## They must still be there, at a retrievable height, for the next trip.
##
var main: Node3D
var robot: Robot
var fl: Flower
var t := 0.0
var phase := 0
var fails := 0
var got_empty := 0
var got_partial := 0
var got_second := 0
var left_height := 0.0

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	main.menu.close()
	await get_tree().create_timer(1.5).timeout
	main._on_menu_start(BB.Mode.FREE_PRACTICE, BB.Alliance.RED, 1,
		{"robots": 1, "per_robot": 1, "opponents": 0})
	await get_tree().create_timer(2.0).timeout
	robot = main.robot
	robot.auto_drive = true
	robot.set_drive(0, 0, 0)
	fl = main.field.flowers[0]
	print("\n--- RETRIEVING FROM A FLOWER ---")
	_clear()
	_load_flower(4)
	phase = 1

## Free everything, including whatever the robot is holding. Clearing only the
## hopper ARRAY leaves the balls frozen to the robot with held_by still set —
## orphans that are invisible to every count in the game.
func _clear() -> void:
	for e in get_tree().get_nodes_in_group("element"):
		e.queue_free()
	robot.hopper.clear()

func _load_flower(n: int) -> void:
	for i in n:
		var e := GameElement.make(BB.Kind.POLLEN, BB.Alliance.RED)
		main.add_child(e)
		e.global_position = fl.global_position + Vector3(0, (30.0 + i * 4.0) * BB.IN, 0)

## Park on the field side of the flower, nose pointing at it. The robot's nose
## is local -Z, which is the direction Basis.looking_at aims.
func _park(dist: float) -> void:
	var flat := Vector3(fl.global_position.x, 0.0, fl.global_position.z)
	var out_dir := flat.normalized()
	var pos := flat - out_dir * dist * BB.IN
	robot.teleport(Transform3D(Basis.looking_at(flat - pos, Vector3.UP), pos))

func _in_flower() -> Array:
	var out: Array = []
	for e in get_tree().get_nodes_in_group("element"):
		var el: GameElement = e
		if el.held_by != null:
			continue
		var r := Vector2(el.global_position.x - fl.global_position.x,
			el.global_position.z - fl.global_position.z).length() / BB.IN
		if r < 5.0:
			out.append(el)
	return out

func _ok(label: String, got, want) -> void:
	var good: bool = got == want
	if not good:
		fails += 1
	print("  %s %-50s got %s   want %s" % ["PASS" if good else "FAIL", label, str(got), str(want)])

func _physics_process(d: float) -> void:
	t += d
	match phase:
		1:
			if t > 7.0:
				_park(15.0)
				phase = 2
				t = 0.0
		2:      # empty hopper, full flower: should get all four
			robot.set_drive(0, 0, 0.45)
			if t > 6.0:
				got_empty = robot.hopper.size()
				robot.set_drive(0, 0, 0)
				# keep the load ON BOARD — the next pass tests a FULL robot
				_load_flower(4)
				phase = 3
				t = 0.0
		3:      # arrive FULL: it must take nothing and leave them all behind
			if t > 6.0:
				_park(15.0)
				phase = 4
				t = 0.0
		4:
			robot.set_drive(0, 0, 0.45)
			if t > 6.0:
				got_partial = _in_flower().size()
				robot.set_drive(0, 0, 0)
				left_height = 99.0
				for el in _in_flower():
					left_height = minf(left_height, el.fz())
				# empty the robot properly and come back for them
				for e in robot.hopper:
					(e as GameElement).queue_free()
				robot.hopper.clear()
				_park(18.0)
				phase = 5
				t = 0.0
		5:
			robot.set_drive(0, 0, 0.45)
			if t > 6.0:
				got_second = robot.hopper.size()
				_report()
				phase = 6

func _report() -> void:
	_ok("an empty robot clears a loaded FLOWER", got_empty, 4)
	_ok("a FULL robot takes none and leaves them", got_partial, 4)
	_ok("the ones left behind are at a retrievable height",
		left_height < 4.5, true)
	_ok("a second trip, emptied, collects them", got_second, 4)
	print("\n  first pass %d/4   left after a full robot %d   lowest %.2f in   second pass %d" % [
		got_empty, got_partial, left_height, got_second])
	print("  %s  (%d failures)" % [
		"FLOWERS GIVE BALLS BACK" if fails == 0 else "BALLS ARE TRAPPED", fails])
	get_tree().quit(1 if fails > 0 else 0)
