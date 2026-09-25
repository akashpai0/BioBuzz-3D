extends Node
## THE SCENARIO CREATOR, TESTED AS BEHAVIOUR.
##
## Walks the acceptance list: build a scenario from a staged field, place and
## remove balls, move and rotate a robot, load its hopper, set a clock and an
## opponent, test it, retry it, come back to an UNCHANGED draft, undo and redo,
## edit a saved snapshot without disturbing motion it was not asked to touch,
## and refuse the things that would not restore.

var main: Node3D
var fails := 0
const NAME := "editor harness"

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(2.0).timeout
	print("\n--- SCENARIO CREATOR ---")
	for e in ScenarioLibrary.list_all():
		if String(e["name"]).begins_with(NAME):
			ScenarioLibrary.delete_one(String(e["id"]))

	await _authoring()
	await _test_and_return()
	await _edit_existing()
	_validation()

	print("  %s  (%d failure%s)" % [
		"THE CREATOR WORKS" if fails == 0 else "CREATOR BROKEN",
		fails, "" if fails == 1 else "s"])
	get_tree().quit(1 if fails > 0 else 0)

# ================================================================ authoring ==

var draft: ScenarioDraft

func _authoring() -> void:
	await main._create_scenario("staged")
	draft = main.editor.draft
	_ok("the editor opened on a staged field", main.editor.is_open(), true)
	_ok("  with the world frozen for editing", BB.editing, true)
	var n0: int = draft.elements().size()

	# ---- place and remove loose elements
	var id: String = draft.add_element(BB.Kind.POLLEN, -1, Vector3(20.0, -30.0, 1.4))
	_ok("a ball can be placed", draft.elements().size(), n0 + 1)
	_ok("  and it starts at rest",
		Snapshot.unpack_v3(draft.find(id).get("lin", [])).length() < 0.001, true)
	draft.remove_object(id)
	_ok("  and removed again", draft.elements().size(), n0)

	# ---- move and rotate the robot
	draft.set_position("robot:0", Vector3(-24.0, 12.0, 0.0))
	draft.set_yaw("robot:0", 135.0)
	var p: Vector3 = draft.position_of("robot:0")
	_ok("the robot moved where it was put",
		absf(p.x - -24.0) < 0.05 and absf(p.y - 12.0) < 0.05, true)
	_ok("  and turned to face the heading typed in",
		absf(draft.yaw_of("robot:0") - 135.0) < 0.5, true)

	# ---- hopper contents and battery
	var before: int = (draft.find("robot:0").get("hopper", []) as Array).size()
	while (draft.find("robot:0").get("hopper", []) as Array).size() > 0:
		draft.take_from_hopper(String((draft.find("robot:0")["hopper"] as Array)[0]))
	draft.fill_hopper_slot(0, BB.Kind.POLLEN, -1)
	draft.fill_hopper_slot(0, BB.Kind.POLLEN, -1)
	_ok("the hopper holds what was put in it",
		(draft.find("robot:0").get("hopper", []) as Array).size(), 2)
	var eid: String = String((draft.find("robot:0")["hopper"] as Array)[0])
	_ok("  and a carried ball is not also loose",
		String(draft.find(eid).get("held", "")), "robot:0")
	var nectar_err: String = draft.fill_hopper_slot(0, BB.Kind.NECTAR, BB.Alliance.RED)
	_ok("  and NECTAR is refused by a pollen-only intake", nectar_err != "", true)
	draft.set_prop("robot:0", "takes_nectar", true)
	_ok("  until the intake is set to take both",
		draft.fill_hopper_slot(0, BB.Kind.NECTAR, BB.Alliance.RED), "")
	draft.set_prop("robot:0", "battery_v", 11.6)
	_ok("the battery can be set",
		absf(float(draft.find("robot:0").get("battery_v", 0.0)) - 11.6) < 0.01, true)

	# ---- 20 seconds left, with an opponent on the field
	draft.set_scenario("phase", BB.Phase.TELEOP)
	draft.set_scenario("time_left", 20.0)
	var foe: String = draft.add_robot(BB.Alliance.BLUE, true)
	_ok("an opponent can be added", foe != "", true)
	_ok("  and the roster shape follows",
		int(draft.setup().get("opponents", 0)), 1)
	_ok("the clock is what was asked for",
		float(draft.match_block().get("time_left", 0.0)), 20.0)
	_ok("the draft has no errors", draft.errors().size(), 0)

	# ---- undo and redo across placement, deletion and a property change
	var tips_before: int = draft.robots().size()
	draft.remove_object(foe)
	_ok("undo/redo: the opponent was removed", draft.robots().size(), tips_before - 1)
	draft.undo()
	_ok("  undo brought it back", draft.robots().size(), tips_before)
	draft.redo()
	_ok("  redo removed it again", draft.robots().size(), tips_before - 1)
	draft.undo()

	# ---- save
	draft.name = NAME
	draft.note = "built by the harness"
	var sid: String = ScenarioLibrary.save(draft.to_snapshot(), draft.name, draft.note)
	_ok("the scenario saved to the library", sid != "", true)
	draft.source_id = sid
	var reread: Dictionary = ScenarioLibrary.load_one(sid)
	_ok("  and reads back clean", String(reread["error"]), "")
	_ok("  with the roster it was saved with",
		(reread["data"]["robots"] as Array).size(), draft.robots().size())

# ========================================================== test and return ==

func _test_and_return() -> void:
	var snapshot: Dictionary = draft.to_snapshot()
	var before: Dictionary = draft.data.duplicate(true)
	await main._test_scenario(snapshot)
	await get_tree().create_timer(0.1).timeout
	_ok("testing launched an attempt", main.mm.in_progress(), true)
	_ok("  from the draft's clock",
		absf(main.mm.time_left - 20.0) < 1.0, true)
	_ok("  flagged as a situation run, not a match", main.scenario_run, true)
	_ok("  with the way back on offer", main.editor_return, true)

	# drive the world somewhere else, then retry
	main.mm.resume()
	await get_tree().create_timer(1.0).timeout
	main.robot.teleport(Transform3D(Basis.IDENTITY, BB.fp(40.0, 40.0, 0.0)))
	await get_tree().create_timer(0.3).timeout
	await main.retry_situation()
	main.mm.pause()
	var p: Vector3 = BB.to_field(main.robot.global_position)
	_ok("retry restored the test's own starting pose",
		absf(p.x - -24.0) < 0.2 and absf(p.y - 12.0) < 0.2, true)

	var history: int = RobotShop.history().size()
	await main.return_to_editor()
	_ok("the editor came back", main.editor.is_open(), true)
	_ok("  with the draft untouched",
		JSON.stringify(main.editor.draft.data) == JSON.stringify(before), true)
	_ok("  and the test left no match history", RobotShop.history().size(), history)

# =========================================================== editing a save ==

func _edit_existing() -> void:
	# a situation with motion in it: editing must not quietly stop it
	var moving: Dictionary = draft.to_snapshot()
	var flyer: String = String((moving["elements"] as Array)[0]["id"])
	for e in moving["elements"]:
		if String(e["id"]) == flyer:
			e["lin"] = Snapshot.pack_v3(Vector3(1.1, 1.9, -0.4))
			e["origin"] = Snapshot.pack_v3(BB.fp(10.0, 10.0, 30.0))
	var id: String = ScenarioLibrary.save(moving, NAME + " moving", "has an airborne ball")
	await main._edit_scenario(id)
	var d2: ScenarioDraft = main.editor.draft
	var kept: Vector3 = Snapshot.unpack_v3(d2.find(flyer).get("lin", []))
	_ok("opening a moving situation keeps its airborne ball moving",
		kept.length() > 1.0, true)
	_ok("  and does not advance the clock",
		absf(float(d2.match_block().get("time_left", 0.0)) - 20.0) < 0.001, true)

	# moving something else must not disturb it
	var other := ""
	for e in d2.elements():
		if String(e["id"]) != flyer and String(e.get("held", "")) == "":
			other = String(e["id"])
			break
	d2.set_position(other, Vector3(5.0, 5.0, 1.4))
	var still: Vector3 = Snapshot.unpack_v3(d2.find(flyer).get("lin", []))
	_ok("  and moving a different ball leaves it alone",
		still.distance_to(kept) < 0.001, true)

	# but moving the flyer itself stops it, because that is the default
	d2.set_position(flyer, Vector3(0.0, 0.0, 1.4), true)
	_ok("  while moving the flyer itself stops it (stop-motion default)",
		Snapshot.unpack_v3(d2.find(flyer).get("lin", [])).length() < 0.001, true)

# ============================================================== validation ===

func _validation() -> void:
	var d: Dictionary = draft.to_snapshot()
	# duplicate id
	var bad: Dictionary = d.duplicate(true)
	(bad["elements"] as Array).append((bad["elements"] as Array)[0].duplicate(true))
	_ok("a duplicate id is an error", _has_error(Snapshot.check_draft(bad)), true)
	# broken hopper reference
	var bad2: Dictionary = d.duplicate(true)
	(bad2["robots"] as Array)[0]["hopper"] = ["e9999"]
	_ok("a hopper pointing at nothing is an error",
		_has_error(Snapshot.check_draft(bad2)), true)
	# no driver
	var bad3: Dictionary = d.duplicate(true)
	for r in bad3["robots"]:
		r["ai"] = true
	_ok("a roster with nobody to drive is an error",
		_has_error(Snapshot.check_draft(bad3)), true)
	# impossible number
	var bad4: Dictionary = d.duplicate(true)
	bad4["match"]["time_left"] = -5.0
	_ok("a negative clock is an error",
		_has_error(Snapshot.check_draft(bad4)), true)
	# an odd but deliberate setup is NOT an error
	var odd: Dictionary = d.duplicate(true)
	for e in odd["elements"]:
		if String(e.get("held", "")) == "":
			e["origin"] = Snapshot.pack_v3(BB.fp(80.0, 80.0, 1.4))
			break
	var probs: Array = Snapshot.check_draft(odd)
	_ok("a ball outside the wall is a warning, not an error",
		_has_error(probs), false)
	_ok("  and it is still reported", probs.size() > 0, true)
	# damaged data does not crash
	_ok("nonsense data is refused politely",
		Snapshot.check_draft({"format": "nope"}).size(), 1)

func _has_error(probs: Array) -> bool:
	for p in probs:
		if String(p.get("severity", "")) == "error":
			return true
	return false

func _ok(what: String, got: Variant, want: Variant) -> void:
	var pass_: bool = str(got) == str(want)
	if not pass_:
		fails += 1
	print("  %s %-56s got %s   want %s" % [
		"PASS" if pass_ else "FAIL", what, str(got), str(want)])
