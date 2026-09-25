class_name Snapshot
extends RefCounted
##
## SAVED PRACTICE SITUATIONS.
##
## A snapshot is the whole playable state of the field at one instant, as plain
## data: the match clock and scoreboard, every robot's pose and mechanism, what
## is in each hopper, every loose ball, the hives mid-swing, what the AI was in
## the middle of, and what the human players still owe. Save one, come back to
## it tomorrow, and drive the same situation again.
##
## WHAT IT PROMISES: the same STARTING CONDITIONS, not bit-identical physics.
## Jolt is deterministic frame to frame but the restored contact set is not the
## one the original simulation had built up, so a ball balanced on a rim may
## fall the other way. Everything you can see and act on is the same; what
## happens next is a real simulation, not a recording.
##
## DESIGN NOTES, because a field editor will read this format later:
##   - Every object has a STABLE ID inside the file (e0001, robots by index).
##     References — a hopper's contents, an AI's target, the human player's
##     queue — are stored as ids and resolved after the objects exist.
##   - Every delay is stored as TIME REMAINING, never a deadline. A wall-clock
##     deadline is meaningless in a process that started at a different time.
##   - Transforms are flat float arrays, so the file is readable and diffable
##     and an editor can nudge a number by hand.
##   - `version` is checked on load. An unreadable or newer file is reported,
##     never crashed on.
##

const FORMAT := "biobuzz.situation"
const VERSION := 1

# ------------------------------------------------------------------ packing --

static func pack_v3(v: Vector3) -> Array:
	return [snappedf(v.x, 0.00001), snappedf(v.y, 0.00001), snappedf(v.z, 0.00001)]

static func unpack_v3(a: Variant) -> Vector3:
	if not (a is Array) or (a as Array).size() < 3:
		return Vector3.ZERO
	var arr: Array = a
	return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))

static func pack_basis(b: Basis) -> Array:
	return pack_v3(b.x) + pack_v3(b.y) + pack_v3(b.z)

static func unpack_basis(a: Variant) -> Basis:
	if not (a is Array) or (a as Array).size() < 9:
		return Basis.IDENTITY
	var arr: Array = a
	return Basis(
		Vector3(float(arr[0]), float(arr[1]), float(arr[2])),
		Vector3(float(arr[3]), float(arr[4]), float(arr[5])),
		Vector3(float(arr[6]), float(arr[7]), float(arr[8])))

# ------------------------------------------------------------------ capture --

## Everything on the field right now, as one dictionary.
##
## `main` is the world root: it owns the match, the field, the robots and the
## roster the situation was set up with.
##
## `rng_seed` is normally drawn from the global generator. The replay recorder
## passes its own so that recording never consumes the game's random numbers —
## a run that is being recorded draws the same human placements as one that
## is not.
static func capture(main: Node, rng_seed := -1) -> Dictionary:
	var mm = main.mm
	var elements: Array = []
	var ids := {}                       # GameElement -> id
	var robots: Array = main.robots

	var robot_index := func(r: Variant) -> int:
		if r == null or not is_instance_valid(r):
			return -1
		for i in robots.size():
			if robots[i] == r:
				return i
		return -1

	# ---- elements first, so everything else can reference them by id
	var n := 0
	for node in main.get_tree().get_nodes_in_group("element"):
		var e: GameElement = node
		if not is_instance_valid(e):
			continue
		n += 1
		var id := "e%04d" % n
		ids[e] = id
		# An element can be owned by a robot that no longer exists — a roster
		# rebuild frees the robot, and `is` on a freed instance is an error
		# that would take the whole capture down. A ghost owner means the ball
		# is nobody's, which is what gets written.
		var hb: Variant = e.held_by
		# `hb != null` is FALSE for a freed object in Godot 4, so the old
		# guard let a freed owner through to the `is` test below.
		if not is_instance_valid(hb):
			hb = null
		var holder := ""
		if hb == e:
			holder = "out"              # left the field, waiting on a person
		elif hb == mm:
			holder = "human"            # a human player is holding it
		elif hb is Robot:
			holder = "robot:%d" % int(robot_index.call(hb))
		elements.append({
			"id": id,
			"kind": e.kind,
			"alliance": e.alliance,
			"held": holder,
			"launcher": int(robot_index.call(e.last_launcher)),
			"basis": pack_basis(e.global_transform.basis),
			"origin": pack_v3(e.global_transform.origin),
			"lin": pack_v3(e.linear_velocity),
			"ang": pack_v3(e.angular_velocity),
		})

	var element_id := func(e: Variant) -> String:
		return String(ids.get(e, ""))

	# ---- robots and their brains
	var out_robots: Array = []
	for i in robots.size():
		var r: Robot = robots[i]
		if not is_instance_valid(r):
			continue
		var d := r.save_state(element_id)
		d["index"] = i
		for brain in main.ais:
			if is_instance_valid(brain) and brain.robot == r:
				d["brain"] = brain.save_state(element_id)
		out_robots.append(d)

	# ---- hives
	var hives: Array = []
	for a in main.field.hives:
		hives.append((main.field.hives[a] as Hive).save_state())

	var opts: Dictionary = main.opts.duplicate()
	var menu = main.menu

	return {
		"format": FORMAT,
		"version": VERSION,
		"saved": Time.get_datetime_string_from_system(true),
		"setup": {
			"mode": mm.mode,
			"alliance": int(main.robot.alliance) if main.robot else BB.Alliance.RED,
			"intakes": int(main.robot.intakes) if main.robot else 1,
			"robots": int(opts.get("robots", 1)),
			"mate_is_ai": bool(opts.get("mate_is_ai", false)),
			"per_robot": int(opts.get("per_robot", 1)),
			"opponents": int(opts.get("opponents", 0)),
			"takes_nectar": bool(opts.get("takes_nectar", false)),
			"ai_mask": _ai_mask(robots),
			"robot_name": RobotShop.robot_name,
			"profile": RobotShop.source,
			"specs": RobotShop.specs.duplicate(),
			"auto_routine": String(main.robot_menu.active_auto) if main.robot_menu else "",
		},
		"match": mm.save_state(element_id, robot_index),
		"robots": out_robots,
		"elements": elements,
		"hives": hives,
		"auto": {
			"playing": bool(main.auto_player.playing),
			"t": float(main.auto_player._t),
			"routine": main.auto_player.routine.name if main.auto_player.routine else "",
		},
		# Not the engine's internal state — Godot does not expose that — but a
		# seed the restore re-applies, so every retry of one situation draws the
		# same "random" human placements and scatter as the last retry did.
		"rng_seed": randi() if rng_seed < 0 else rng_seed,
	}

## Which robots the game drives, in roster order. Written into every capture
## so a roster with a human opponent (online) comes back the same way.
static func _ai_mask(robots: Array) -> Array:
	var out: Array = []
	for r in robots:
		out.append(is_instance_valid(r) and (r as Robot).ai_driver)
	return out

# ------------------------------------------------------------------- reading --

## "" when the file is usable, otherwise a sentence to put in front of a person.
static func validate(d: Variant) -> String:
	if not (d is Dictionary):
		return "That file is not a saved situation."
	var dict: Dictionary = d
	if String(dict.get("format", "")) != FORMAT:
		return "That file is not a BIOBUZZ situation."
	var v := int(dict.get("version", 0))
	if v > VERSION:
		return "That situation was saved by a newer version of the game."
	if v < 1:
		return "That situation file is too old to read."
	for key in ["setup", "match", "robots", "elements", "hives"]:
		if not dict.has(key):
			return "That situation file is missing its %s." % key
	return ""

## The one-line facts the library shows, without loading the world.
static func describe(d: Dictionary) -> Dictionary:
	var m: Dictionary = d.get("match", {})
	var s: Dictionary = d.get("setup", {})
	var phase := int(m.get("phase", BB.Phase.PRE))
	var names := ["Pre-match", "Autonomous", "Transition", "Teleop",
		"Settling", "Finished"]
	var robots: Array = d.get("robots", [])
	var ours := 0
	for r in robots:
		ours += 1
	return {
		"phase": names[clampi(phase, 0, names.size() - 1)],
		"time_left": float(m.get("time_left", 0.0)),
		"robots": ours,
		"alliance": int(s.get("alliance", BB.Alliance.RED)),
		"mode": int(s.get("mode", BB.Mode.FULL_MATCH)),
		"elements": (d.get("elements", []) as Array).size(),
	}

# ------------------------------------------------------------------ restore --

## Put a situation back on the field.
##
## Runs with the match PAUSED and `BB.restoring` set, so nothing that happens
## while objects are being placed counts as a pickup, a score, a foul or a
## sound. The caller resumes when this returns.
##
## Returns a list of problems; empty means everything came back.
## `for_editing` leaves the whole field FROZEN where it was placed and hands
## nothing back: the scenario editor poses objects by hand and must not have
## gravity, contacts or an intake running underneath it.
static func restore(main: Node, d: Dictionary, for_editing := false) -> Array:
	var problems: Array = []
	var err := validate(d)
	if err != "":
		return [err]

	var mm = main.mm
	BB.set_restoring(true)
	# abort() clears `paused`, so the pause goes on AFTER it, not before — and
	# the human players' work queue is emptied here, because it holds element
	# references from the world that is about to be thrown away and
	# _pump_humans would try to place freed balls.
	mm.abort()
	mm.human_queue = {BB.Alliance.RED: [], BB.Alliance.BLUE: []}
	mm.nectar_pool = {BB.Alliance.RED: [], BB.Alliance.BLUE: []}
	mm.paused = true

	var setup: Dictionary = d.get("setup", {})

	# ---- the roster the situation was set up with. Devices are NOT restored
	# from the file: the seat allocation hands out whatever is plugged in now,
	# so a situation saved on a machine with two pads does not silently give
	# robot 2 a controller that is not there.
	main.opts = {
		"robots": int(setup.get("robots", 1)),
		"mate_is_ai": bool(setup.get("mate_is_ai", false)),
		"per_robot": int(setup.get("per_robot", 1)),
		"opponents": int(setup.get("opponents", 0)),
		"takes_nectar": bool(setup.get("takes_nectar", false)),
	}
	# who drives each robot, when the situation says so (online rooms, and
	# situations saved from online replays)
	if setup.get("ai_mask") is Array:
		main.opts["ai_mask"] = (setup["ai_mask"] as Array).duplicate()
	main._build_robots(int(setup.get("alliance", BB.Alliance.RED)),
		int(setup.get("intakes", 1)))
	await main.get_tree().physics_frame

	# ---- clear the field completely before putting anything back, so a retry
	# can never accumulate balls
	for node in main.get_tree().get_nodes_in_group("element"):
		node.held_by = null
		node.queue_free()
	main._parked.clear()
	for r in main.robots:
		if is_instance_valid(r):
			r.hopper.clear()
	await main.get_tree().physics_frame
	await main.get_tree().physics_frame

	# ---- elements
	var by_id := {}
	for spec in d.get("elements", []):
		var e := GameElement.make(int(spec.get("kind", BB.Kind.POLLEN)),
			int(spec.get("alliance", -1)))
		# `_adopt` rather than `add_child`: the world root runs while the game
		# is halted so it can still take input, and anything that simply
		# inherits from it keeps running too. Restored balls went in through
		# the back door and settled and bounds-checked themselves behind the
		# pause menu.
		main._adopt(e)
		e.exited_field.connect(mm.on_element_left_field)
		# Frozen while the field is assembled. A ball that is live during the
		# load spends the loading frames falling, rolling and settling into a
		# pose that is NOT the one it was saved in — and an airborne one lands.
		# Motion is handed back at the very end, in one pass.
		e.freeze = true
		e.global_transform = Transform3D(
			unpack_basis(spec.get("basis", [])),
			unpack_v3(spec.get("origin", [])))
		e.linear_velocity = Vector3.ZERO
		e.angular_velocity = Vector3.ZERO
		# the id the file knows this ball by, so the editor can find the live
		# node for a row in the draft without guessing at group order
		e.set_meta("sid", String(spec.get("id", "")))
		by_id[String(spec.get("id", ""))] = e

	var element_of := func(id: String) -> Variant:
		var e: Variant = by_id.get(id, null)
		return e if (e is GameElement and is_instance_valid(e)) else null
	var robot_of := func(i: int) -> Variant:
		return main.robots[i] if i >= 0 and i < main.robots.size() else null

	# ---- hives, before the robots, because a hive swing moves the cells that
	# balls were just placed inside
	var hives: Array = d.get("hives", [])
	for spec in hives:
		var a := int(spec.get("alliance", BB.Alliance.RED))
		if main.field.hives.has(a):
			(main.field.hives[a] as Hive).apply_state(spec)

	# ---- robots, then their hoppers
	for spec in d.get("robots", []):
		var i := int(spec.get("index", -1))
		var r: Variant = robot_of.call(i)
		if not (r is Robot):
			problems.append("robot %d in the file has nowhere to go" % i)
			continue
		var rob: Robot = r
		rob.apply_state(spec)
		for eid in spec.get("hopper", []):
			var held: Variant = element_of.call(String(eid))
			if held is GameElement:
				rob.adopt(held)
			else:
				problems.append("a ball in %s's hopper was missing" % rob.driver_label)
		if spec.has("brain"):
			for brain in main.ais:
				if is_instance_valid(brain) and brain.robot == rob:
					brain.apply_state(spec["brain"], element_of)

	# ---- held and out-of-play elements, now that the robots exist
	for spec in d.get("elements", []):
		var e: Variant = element_of.call(String(spec.get("id", "")))
		if not (e is GameElement):
			continue
		var el: GameElement = e
		var holder := String(spec.get("held", ""))
		if holder == "out":
			el.set_held(el)
			el.global_position = BB.fp(0.0, 0.0, -60.0)
		elif holder == "human":
			el.set_held(mm)
			el.global_position = BB.fp(0.0, 0.0, -60.0)
		var li := int(spec.get("launcher", -1))
		var launcher: Variant = robot_of.call(li)
		el.last_launcher = launcher if launcher is Robot else null

	# ---- the match: clock, scoreboard, fouls, the human players' queue
	mm.apply_state(d.get("match", {}), element_of, robot_of)
	mm.robot = main.robot
	mm.robots = main.robots

	# ---- the autonomous routine, if one was mid-playback
	main.auto_player.stop_play()
	var auto: Dictionary = d.get("auto", {})
	if bool(auto.get("playing", false)):
		var rt := AutoRoutine.load_named(String(auto.get("routine", "")))
		if rt != null:
			main.auto_player.begin_play(main.robot, rt)
			main.auto_player._t = float(auto.get("t", 0.0))
		else:
			problems.append("the autonomous routine '%s' is not saved any more"
				% String(auto.get("routine", "")))

	# ---- stats start fresh for the attempt: this is a practice rep, not a
	# continuation of whatever match the situation was cut from
	if main.stats:
		main.stats.per.clear()
		for r2 in main.robots:
			if is_instance_valid(r2):
				main.stats.track(r2)

	seed(int(d.get("rng_seed", 0)))

	# Let the physics server see the new poses, with everything still frozen,
	# before anything is allowed to react to them.
	await main.get_tree().physics_frame
	await main.get_tree().physics_frame

	if for_editing:
		# The editor takes over with everything still frozen. Velocities stay
		# in the DRAFT untouched — an airborne ball keeps the motion it was
		# saved with unless the author moves it.
		BB.set_restoring(false)
		BB.editing = true
		return problems

	# ---- HAND THE MOTION BACK. One pass, on one frame, so the field starts
	# moving from the instant it was saved rather than from wherever two frames
	# of gravity had carried it.
	for spec in d.get("elements", []):
		var e2: Variant = element_of.call(String(spec.get("id", "")))
		if not (e2 is GameElement):
			continue
		var el2: GameElement = e2
		if el2.held_by != null:
			continue                       # in a hopper or with a person
		el2.freeze = false
		el2.sleeping = false
		el2.linear_velocity = unpack_v3(spec.get("lin", []))
		el2.angular_velocity = unpack_v3(spec.get("ang", []))
	for spec in hives:
		var a2 := int(spec.get("alliance", BB.Alliance.RED))
		if main.field.hives.has(a2):
			(main.field.hives[a2] as Hive).release_from_restore(spec)
	for spec in d.get("robots", []):
		var r2: Variant = robot_of.call(int(spec.get("index", -1)))
		if r2 is Robot:
			(r2 as Robot).release_from_restore(
				unpack_v3(spec.get("lin", [])), unpack_v3(spec.get("ang", [])))

	BB.set_restoring(false)
	for r3 in main.robots:
		if is_instance_valid(r3):
			r3.clear_inputs()
	DriverInput.forget()
	return problems


# ============================================================== validation ===
#
# Two kinds of problem, and the difference matters:
#
#   error    the situation would not RESTORE — a duplicate id, a hopper that
#            points at a ball that is not there, a roster the game cannot
#            build, a number that is not a number. These block saving.
#   warning  an unusual but deliberate practice setup — a robot parked inside
#            the opposing alliance area, five balls on top of each other, a
#            phase that does not match the mode. Practice is allowed to be
#            strange; these never block anything.
#
# Every problem carries the `id` of the object it belongs to, so the editor can
# show it beside that object rather than in a list at the bottom of the screen.

static func check_draft(d: Dictionary) -> Array:
	var out: Array = []
	var base := validate(d)
	if base != "":
		return [{"severity": "error", "where": "file", "id": "", "msg": base}]

	var elements: Array = d.get("elements", [])
	var robots: Array = d.get("robots", [])
	var setup: Dictionary = d.get("setup", {})
	var m: Dictionary = d.get("match", {})

	# ---- ids
	var seen := {}
	for e in elements:
		var id := String(e.get("id", ""))
		if id == "":
			out.append({"severity": "error", "where": "element", "id": "",
				"msg": "An element has no id."})
			continue
		if seen.has(id):
			out.append({"severity": "error", "where": "element", "id": id,
				"msg": "Two elements share the id %s." % id})
		seen[id] = e

	# ---- numbers
	for e in elements:
		var p := unpack_v3(e.get("origin", []))
		if not (is_finite(p.x) and is_finite(p.y) and is_finite(p.z)):
			out.append({"severity": "error", "where": "element",
				"id": String(e.get("id", "")), "msg": "Its position is not a number."})
		elif absf(p.x / BB.IN) > BB.FIELD_HALF + 6.0 \
				or absf(p.z / BB.IN) > BB.FIELD_HALF + 6.0:
			if String(e.get("held", "")) == "":
				out.append({"severity": "warning", "where": "element",
					"id": String(e.get("id", "")),
					"msg": "This ball is outside the field walls."})
		if p.y < -BB.m(1.0) and String(e.get("held", "")) == "":
			out.append({"severity": "warning", "where": "element",
				"id": String(e.get("id", "")),
				"msg": "This ball is below the tiles and will fall out of play."})

	# ---- ownership: a ball is either loose or in exactly one hopper
	var owned := {}
	for r in robots:
		var idx := int(r.get("index", -1))
		var hop: Array = r.get("hopper", [])
		if hop.size() > BB.HOPPER_MAX:
			out.append({"severity": "error", "where": "robot",
				"id": "robot:%d" % idx,
				"msg": "A hopper holds at most %d; this one has %d." % [
					BB.HOPPER_MAX, hop.size()]})
		for eid in hop:
			var sid := String(eid)
			if not seen.has(sid):
				out.append({"severity": "error", "where": "robot",
					"id": "robot:%d" % idx,
					"msg": "Its hopper holds %s, which is not on the field." % sid})
				continue
			if owned.has(sid):
				out.append({"severity": "error", "where": "robot",
					"id": "robot:%d" % idx,
					"msg": "%s is in two hoppers at once." % sid})
			owned[sid] = idx
			var e2: Dictionary = seen[sid]
			if String(e2.get("held", "")) != "robot:%d" % idx:
				out.append({"severity": "error", "where": "element", "id": sid,
					"msg": "This ball is in a hopper but does not say so."})
			if int(e2.get("kind", 0)) == BB.Kind.NECTAR \
					and not bool(r.get("takes_nectar", false)):
				out.append({"severity": "error", "where": "robot",
					"id": "robot:%d" % idx,
					"msg": "NECTAR is in the hopper but this intake only takes POLLEN."})
	for e in elements:
		var held := String(e.get("held", ""))
		if held.begins_with("robot:") and not owned.has(String(e.get("id", ""))):
			out.append({"severity": "error", "where": "element",
				"id": String(e.get("id", "")),
				"msg": "This ball says it is carried, but no hopper holds it."})

	# ---- roster
	var ours := 0
	var foes := 0
	var drivers := 0
	var our_alliance := int(setup.get("alliance", BB.Alliance.RED))
	for r in robots:
		if int(r.get("alliance", 0)) == our_alliance:
			ours += 1
			if not bool(r.get("ai", false)):
				drivers += 1
		else:
			foes += 1
	if drivers < 1:
		out.append({"severity": "error", "where": "roster", "id": "",
			"msg": "There is no robot for you to drive. Add a player robot."})
	if ours > ScenarioDraft.MAX_OURS:
		out.append({"severity": "error", "where": "roster", "id": "",
			"msg": "Your alliance can field at most %d robots." % ScenarioDraft.MAX_OURS})
	if foes > ScenarioDraft.MAX_FOES:
		out.append({"severity": "error", "where": "roster", "id": "",
			"msg": "There can be at most %d opponent robots." % ScenarioDraft.MAX_FOES})
	for r in robots:
		var bv := float(r.get("battery_v", BB.BATTERY_NOMINAL))
		if bv < 9.0 or bv > 14.0:
			out.append({"severity": "error", "where": "robot",
				"id": "robot:%d" % int(r.get("index", -1)),
				"msg": "A battery reads %.1f V, which the robot cannot run on." % bv})
		if int(r.get("intakes", 1)) not in [1, 2]:
			out.append({"severity": "error", "where": "robot",
				"id": "robot:%d" % int(r.get("index", -1)),
				"msg": "A robot has an intake count the game cannot build."})

	# ---- clock and phase
	var phase := int(m.get("phase", BB.Phase.PRE))
	var t := float(m.get("time_left", 0.0))
	if not is_finite(t) or t < 0.0:
		out.append({"severity": "error", "where": "match", "id": "",
			"msg": "The remaining time is not a valid number."})
	elif phase == BB.Phase.AUTO and t > BB.AUTO_S:
		out.append({"severity": "error", "where": "match", "id": "",
			"msg": "Autonomous is only %d seconds long." % int(BB.AUTO_S)})
	elif phase == BB.Phase.TELEOP and t > BB.TELEOP_S:
		out.append({"severity": "error", "where": "match", "id": "",
			"msg": "Teleop is only %d seconds long." % int(BB.TELEOP_S)})
	if phase == BB.Phase.AUTO and int(setup.get("mode", 0)) == BB.Mode.TELEOP_ONLY:
		out.append({"severity": "warning", "where": "match", "id": "",
			"msg": "This starts in autonomous but the mode skips autonomous."})

	# ---- the objective, if there is one
	for p2 in Objective.check(d.get("objective", {}), robots, our_alliance):
		out.append(p2)

	# ---- practice opponents. A malformed brain block is read through the
	# compatibility path rather than crashing; its problems are reported.
	for r3 in robots:
		if not bool(r3.get("ai", false)):
			continue
		var br: Variant = r3.get("brain")
		if OpponentConfig.is_legacy(br):
			continue
		var cfg := OpponentConfig.from_brain(br)
		for p3 in OpponentConfig.check(cfg, int(r3.get("index", -1)), robots):
			p3["id"] = "robot:%d" % int(r3.get("index", -1))
			out.append(p3)

	# ---- balls saved in mid-air, which two goals treat differently
	var flying := Objective.count_in_flight(d)
	if flying > 0:
		var okind := int(d.get("objective", {}).get("kind", Objective.Kind.NONE))
		if okind == Objective.Kind.POINTS:
			out.append({"severity": "warning", "where": "objective", "id": "",
				"msg": "%d ball%s already in the air here. %s" % [flying,
					"" if flying == 1 else "s are", Objective.FLIGHT_RULE_POINTS]})
		elif okind == Objective.Kind.SHOTS:
			out.append({"severity": "warning", "where": "objective", "id": "",
				"msg": "%d ball%s already in the air here. %s" % [flying,
					"" if flying == 1 else "s are", Objective.FLIGHT_RULE_SHOTS]})

	# ---- the human players' queue
	for key in ["human_queue"]:
		var q: Dictionary = m.get(key, {})
		for a in q.keys():
			for entry in q[a]:
				if not seen.has(String(entry[0])):
					out.append({"severity": "error", "where": "match", "id": "",
						"msg": "A pending human feed refers to a ball that is gone."})
				elif float(entry[1]) < 0.0:
					out.append({"severity": "error", "where": "match", "id": "",
						"msg": "A pending human feed has a negative delay."})
	return out
