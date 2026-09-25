class_name AIDriver
extends Node
##
## A PRACTICE OPPONENT. One brain, four behaviors, all driving the ordinary
## robot through `Robot.set_drive()` — the same door a human's stick goes
## through, downstream of none of the human controller tuning.
##
##   COLLECT     the opponent this game has always had: nearest loose POLLEN,
##               collect four, drive to a spot the CELL is open from, fire.
##   STATIONARY  hold the starting pose with ordinary drivetrain control.
##   ROUTE       drive user-placed waypoints in order, with waits.
##   DEFEND      stay in a circle and get in the way of one chosen robot.
##
## WHAT IS NEVER DONE TO MAKE AN OPPONENT HARDER: no change to grip, motor
## power, top speed, battery, launcher accuracy, capacity, cooldowns or what
## it can see. `pace` caps the COMMAND it sends, as a share of a full stick;
## `reaction` delays when it acts on a change. See OpponentConfig.
##
## EVERY TIMER HERE IS SIMULATION TIME. The brain is PAUSABLE (main adopts it)
## and only ever counts `delta` from _physics_process, so a pause menu freezes
## waits, reaction delays and recovery manoeuvres exactly where they were.
## Every timer is stored as time REMAINING, never as a deadline, so a saved
## situation resumes a half-finished wait with the half that was left.
##
## `status` is set by whatever branch actually ran this tick. It is a fact
## about the state machine, never an explanation or a piece of advice.
##

enum Mode { SEEK, COLLECT, SHOOT, UNSTICK }

var robot: Robot
var field: Field
var rival: Robot
## The world root, for looking up a defended robot by roster index.
var roster_owner: Node

## Which behavior, and its settings. See OpponentConfig.
var config: Dictionary = OpponentConfig.blank()
## What it is doing right now, in plain words. Read by the status overlay.
var status := ""

# ---- COLLECT (the original opponent; field names kept for old saves)
var mode: int = Mode.SEEK
var _target: GameElement
var _stuck := 0.0
## Closest the bot has got to its current goal. Progress resets the timer.
var _best_dist := 1e9
var _unstick_side := 1.0
var _unstick := 0.0
var _think := 0.0

# ---- ROUTE
var _wp := 0                 # waypoint currently being driven to
var _dir := 1                # +1 forwards along the route, -1 back
var _wait_left := 0.0        # remaining wait at the waypoint just reached
var _done := false           # Stop-at-end has stopped
var _attempts := 0           # recovery manoeuvres tried on this leg
var _blocked_wait := 0.0     # remaining pause after recoveries ran out

# ---- STATIONARY
var _home := Vector2.INF     # field inches; INF until the first live tick
var _home_yaw := 0.0
var _react_left := 0.0       # remaining reaction delay before correcting

# ---- DEFEND
var _seen := Vector2.INF     # where the defended robot was last OBSERVED
var _seen_left := 0.0        # remaining time before it looks again

## Where the original opponent's drive commands came from, kept as the
## defaults so Collect at the Standard preset is the same robot it always was.
const CRUISE := 0.55
const APPROACH := 0.34            # once it is close
const CLOSE_IN := 14.0            # in, where it slows down
## Where it parks to shoot from, measured out along the CELL mouth's normal.
const SHOOT_STANDOFF := 46.0
const SHOOT_TOLERANCE := 9.0      # in, close enough to start firing

## BLOCKED. No progress towards the goal for this long means something is in
## the way. Then a short back-and-slide, at most this many times, then a wait.
const BLOCK_S := 1.4
const RECOVER_S := 1.1
const MAX_RECOVERIES := 2
const BLOCKED_WAIT_S := 2.0

## Stationary: how far it may be displaced, and how far turned, before it
## counts as moved and starts (after its reaction delay) to drive back.
const HOLD_TOL := 3.0             # in
const HOLD_YAW_TOL := 6.0         # deg

## OBSTACLE WHISKERS.
##
## The HIVE stands on four legs at |x| = 24.5, |y| = 19.4, and a bot that
## drives at a ball behind one of them will wedge itself on it for the rest of
## the match. Rays rather than a list of known obstacles, because then it also
## avoids the flowers, the wall, and whatever else a situation puts in the way.
const WHISKER_LEN := 26.0         # in, roughly a robot and a half ahead
const WHISKER_SPREAD := 30.0      # deg either side
const WHISKER_Y := 5.0            # in up: above the 1 in base lip, below the hive
## How close something has to be, as a fraction of WHISKER_LEN, before the bot
## steers round it.
const AVOID_AT := 0.42

## THE HIVE FOOTPRINT, as a box the planners route round.
const HIVE_KEEP_X := 29.0         # in, half-width of the no-go box
const HIVE_KEEP_Y := 24.0         # in, half-depth

func behavior() -> int:
	return int(config.get("behavior", OpponentConfig.Behavior.COLLECT))

func pace() -> float:
	return OpponentConfig.get_f(config, "pace")

func reaction() -> float:
	return OpponentConfig.get_f(config, "reaction")

func _physics_process(delta: float) -> void:
	if BB.frozen() or BB.halted:
		return
	if robot == null or not is_instance_valid(robot):
		return
	robot.auto_drive = true
	if not robot.enabled:
		robot.set_drive(0, 0, 0)
		status = "Disabled by the match"
		return
	match behavior():
		OpponentConfig.Behavior.STATIONARY:
			robot.intake_on = false
			_run_stationary(delta)
		OpponentConfig.Behavior.ROUTE:
			robot.intake_on = false
			_run_route(delta)
		OpponentConfig.Behavior.DEFEND:
			robot.intake_on = false
			_run_defend(delta)
		_:
			robot.intake_on = true
			_run_collect_brain(delta)

# ============================================================== COLLECT ======
#
# The original opponent, unchanged except that its two hard-wired numbers are
# now its settings: CRUISE is `pace`, and the 0.25 s between decisions is
# `reaction`. At the Standard preset both are exactly what they always were.

func _run_collect_brain(delta: float) -> void:

	# --- stuck detector, measured as PROGRESS rather than speed.
	#
	# Speed is the obvious test and it does not work. Wedged against the HIVE's
	# base bar the bot sits there commanding strafe and turn at once, grinding
	# along the obstacle at four or five inches a second while getting nowhere
	# — fast enough to look like driving, so a speed-based detector never
	# fires and it stays there for the rest of the match. Distance to whatever
	# it is currently trying to reach is the honest measure.
	var goal := _goal_point()
	var dist := robot.global_position.distance_to(goal) / BB.IN if goal != Vector3.INF else 0.0
	if mode != Mode.SHOOT and goal != Vector3.INF:
		if dist < _best_dist - 1.0:
			_best_dist = dist
			_stuck = 0.0
		else:
			_stuck += delta
	else:
		_stuck = 0.0
		_best_dist = 1e9
	if _stuck > 1.4 and _unstick <= 0.0:
		_unstick = 1.1
		_stuck = 0.0
		_best_dist = 1e9
		var clear := _whiskers()
		_unstick_side = 1.0 if float(clear["right"]) > float(clear["left"]) else -1.0
		mode = Mode.UNSTICK
	if _unstick > 0.0:
		_unstick -= delta
		# Back out AND slide sideways, so it comes off the obstacle rather than
		# reversing straight into the approach that wedged it in the first
		# place. The side is fixed for the whole manoeuvre; alternating mid-way
		# just rocks it against the same corner.
		robot.set_drive(_unstick_side * 0.7, 0.25, -0.55)
		status = "Blocked — backing off"
		if _unstick <= 0.0:
			mode = Mode.SEEK
			_target = null
			_best_dist = 1e9
		return

	_think -= delta
	if _think <= 0.0:
		_think = maxf(reaction(), 1.0 / 180.0)
		_choose()

	match mode:
		Mode.SEEK, Mode.COLLECT: _run_collect()
		Mode.SHOOT: _run_shoot()

## Whatever the bot is currently driving at, or Vector3.INF if it is not
## driving at anything. Used by the stuck detector.
func _goal_point() -> Vector3:
	if mode == Mode.COLLECT and _target != null and is_instance_valid(_target):
		return _target.global_position
	return Vector3.INF

## Full hopper means go and score it; otherwise go and get another ball.
func _choose() -> void:
	if robot.hopper.size() >= BB.HOPPER_CAP:
		mode = Mode.SHOOT
		return
	if _target == null or not is_instance_valid(_target) or _target.held_by != null:
		_target = _nearest_pollen()
		_best_dist = 1e9
	mode = Mode.COLLECT if _target != null else Mode.SEEK

## Nearest loose POLLEN on the tiles. Not the best one — the nearest one.
func _nearest_pollen() -> GameElement:
	var best: GameElement = null
	var bd := 1e9
	for n in robot.get_tree().get_nodes_in_group("element"):
		var e: GameElement = n
		# COMPATIBILITY. Only POLLEN is targeted: it is what every intake
		# accepts and what this behavior knows how to score (by shooting it at
		# the CELL). NECTAR is never targeted, even by an intake that takes it.
		if e.kind != BB.Kind.POLLEN or e.held_by != null:
			continue
		var cr := OpponentConfig.get_f(config, "collect_r")
		if cr > 0.0:
			var ar: Dictionary = config.get("area", {})
			if Vector2(e.fx() - float(ar.get("x", 0.0)),
					e.fy() - float(ar.get("y", 0.0))).length() > cr:
				continue
		if e.fz() > 8.0:                        # up a flower or in a cell
			continue
		if absf(e.fx()) > BB.FIELD_HALF - 2.0 or absf(e.fy()) > BB.FIELD_HALF - 2.0:
			continue
		# Anything sitting inside the HIVE footprint is not worth going for:
		# the structure is in the way and the bot only wedges itself trying.
		if absf(e.fx()) < HIVE_KEEP_X and absf(e.fy()) < HIVE_KEEP_Y:
			continue
		var d := robot.global_position.distance_to(e.global_position)
		if d < bd:
			bd = d
			best = e
	return best

func _run_collect() -> void:
	if _target == null or not is_instance_valid(_target):
		robot.set_drive(0, 0, 0)
		status = "Waiting: no compatible elements"
		return
	var d := robot.global_position.distance_to(_target.global_position) / BB.IN
	status = "Collecting"
	# APPROACH keeps its original proportion to CRUISE: 0.34 / 0.55.
	_steer_to(_route_round_hive(_target.global_position),
		pace() if d > CLOSE_IN else pace() * (APPROACH / CRUISE))

## If the straight line to `point` would take the robot through the HIVE
## structure, aim at the nearer corner of the keep-out box first. One waypoint
## is enough: from the corner the rest of the path is clear.
func _route_round_hive(point: Vector3) -> Vector3:
	var from := Vector2(robot.fx(), robot.fy())
	var to := Vector2(point.x / BB.IN, -point.z / BB.IN)
	if not _crosses_hive(from, to):
		return point
	# go round whichever side the robot is already nearer to
	var side := signf(from.y) if absf(from.y) > 1.0 else 1.0
	var corner := Vector2(
		clampf(from.x, -HIVE_KEEP_X - 8.0, HIVE_KEEP_X + 8.0),
		side * (HIVE_KEEP_Y + 6.0))
	# if it is already clear of the box on that side, head for the far corner
	if absf(from.y) > HIVE_KEEP_Y:
		corner.x = clampf(to.x, -HIVE_KEEP_X - 8.0, HIVE_KEEP_X + 8.0)
	return BB.fp(corner.x, corner.y, 3.0)

## Segment-versus-box, sampled. Exact clipping is not worth it here — a dozen
## points along the line is plenty to notice a 58 x 48 inch obstacle.
func _crosses_hive(from: Vector2, to: Vector2) -> bool:
	for i in 13:
		var p := from.lerp(to, float(i) / 12.0)
		if absf(p.x) < HIVE_KEEP_X and absf(p.y) < HIVE_KEEP_Y:
			return true
	return false

func _run_shoot() -> void:
	var hive := _own_hive()
	if hive == null:
		robot.set_drive(0, 0, 0)
		return
	# Stand off the CELL mouth along its own normal, which is the one side a
	# shot can get in from — but measure that standoff FLAT. The mouth points
	# up and outboard, so 46 inches along the raw normal only puts the robot
	# about 38 inches out horizontally, under a target 56 inches up. That is a
	# near-vertical shot, the solver refuses it, and the bot stands at its
	# firing point forever without ever taking one.
	var flat_n := hive.mouth_normal()
	flat_n.y = 0.0
	flat_n = flat_n.normalized()
	var aim := hive.aim_point()
	var spot := Vector3(aim.x, 0.0, aim.z) + flat_n * SHOOT_STANDOFF * BB.IN
	var d := Vector2(robot.global_position.x - spot.x,
		robot.global_position.z - spot.z).length() / BB.IN
	if d > SHOOT_TOLERANCE:
		status = "Travelling to shooting spot"
		_steer_to(spot, pace() if d > CLOSE_IN * 2.0 else pace() * (APPROACH / CRUISE))
		return
	robot.set_drive(0, 0, 0)
	if robot.hopper.is_empty():
		mode = Mode.SEEK
		return
	if not robot.aim_locked:
		status = "Aiming"
		return
	status = "Shooting"
	if robot.can_fire():
		robot.fire()

func _own_hive() -> Hive:
	var best: Hive = null
	var bd := 1e9
	for a in field.hives:
		var h: Hive = field.hives[a]
		if h.alliance != robot.alliance:
			continue
		var d := robot.global_position.distance_to(h.aim_point())
		if d < bd:
			bd = d
			best = h
	return best

## Drive at a world point. The command is built in the ROBOT's frame, so the
## mecanum can strafe toward it while turning to face it rather than having to
## point first and drive second.
func _steer_to(point: Vector3, gain: float, avoid := true) -> void:
	var local := robot.to_local(point)
	var flat := Vector2(local.x, local.z)
	if flat.length() < 0.001:
		robot.set_drive(0, 0, 0)
		return
	var dir := flat.normalized()
	# robot forward is local -Z, so a target ahead has local.z negative
	var fwd := -dir.y
	var strafe := dir.x
	# turn toward it as well, so it ends up facing what it is driving at
	var bearing := atan2(local.x, -local.z)
	var turn := clampf(bearing * 1.2, -0.6, 0.6)

	# --- go round whatever is in the way
	#
	# Only react to something genuinely CLOSE. Reacting to anything inside the
	# whisker length means reacting to the perimeter wall for most of the
	# field, and the bot spends the match sidling along refusing to commit to
	# anything — measured: two balls collected in seventy seconds.
	if not avoid:
		robot.set_drive(strafe * gain, turn, fwd * gain)
		return
	var clear := _whiskers()
	var ahead: float = float(clear["ahead"])
	if ahead < AVOID_AT:
		var side: float = 1.0 if float(clear["right"]) > float(clear["left"]) else -1.0
		var urgency: float = (AVOID_AT - ahead) / AVOID_AT
		# Slide sideways past it without abandoning the approach. Mecanum can
		# do that; a tank drive would have to turn away and come back.
		strafe = clampf(strafe + side * urgency * 1.6, -1.0, 1.0)
		fwd *= maxf(0.3, 1.0 - urgency)
	robot.set_drive(strafe * gain, turn, fwd * gain)

## How clear each whisker is, 0 (blocked at the bumper) to 1 (nothing within
## WHISKER_LEN). Cast from just above the HIVE's base lip so the 1 inch bar it
## is supposed to drive over does not read as a wall.
func _whiskers() -> Dictionary:
	var space := robot.get_world_3d().direct_space_state
	var origin := robot.global_position + Vector3(0, BB.m(WHISKER_Y), 0)
	var out := {}
	# Five whiskers, not three. A leg caught on the shoulder at 50 degrees is
	# still a leg you are about to wedge on.
	for spec in [["ahead", 0.0], ["left", -WHISKER_SPREAD], ["right", WHISKER_SPREAD],
			["left", -WHISKER_SPREAD * 2.0], ["right", WHISKER_SPREAD * 2.0]]:
		var ang := deg_to_rad(float(spec[1]))
		var dir := (-robot.global_transform.basis.z).rotated(Vector3.UP, ang)
		var q := PhysicsRayQueryParameters3D.create(
			origin, origin + dir * BB.m(WHISKER_LEN))
		q.exclude = [robot.get_rid()]
		# the world, the flower guards, and anything else solid
		q.collision_mask = 0
		q.collision_mask |= 1 << (BB.LAYER_WORLD - 1)
		q.collision_mask |= 1 << (BB.LAYER_GUARD - 1)
		var hit := space.intersect_ray(q)
		var v := 1.0 if hit.is_empty() else clampf(
			origin.distance_to(hit["position"]) / BB.m(WHISKER_LEN), 0.0, 1.0)
		# two rays share each side name; keep the nearer obstruction
		var key := String(spec[0])
		out[key] = minf(float(out.get(key, 1.0)), v)
	return out

# ============================================================ STATIONARY =====
#
# Holds the pose it started in, using the drivetrain exactly as a driver
# holding the stick against a shove would. Nothing is locked or frozen: the
# robot is an ordinary rigid body, so pushing it moves it, and only then does
# it drive back. Its `pace` caps how hard it drives back; its `reaction` is how
# long it takes to notice it has been moved.

func _run_stationary(delta: float) -> void:
	if _home == Vector2.INF:
		_home = Vector2(robot.fx(), robot.fy())
		_home_yaw = robot.global_rotation.y
	var here := Vector2(robot.fx(), robot.fy())
	var off := here.distance_to(_home)
	var yaw_err := rad_to_deg(angle_difference(robot.global_rotation.y, _home_yaw))
	var hold_heading := OpponentConfig.get_f(config, "hold_heading") >= 0.5
	var moved := off > HOLD_TOL or (hold_heading and absf(yaw_err) > HOLD_YAW_TOL)
	if not moved:
		_react_left = reaction()
		robot.set_drive(0, 0, 0)
		status = "Holding position"
		return
	# it has been moved: wait out its reaction delay before responding
	if _react_left > 0.0:
		_react_left -= delta
		robot.set_drive(0, 0, 0)
		status = "Holding position (pushed %.0f in)" % off
		return
	var goal := BB.fp(_home.x, _home.y, 0.0)
	var local := robot.to_local(goal)
	var flat := Vector2(local.x, local.z)
	var strafe := 0.0
	var fwd := 0.0
	if off > HOLD_TOL * 0.5 and flat.length() > 0.0001:
		var dir := flat.normalized()
		# slow down on the way in rather than overshooting the spot
		var gain := pace() * clampf(off / 12.0, 0.25, 1.0)
		strafe = dir.x * gain
		fwd = -dir.y * gain
	var turn := 0.0
	if hold_heading:
		# +turn is clockwise from above, which DECREASES yaw
		turn = clampf(-deg_to_rad(yaw_err) * 1.6, -pace(), pace())
	robot.set_drive(strafe, turn, fwd)
	status = "Returning to position"

# ================================================================= ROUTE ====

func _waypoints() -> Array:
	return config.get("waypoints", [])

func _run_route(delta: float) -> void:
	var wps := _waypoints()
	if wps.size() < 1:
		robot.set_drive(0, 0, 0)
		status = "No route"
		return
	_wp = clampi(_wp, 0, wps.size() - 1)
	if _done:
		robot.set_drive(0, 0, 0)
		status = "Route complete"
		return
	if _wait_left > 0.0:
		_wait_left -= delta
		robot.set_drive(0, 0, 0)
		status = "Waiting: %.1f s" % maxf(_wait_left, 0.0)
		if _wait_left <= 0.0:
			_wait_left = 0.0
			_advance(wps.size())
			if _done:
				status = "Route complete"
		return
	if _blocked_wait > 0.0:
		_blocked_wait -= delta
		robot.set_drive(0, 0, 0)
		status = "Blocked — waiting %.1f s" % maxf(_blocked_wait, 0.0)
		if _blocked_wait <= 0.0:
			_attempts = 0
			_best_dist = 1e9
		return
	if _unstick > 0.0:
		_unstick -= delta
		robot.set_drive(_unstick_side * 0.6, 0.0, -0.5)
		status = "Blocked — recovering"
		if _unstick <= 0.0:
			_best_dist = 1e9
			if _attempts >= MAX_RECOVERIES:
				_blocked_wait = BLOCKED_WAIT_S
		return

	var w: Dictionary = wps[_wp]
	var goal := BB.fp(float(w["x"]), float(w["y"]), 0.0)
	var dist := Vector2(robot.fx() - float(w["x"]), robot.fy() - float(w["y"])).length()
	if dist <= OpponentConfig.get_f(config, "tolerance"):
		robot.set_drive(0, 0, 0)
		_attempts = 0
		_stuck = 0.0
		_best_dist = 1e9
		_wait_left = float(w.get("wait", 0.0))
		if _wait_left <= 0.0:
			_advance(wps.size())
			# the status is for the state it is IN now, which after the last
			# waypoint of a Stop-at-end route is finished, not travelling
			status = "Route complete" if _done \
				else "Travelling to waypoint %d" % (_wp + 1)
		else:
			status = "Waiting: %.1f s" % _wait_left
		return

	# progress, not speed, decides whether it is blocked
	if dist < _best_dist - 1.0:
		_best_dist = dist
		_stuck = 0.0
	else:
		_stuck += delta
	if _stuck > BLOCK_S:
		_stuck = 0.0
		_attempts += 1
		var clear := _whiskers()
		_unstick_side = 1.0 if float(clear["right"]) > float(clear["left"]) else -1.0
		_unstick = RECOVER_S
		status = "Blocked — recovering"
		return

	status = "Travelling to waypoint %d" % (_wp + 1)
	_steer_to(_route_round_hive(goal),
		pace() if dist > CLOSE_IN else pace() * (APPROACH / CRUISE))

## Move to the next waypoint according to the traversal mode.
func _advance(n: int) -> void:
	if n <= 1:
		_done = true
		return
	match int(OpponentConfig.get_f(config, "route_mode")):
		OpponentConfig.RouteMode.LOOP:
			_wp = (_wp + 1) % n
		OpponentConfig.RouteMode.BACK_AND_FORTH:
			if _wp + _dir >= n or _wp + _dir < 0:
				_dir = -_dir
			_wp += _dir
		_:
			if _wp >= n - 1:
				_done = true
			else:
				_wp += 1
	_best_dist = 1e9
	_stuck = 0.0

# ================================================================ DEFEND ====
#
# Goalkeeper geometry, bounded by a circle. While the defended robot's centre
# is within the area (plus ENGAGE_MARGIN), the defender aims for the point
# `standoff` inches from that robot on the line towards the middle of the
# area — between it and the centre. Otherwise it goes back to the middle.
#
# EVERY GOAL IS CLAMPED INSIDE THE CIRCLE, measured on the defender's own
# ground-plane centre. It never plans a point outside its area, so it never
# pursues across the field. Physical contact can still shove it past the edge
# for a moment; see OpponentConfig.AREA_NOTE.
#
# Its knowledge of where the target is comes from looking, with a delay: the
# position is SAMPLED every `reaction` seconds and held in between.

func defended_robot() -> Robot:
	var t := int(config.get("target", -1))
	if roster_owner == null or not is_instance_valid(roster_owner):
		return null
	var list: Array = roster_owner.get("robots") if "robots" in roster_owner else []
	if t < 0 or t >= list.size() or not is_instance_valid(list[t]):
		return null
	var r: Robot = list[t]
	return r if r != robot and r.alliance != robot.alliance else null

func area_center() -> Vector2:
	var a: Dictionary = config.get("area", {})
	return Vector2(float(a.get("x", 0.0)), float(a.get("y", 0.0)))

func _run_defend(delta: float) -> void:
	var c := area_center()
	var radius := OpponentConfig.get_f(config, "radius")
	var here := Vector2(robot.fx(), robot.fy())
	var target := defended_robot()
	if target == null:
		robot.set_drive(0, 0, 0)
		status = "No robot to defend against"
		return

	_seen_left -= delta
	if _seen_left <= 0.0 or _seen == Vector2.INF:
		_seen = Vector2(target.fx(), target.fy())
		_seen_left = maxf(reaction(), 1.0 / 180.0)

	var goal := c
	var engaged := _seen.distance_to(c) <= radius + OpponentConfig.ENGAGE_MARGIN
	if engaged:
		var towards := c - _seen
		if towards.length() < 1.0:
			towards = here - _seen
		if towards.length() < 0.001:
			towards = Vector2.RIGHT
		goal = _seen + towards.normalized() * OpponentConfig.get_f(config, "standoff")
		status = "Defending Robot %d" % (int(config.get("target", 0)) + 1)
	elif here.distance_to(c) > 6.0:
		status = "Returning to area"
	else:
		status = "Holding area"
	# the goal is never outside the circle
	var from_c := goal - c
	if from_c.length() > radius:
		goal = c + from_c.normalized() * radius

	var world := BB.fp(goal.x, goal.y, 0.0)
	var d := here.distance_to(goal)
	if d < 2.0:
		# in position: face the robot it is defending against
		var face := robot.to_local(BB.fp(_seen.x, _seen.y, 0.0))
		var bearing := atan2(face.x, -face.z)
		robot.set_drive(0, clampf(bearing * 1.2, -pace(), pace()), 0)
		return
	# NO whisker avoidance: a defender that sidesteps the robot it is meant to
	# block is not defending. It still routes round the HIVE structure.
	_steer_to(_route_round_hive(world),
		pace() if d > CLOSE_IN else pace() * (APPROACH / CRUISE), false)

# ============================================================== snapshots ====

## What the brain was in the middle of. `_target` is an element, so it is saved
## by id and resolved after the elements exist; the timers are all REMAINING
## time, never a deadline, so they mean the same thing on a machine that has
## been running for five minutes and one that has been running for five hours.
func save_state(element_id: Callable) -> Dictionary:
	return {
		# WHAT it was told to do. The presence of `behavior` is what marks a
		# brain as post-legacy; see OpponentConfig.from_brain().
		"behavior": behavior(),
		"config": config.duplicate(true),
		# COLLECT, under the original names so old files still read
		"mode": mode,
		"target": element_id.call(_target),
		"stuck": _stuck,
		"best_dist": _best_dist,
		"unstick_side": _unstick_side,
		"unstick": _unstick,
		"think": _think,
		# ROUTE — all REMAINING times
		"wp": _wp, "dir": _dir, "wait_left": _wait_left, "done": _done,
		"attempts": _attempts, "blocked_wait": _blocked_wait,
		# STATIONARY
		"home": [_home.x, _home.y] if _home != Vector2.INF else [],
		"home_yaw": _home_yaw, "react_left": _react_left,
		# DEFEND
		"seen": [_seen.x, _seen.y] if _seen != Vector2.INF else [],
		"seen_left": _seen_left,
		"status": status,
		# The new behaviors draw no random numbers. Recorded so a later version
		# that does can tell a file that needs one from a file that did not.
		"rng": null,
	}

func apply_state(d: Dictionary, element_of: Callable) -> void:
	config = OpponentConfig.from_brain(d)
	mode = int(d.get("mode", Mode.SEEK))
	var tid := String(d.get("target", "")) if d.get("target") is String else ""
	var t: Variant = element_of.call(tid)
	_target = t if t is GameElement else null
	_stuck = _num(d, "stuck", 0.0)
	_best_dist = _num(d, "best_dist", 1e9)
	_unstick_side = _num(d, "unstick_side", 1.0)
	_unstick = _num(d, "unstick", 0.0)
	_think = _num(d, "think", 0.0)
	var n := (config.get("waypoints", []) as Array).size()
	_wp = clampi(int(_num(d, "wp", 0.0)), 0, maxi(n - 1, 0))
	_dir = 1 if _num(d, "dir", 1.0) >= 0.0 else -1
	_wait_left = maxf(_num(d, "wait_left", 0.0), 0.0)
	_done = bool(d.get("done", false))
	_attempts = int(_num(d, "attempts", 0.0))
	_blocked_wait = maxf(_num(d, "blocked_wait", 0.0), 0.0)
	_home = _v2(d.get("home", []))
	_home_yaw = _num(d, "home_yaw", 0.0)
	_react_left = maxf(_num(d, "react_left", 0.0), 0.0)
	_seen = _v2(d.get("seen", []))
	_seen_left = maxf(_num(d, "seen_left", 0.0), 0.0)
	status = String(d.get("status", "")) if d.get("status") is String else ""

static func _num(d: Dictionary, k: String, fallback: float) -> float:
	var v: Variant = d.get(k, fallback)
	return float(v) if (v is float or v is int) and is_finite(float(v)) else fallback

static func _v2(v: Variant) -> Vector2:
	if v is Array and (v as Array).size() == 2:
		var a: Variant = (v as Array)[0]
		var b: Variant = (v as Array)[1]
		if (a is float or a is int) and (b is float or b is int):
			return Vector2(float(a), float(b))
	return Vector2.INF
