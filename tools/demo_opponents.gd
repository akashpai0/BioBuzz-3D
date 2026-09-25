extends Node
## RENDERED DEMONSTRATIONS OF THE FOUR OPPONENT BEHAVIORS.
##
## Not a test: a recording. Each of the four opponent starter drills is played
## through the ordinary library path with the practice overlay switched on,
## robot 1 is driven along a scripted line that interacts with the opponent,
## and frames are written to _shots/demo_<name>/ for ffmpeg to encode.
##
## Run under a display (xvfb) with a fixed --resolution.

var main: Node3D
var _goal := Vector2.INF
var _speed := 0.55
const FPS := 12

func _ready() -> void:
	Settings.set_value("game/opponent_overlay", 1.0, false)
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(2.5).timeout
	# [drill tag, file name, seconds, robot-1 script: [[x, y, until_s], ...]]
	# [drill tag, file name, seconds, robot-1 script: [[x, y, until_s], ...]]
	var plan := [
		# push the parked robot, back off, go round the open side, arrive
		["opp_around", "stationary", 11.0,
			[[4.0, -58.0, 3.0], [-24.0, -58.0, 4.2], [-6.0, -34.0, 6.0],
				[24.0, -36.0, 7.6], [56.0, -58.0, 11.0]]],
		# wait short of the loop, then cross
		["opp_traffic", "route", 11.0,
			[[-12.0, -52.0, 5.0], [58.0, -52.0, 11.0]]],
		# approach, feint high, drop low, go for the target
		["opp_guarded", "defend", 12.0,
			[[18.0, -52.0, 3.0], [36.0, -36.0, 6.0], [34.0, -66.0, 9.0],
				[54.0, -52.0, 12.0]]],
		["opp_compete", "collect", 14.0, []],
	]
	for p in plan:
		await _record(String(p[0]), String(p[1]), float(p[2]), p[3] as Array)
	Settings.set_value("game/opponent_overlay", 0.0, false)
	print("DEMOS DONE")
	get_tree().quit()

## Timed on the SIMULATION clock. Counting awaited frames undercounts badly
## under software rendering, where one screenshot lets several physics steps
## pass — the first version of this recorder ran each attempt out past its
## time limit and recorded mostly the results screen.
func _record(tag: String, nm: String, secs: float, route: Array) -> void:
	var id := ""
	for e in ScenarioLibrary.list_all():
		if String(((e["data"] as Dictionary).get("meta", {}) as Dictionary).get("drill", "")) == tag:
			id = String(e["id"])
	if id == "":
		print("missing drill ", tag)
		return
	await main.play_situation(id)
	# a recording, not an attempt: lift the time limit so the whole
	# behavior is on film rather than the results screen
	if main.attempt != null:
		main.attempt.objective["time_limit"] = 0.0
	main.rig.mode = CameraRig.Mode.OVERHEAD
	DirAccess.make_dir_recursive_absolute("res://_shots/demo_%s" % nm)
	var t0 := BB.sim_now()
	var frame := 0
	var next_shot := 0.0
	var next_log := 0.0
	var ended := ""
	while BB.sim_now() - t0 < secs:
		# the attempt finishing halts the world, which stops the clock this
		# loop is waiting on - so a finished attempt ends the clip
		if BB.halted:
			ended = "attempt finished" if main.attempt_results.is_open() else "halted"
			break
		var t := BB.sim_now() - t0
		_goal = Vector2.INF
		for leg in route:
			if t < float(leg[2]):
				_goal = Vector2(float(leg[0]), float(leg[1]))
				break
		await get_tree().physics_frame
		if t >= next_shot:
			next_shot += 1.0 / float(FPS)
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(
				"res://_shots/demo_%s/f%04d.png" % [nm, frame])
			frame += 1
		if t >= next_log:
			next_log += 1.0
			var br := _foe()
			if br:
				print("  %-10s t=%4.1f  me=(%4.0f,%4.0f)  opp=(%4.0f,%4.0f)  %s" % [nm, t,
					main.robot.fx(), main.robot.fy(), br.robot.fx(), br.robot.fy(), br.status])
	_goal = Vector2.INF
	if is_instance_valid(main.robot):
		main.robot.set_drive(0, 0, 0)
	# hold the last frame a moment, and show how it ended
	for k in 6:
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(
			"res://_shots/demo_%s/f%04d.png" % [nm, frame])
		frame += 1
	print("  %s: %d frames over %.1f s of simulation%s" % [nm, frame,
		BB.sim_now() - t0, (" - " + ended) if ended != "" else ""])
	main.attempt_results.close()
	main.mm.resume()

func _foe() -> AIDriver:
	for b in main.ais:
		if is_instance_valid(b) and b.robot.alliance != main.robot.alliance:
			return b
	return null

func _physics_process(_d: float) -> void:
	if main == null or not is_instance_valid(main.robot) or _goal == Vector2.INF:
		return
	var me: Robot = main.robot
	me.auto_drive = true
	var loc := me.to_local(BB.fp(_goal.x, _goal.y, 0.0))
	var f := Vector2(loc.x, loc.z)
	if f.length() > BB.m(2.0):
		f = f.normalized() * _speed
		me.set_drive(f.x, 0.0, -f.y)
	else:
		me.set_drive(0, 0, 0)
