class_name MatchManager
extends Node
##
## The match clock and everything that hangs off it (S10.4, Table 9-1):
##   AUTO 0:30 -> TRANSITION 0:08 (no powered movement, G403) -> TELEOP 2:00,
##   FLOWER ownership unlocked with 1:00 left (G410), "train whistle" at 0:20,
##   then SETTLE 2.8 s before the score is harvested, because S10.5 A-G scores
##   the field AT REST and not the field at 0:00.
##

signal phase_changed(phase: int)
signal foul(text: String, alliance: int, points: int)
signal finished(result: Dictionary)
## AUTO is over — whatever was replaying a saved routine should stop.
signal auto_ended
## A match (or free practice) was put on the clock by `start()`.
signal started
## A match that was in progress was thrown away by `abort()` — ended from a
## menu, reset, retried or replaced. Not emitted when nothing was running.
signal aborted

var phase: int = BB.Phase.PRE
var mode: int = BB.Mode.FULL_MATCH
var time_left := 0.0
var scoring := Scoring.new()
var field: Field
## Every ROBOT on the FIELD, ours and the opponent's. `robot` stays as the
## first player robot so everything that only cares about "the driver's robot"
## (the HUD, the camera, the leaderboard) keeps working unchanged.
var robot: Robot
var robots: Array[Robot] = []
var human_nectar_owed := {BB.Alliance.RED: 0, BB.Alliance.BLUE: 0}
var nectar_pool := {BB.Alliance.RED: [], BB.Alliance.BLUE: []}
## What each alliance's human player is holding and has not fed in yet, as
## [element, seconds until they get to it]. See _pump_humans().
var human_queue := {BB.Alliance.RED: [], BB.Alliance.BLUE: []}
var _human_gap := {BB.Alliance.RED: 0.0, BB.Alliance.BLUE: 0.0}
var last_result := {}
var events: Array[String] = []

## G407 state, kept PER ROBOT. `over` is how long that robot has been holding
## more than the legal four; `instances` counts separate occasions, because the
## manual escalates on repetition. Two drivers each carry their own history —
## one of them dragging a fifth ball must not clear the other one's timer.
var _control: Dictionary = {}
## Mirrors of robot 1's state, which is what the HUD reads.
var control_over := 0.0
var control_instances := 0
var control_flagged := false
var control_warning := ""

var _endgame_called := false
var _unlock_called := false
var _settle := 0.0

func teleop_remaining() -> float:
	return time_left if phase == BB.Phase.TELEOP else (BB.TELEOP_S if phase < BB.Phase.TELEOP else 0.0)

func flowers_unlocked() -> bool:
	if free_practice():
		return true
	return phase == BB.Phase.TELEOP and time_left <= BB.FLOWER_NECTAR_UNLOCK

func start() -> void:
	paused = false
	_endgame_called = false
	_unlock_called = false
	events.clear()
	control_over = 0.0
	control_instances = 0
	control_flagged = false
	control_warning = ""
	_control.clear()
	match mode:
		BB.Mode.TELEOP_ONLY:
			# straight into TELEOP: driver practice without 30 s of dead air
			phase = BB.Phase.TELEOP
			time_left = BB.TELEOP_S
			_enable(true)
			log_event("TELEOP ONLY - practice")
			SFX.play("start", -8.0)
		BB.Mode.FREE_PRACTICE:
			# no clock at all; nothing locks, nothing ends
			phase = BB.Phase.TELEOP
			time_left = BB.TELEOP_S
			_enable(true)
			_unlock_called = true
			log_event("FREE PRACTICE - no clock")
		_:
			phase = BB.Phase.AUTO
			time_left = BB.AUTO_S
			_enable(false)             # G401: no driver input in AUTO
			log_event("AUTO")
			SFX.play("start", -8.0)
	phase_changed.emit(phase)
	started.emit()

## Cut AUTO (and the transition) short and hand the robot to the driver.
func skip_auto() -> void:
	if phase != BB.Phase.AUTO and phase != BB.Phase.TRANSITION:
		return
	log_event("AUTO SKIPPED")
	if phase == BB.Phase.AUTO:
		_end_auto()
	time_left = 0.0

func free_practice() -> bool:
	return mode == BB.Mode.FREE_PRACTICE

## PAUSE. Opening a menu mid-match freezes the clock and switches the robots
## off rather than throwing the match away — come back and it picks up on the
## same second, with the same score.
var paused := false

func pause() -> void:
	if paused or phase == BB.Phase.PRE or phase == BB.Phase.DONE:
		return
	paused = true
	_enable(false)
	# STOP THE WHOLE WORLD, not just the input. Switching the robots off left
	# every ball, every hive and every statistic running behind the menu.
	BB.set_menu_halt(true)

func resume() -> void:
	if not paused:
		return
	paused = false
	BB.set_menu_halt(false)
	# AUTO and TELEOP drive; TRANSITION and SETTLE are meant to be dead time
	_enable(phase == BB.Phase.AUTO or phase == BB.Phase.TELEOP)

## True while a match is on the clock, paused or not.
func in_progress() -> bool:
	return phase != BB.Phase.PRE and phase != BB.Phase.DONE

func abort() -> void:
	var was_running := in_progress()
	paused = false
	BB.set_menu_halt(false)
	phase = BB.Phase.PRE
	_enable(false)
	if was_running:
		aborted.emit()
	phase_changed.emit(phase)

## Every robot that is on the field, with robot 1 first. Falls back to the
## single `robot` reference so older callers and the test harnesses still work.
## Drop every reference to the current robots, before they are freed.
##
## It does NOT clear `robots`: that array is the SAME OBJECT as the world's
## roster (arrays are references in GDScript), so emptying it here empties the
## list the caller is about to iterate to free the old robots — and they never
## get freed. They stay on the field, still driving, still intaking, invisibly
## fighting the new ones for the same ball.
func forget_robots() -> void:
	_control.clear()
	robot = null
	control_over = 0.0
	control_instances = 0
	control_flagged = false
	control_warning = ""

func all_robots() -> Array[Robot]:
	if robots.is_empty():
		var one: Array[Robot] = []
		if robot:
			one.append(robot)
		return one
	return robots

func _enable(on: bool) -> void:
	for r in all_robots():
		if is_instance_valid(r):
			r.enabled = on

func log_event(t: String) -> void:
	events.append("%s  %s" % [BB.clock_text(time_left), t])
	if events.size() > 9:
		events.pop_front()

func _process(delta: float) -> void:
	if paused:
		return
	# The human players work whether or not the clock is running: an element
	# that went over the wall during a pause still has to be walked back.
	_pump_humans(delta)
	# G407 is a per-ROBOT rule, so each robot carries its own timer and its own
	# instance count. Only robot 1's state is mirrored out for the HUD.
	for r in all_robots():
		if not is_instance_valid(r):
			continue
		check_control(r.controlled_count(), delta, r.alliance, r)
	match phase:
		BB.Phase.AUTO:
			time_left -= delta
			if time_left <= 0.0:
				_end_auto()
		BB.Phase.TRANSITION:
			time_left -= delta
			if time_left <= 0.0:
				phase = BB.Phase.TELEOP
				time_left = BB.TELEOP_S
				_enable(true)
				log_event("TELEOP")
				SFX.play("start", -9.0)
				phase_changed.emit(phase)
		BB.Phase.TELEOP:
			if free_practice():
				return                 # no clock, no endgame, no buzzer
			time_left -= delta
			if not _unlock_called and time_left <= BB.FLOWER_NECTAR_UNLOCK:
				_unlock_called = true
				log_event("FLOWERS UNLOCKED - all remaining NECTAR released (G426)")
				_release_all_nectar()
			if not _endgame_called and time_left <= BB.ENDGAME_S:
				_endgame_called = true
				log_event("TRAIN WHISTLE - endgame")
			if time_left <= 0.0:
				phase = BB.Phase.SETTLE
				time_left = 0.0
				_enable(false)
				_settle = BB.SETTLE_S
				log_event("BUZZER - settling")
				SFX.play("buzzer", -5.0)
				phase_changed.emit(phase)
		BB.Phase.SETTLE:
			_settle -= delta
			if _settle <= 0.0:
				_finish()

func _end_auto() -> void:
	# S10.5: LEAVE and AUTO PARK are per ROBOT, but the points land on the
	# ALLIANCE, so two robots that both leave are worth two LEAVEs.
	for r in all_robots():
		if not is_instance_valid(r):
			continue
		if r.has_left:
			scoring.leave[r.alliance] = int(scoring.leave.get(r.alliance, 0)) + 1
			log_event("LEAVE (%s)" % r.driver_label)
		if r.in_loading_zone():
			scoring.park_auto[r.alliance] = int(scoring.park_auto.get(r.alliance, 0)) + 1
			log_event("AUTO PARK (%s)" % r.driver_label)
	phase = BB.Phase.TRANSITION
	time_left = BB.TRANSITION_S
	_enable(false)
	auto_ended.emit()
	log_event("TRANSITION - no powered movement (G403)")
	phase_changed.emit(phase)

func _finish() -> void:
	for r in all_robots():
		if is_instance_valid(r) and r.in_loading_zone():
			scoring.park_teleop[r.alliance] = int(scoring.park_teleop.get(r.alliance, 0)) + 1
	var b := scoring.breakdown(field, true)
	last_result = {
		"breakdown": b,
		"rp": {
			BB.Alliance.RED: scoring.ranking_points(BB.Alliance.RED, b),
			BB.Alliance.BLUE: scoring.ranking_points(BB.Alliance.BLUE, b),
		},
	}
	phase = BB.Phase.DONE
	phase_changed.emit(phase)
	finished.emit(last_result)

# --------------------------------------------------------------- hive tips --

func on_tip(alliance: int, _h: Hive) -> void:
	if phase == BB.Phase.PRE or phase == BB.Phase.DONE:
		return
	scoring.tips[alliance] += 1
	log_event("HIVE TIP (%s) x%d" % [BB.alliance_name(alliance), scoring.tips[alliance]])
	# G426: humans may enter one NECTAR per own-HIVE TIP
	_release_nectar(alliance, 1)

## G426 entitles the human player to enter NECTAR; it does not teleport it in.
## The element goes into that alliance's human queue with a reaction time on
## it, and _pump_humans() places it a beat later.
func _release_nectar(a: int, n: int) -> void:
	var pool: Array = nectar_pool[a]
	for i in mini(n, pool.size()):
		_hand_to_human(a, pool.pop_front(),
			randf_range(BB.HUMAN_REACT_MIN, BB.HUMAN_REACT_MAX))

func _release_all_nectar() -> void:
	for a in [BB.Alliance.RED, BB.Alliance.BLUE]:
		_release_nectar(a, nectar_pool[a].size())

func _hand_to_human(a: int, e: GameElement, wait: float) -> void:
	if e == null or not is_instance_valid(e):
		return
	if e.held_by == null:
		e.set_held(self)
		e.global_position = BB.fp(0.0, 0.0, -60.0)
	(human_queue[a] as Array).append([e, wait])

## One element at a time, at human speed (G427). Each alliance's player works
## independently, so red being busy never holds blue up.
func _pump_humans(delta: float) -> void:
	for a in [BB.Alliance.RED, BB.Alliance.BLUE]:
		var q: Array = human_queue[a]
		_human_gap[a] = maxf(0.0, float(_human_gap[a]) - delta)
		if q.is_empty():
			continue
		var head: Array = q[0]
		head[1] = float(head[1]) - delta
		if float(head[1]) > 0.0 or float(_human_gap[a]) > 0.0:
			continue
		q.pop_front()
		_human_gap[a] = BB.HUMAN_PLACE_GAP
		var e: GameElement = head[0]
		if e == null or not is_instance_valid(e):
			continue
		# Placed, not dropped: set down inside the LOADING ZONE, touching the
		# tiles, motionless — which is what a person handing a ball through the
		# gap actually produces.
		var rect := BB.loading_zone(a)
		var x := randf_range(rect[0] + 3.0, rect[2] - 3.0)
		var y := randf_range(rect[1] + 3.0, rect[3] - 3.0)
		e.release(Transform3D(Basis.IDENTITY,
			BB.fp(x, y, e.radius_in + 0.15)), Vector3.ZERO)
		e.linear_velocity = Vector3.ZERO
		e.angular_velocity = Vector3.ZERO

## How many elements the human players are still holding — the HUD shows it so
## a driver waiting on a ball knows one is coming.
func human_pending(a: int) -> int:
	return (human_queue[a] as Array).size()

# ------------------------------------------------------------------ fouls ---

## An element left the FIELD and a human put it back.
##
## G405 makes DELIBERATELY ejecting an element a MAJOR FOUL, but explicitly
## exempts elements that leave "during scoring attempts or as the result of
## ROBOT-to-ROBOT interactions". A sim cannot tell a deliberate ejection from a
## missed shot, so rather than hand out 20 points for an overcooked launch it
## charges the lesser MINOR — enough to discourage firing balls out of the
## arena, not enough to decide a match on a bad shot.
func on_element_left_field(side: int, e: GameElement = null) -> void:
	# The walk back around the guardrail happens whatever the phase.
	_hand_to_human(side, e, randf_range(BB.HUMAN_RETURN_MIN, BB.HUMAN_RETURN_MAX))
	if phase != BB.Phase.AUTO and phase != BB.Phase.TELEOP:
		return
	var by: int = robot.alliance if robot else side
	scoring.fouls_against[by] += BB.FOUL_MINOR
	log_event("MINOR FOUL - element left the FIELD (G405), returned by %s" % BB.alliance_name(side))
	foul.emit("G405 - element left the FIELD", by, BB.FOUL_MINOR)

## G407 - "No more than 4 at a time. A ROBOT may not simultaneously CONTROL more
## than 4 SCORING ELEMENTS."  Violation: VERBAL WARNING; MAJOR FOUL and YELLOW
## CARD per MATCH if STRATEGIC.
##
## The manual's own guidance decides when it is STRATEGIC (S11.4.3): holding 5
## or more is "under scrutiny"; picking up and CONTROLLING 6 or more, or
## repeatedly holding 5 for longer than MOMENTARY, is the strategic case, while
## momentarily touching 5 and immediately giving one back is not. So: over four
## for longer than ~3 s is an instance, the first instance is a warning, and any
## repeat — or ever holding six — is a MAJOR FOUL.
func check_control(n: int, delta: float, by: int, who: Robot = null) -> void:
	if who == null:
		who = robot
	var st: Dictionary = _control.get(who, {"over": 0.0, "instances": 0, "flagged": false, "warning": ""})
	_control[who] = st

	if phase != BB.Phase.AUTO and phase != BB.Phase.TELEOP:
		_mirror(who, st)
		return
	if n <= BB.HOPPER_CAP:
		st["over"] = 0.0
		st["flagged"] = false
		st["warning"] = ""
		_mirror(who, st)
		return

	st["over"] = float(st["over"]) + delta
	if n >= BB.HOPPER_CAP + 2:
		st["warning"] = "G407 - CONTROLLING %d, that is a MAJOR FOUL" % n
	else:
		var left := maxf(0.0, BB.CONTROL_GRACE - float(st["over"]))
		var dragged := who.herded_count() if who else 0
		st["warning"] = "G407 - CONTROLLING %d (%d dragged), let one go (%.1fs)" % [
			n, dragged, left]
	_mirror(who, st)
	if bool(st["flagged"]):
		return

	# six or more is STRATEGIC on its own; five is only a violation once it has
	# lasted longer than MOMENTARY
	var strategic := n >= BB.HOPPER_CAP + 2
	if not strategic and float(st["over"]) < BB.CONTROL_GRACE:
		return

	st["flagged"] = true
	st["instances"] = int(st["instances"]) + 1
	_mirror(who, st)
	var tag := "" if who == null else " [%s]" % who.driver_label
	if strategic or int(st["instances"]) > 1:
		scoring.fouls_against[by] += BB.FOUL_MAJOR
		log_event("G407 MAJOR FOUL - CONTROL of %d elements%s" % [n, tag])
		SFX.play("foul", -8.0)
		foul.emit("G407 - CONTROL of more than 4", by, BB.FOUL_MAJOR)
	else:
		log_event("G407 VERBAL WARNING - CONTROL of %d elements%s" % [n, tag])
		foul.emit("G407 - verbal warning", by, 0)

## The HUD shows one robot's G407 state — the one the camera is following. Only
## that robot's numbers are copied out to the flat fields.
func _mirror(who: Robot, st: Dictionary) -> void:
	if who != robot:
		return
	control_over = float(st["over"])
	control_instances = int(st["instances"])
	control_flagged = bool(st["flagged"])
	control_warning = String(st["warning"])


## G410: no NECTAR into a FLOWER before 1:00 left. MAJOR per NECTAR; the
## achievement still scores.
func check_flower_entry(e: GameElement, by: int) -> void:
	if e.kind != BB.Kind.NECTAR:
		return
	if flowers_unlocked() or phase == BB.Phase.DONE:
		return
	scoring.fouls_against[by] += BB.FOUL_MAJOR
	log_event("G410 MAJOR FOUL - NECTAR into a FLOWER before 1:00")
	foul.emit("G410 - NECTAR in FLOWER before 1:00", by, BB.FOUL_MAJOR)

# ============================================================== snapshots ====

## THE MATCH AS DATA.
##
## Phase, clock, scoreboard, fouls and the human players' work queue. Every
## delay in here is stored as TIME REMAINING — the settle timer, each feed's
## wait, the gap between placements — so a situation saved with "1.4 s until
## the human puts the next ball down" comes back with 1.4 s to go rather than
## with a timestamp from a session that ended yesterday.
func save_state(element_id: Callable, robot_index: Callable) -> Dictionary:
	var queue := {}
	var pool := {}
	for a in [BB.Alliance.RED, BB.Alliance.BLUE]:
		var q: Array = []
		for entry in (human_queue[a] as Array):
			var e: GameElement = entry[0]
			if e != null and is_instance_valid(e):
				q.append([element_id.call(e), float(entry[1])])
		queue[str(a)] = q
		var p: Array = []
		for e2 in (nectar_pool[a] as Array):
			if e2 != null and is_instance_valid(e2):
				p.append(element_id.call(e2))
		pool[str(a)] = p

	var control: Array = []
	for who in _control:
		var idx: int = robot_index.call(who)
		if idx < 0:
			continue
		var st: Dictionary = _control[who]
		control.append({
			"robot": idx, "over": float(st.get("over", 0.0)),
			"instances": int(st.get("instances", 0)),
			"flagged": bool(st.get("flagged", false)),
			"warning": String(st.get("warning", "")),
		})

	return {
		"phase": phase, "mode": mode, "time_left": time_left,
		"settle_left": _settle,
		"endgame_called": _endgame_called,
		"unlock_called": _unlock_called,
		"events": events.duplicate(),
		"scoring": scoring.save_state(),
		"owed": Scoring._pair(human_nectar_owed),
		"human_queue": queue,
		"human_pool": pool,
		"human_gap": [float(_human_gap[BB.Alliance.RED]),
			float(_human_gap[BB.Alliance.BLUE])],
		"control": control,
	}

func apply_state(d: Dictionary, element_of: Callable, robot_of: Callable) -> void:
	phase = int(d.get("phase", BB.Phase.PRE))
	mode = int(d.get("mode", BB.Mode.FULL_MATCH))
	time_left = float(d.get("time_left", 0.0))
	_settle = float(d.get("settle_left", 0.0))
	_endgame_called = bool(d.get("endgame_called", false))
	_unlock_called = bool(d.get("unlock_called", false))
	events.clear()
	for line in d.get("events", []):
		events.append(String(line))
	scoring = Scoring.new()
	scoring.apply_state(d.get("scoring", {}))
	human_nectar_owed = Scoring._unpair(d.get("owed", [0, 0]))
	last_result = {}

	human_queue = {BB.Alliance.RED: [], BB.Alliance.BLUE: []}
	nectar_pool = {BB.Alliance.RED: [], BB.Alliance.BLUE: []}
	var q_in: Dictionary = d.get("human_queue", {})
	var p_in: Dictionary = d.get("human_pool", {})
	for a in [BB.Alliance.RED, BB.Alliance.BLUE]:
		for entry in q_in.get(str(a), []):
			var e: Variant = element_of.call(String(entry[0]))
			if e is GameElement:
				(human_queue[a] as Array).append([e, float(entry[1])])
		for eid in p_in.get(str(a), []):
			var e2: Variant = element_of.call(String(eid))
			if e2 is GameElement:
				(nectar_pool[a] as Array).append(e2)
	var gap: Array = d.get("human_gap", [0.0, 0.0])
	_human_gap = {BB.Alliance.RED: float(gap[0]), BB.Alliance.BLUE: float(gap[1])}

	_control.clear()
	control_over = 0.0
	control_instances = 0
	control_flagged = false
	control_warning = ""
	for st in d.get("control", []):
		var who: Variant = robot_of.call(int(st.get("robot", -1)))
		if who is Robot:
			_control[who] = {
				"over": float(st.get("over", 0.0)),
				"instances": int(st.get("instances", 0)),
				"flagged": bool(st.get("flagged", false)),
				"warning": String(st.get("warning", "")),
			}
			_mirror(who, _control[who])
	paused = true
