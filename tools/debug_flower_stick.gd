extends Node
##
## NOTHING MAY WEDGE ON A FLOWER.
##
## Two loads, because they fail differently:
##
##   RAIN     balls dropped from above, on and off target. Catches anything
##            perching on the rim or the collar.
##   INCOMING balls FIRED horizontally at the structure from eight bearings at
##            three heights — a missed shot, or a ball a robot shoved into it.
##            This is the case the old version of this harness never ran, and
##            it is the one that produced the balls hanging on the side of the
##            tube in the field.
##
## A ball is WEDGED if it has come to rest, is not on the tiles, and is not
## inside the tube bore. Anywhere else on the structure counts, because a ball
## parked there is neither scored nor retrievable.
##
var main: Node3D
var t := 0.0
var phase := 0
var fails := 0
var worst: Array = []

## Outside this radius from the flower axis, a resting ball is on the outside
## of the structure rather than in the bore.
const BORE_R := 2.62
## Below this height it is on the tiles (or in a pile on them), which is fine.
const FLOOR_H := 5.0

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	main.menu.close()
	main.mm.mode = BB.Mode.FREE_PRACTICE
	await get_tree().create_timer(1.8).timeout
	print("\n--- FLOWER STICKING ---")
	_rain()
	phase = 1

## Dropped from above, mostly off target.
func _rain() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for f in main.field.flowers:
		var fl: Flower = f
		for i in 8:
			var kind := BB.Kind.POLLEN if i % 3 != 0 else BB.Kind.NECTAR
			var e := GameElement.make(kind, BB.Alliance.RED)
			main.add_child(e)
			e.global_position = fl.global_position + Vector3(
				rng.randf_range(-5.0, 5.0) * BB.IN,
				(26.0 + float(i) * 2.2) * BB.IN,
				rng.randf_range(-5.0, 5.0) * BB.IN)

## Fired AT the structure from every side, at the heights a real shot and a
## real shove arrive at.
func _incoming() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	for f in main.field.flowers:
		var fl: Flower = f
		for b in 8:
			var ang := TAU * float(b) / 8.0
			var dir := Vector3(sin(ang), 0.0, cos(ang))
			for h in [4.0, 11.0, 19.0]:
				var e := GameElement.make(
					BB.Kind.POLLEN if b % 3 != 0 else BB.Kind.NECTAR, BB.Alliance.RED)
				main.add_child(e)
				e.global_position = fl.global_position \
					+ dir * 16.0 * BB.IN + Vector3(0, float(h) * BB.IN, 0)
				# aimed slightly off-centre, which is how a ball finds a gap
				var aim := (-dir).rotated(Vector3.UP, rng.randf_range(-0.28, 0.28))
				e.linear_velocity = aim * BB.m(rng.randf_range(70.0, 150.0))

func _physics_process(d: float) -> void:
	if phase == 0:
		return
	t += d
	match phase:
		1:
			if t > 9.0:
				_report("RAIN")
				for e in get_tree().get_nodes_in_group("element"):
					e.queue_free()
				phase = 2
				t = 0.0
		2:
			if t > 0.6:
				_incoming()
				phase = 3
				t = 0.0
		3:
			if t > 11.0:
				_report("INCOMING")
				_finish()
				phase = 4

func _report(label: String) -> void:
	var wedged := 0
	var inside := 0
	var floored := 0
	for e in get_tree().get_nodes_in_group("element"):
		var el: GameElement = e
		if el.held_by != null:
			continue
		# still moving? not settled, so not stuck
		if el.linear_velocity.length() > BB.m(1.5):
			continue
		var best := 999.0
		var which: Flower = null
		for f in main.field.flowers:
			var fl: Flower = f
			var r := Vector2(el.global_position.x - fl.global_position.x,
				el.global_position.z - fl.global_position.z).length() / BB.IN
			if r < best:
				best = r
				which = fl
		if el.fz() < FLOOR_H:
			floored += 1
			continue
		if best < BORE_R:
			inside += 1
			continue
		# a HIVE cell is not this test's business
		if absf(el.fx()) < 32.0 and absf(el.fy()) < 26.0 and el.fz() > 25.0:
			floored += 1
			continue
		if best > 14.0:
			floored += 1          # nowhere near a flower
			continue
		wedged += 1
		worst.append("%s: %.1f in out, %.1f in up" % [label, best, el.fz()])
	if wedged > 0:
		fails += 1
	print("  %-9s in the bore %-3d on the tiles %-3d   WEDGED %d" % [
		label, inside, floored, wedged])

func _finish() -> void:
	for w in worst.slice(0, 12):
		print("      %s" % w)
	print("  %s  (%d failures)" % [
		"NOTHING WEDGES ON A FLOWER" if fails == 0 else "BALLS ARE STICKING", fails])
	get_tree().quit(1 if fails > 0 else 0)
