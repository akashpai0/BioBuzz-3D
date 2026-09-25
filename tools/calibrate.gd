extends Node3D
##
## HEADLESS HIVE CALIBRATION.
##
## The manual publishes a TABLE of how many POLLEN tip a CELL holding N NECTAR,
## and explicitly says no single mass model reproduces it. This project does not
## hard-code the table: it puts real masses in the cell and lets a hinged,
## pivot-balanced seesaw decide. That leaves exactly ONE free parameter, the
## bi-stable detent torque, and this harness solves for it.
##
## For each candidate torque it runs the four rows that come from FIRST's own
## Event Field Setup Guide S12.3 (the other rows are owner measurements):
##      0 NECTAR + 7 POLLEN -> must NOT tip
##      0 NECTAR + 8 POLLEN -> must tip
##      3 NECTAR + 2 POLLEN -> must NOT tip
##      3 NECTAR + 3 POLLEN -> must tip
## and then sweeps the full table with the winner.
##
## Run:  godot --headless --path . tools/calibrate.tscn
##

const TORQUES := [-1.0]   # -1 = leave hive.gd's own mass gate in charge
## NECTAR mass candidates, kg. The closed CELL changed the problem: the big
## NECTAR settle hard against the inner end wall at a SHORT lever arm while
## POLLEN stack behind them further out, so nectar pull their weight less than
## mass alone suggests. That is a geometry fact, not a fudge — so the mass is
## re-solved against it rather than the geometry being bent to fit.
const MASSES := [-1.0]
## The team's rule: a CELL lets go at 0.44 lb, which is 8 POLLEN or 6 NECTAR or
## any mix. These rows check the boundary from both sides and in combination.
const GATE := [
	[0, 7, false], [0, 8, true],
	[5, 0, false], [6, 0, true],
	[3, 3, false], [3, 4, true],
	[4, 1, false], [4, 2, true],
]
const SETTLE := 9.0   # a light load creeps to centre before it commits

var field: Field
var hive: Hive
var _queue: Array = []
var _cur: Dictionary = {}
var _t := 0.0
var _results: Array = []
var _phase := "gate"
var _threshold := {}

func _ready() -> void:
	field = Field.new()
	add_child(field)
	field.build()
	hive = field.hives[BB.Alliance.RED]
	for t in TORQUES:
		for m in MASSES:
			for row in GATE:
				_queue.append({"torque": t, "mass": m, "n": row[0], "p": row[1], "want": row[2]})
	print("hive calibration: %d gate runs" % _queue.size())
	call_deferred("_next")

func _next() -> void:
	if _queue.is_empty():
		_report()
		return
	var c: Dictionary = _queue.pop_front()
	if _phase == "sweep" and _threshold.has(c["n"]):
		_next()                      # this row is already solved; do not burn 6 s on it
		return
	if c["torque"] > 0.0:
		hive.hold_torque = c["torque"]
	GameElement.nectar_mass_override = -1.0
	hive.tip_count = 0
	hive.set_tilt(-1)
	for n in get_tree().get_nodes_in_group("element"):
		n.queue_free()
	await get_tree().physics_frame
	_fill(c["n"], c["p"])
	_t = 0.0
	_cur = c          # armed last, so _physics_process cannot judge a half-set run

## Lay the load into the raised CELL the way a match would: dropped in, settling
## under gravity, not teleported to a lever arm we picked.
func _fill(nectar: int, pollen: int) -> void:
	var cell := hive.up_cell()
	# The CELL's Area3D sits at the centre of the box interior, so slots are laid
	# out around that: across the 20 in width, up from the floor, and along the
	# 12 in depth. Dropped in, not teleported to a lever arm we chose.
	var slots: Array = []
	for layer in 3:
		for ix in 5:
			for iz in 2:
				slots.append(Vector3(
					(float(ix) - 2.0) * 3.9,
					-BB.CELL_HEIGHT * 0.5 + 1.8 + float(layer) * 3.6,
					(float(iz) - 0.5) * 4.0))
	var i := 0
	for k in nectar:
		_drop(BB.Kind.NECTAR, cell, slots[i]); i += 1
	for k in pollen:
		_drop(BB.Kind.POLLEN, cell, slots[i]); i += 1

func _drop(kind: int, cell: Area3D, local_in: Vector3) -> void:
	var e := GameElement.make(kind, BB.Alliance.RED)
	add_child(e)
	e.global_position = cell.global_transform * (local_in * BB.IN)

func _physics_process(delta: float) -> void:
	if _cur.is_empty():
		return
	_t += delta
	var tipped := hive.tip_count > 0
	if _t < SETTLE and not tipped:
		return          # a tip ends the run early; a non-tip has to serve its time
	_results.append({
		"torque": _cur["torque"], "mass": _cur.get("mass", -1.0),
		"n": _cur["n"], "p": _cur["p"],
		"want": _cur["want"], "got": tipped, "ok": tipped == _cur["want"]})
	print("  run T=%.2f m=%.3f %dn+%dp -> %-4s want %-5s %s  (angle %.1f)" % [
		_cur["torque"], _cur.get("mass", -1.0), _cur["n"], _cur["p"],
		"TIP" if tipped else "held", str(_cur["want"]),
		"OK" if tipped == _cur["want"] else "FAIL", rad_to_deg(hive.angle())])
	if _phase == "sweep" and tipped and not _threshold.has(_cur["n"]):
		_threshold[_cur["n"]] = _cur["p"]
	_cur = {}
	_next()

func _report() -> void:
	if _phase == "gate":
		var score := {}
		for r in _results:
			var key := "mass-gate"
			score[key] = score.get(key, 0) + (1 if r["ok"] else 0)
		var best_key := ""
		var best_n := -1
		for k in score:
			print("  %s -> %d/4" % [k, score[k]])
			if score[k] > best_n:
				best_n = score[k]
				best_key = k
		var best := -1.0
		print("\nMASS GATE: %d/%d rows correct" % [best_n, GATE.size()])
		print("sweeping the full table at %.2f ...\n" % best)
		_phase = "sweep"
		_results.clear()
		for n in 6:
			for p in 10:
				_queue.append({"torque": best, "mass": GameElement.nectar_mass_override,
					"n": n, "p": p, "want": true})
		call_deferred("_next")
		return

	var threshold := _threshold
	print("nectar | pollen to tip (sim) | manual")
	var manual := [8, 7, 6, 3, 1, 0]
	for n in 6:
		print("   %d   |        %-4s           |   %d" % [n, str(threshold.get(n, "none")), manual[n]])
	get_tree().quit()
