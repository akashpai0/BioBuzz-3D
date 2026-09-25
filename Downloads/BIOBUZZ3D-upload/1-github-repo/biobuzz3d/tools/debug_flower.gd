extends Node
## Drops one POLLEN down a FLOWER and reports every body it touches on the way.
var main: Node3D
var ball: GameElement
var t := 0.0

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	main.menu.close()
	await get_tree().create_timer(1.6).timeout
	var f: Flower = main.field.flowers[0]
	print("flower %s at (%.1f, %.1f)" % [f.id, f.global_position.x / BB.IN, -f.global_position.z / BB.IN])
	ball = GameElement.make(BB.Kind.POLLEN)
	main.add_child(ball)
	ball.global_position = f.global_position + Vector3(0, BB.m(26.0), 0)
	t = 0.0

func _physics_process(d: float) -> void:
	if ball == null:
		return
	t += d
	if fmod(t, 0.1) < d:
		var hits := ""
		for b in ball.get_colliding_bodies():
			var n: Node = b
			hits += " HIT:%s<%s>" % [n.name, n.get_parent().name]
		print("t=%.2f  z=%6.2f in   v=%5.1f in/s%s" % [
			t, ball.fz(), ball.linear_velocity.length() / BB.IN, hits])
	if t > 3.0:
		get_tree().quit()
