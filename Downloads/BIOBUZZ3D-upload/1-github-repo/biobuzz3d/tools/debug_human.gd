extends Node
##
## THE HUMAN PLAYER IS A PERSON.
##
## G426 lets the human player enter NECTAR; it never said the ball appears out
## of thin air the instant a HIVE tips. Before this pass the sim teleported it
## in on the same frame, which is both wrong and useful information the driver
## never got — you could not learn to wait for a feed.
##
## Now each alliance's player has a reaction time and feeds one element at a
## time (G427). This checks: nothing appears immediately, everything owed
## arrives eventually, each one lands inside the LOADING ZONE resting on the
## tiles, and they arrive spaced out rather than all at once.
##
var main: Node3D
var mm: MatchManager
var fails := 0
var at_0 := 0
var at_half := 0
var arrivals: Array = []
var placed: Array = []
var t := 0.0
var owed := 0
var done := false

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	main.menu.close()
	await get_tree().create_timer(1.5).timeout
	main._on_menu_start(BB.Mode.FREE_PRACTICE, BB.Alliance.RED, 1,
		{"robots": 1, "per_robot": 1, "opponents": 0})
	await get_tree().create_timer(2.0).timeout
	mm = main.mm
	print("\n--- HUMAN PLAYER ---")
	owed = 3
	mm._release_nectar(BB.Alliance.RED, owed)
	at_0 = _in_zone(BB.Alliance.RED)
	t = 0.0

## NECTAR sitting in red's LOADING ZONE and actually in play.
func _in_zone(a: int) -> int:
	var lz := BB.loading_zone(a)
	var n := 0
	for e in get_tree().get_nodes_in_group("element"):
		var el: GameElement = e
		if el.kind == BB.Kind.NECTAR and el.held_by == null \
				and BB.rect_has(lz, el.fx(), el.fy()):
			n += 1
			if not placed.has(el):
				placed.append(el)
				arrivals.append([t, el.fz(), el.linear_velocity.length() / BB.IN])
	return n

func _ok(label: String, got, want) -> void:
	var good: bool = got == want
	if not good:
		fails += 1
	print("  %s %-52s got %s   want %s" % ["PASS" if good else "FAIL", label, str(got), str(want)])

func _physics_process(d: float) -> void:
	if mm == null or done:
		return
	t += d
	var n := _in_zone(BB.Alliance.RED)
	if t >= 0.5 and at_half == 0:
		at_half = n + 1000        # marker so "0 so far" is distinguishable
	if t > 12.0:
		done = true
		_report(n)

func _report(final_n: int) -> void:
	_ok("nothing appears on the frame the hive tips", at_0, 0)
	_ok("still nothing half a second later", at_half - 1000, 0)
	_ok("all three arrive in the end", final_n, owed)
	var spaced := true
	for i in range(1, arrivals.size()):
		if float(arrivals[i][0]) - float(arrivals[i - 1][0]) < BB.HUMAN_PLACE_GAP * 0.8:
			spaced = false
	_ok("fed one at a time, not in a clump (G427)", spaced, true)
	var on_tiles := arrivals.all(func(a: Array) -> bool: return float(a[1]) < 4.0)
	_ok("each one is placed on the tiles, not dropped in", on_tiles, true)
	var still := arrivals.all(func(a: Array) -> bool: return float(a[2]) < 6.0)
	_ok("and placed at rest, not thrown", still, true)
	for a in arrivals:
		print("    arrived at %.2f s, %.1f in high, %.1f in/s" % [a[0], a[1], a[2]])
	print("  %s  (%d failures)" % ["HUMAN PLAYER BEHAVES LIKE A PERSON" if fails == 0 else "PROBLEMS", fails])
	get_tree().quit(1 if fails > 0 else 0)
