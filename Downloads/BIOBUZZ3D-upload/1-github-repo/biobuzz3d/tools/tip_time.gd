extends Node
##
## HOW LONG A TIP TAKES.
##
## The load torque is fixed — 0.44 lb in the raised CELL, by the manual — so the
## only knob that sets the duration of the swing is the damper. This sweeps
## BB.HIVE_ANGULAR_DAMP and reports, for each value, how long the seesaw takes
## to go from the catch releasing to the far stop, loaded with a full eight
## POLLEN and again with a full six NECTAR.
##
## Measured from a SETTLED load: the hive's gate is held shut while the balls
## come to rest, then released on a known frame. Timing from the moment the last
## ball lands would be timing the bounce, not the tip.
##
var main: Node3D
var hive: Hive
var t := 0.0
var phase := 0
var released := 0.0
var results: Array = []
## set true for a per-frame trace of one configuration
var trace := false
## load moment arm at the instant the catch lets go
var settled_arm := 0.0

var _queue: Array = []
var _job: Dictionary = {}

## Sweep here; the harness prints a table and the winner is whatever lands on
## the target.
## Just the shipping value. Widen this back out to re-solve the damper.
var DAMPS := [BB.HIVE_ANGULAR_DAMP]
## three different drops per configuration
const SEEDS := [20261231, 8675309, 424242]
const TARGET_POLLEN := 4.0
const TARGET_NECTAR := 3.6
## trace this damp value in detail
var TRACE_DAMP := BB.HIVE_ANGULAR_DAMP

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	main.menu.close()
	await get_tree().create_timer(1.5).timeout
	hive = main.field.hives[BB.Alliance.RED]
	print("\n--- TIP DURATION SWEEP ---")
	# Every configuration is run on several different drops. Where the balls
	# happen to settle moves the tip time by a few percent, which is the same
	# order as the gap between a full POLLEN load and a full NECTAR one - so a
	# single run can rank them either way and prove nothing.
	for sd in SEEDS:
		for d in DAMPS:
			_queue.append({"damp": d, "kind": BB.Kind.POLLEN, "n": 8, "seed": sd})
			_queue.append({"damp": d, "kind": BB.Kind.NECTAR, "n": 6, "seed": sd})
		# and check that piling MORE in really does tip it quicker
		for extra in [10, 12]:
			_queue.append({"damp": TRACE_DAMP, "kind": BB.Kind.POLLEN, "n": extra, "seed": sd})
		_queue.append({"damp": TRACE_DAMP, "kind": BB.Kind.NECTAR, "n": 8, "seed": sd})
	_next()

func _next() -> void:
	if _queue.is_empty():
		_report()
		return
	_job = _queue.pop_front()
	# clear the field of anything loose so only this run's load is in the cell.
	# The robot holds four of them, and freeing those out from under it makes
	# it write to a dead node every frame — empty the hopper first.
	for r in main.robots:
		if is_instance_valid(r):
			r.hopper.clear()
			r.enabled = false
	for e in get_tree().get_nodes_in_group("element"):
		e.queue_free()
	await get_tree().physics_frame
	hive.swing.angular_damp = float(_job["damp"])
	hive.gate_locked = true
	hive.set_tilt(BB.STAGED_TILT[BB.Alliance.RED])
	await get_tree().physics_frame

	var cell := hive.up_cell()
	var n: int = int(_job["n"])
	# Drop BOTH loads the same way: a loose cluster around the cell centre, let
	# gravity and the balls' own size decide where they end up. An earlier
	# version laid them out on a fixed 3-wide grid, which for 6 balls filled
	# two rows and for 8 filled three - so the nectar started biased toward the
	# pivot and "measured" slower purely because of how it was placed.
	# Drop BOTH loads the same way, and INSIDE the box. The cell interior is
	# 20 x 14 x 12 in and cell.global_transform sits at its centre, so anything
	# dropped more than 7 in up lands on the roof and never counts - which is
	# how an earlier version of this harness "proved" a full load would not tip.
	# Same seed for both runs, so the only difference between them is ball size.
	seed(int(_job["seed"]))
	var half_w: float = BB.CELL_WIDTH * 0.5 - 3.0
	var half_d: float = BB.CELL_DEPTH * 0.5 - 2.5
	for i in n:
		var e := GameElement.make(int(_job["kind"]), BB.Alliance.RED)
		main.add_child(e)
		e.global_position = cell.global_transform * Vector3(
			randf_range(-half_w, half_w) * BB.IN,
			randf_range(0.0, 4.0) * BB.IN,
			randf_range(-half_d, half_d) * BB.IN)
	phase = 1
	t = 0.0
	_next_trace = 0.0
	trace = false

func _physics_process(d: float) -> void:
	if phase == 0:
		return
	t += d
	match phase:
		1:      # let the load settle with the catch held shut
			if t > 2.2:
				settled_arm = _arm()
				hive.gate_locked = false
				released = t
				phase = 2
		2:      # timing the swing
			_trace()
			if hive.tip_count > 0:
				_record(t - released)
			elif t - released > 20.0:
				_record(-1.0)      # never went over

## Angle and how much of the load is still in the cell, every 0.25 s. A tip that
## takes too long is usually a tip whose load left through the mouth early.
var _next_trace := 0.0
func _trace() -> void:
	if not trace or t < _next_trace:
		return
	_next_trace = t + 0.25
	var cell := hive.up_cell()
	print("      t+%.2f  angle %6.1f deg   in cell %d   arm %5.2f in   load %.3f kg   hold %.2f" % [
		t - released, rad_to_deg(hive.angle()),
		hive.up_cell_elements().size(), _arm(),
		hive.cell_mass(hive.up_cell()), hive.hold_torque])

## Horizontal distance from the pivot axis to the load's centre of mass, in
## inches. THIS is the number that decides how fast a tip goes: the mass is
## fixed at 0.44 lb by the manual, so torque is arm x weight and nothing else.
func _arm() -> float:
	var els := hive.up_cell_elements()
	if els.is_empty():
		return 0.0
	var c := Vector3.ZERO
	var m := 0.0
	for e in els:
		var el: GameElement = e
		c += el.global_position * el.mass
		m += el.mass
	c /= maxf(m, 0.0001)
	var flat := c - hive.swing.global_position
	flat.y = 0.0
	return flat.length() / BB.IN

func _record(secs: float) -> void:
	phase = 0
	hive.tip_count = 0
	results.append({"damp": float(_job["damp"]), "kind": int(_job["kind"]),
		"n": int(_job["n"]), "secs": secs, "arm": settled_arm})
	print("  damp %.2f  %-10s -> %-14s settled arm %.2f in" % [
		float(_job["damp"]),
		"%d %s" % [int(_job["n"]),
			"POLLEN" if int(_job["kind"]) == BB.Kind.POLLEN else "NECTAR"],
		("%.2f s" % secs) if secs > 0.0 else "NEVER TIPPED", settled_arm])
	call_deferred("_next")

func _report() -> void:
	print("")
	var fails := 0
	var p8 := _secs(BB.Kind.POLLEN, 8)
	var p10 := _secs(BB.Kind.POLLEN, 10)
	var p12 := _secs(BB.Kind.POLLEN, 12)
	var n6 := _secs(BB.Kind.NECTAR, 6)
	var n8 := _secs(BB.Kind.NECTAR, 8)

	# What the hive is contracted to do, in Julian's words:
	#   a full POLLEN load takes about four seconds;
	#   a full NECTAR load goes over FASTER than that;
	#   and piling more in makes it quicker again.
	fails += _ok("8 POLLEN tips in about 4 s", p8 > 3.5 and p8 < 4.5, true)
	fails += _ok("6 NECTAR is FASTER than 8 POLLEN", n6 < p8, true)
	fails += _ok("10 POLLEN beats 8", p10 < p8, true)
	fails += _ok("12 POLLEN beats 10", p12 < p10, true)
	fails += _ok("8 NECTAR beats 6", n8 < n6, true)
	print("\n  mean of %d drops each, damper %.2f" % [SEEDS.size(), BB.HIVE_ANGULAR_DAMP])
	print("   8 POLLEN  %.2f s  (%s)" % [p8, _spread(BB.Kind.POLLEN, 8)])
	print("   6 NECTAR  %.2f s  (%s)" % [n6, _spread(BB.Kind.NECTAR, 6)])
	print("  10 POLLEN  %.2f s   12 POLLEN %.2f s   8 NECTAR %.2f s" % [p10, p12, n8])
	print("  %s  (%d failures)" % [
		"TIP TIMING CORRECT" if fails == 0 else "TIP TIMING WRONG", fails])
	get_tree().quit(1 if fails > 0 else 0)

## Mean tip time across every drop of this configuration.
func _secs(kind: int, n: int) -> float:
	var total := 0.0
	var hits := 0
	for r in results:
		if int(r["kind"]) == kind and int(r["n"]) == n and float(r["secs"]) > 0.0:
			total += float(r["secs"])
			hits += 1
	return (total / float(hits)) if hits > 0 else -1.0

## Worst and best of the runs, so the spread is visible next to the mean.
func _spread(kind: int, n: int) -> String:
	var lo := 1e9
	var hi := -1e9
	for r in results:
		if int(r["kind"]) == kind and int(r["n"]) == n and float(r["secs"]) > 0.0:
			lo = minf(lo, float(r["secs"]))
			hi = maxf(hi, float(r["secs"]))
	return "%.2f-%.2f" % [lo, hi] if hi > 0.0 else "none"

func _ok(label: String, got, want) -> int:
	var good: bool = got == want
	print("  %s %-44s got %s   want %s" % [
		"PASS" if good else "FAIL", label, str(got), str(want)])
	return 0 if good else 1
