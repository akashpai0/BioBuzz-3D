extends Node3D
##
## Assembles the world and stages a match per S10.3.1 / G304.
##
## STAGING (S3 of the reference):
##   40 POLLEN = 4 in each FLOWER (16) + 4 in each GARDEN (8) + 4 per ROBOT (16).
##               The three absent robots' 16 go to their LOADING ZONES, which is
##               what the manual does with a no-show.
##   16 NECTAR = 3 in each upward-facing CELL (6) + 5 per ALLIANCE AREA (10),
##               the latter entered by the human player per G426.
##

var field: Field
## robot 1. Kept as its own name because the HUD, the camera and the
## leaderboard all mean "the robot you are driving" when they say robot.
var robot: Robot
## Every robot on the field: our one or two, then the opponent if there is one.
var robots: Array[Robot] = []
var opponent: Robot
var ai: AIDriver
## Chosen on the title screen. Defaults are one driver, empty field, perfect
## setup — the state a driver practising alone wants.
var opts := {"robots": 1, "mate_is_ai": false, "per_robot": 1,
	"opponents": 0, "takes_nectar": false}
## Every AI on the field — opponents and an optional teammate.
var ais: Array[AIDriver] = []
var mm: MatchManager
var stats: MatchStats
var hud: Hud
var rig: CameraRig
var menu: Menu
var settings_menu: SettingsMenu
var results: ResultsScreen
var robot_menu: RobotMenu
var progress: ProgressScreen
var auto_player: AutoPlayer
## Seconds left in a guided recording, for the HUD. Zero when not recording.
var recording_left := 0.0
var signin: SignIn
var scenarios: ScenarioScreen
var editor: ScenarioEditor
var objective_hud: ObjectiveHud
var attempt_results: AttemptResults
## The objective attempt in progress, if the loaded situation has one.
var attempt: Attempt
## True while a test run launched from the editor is in progress, so the pause
## menu and the results screen can offer the way back.
var editor_return := false
var _parked: Array[GameElement] = []

## THE SITUATION THIS RUN CAME FROM.
##
## `scenario_source` is the snapshot as it was SAVED, kept untouched for the
## whole session: every Retry restores from this, so attempt twelve starts from
## exactly what attempt one started from. Saving a later moment writes a new
## file and does not touch it unless the player asks to overwrite.
var scenario_source: Dictionary = {}
var scenario_id := ""
## True for any run started from a situation. Those are practice reps, so they
## stay out of the leaderboard and out of the match history.
var scenario_run := false

## Every run is recorded (ReplayRecorder); the viewer plays recordings back.
var recorder: ReplayRecorder
var viewer: ReplayViewer
## The next mm.start() is not a run anyone would want a replay of (test drive,
## guided auto recording).
var _no_record_next := false
## Where the viewer's Back goes: "results", "attempt_results" or "progress".
var _viewer_back := ""
## Online: the room server (in a room process) or the client (in the game).
var net_room: Node
var net: Node

func _ready() -> void:
	_environment()

	field = Field.new()
	add_child(field)
	field.build()

	mm = MatchManager.new()
	mm.name = "Match"
	mm.field = field
	add_child(mm)

	# Stats are a passive observer: they listen to signals the match already
	# emits and never influence anything. Deleting this node would leave the
	# match playing identically.
	stats = MatchStats.new()
	stats.name = "Stats"
	stats.field = field
	stats.mm = mm
	add_child(stats)
	stats.hook_field()

	_build_robots(BB.Alliance.RED, 1)

	rig = CameraRig.new()
	rig.target = robot
	rig.alliance = robot.alliance
	add_child(rig)

	menu = Menu.new()
	add_child(menu)
	menu.build()
	menu.started.connect(_on_menu_start)
	menu.settings_changed.connect(_apply_settings)

	results = ResultsScreen.new()
	add_child(results)
	results.build()
	results.closed.connect(func() -> void:
		mm.abort()
		goto("Play"))
	results.replay.connect(func() -> void:
		await stage()
		mm.start()
		_start_auto_routine())

	robot_menu = RobotMenu.new()
	add_child(robot_menu)
	robot_menu.play = menu
	robot_menu.build()
	menu.garage = robot_menu
	robot_menu.record_requested.connect(func(_n: String) -> void:
		_guided_record())

	progress = ProgressScreen.new()
	add_child(progress)
	progress.play = menu
	progress.build()

	auto_player = AutoPlayer.new()
	auto_player.name = "AutoPlayer"
	add_child(auto_player)

	# The recorder is simulation: it pauses with the world by exclusion, so a
	# pause menu, a restore or the editor can never add a frame to a replay.
	recorder = ReplayRecorder.new()
	recorder.name = "ReplayRecorder"
	recorder.main = self
	add_child(recorder)
	recorder.problem.connect(_on_replay_problem)

	settings_menu = SettingsMenu.new()
	add_child(settings_menu)
	settings_menu.test_drive_requested.connect(_test_drive)
	settings_menu.play = menu
	settings_menu.build()

	scenarios = ScenarioScreen.new()
	add_child(scenarios)
	scenarios.play = menu
	scenarios.build()
	scenarios.play_requested.connect(play_situation)

	editor = ScenarioEditor.new()
	add_child(editor)
	editor.main = self
	editor.build()
	editor.closed.connect(func() -> void:
		editor.close()
		# The editor poses the match manager to the draft's phase and clock so
		# the field looks right. Leaving without clearing it would convince
		# Play that a match is running when nothing is.
		mm.abort()
		hud.visible = true
		editor_return = false
		_forget_scenario()
		goto("Scenarios"))
	editor.test_requested.connect(_test_scenario)
	results.return_to_editor.connect(return_to_editor)
	editor.saved.connect(func(_id: String) -> void: scenarios.refresh())

	objective_hud = ObjectiveHud.new()
	add_child(objective_hud)
	objective_hud.build()

	attempt_results = AttemptResults.new()
	add_child(attempt_results)
	attempt_results.build()
	attempt_results.retry_requested.connect(retry_situation)
	attempt_results.library_requested.connect(func() -> void:
		_end_attempt("abandoned")
		mm.abort()
		_forget_scenario()
		goto("Scenarios"))
	attempt_results.edit_requested.connect(func(id: String) -> void:
		_end_attempt("abandoned")
		mm.abort()
		_edit_scenario(id))
	attempt_results.editor_requested.connect(return_to_editor)
	attempt_results.watch_requested.connect(func() -> void:
		var err: String = await watch_replay(_this_runs_replay(), "attempt_results")
		if err != "":
			attempt_results.show_note(err))
	results.watch_requested.connect(func() -> void:
		var err: String = await watch_replay(_this_runs_replay(), "results")
		if err != "":
			results.show_note(err))
	progress.watch_requested.connect(func(id: String, practise: bool) -> void:
		var err: String = await watch_replay(id, "progress", practise)
		if err != "":
			progress.show_note(err))
	progress.replay_folder_busy = func() -> bool:
		return recorder.state == ReplayRecorder.State.RECORDING
	progress.session_suspended = func() -> bool:
		return mm.in_progress()

	viewer = ReplayViewer.new()
	viewer.name = "ReplayViewer"
	viewer.main = self
	add_child(viewer)
	viewer.closed.connect(_on_viewer_closed)

	# ONLINE PRACTICE. Every copy of the game can host a room (its own world
	# becomes the room's simulation, see NetRoomServer) or join one.
	if true:
		net = NetClient.new()
		net.name = "NetClient"
		net.main = self
		add_child(net)
		menu.open_online.connect(func() -> void:
			for screen in [menu, robot_menu, progress, settings_menu, scenarios]:
				if screen != null and screen.is_open():
					screen.close()
			net.open_online())

	scenarios.create_requested.connect(_create_scenario)
	scenarios.edit_requested.connect(_edit_scenario)

	menu.open_scenarios.connect(func() -> void: goto("Scenarios"))
	menu.return_to_editor.connect(return_to_editor)
	menu.save_situation.connect(_save_situation)
	menu.retry_situation.connect(retry_situation)
	menu.end_match.connect(func() -> void:
		_end_attempt("abandoned")
		mm.abort()
		_forget_scenario()
		menu.match_running = false
		goto("Play"))

	# ONE router. Every page's top navigation, every footer and every deep link
	# ends up here, so there is one place that knows what "go to Garage" means
	# and one place that rebuilds the robot after the Garage changed it.
	for screen in [menu, robot_menu, progress, settings_menu, scenarios]:
		screen.navigate.connect(goto)
	menu.open_robot.connect(func() -> void: goto("Garage"))
	menu.open_settings.connect(func() -> void: goto("Settings"))
	menu.open_controls.connect(func() -> void: goto("Settings", 3))
	menu.open_garage_tab.connect(func(tab: int) -> void: goto("Garage", tab))
	menu.resumed.connect(func() -> void:
		menu.close()
		_resume_match())

	rig.mode = CameraRig.Mode.MENU

	hud = Hud.new()
	hud.mm = mm
	hud.robot = robot
	hud.field = field
	hud.rig = rig
	hud.menu = menu
	add_child(hud)
	hud.build()
	objective_hud.hud = hud      # so the practice card can stay clear of it

	_mark_process_modes()

	# A CONTROLLER VANISHING MID-RUN STOPS THE RUN. Carrying on with a dead
	# seat means a robot that will not answer and a driver who cannot tell
	# whether it is the game or the pad. Reconnecting deliberately does NOT
	# resume: the player has to pick the controller back up and say so.
	Settings.device_lost.connect(_on_device_lost)

	mm.finished.connect(_on_match_finished)
	mm.auto_ended.connect(func() -> void: auto_player.stop_play())
	mm.started.connect(_on_match_started)
	# asked once, the first time the game is ever opened
	if not Leaderboard.signed_in() and not NetRole.is_server:
		signin = SignIn.new()
		signin.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(signin)
		signin.build()
		menu.close()
		signin.done.connect(func(_n: String) -> void: goto("Play"))
	# The four starter drills are written once, from a real staged field, using
	# the same editor operations and the same library a player would.
	await stage()
	if not NetRole.is_server:
		StarterDrills.ensure(self)
	mm.abort()

	for a in field.hives:
		(field.hives[a] as Hive).tipped.connect(mm.on_tip)
	for f: Flower in field.flowers:
		f.volume.body_entered.connect(_on_flower_entry)

	call_deferred("stage")

## WHAT KEEPS RUNNING WHILE THE WORLD IS HALTED — decided by EXCLUSION.
##
## `BB.halt()` pauses the scene tree. Halting stops the physics server outright
## (bodies do not integrate whatever their process mode), but `_process` and
## `_physics_process` still fire on PROCESS_MODE_ALWAYS nodes — and this root
## has to be ALWAYS, or Esc could never un-pause what Esc paused. Every child
## that INHERITS therefore runs while halted unless something says otherwise.
##
## The first version of this said otherwise with a list of simulation nodes to
## hold down: `field`, `mm`, `stats`. A follow-up review found the node that
## list forgot — `auto_player` — recording thirty frames and consuming a second
## of autonomous playback behind the pause menu.
##
## SO THE DEFAULT IS INVERTED. Only the nodes named here keep running, and
## everything else under this root is simulation and stops, whether or not
## anybody remembered it existed. Adding a subsystem now makes it pause by
## default; the way to get it wrong is to opt in deliberately.
##
## `tools/debug_pause.gd` walks the live tree while halted and fails if any
## node outside this set can still process, so the next omission is a test
## failure rather than a review finding.
func always_running() -> Array[Node]:
	var out: Array[Node] = [self]
	for ui in [rig, hud, menu, results, robot_menu, progress, settings_menu,
			scenarios, editor, objective_hud, attempt_results, signin, viewer, net]:
		if ui != null and is_instance_valid(ui):
			out.append(ui)
	return out

func _mark_process_modes() -> void:
	var keep := always_running()
	for n in keep:
		n.process_mode = Node.PROCESS_MODE_ALWAYS
	for child in get_children():
		if not keep.has(child):
			child.process_mode = Node.PROCESS_MODE_PAUSABLE

## Anything added to the world AFTER startup — robots, balls, AI brains, the
## objective attempt — goes through here so it pauses like everything else.
func _adopt(n: Node) -> void:
	n.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(n)

func _environment() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var pmat := ProceduralSkyMaterial.new()
	pmat.sky_top_color = Color(0.11, 0.13, 0.18)
	pmat.sky_horizon_color = Color(0.22, 0.24, 0.28)
	pmat.ground_bottom_color = Color(0.06, 0.06, 0.07)
	pmat.ground_horizon_color = Color(0.12, 0.13, 0.15)
	sky.sky_material = pmat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.1
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-58, -40, 0)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	# The whole field is 3.7 m across and the camera never sees much past it.
	# Spending the shadow map on 100 m (the default) is what made shadows soft
	# and stair-stepped; on 12 m every texel lands on something you can see.
	sun.directional_shadow_max_distance = 12.0
	sun.shadow_bias = 0.05
	sun.shadow_normal_bias = 1.0
	sun.add_to_group("sunlight")        # Settings toggles shadows through this
	add_child(sun)
	Settings.apply_graphics()

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-30, 140, 0)
	fill.light_energy = 0.35
	add_child(fill)

# ================================================================== staging ==

func stage() -> void:
	# Let go of everything the robots are carrying BEFORE the balls are freed,
	# so no hopper is left holding a ghost.
	for r in robots:
		if is_instance_valid(r):
			r.hopper.clear()
	for n in get_tree().get_nodes_in_group("element"):
		n.held_by = null
		n.queue_free()
	_parked.clear()
	mm.scoring = Scoring.new()
	if stats:
		# a new match is a new set of numbers; the old ones are already saved
		stats.per.clear()
		for r in robots:
			if is_instance_valid(r):
				stats.track(r)
	mm.nectar_pool = {BB.Alliance.RED: [], BB.Alliance.BLUE: []}
	mm.human_queue = {BB.Alliance.RED: [], BB.Alliance.BLUE: []}
	mm.abort()
	await get_tree().physics_frame

	for a in field.hives:
		# S10.3.1: staged so the CELL pointing at a FLOWER is DOWN. Red's raised
		# CELL is south, blue's north — they are NOT staged the same way.
		(field.hives[a] as Hive).set_tilt(BB.STAGED_TILT[a])

	# --- every ROBOT to its G304 start: own side, touching the wall, clear of
	# the LOADING ZONE and of the near FLOWER's scoring volume. Point-symmetric,
	# so blue starts at the opposite wall facing the other way, and a second
	# robot on the same alliance takes the next spot along that wall.
	var seat := {BB.Alliance.RED: 0, BB.Alliance.BLUE: 0}
	for r in robots:
		if not is_instance_valid(r):
			continue
		var i: int = seat[r.alliance]
		seat[r.alliance] = i + 1
		r.reset_to(_start_pose(r.alliance, i))
	await get_tree().physics_frame

	# --- POLLEN. 16 of the 40 are ROBOT preloads, 4 apiece. Whatever no robot
	# is there to carry goes into that alliance's LOADING ZONE — the same thing
	# the FIELD crew does with a no-show.
	for r in robots:
		if not is_instance_valid(r):
			continue
		for i in 4:
			r._take(_spawn_pollen(r.to_global(Vector3(0, BB.m(6.0), 0))))
	for spec in BB.FLOWERS:
		for i in 4:
			_spawn_pollen(BB.fp(spec["x"], spec["y"], 26.0 + float(i) * 3.4))
	for a in [BB.Alliance.RED, BB.Alliance.BLUE]:
		var g := BB.garden(a)
		for i in 4:
			var gx: float = lerpf(g[0] + 2.0, g[2] - 2.0, float(i) / 3.0)
			_spawn_pollen(BB.fp(gx, (g[1] + g[3]) * 0.5, 1.6))
	for a in [BB.Alliance.RED, BB.Alliance.BLUE]:
		var lz := BB.loading_zone(a)
		var n: int = (2 - mini(2, int(seat[a]))) * 4
		for i in n:
			var lx: float = lerpf(lz[0] + 2.0, lz[2] - 2.0, 0.5)
			var ly: float = lerpf(lz[1] + 3.0, lz[3] - 3.0, float(i) / maxf(float(n - 1), 1.0))
			_spawn_pollen(BB.fp(lx, ly, 1.6 + float(i % 2) * 3.0))

	# --- NECTAR: 3 in each raised CELL, 5 per alliance held for the human player
	for a in field.hives:
		var h: Hive = field.hives[a]
		var cell := h.up_cell()
		for i in 3:
			var p := cell.global_position + Vector3(
				(float(i) - 1.0) * BB.m(5.0), BB.m(3.0), 0.0)
			_spawn_nectar(a, p)
		for i in 5:
			var e := _spawn_nectar(a, BB.fp(0, 0, -60.0))
			e.set_held(mm)
			mm.nectar_pool[a].append(e)
	# Everything just jumped to its start; don't let the renderer slide it there
	# from where it was last match.
	get_tree().root.reset_physics_interpolation()

## Where robot `i` of an alliance starts. Seat 0 is the classic spot; seat 1 is
## 36 in further along the same wall, away from the LOADING ZONE.
func _start_pose(a: int, i: int) -> Transform3D:
	var red := a == BB.Alliance.RED
	var sx := -1.0 if red else 1.0
	var x := sx * (BB.FIELD_HALF - Robot.HALF - 0.5)
	var y := -sx * (4.0 - 36.0 * float(i))
	var yaw := (-PI * 0.5) if red else (PI * 0.5)
	return Transform3D(Basis(Vector3.UP, yaw), BB.fp(x, y, 0.0))

func _spawn_pollen(at: Vector3) -> GameElement:
	var e := GameElement.make(BB.Kind.POLLEN)
	_adopt(e)
	e.global_position = at
	e.exited_field.connect(mm.on_element_left_field)
	return e

func _spawn_nectar(a: int, at: Vector3) -> GameElement:
	var e := GameElement.make(BB.Kind.NECTAR, a)
	_adopt(e)
	e.global_position = at
	e.exited_field.connect(mm.on_element_left_field)
	return e

# ================================================================== routing ==

## THE ONE ROUTER.
##
## Every page's top navigation, every footer button and every deep link ("Set
## up" on Play, "Assign controllers") comes through here. It is also the only
## place that knows a match may be paused behind the menus, so going back to
## Play while one is running resumes it instead of throwing it away.
##
## EVERY ROUTE THROUGH HERE PAUSES A RUNNING MATCH. It used to be only the
## Esc/Start key that did, so walking to Garage, Progress or Settings from the
## nav bar left the robots driving and the clocks running behind the page.
##
## `tab` is the sub-page to land on: a Garage tab, or a Settings category.
func goto(page: String, tab := -1) -> void:
	# IN AN ONLINE ROOM the menus are personal: only Settings is reachable
	# (from the online menu), and every way back leads to the room.
	if net and net.in_room():
		for sc in [menu, robot_menu, progress, scenarios]:
			if sc != null and sc.is_open():
				sc.close()
		if page == "Settings":
			if tab >= 0:
				settings_menu.open_at(tab)
			else:
				settings_menu.open()
		else:
			settings_menu.close()
		return
	# LEAVING A TEST DRIVE GOES BACK WHERE IT CAME FROM. The player pressed
	# Test drive from Controls to feel a tuning change; dropping them on Play
	# loses the screen they were working on.
	if returning_to_controls and page == "Play" and mm.mode == BB.Mode.FREE_PRACTICE:
		returning_to_controls = false
		mm.abort()
		hud.visible = false
		settings_menu.open_at(3)
		return
	if mm.in_progress():
		mm.pause()
	var leaving_garage: bool = robot_menu != null and robot_menu.is_open()
	for screen in [menu, robot_menu, progress, settings_menu, scenarios]:
		if screen != null and screen.is_open():
			screen.close()
	# A profile, model or intake change means the robot has to be rebuilt — but
	# NEVER while a match is paused behind the menus: rebuilding frees the
	# robot the match, the camera and the stats are all holding, and the match
	# you came back for is gone. Mid-match the Garage's changes wait for the
	# next start, which is what its footer says they do.
	if leaving_garage and not mm.in_progress():
		_build_robots(robot.alliance, menu.robot_intakes)
		_apply_settings()
	match page:
		"Scenarios":
			scenarios.open()
		"Garage":
			robot_menu.open()
			if tab >= 0:
				robot_menu.show_tab(tab)
		"Progress":
			progress.open()
		"Settings":
			if tab >= 0:
				settings_menu.open_at(tab)
			else:
				settings_menu.open()
		_:
			# back on Play: a paused match is still there, so show the pause
			# menu over it rather than resuming behind the player's back or,
			# worse, throwing the run away
			if mm.in_progress():
				_open_pause_menu()
			else:
				# ONE source of truth for which face Play shows: whether a
				# match is actually running. Anything else leaves a phantom
				# pause menu over a field with nothing on the clock.
				menu.match_running = mm.in_progress()
				menu.naming = false
				menu.open()
				rig.mode = CameraRig.Mode.MENU

## THE OPTIONAL PRACTICE OVERLAY: one per AI brain while the setting is on,
## none at all while it is off. Rebuilt when the roster changes, since the
## brains are new objects then.
var _overlays: Array = []

func _sync_opponent_overlays() -> void:
	var want := Settings.is_on("game/opponent_overlay") and not BB.editing
	var live: Array = []
	for o in _overlays:
		if is_instance_valid(o) and is_instance_valid((o as OpponentOverlay).brain):
			live.append(o)
		elif is_instance_valid(o):
			(o as Node).queue_free()
	_overlays = live
	if not want:
		for o2 in _overlays:
			(o2 as Node).queue_free()
		_overlays.clear()
		return
	for b in ais:
		if not is_instance_valid(b):
			continue
		var has := false
		for o3 in _overlays:
			if (o3 as OpponentOverlay).brain == b:
				has = true
		if not has:
			var ov := OpponentOverlay.for_brain(b)
			_adopt(ov)
			_overlays.append(ov)

## TEST DRIVE, from the Controls screen.
##
## Free practice on an ordinary staged field with no clock and no objective, so
## there is nothing for it to record: `_on_match_finished` never fires for free
## practice, no attempt is armed, and no scenario is loaded. It exists purely
## so you can feel a tuning change without leaving the settings behind.
func _test_drive() -> void:
	if mm.in_progress() or (net and net.in_room()):
		return                       # a real run (or an online room) is behind this screen
	returning_to_controls = true
	settings_menu.close()
	menu.close()
	_forget_scenario()
	mm.mode = BB.Mode.FREE_PRACTICE
	menu.mode = BB.Mode.FREE_PRACTICE
	hud.visible = true
	await stage()
	_no_record_next = true
	mm.start()
	mm.log_event("TEST DRIVE - nothing here is recorded")
	rig.mode = CameraRig.Mode.DRIVER
	DriverInput.gate_all()

## True while a test drive launched from Controls is running, so leaving it
## goes back to Controls rather than to Play.
var returning_to_controls := false

## A seat lost its controller. Stop, and say which one.
func _on_device_lost(_seat: int, label: String) -> void:
	if net and net.in_room():
		net.on_device_lost(label)
		return
	if not mm.in_progress() or (viewer and viewer.is_open()):
		return
	mm.log_event("CONTROLLER DISCONNECTED - %s" % label.to_upper())
	lost_device_note = ("%s lost its controller. Plug it back in, check the "
		% label + "seat in Settings -> Controls, then resume.")
	_open_pause_menu()
	menu.pause_line = lost_device_note
	SFX.play("foul", -14.0)

## Set when a controller vanished mid-run, so the pause menu can say so.
var lost_device_note := ""

## Put the pause menu up over a running match, with the facts it needs.
##
## THE MENU PAUSES. It used to be the caller's job, and only the Esc/Start path
## remembered — so coming back to Play from Garage, Progress or Settings put
## the pause menu up over robots that were still driving and an objective clock
## that was still running. Pausing here means every route to this menu stops
## the match, and `MatchManager.pause()` is idempotent, so the paths that
## already paused are unaffected.
func _open_pause_menu() -> void:
	mm.pause()
	menu.match_running = true
	menu.naming = false
	menu.pause_line = _pause_line()
	# A draft under test is a situation too: Retry restores the test's own
	# starting state, so the pause menu must not claim there is nothing to
	# go back to.
	if editor_return and editor and editor.draft:
		menu.scenario_id = "draft"
		menu.scenario_name = editor.draft.name
	else:
		menu.scenario_id = scenario_id
		menu.scenario_name = _scenario_name()
	menu.testing_draft = editor_return
	menu.open()
	rig.mode = CameraRig.Mode.MENU

## Leave the menus and hand the field back with the clock where it was.
func _resume_match() -> void:
	# whatever was held down while the menus were up does not count as a fresh
	# press the moment the field comes back
	DriverInput.forget()
	for r in robots:
		if is_instance_valid(r):
			r.clear_inputs()
	mm.resume()
	rig.mode = CameraRig.Mode.DRIVER

# =================================================================== input ===

## Chosen from the title screen: set the mode, rebuild the roster if the
## alliance, the robot or the number of drivers changed, re-stage and go.
func _on_menu_start(m: int, a: int, intakes: int, o: Dictionary) -> void:
	# starting a fresh match leaves whatever situation was loaded behind
	_end_attempt("abandoned")
	_forget_scenario()
	mm.mode = m
	opts = o.duplicate()
	_build_robots(a, intakes)
	rig.alliance = robot.alliance
	_apply_settings()
	menu.close()
	rig.mode = CameraRig.Mode.DRIVER
	await stage()
	mm.start()
	_start_auto_routine()

# ================================================================== roster ===

## Builds the robots the chosen setup calls for and throws away the old ones.
##
## One or two on the driver's alliance, plus at most one opponent. Input devices
## are handed out in DriverInput.devices() order — pads first, keyboard last —
## so with two pads plugged in each driver gets one, with one pad the second
## driver falls back to the keyboard, and the AI opponent never takes a device
## away from a person.
func _build_robots(a: int, intakes: int) -> void:
	# Everything that keyed a dictionary on a ROBOT has to let go first. A
	# freed robot left as a key in the G407 bookkeeping or the stats table is a
	# "previously freed instance" error on every frame afterwards.
	for r in robots:
		if not is_instance_valid(r):
			continue
		# A robot that leaves the field drops what it was carrying. Without
		# this the balls stay owned by a freed robot: invisible, uncollectable
		# and unscoreable for the rest of the session.
		for e in r.hopper:
			if is_instance_valid(e):
				e.held_by = null
				e.set_collision_layer_value(BB.LAYER_ELEMENT, true)
				e.set_collision_mask_value(BB.LAYER_WORLD, true)
				e.set_collision_mask_value(BB.LAYER_ELEMENT, true)
				e.freeze = false
		r.hopper.clear()
		r.queue_free()
	robots.clear()
	if mm:
		mm.forget_robots()
	if stats:
		stats.per.clear()
	for old_ai in ais:
		if is_instance_valid(old_ai):
			old_ai.queue_free()
	ais.clear()
	ai = null
	opponent = null

	var foe := BB.Alliance.BLUE if a == BB.Alliance.RED else BB.Alliance.RED
	var n_ours: int = clampi(int(opts.get("robots", 1)), 1, 2)
	var mate_ai: bool = n_ours > 1 and bool(opts.get("mate_is_ai", false))
	var per: int = clampi(int(opts.get("per_robot", 1)), 1, 2)
	var n_foes: int = clampi(int(opts.get("opponents", 0)), 0, 2)
	var nectar: bool = bool(opts.get("takes_nectar", false))

	# Devices are handed out seat by seat, pads first and the keyboard last, in
	# the order a person would expect: robot 1's driver, then robot 1's
	# operator, then robot 2's. Run out and the remaining seats get NONE, which
	# reads as zero rather than quietly doubling up on someone else's controls.
	# Seats are filled from this list in order. NOT via a lambda counter:
	# GDScript closures capture locals by VALUE, so an incrementing `seat`
	# inside one never advances the outer variable — every seat silently got
	# the same controller, which means two robots moving as one and no clue
	# why.
	# Settings works out the WHOLE allocation in one go, because a pinned seat
	# and an automatic one can want the same controller and only one of them
	# can have it.
	var pool := DriverInput.devices()
	var human_robots := n_ours - (1 if mate_ai else 0)
	_seat_devices = Settings.allocate_devices(human_robots * per, pool)
	# Tell Settings who ended up holding what, so a controller vanishing can
	# name the seat that lost it, and hand each seat's PROFILE to the input
	# layer keyed by the device that seat is actually using.
	var _plan := Settings.seat_plan(n_ours, mate_ai, per)
	Settings.note_live_seats(_plan, _seat_devices)
	Settings.push_profiles(_plan, _seat_devices)
	DriverInput.gate_all()   # nothing held across a rebuild counts as a press
	_seat_next = 0

	# ONLINE ROSTERS can say, robot by robot, who drives: `ai_mask` (ours
	# first, then the opponents'). Offline setups never carry one, so the
	# classic rules below — robot 1 is a person, a teammate may be AI,
	# opponents are AI — are unchanged.
	var mask: Array = opts.get("ai_mask", []) if opts.get("ai_mask") is Array else []
	for i in n_ours:
		var r := Robot.make(a, intakes, true)
		r.driver_label = "P%d" % (i + 1)
		r.realistic_power = true
		r.takes_nectar = nectar
		var is_mate_ai := mate_ai and i == 1
		if i < mask.size():
			is_mate_ai = bool(mask[i])
		if is_mate_ai:
			r.ai_driver = true
			r.driver_label = "MATE"
			r.device = DriverInput.NONE
			r.op_device = DriverInput.NONE
		else:
			r.device = _take_seat(pool)
			r.op_device = _take_seat(pool) if per > 1 else r.device
		RobotShop.apply(r)
		_adopt(r)
		r.teleport(_start_pose(a, i))
		r.recalibrated.connect(_on_recalibrated)
		robots.append(r)
		if is_mate_ai:
			_attach_ai(r, robots[0])

	robot = robots[0]

	for i in n_foes:
		var foe_bot := Robot.make(foe, 1)
		var foe_ai := true
		if n_ours + i < mask.size():
			foe_ai = bool(mask[n_ours + i])
		foe_bot.ai_driver = foe_ai
		foe_bot.device = DriverInput.NONE
		foe_bot.op_device = DriverInput.NONE
		foe_bot.driver_label = "OPP%d" % (i + 1)
		foe_bot.realistic_power = true
		foe_bot.takes_nectar = nectar
		RobotShop.apply(foe_bot)
		_adopt(foe_bot)
		foe_bot.teleport(_start_pose(foe, i))
		robots.append(foe_bot)
		if foe_ai:
			_attach_ai(foe_bot, robot)
		if opponent == null:
			opponent = foe_bot

	mm.robot = robot
	mm.robots = robots
	if stats:
		for r in robots:
			stats.track(r)
	if hud:
		hud.robot = robot
		hud.robots = robots
	if rig:
		rig.target = robot
		rig.robots = robots

## Push the title-screen sliders onto the robot. Called when the match starts,
## when the pause menu closes, and live while a slider is being dragged.
## Hand the robot its saved routine for the AUTO period, if one is selected.
func _start_auto_routine() -> void:
	auto_player.stop_play()
	if mm.phase != BB.Phase.AUTO or robot_menu.active_auto == "":
		return
	var rt := AutoRoutine.load_named(robot_menu.active_auto)
	if rt == null:
		return
	auto_player.begin_play(robot, rt)
	mm.log_event("AUTO ROUTINE: %s" % robot_menu.active_auto)

func _apply_settings() -> void:
	if menu == null:
		return
	for r in robots:
		if not is_instance_valid(r):
			continue
		RobotShop.apply(r)

## The launcher reset itself (or the driver asked): put it in the event log so
## it is visible rather than mysterious.
## A finished match goes on the leaderboard, under the variant that drove it.
## Free practice never ends, so it never records.
func _on_match_finished(result: Dictionary) -> void:
	if net_room != null:
		# an online room: the result goes to the players, never to this
		# machine's history or leaderboard
		if net_room:
			net_room.on_match_finished(result)
		return
	if mm.mode == BB.Mode.FREE_PRACTICE:
		return
	# the full report, plus each driver's own numbers
	var sums: Array = []
	for r in robots:
		if is_instance_valid(r) and not r.ai_driver:
			var sm := stats.summary(r)
			if not sm.is_empty():
				sums.append(sm)
	results.show_result(result.get("breakdown", {}), result.get("rp", {}),
		mm.scoring, sums)
	# A SITUATION ATTEMPT IS NOT A MATCH. It started mid-run from a saved
	# state, so its score is not comparable with anyone's full match: it goes
	# on neither the leaderboard nor the match history.
	if scenario_run:
		return
	RobotShop.log_match(result, sums, mm.mode)
	var b: Dictionary = result.get("breakdown", {})
	if not b.has(robot.alliance):
		return
	Leaderboard.submit(Leaderboard.player_name(), int(b[robot.alliance]["total"]),
		robot.intakes, "FULL MATCH" if mm.mode == BB.Mode.FULL_MATCH else "TELEOP")

## GUIDED RECORDING.
##
## Sets the field, counts the driver in, records exactly one AUTO period, and
## then offers to keep it. Free practice underneath, so nothing about the match
## clock interferes — but the recording window is the real AUTO_S, so what you
## record is what will fit.
func _guided_record() -> void:
	menu.close()
	rig.mode = CameraRig.Mode.DRIVER
	mm.mode = BB.Mode.FREE_PRACTICE
	await stage()
	_no_record_next = true
	mm.start()
	auto_player.stop_play()
	for n in [3, 2, 1]:
		mm.log_event("RECORDING IN %d..." % n)
		SFX.play("click", -10.0)
		# process_always = FALSE: a count-in that keeps counting behind a pause
		# menu starts the recording while nobody is driving
		await get_tree().create_timer(1.0, false).timeout
	mm.log_event("RECORDING - drive your auto")
	SFX.play("start", -8.0)
	auto_player.begin_record(robot)
	recording_left = BB.AUTO_S
	var t := BB.AUTO_S
	while t > 0.0 and auto_player.recording:
		await get_tree().create_timer(0.1, false).timeout   # pauses with the world
		t -= 0.1
		recording_left = t
	recording_left = 0.0
	if not auto_player.recording:
		return                       # driver stopped it early with the key
	var rt := auto_player.stop_record()
	SFX.play("buzzer", -8.0)
	mm.log_event("RECORDING DONE - %.1f s" % rt.length_s())
	mm.abort()
	if rt.frames.is_empty():
		menu.open()
		rig.mode = CameraRig.Mode.MENU
		return
	robot_menu.offer_save(rt)

## Next free input device, or NONE once they run out.
var _seat_next := 0
var _seat_devices: Array = []
func _take_seat(_pool: Array) -> int:
	var v: int = _seat_devices[_seat_next] if _seat_next < _seat_devices.size() \
		else DriverInput.NONE
	_seat_next += 1
	return v

## Give a robot a brain. Kept in one place so opponents and teammates are
## driven by exactly the same code — the only difference is which colour they
## are and who they treat as the rival.
func _attach_ai(r: Robot, rival: Robot) -> void:
	var brain := AIDriver.new()
	brain.name = "AI_" + r.driver_label
	brain.robot = r
	brain.field = field
	brain.rival = rival
	brain.roster_owner = self      # a defender finds its target by roster index
	_adopt(brain)
	ais.append(brain)
	if ai == null:
		ai = brain

## RECORDING AN AUTO.
##
## Only in free practice: a routine recorded while a match clock was running
## would be thirty seconds out of a two minute run and would not line up with
## anything. Stopping saves it under a name derived from the clock; it can be
## picked or deleted on the ROBOT screen.
func _toggle_record() -> void:
	if not mm.free_practice():
		mm.log_event("RECORD: free practice only")
		SFX.play("foul", -14.0)
		return
	if auto_player.recording:
		var rt := auto_player.stop_record()
		var stamp := Time.get_datetime_string_from_system(true)
		var n := "auto-%s" % stamp.substr(5, 11).replace(":", "").replace("T", "-")
		if rt and rt.frames.size() > 0 and rt.save_as(n):
			mm.log_event("AUTO SAVED: %s (%.1f s)" % [n, rt.length_s()])
			robot_menu.active_auto = n
			SFX.play("select", -10.0)
		else:
			mm.log_event("AUTO: nothing recorded")
		return
	auto_player.begin_record(robot)
	mm.log_event("RECORDING AUTO - press P again to stop")
	SFX.play("start", -12.0)

func _on_recalibrated(reason: String) -> void:
	if mm:
		mm.log_event("TURRET RECALIBRATED (%s)" % reason)

## F3 anywhere: a small performance readout (frames per second and frame
## time). Mostly for checking the browser version on slow laptops.
var _perf: Label
var _perf_t := 0.0

func _input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo and ev.keycode == KEY_F3:
		if _perf == null:
			var layer := CanvasLayer.new()
			layer.layer = 100
			add_child(layer)
			_perf = Label.new()
			_perf.add_theme_font_size_override("font_size", 16)
			_perf.add_theme_color_override("font_color", Color(0.75, 1.0, 0.6))
			_perf.add_theme_constant_override("outline_size", 6)
			_perf.add_theme_color_override("font_outline_color", Color.BLACK)
			# top centre, under the match clock: clear of both score panels
			_perf.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP,
				Control.PRESET_MODE_MINSIZE)
			_perf.grow_horizontal = Control.GROW_DIRECTION_BOTH
			_perf.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			_perf.offset_top = 118
			_perf.visible = false
			layer.add_child(_perf)
		_perf.visible = not _perf.visible

func _update_perf(d: float) -> void:
	if _perf == null or not _perf.visible:
		return
	_perf_t -= d
	if _perf_t > 0.0:
		return
	_perf_t = 0.25
	var fps := Engine.get_frames_per_second()
	var q := Settings.matching_preset()
	_perf.text = "%d fps · %.1f ms · physics %d Hz · %s %d%%%s" % [fps,
		1000.0 / maxf(fps, 1.0), Engine.physics_ticks_per_second,
		(Settings.QUALITY_NAMES[q] if q < 4 else "Custom"),
		roundi(get_viewport().scaling_3d_scale * 100.0),
		" · browser" if OS.has_feature("web") else ""]

func _unhandled_input(ev: InputEvent) -> void:
	if signin and signin.is_open():
		return
	# The replay viewer has its own controls; nothing reaches gameplay.
	if viewer and viewer.is_open():
		return
	# Online, this computer drives nothing directly: the client sends inputs.
	if net and net.active():
		return
	# The editor owns every key while it is up: no driving, no firing, no
	# camera cycling, no resetting the field by accident.
	if editor and editor.is_open():
		return
	# A test can be PRE (a newly staged draft), running, or already finished.
	# Escape always returns to its unchanged draft, even over a results screen.
	if editor_return and (ev.is_action_pressed("pause") or (
			ev is InputEventKey and ev.pressed and not ev.echo
			and (ev.keycode == KEY_ESCAPE or ev.physical_keycode == KEY_ESCAPE))):
		get_viewport().set_input_as_handled()
		return_to_editor()
		return
	# ESC anywhere in the menus goes back to Play, which resumes a paused match
	for screen in [settings_menu, robot_menu, progress]:
		if screen != null and screen.is_open():
			if ev.is_action_pressed("pause"):
				goto("Play")
			return
	if attempt_results and attempt_results.is_open():
		return
	if results and results.is_open():
		return
	if ev.is_action_pressed("pause"):
		if menu.is_open():
			_apply_settings()
			menu.close()
			if mm.in_progress():
				_resume_match()
			else:
				rig.mode = CameraRig.Mode.DRIVER
			return
		if mm.in_progress():
			# PAUSE, not abort: the clock stops and the robots switch off, and
			# the same match is still there when you come back.
			mm.pause()
			_open_pause_menu()
			return
		# Not in a match and no menu up. The controller shares one button
		# between pause and start, so fall through and let START start one.
	if menu.is_open():
		return
	if ev.is_action_pressed("start_match") and (mm.phase == BB.Phase.PRE or mm.phase == BB.Phase.DONE):
		mm.start()
	elif ev.is_action_pressed("reset"):
		stage()
	elif ev.is_action_pressed("cam_toggle"):
		rig.cycle()
	elif ev.is_action_pressed("skip_auto"):
		mm.skip_auto()
	elif ev.is_action_pressed("record_auto"):
		_toggle_record()
	elif ev.is_action_pressed("save_situation"):
		capture_situation()
	elif ev.is_action_pressed("retry_scenario"):
		retry_situation()

func _process(_d: float) -> void:
	_update_perf(_d)
	# NOT while a situation is being restored: the brains exist before their
	# saved settings are applied, and an overlay built then would draw the
	# default route rather than the real one.
	if BB.frozen():
		return
	_sync_opponent_overlays()
	if BB.halted:
		return
	# Motors are only heard for the robot you are actually watching. Three
	# drivetrains and three intakes at once is mud, and the one that matters is
	# the one on screen.
	var ear: Node3D = rig.focus() if rig else null
	for r in robots:
		if is_instance_valid(r):
			r.audible = (r == robot or r == ear) and not menu.is_open()
	if menu.is_open():
		return
	# A manual nudge steers by hand for a couple of seconds, then auto-aim
	# quietly takes back over rather than staying off forever.
	#
	# The AI opponent is in this loop too. It has the same turret automation a
	# driver does, and without it `aim_locked` never goes true, so the bot
	# drives to its shooting spot, stands there and never fires a single ball.
	for r in robots:
		if is_instance_valid(r) and r.auto_aim and not r.manual_aim():
			_auto_target(r)
	# firing is handled per driver inside Robot._read_input now

## AUTO-TARGETING.
##
## Locks the turret onto the nearest raised CELL of the robot's own colour. The
## CELL's only opening faces outboard, so which side of the field the robot is
## standing on decides whether there is a shot at all: a cell whose mouth points
## away is picked only if nothing better exists, and the HUD says so rather than
## letting the driver fire into the back of a box.
func _auto_target(r: Robot) -> void:
	var best: Hive = null
	var best_score := -1.0
	for a in field.hives:
		var h: Hive = field.hives[a]
		if h.alliance != r.alliance:
			continue
		var d := r.global_position.distance_to(h.aim_point())
		var open := h.has_line_from(r.global_position)
		# a cell we can actually shoot into always beats a closer one we cannot
		var score := (1000.0 if open else 0.0) - d
		if score > best_score:
			best_score = score
			best = h
	if best == null:
		r.aim_locked = false
		return
	r.aim_dist_in = r.global_position.distance_to(best.aim_point()) / BB.IN
	r.aim_blocked = not best.has_line_from(r.global_position)
	r.aim_locked = r.aim_at(best.aim_point(), best.preferred_arrival(), best.aperture()) \
		and not r.aim_blocked

## G410 watchdog: a NECTAR crossing into a FLOWER's scoring volume early is a
## MAJOR foul against whoever launched it. The achievement still scores.
func _on_flower_entry(body: Node3D) -> void:
	if not (body is GameElement):
		return
	var e: GameElement = body
	if e.kind != BB.Kind.NECTAR:
		return
	var by: int = e.last_launcher.alliance if e.last_launcher is Robot else robot.alliance
	mm.check_flower_entry(e, by)

# ============================================================== situations ===
#
# SAVE -> LIBRARY -> PLAY FROM HERE -> RETRY.
#
# The whole loop lives here because it is the world that gets captured and the
# world that gets put back. `Snapshot` knows the format; `ScenarioLibrary`
# knows the files; this knows when.

## Freeze the match and put the naming card up. Reachable from the save key or
## from the pause menu; both land here.
func capture_situation() -> void:
	if not mm.in_progress() and mm.phase != BB.Phase.PRE:
		return
	# Capture at a PHYSICS BOUNDARY, not mid-frame: waiting for the next
	# physics frame means every body has finished integrating, so the poses and
	# velocities written to the file are a consistent set rather than a mix of
	# before and after.
	await get_tree().physics_frame
	mm.pause()
	_pending_capture = Snapshot.capture(self)
	menu.match_running = true
	menu.pause_line = _pause_line()
	# A draft under test is a situation too: Retry restores the test's own
	# starting state, so the pause menu must not claim there is nothing to
	# go back to.
	if editor_return and editor and editor.draft:
		menu.scenario_id = "draft"
		menu.scenario_name = editor.draft.name
	else:
		menu.scenario_id = scenario_id
		menu.scenario_name = _scenario_name()
	menu.testing_draft = editor_return
	menu.open()
	menu.begin_naming()
	rig.mode = CameraRig.Mode.MENU
	SFX.play("select", -14.0)

var _pending_capture: Dictionary = {}

## The player named it. Write it, and adopt it as the situation this run is
## attempting so Retry has somewhere to go.
func _save_situation(name: String, note: String, overwrite: String) -> void:
	if _pending_capture.is_empty():
		_pending_capture = Snapshot.capture(self)
	var id := ScenarioLibrary.save(_pending_capture, name, note, overwrite)
	if id == "":
		menu._s["foot_note"].text = "Could not write that situation to disk."
		SFX.play("foul", -16.0)
		menu.refresh()
		return
	# The saved file is now this run's situation, so Retry goes back HERE.
	var entry := ScenarioLibrary.load_one(id)
	scenario_source = entry["data"] if entry["error"] == "" else _pending_capture
	scenario_id = id
	scenario_run = true
	_pending_capture = {}
	menu.scenario_id = id
	menu.scenario_name = name
	menu._s["foot_note"].text = 'Saved "%s". Retry comes back to it.' % name
	menu.refresh()

## Load a situation from the library and hand the player the field.
func play_situation(id: String) -> void:
	var entry := ScenarioLibrary.load_one(id)
	if String(entry["error"]) != "":
		scenarios._s["foot_note"].text = String(entry["error"])
		SFX.play("foul", -16.0)
		return
	scenario_source = entry["data"]
	scenario_id = id
	scenario_run = true
	menu.scenario_id = id
	menu.scenario_name = String(entry["name"])
	for screen in [menu, robot_menu, progress, settings_menu, scenarios]:
		if screen != null and screen.is_open():
			screen.close()
	await _restore_and_play()

## Put the ORIGINAL snapshot back. Never the last save, never the current
## field: the situation you have been practising, exactly as it was.
func retry_situation() -> void:
	if scenario_source.is_empty():
		return
	# One retry, one new attempt: the old one is closed out as abandoned
	# before the field is restored, never left running to finish twice.
	_end_attempt("abandoned")
	attempt_results.close()
	for screen in [menu, robot_menu, progress, settings_menu, scenarios]:
		if screen != null and screen.is_open():
			screen.close()
	SFX.play("start", -12.0)
	await _restore_and_play()

## The shared tail: restore while paused, then hand control back only once the
## field has settled into its restored pose.
func _restore_and_play() -> void:
	menu.match_running = false
	results.close()
	var problems: Array = await Snapshot.restore(self, scenario_source)
	rig.alliance = robot.alliance
	rig.target = robot
	rig.robots = robots
	rig.mode = CameraRig.Mode.DRIVER
	_apply_settings()
	hud.robot = robot
	hud.robots = robots
	mm.resume()
	for line in problems:
		mm.log_event("SITUATION: %s" % String(line))
	mm.log_event("SITUATION LOADED - %s" % _scenario_name())
	_start_attempt()
	recorder.begin(_replay_context("editor_test" if editor_return else "situation"))

func _scenario_name() -> String:
	if scenario_id == "":
		return ""
	var meta: Dictionary = scenario_source.get("meta", {})
	return String(meta.get("name", scenario_id))

func _forget_scenario() -> void:
	scenario_source = {}
	scenario_id = ""
	scenario_run = false
	_pending_capture = {}
	if menu:
		menu.scenario_id = ""
		menu.scenario_name = ""

## One line for the pause menu: where the match actually is.
func _pause_line() -> String:
	var names := ["Pre-match", "Autonomous", "Transition", "Teleop",
		"Settling", "Finished"]
	var phase: String = names[clampi(mm.phase, 0, names.size() - 1)]
	var b := mm.scoring.breakdown(field, false)
	var ours: int = int(b.get(robot.alliance, {}).get("total", 0))
	if mm.free_practice():
		return "%s · no clock · %d points" % [phase, ours]
	return "%s · %s left · %d points" % [phase, BB.clock_text(mm.time_left), ours]


# ========================================================= scenario creator ==

## Start a new draft. `source` is "staged", "empty", or a library id.
func _create_scenario(source: String) -> void:
	var draft: ScenarioDraft
	if source == "empty":
		await _reset_for_authoring()
		draft = ScenarioDraft.empty_field(self)
	elif source == "staged":
		await _reset_for_authoring()
		draft = ScenarioDraft.staged(self)
	else:
		var entry := ScenarioLibrary.load_one(source)
		if String(entry["error"]) != "":
			scenarios._s["foot_note"].text = String(entry["error"])
			return
		draft = ScenarioDraft.from_snapshot(entry["data"],
			String(entry["name"]) + " copy", String(entry["note"]), "")
	await open_editor(draft)

## Edit a saved situation in place — Save writes back to the same entry.
func _edit_scenario(id: String) -> void:
	var entry := ScenarioLibrary.load_one(id)
	if String(entry["error"]) != "":
		scenarios._s["foot_note"].text = String(entry["error"])
		return
	await open_editor(ScenarioDraft.from_snapshot(entry["data"],
		String(entry["name"]), String(entry["note"]), id))

## A clean staged field to author from, without disturbing a match in progress
## (there is none: the editor is only reachable from the library).
func _reset_for_authoring() -> void:
	mm.abort()
	mm.mode = BB.Mode.FULL_MATCH
	opts = {"robots": 1, "mate_is_ai": false, "per_robot": 1,
		"opponents": 0, "takes_nectar": false}
	_build_robots(BB.Alliance.RED, 1)
	await stage()

func open_editor(draft: ScenarioDraft) -> void:
	_forget_scenario()
	editor_return = false
	for screen in [menu, robot_menu, progress, settings_menu, scenarios]:
		if screen != null and screen.is_open():
			screen.close()
	results.close()
	hud.visible = false
	await editor.open(draft)

## TEST. Runs an immutable copy of the draft as an ordinary situation attempt:
## Retry restores the test's own starting state, and nothing it does can reach
## back into the draft or the saved file.
func _test_scenario(snapshot: Dictionary) -> void:
	editor.close()
	hud.visible = true
	editor_return = true
	menu.testing_draft = true
	results.offer_editor = true
	scenario_source = snapshot.duplicate(true)
	scenario_id = ""
	scenario_run = true
	menu.scenario_id = "draft"
	menu.scenario_name = editor.draft.name
	await _restore_and_play()

## Back to authoring, with the draft exactly as it was before the test.
func return_to_editor() -> void:
	if editor == null or editor.draft == null:
		return
	_end_attempt("abandoned")
	attempt_results.close()
	mm.abort()
	results.close()
	menu.close()
	menu.match_running = false
	hud.visible = false
	_forget_scenario()
	editor_return = false
	menu.testing_draft = false
	results.offer_editor = false
	await editor.reopen()


# ================================================================= attempts ==
#
# An objective attempt wraps a situation run. It starts when the field is
# handed back to the player, it is abandoned by a retry or an exit, and it
# finishes exactly once.

## Arm a new attempt, if the situation that was just loaded asks for one.
func _start_attempt() -> void:
	_end_attempt("abandoned")
	var obj: Dictionary = scenario_source.get("objective", {})
	if not Objective.is_set(obj):
		objective_hud.hide_card()
		return
	var sig := AttemptLog.signature(scenario_source, obj)
	attempt = Attempt.new()
	attempt.name = "Attempt"
	_adopt(attempt)
	attempt.finished.connect(_on_attempt_finished)
	attempt.begin(self, obj, {
		"attempt_no": AttemptLog.group(sig).size() + 1,
		"scenario_id": scenario_id,
		"scenario_name": _scenario_name() if scenario_id != ""
			else (editor.draft.name if editor and editor.draft else "Draft"),
		"signature": sig,
		"from_editor": editor_return,
	})
	objective_hud.follow(attempt)

## Stop the current attempt if one is running. Recording an abandon is the
## point: a retry two seconds in is not a completed attempt and must not look
## like one.
func _end_attempt(why: String) -> void:
	if attempt != null and is_instance_valid(attempt):
		if not attempt.is_done():
			attempt.abandon(why)
		attempt.queue_free()
	attempt = null
	objective_hud.hide_card()

func _on_attempt_finished(rec: Dictionary) -> void:
	# The recording ends with the attempt, and carries its outcome.
	recorder.note_attempt(rec)
	if net_room != null:
		# online: no local attempt history on the server; the room tells the
		# players and pauses everyone together
		if net_room:
			net_room.on_attempt_finished(rec)
		return
	# the best BEFORE this one, so the comparison line is about improvement
	var sig := String(rec.get("signature", ""))
	var previous := AttemptLog.best(sig)
	AttemptLog.add(rec)
	var summary := AttemptLog.summary(sig)
	if String(rec.get("state", "")) == "abandoned":
		return                       # logged, but nobody wants a screen for it
	mm.pause()
	rig.mode = CameraRig.Mode.MENU
	objective_hud.hide_card()
	attempt_results.show_attempt(rec, previous, summary, editor_return)


# ================================================================= replays ===
#
# RECORD EVERY RUN -> WATCH IT -> PRACTISE FROM A RECORDED MOMENT.

## A run was put on the clock from the menus, the results screen or the start
## key. Situations are armed in `_restore_and_play` instead, because they
## resume rather than start.
func _on_match_started() -> void:
	if net_room != null:
		return                       # the room arms its own recording
	if _no_record_next:
		_no_record_next = false
		return
	recorder.begin(_replay_context("match"))

## The run a results screen is showing. Its recording is normally finished
## already; if the deferred finish has not run yet, finish it now.
func _this_runs_replay() -> String:
	if recorder.is_recording():
		return recorder.finish("finished" if mm.phase == BB.Phase.DONE else "abandoned",
			"results shown")
	return recorder.last_id

func _replay_context(kind: String) -> Dictionary:
	var names := {BB.Mode.FULL_MATCH: "Full match", BB.Mode.TELEOP_ONLY: "Teleop only",
		BB.Mode.FREE_PRACTICE: "Free practice"}
	var mode_name := String(names.get(mm.mode, "Match"))
	var sname := ""
	var title := mode_name
	if kind == "situation":
		sname = _scenario_name()
		title = sname if sname != "" else "Situation"
	elif kind == "editor_test":
		sname = editor.draft.name if editor and editor.draft else "Draft"
		title = "Editor test: %s" % sname
	if attempt != null and is_instance_valid(attempt) and kind != "match":
		title += " — attempt %d" % attempt.attempt_no
	return {"kind": kind, "mode": mm.mode, "mode_name": mode_name,
		"title": title, "scenario_id": scenario_id, "scenario_name": sname,
		"our_alliance": robot.alliance if is_instance_valid(robot) else BB.Alliance.RED}

## Recording hit a problem. The run carries on; the player is told, on the
## HUD and in the event log, exactly how much was saved.
func _on_replay_problem(text: String) -> void:
	if hud:
		hud.notice(text)
	mm.log_event(text.substr(0, 90))

## OPEN THE VIEWER. Only from a results screen or the Progress library, and
## never over a run that is still paused behind the menus: that session is
## the player's to resume or end, and it is never discarded to make room.
## Returns "" or a sentence to show where the request came from.
func watch_replay(id: String, back_to: String, practise := false) -> String:
	if viewer.is_open():
		return ""
	if id == "":
		var why := recorder.last_note if recorder.last_note != "" else \
			"Nothing was played, so there is nothing to watch."
		return "This run has no replay. " + why
	if recorder.state == ReplayRecorder.State.RECORDING and recorder.id == id:
		recorder.finish("finished" if mm.phase == BB.Phase.DONE else "abandoned")
	if back_to == "progress" and mm.in_progress():
		return ("A run is paused behind this screen. Resume it or end it from the "
			+ "pause menu first — it has not been touched.")
	if back_to == "progress" and editor and editor.is_open():
		return "Close the scenario editor first."
	var path := ReplayStore.recording_path(id)
	# check the file before anything on the field is touched
	var probe := ReplayReader.new()
	var perr := probe.open(path)
	probe.close()
	if perr != "":
		return perr
	_viewer_back = back_to
	for screen in [menu, robot_menu, progress, settings_menu, scenarios]:
		if screen != null and screen.is_open():
			screen.close()
	results.close()
	attempt_results.close()
	objective_hud.hide_card()
	hud.visible = false
	for o in _overlays:
		if is_instance_valid(o):
			(o as Node).queue_free()
	_overlays.clear()
	var err: String = await viewer.open(path)
	if err != "":
		await _leave_replay_world()
		_back_from_viewer()
		return err
	if practise:
		viewer.flash("Scrub to the moment you want, then press Practise from here.")
	return ""

func _on_viewer_closed(reason: String, payload: Dictionary) -> void:
	if reason == "practise":
		var sid := String(payload.get("id", ""))
		mm.abort()
		BB.set_viewing(false)
		hud.visible = true
		if String(payload.get("action", "play")) == "edit":
			await _edit_scenario(sid)
		else:
			await play_situation(sid)
		return
	await _leave_replay_world()
	_back_from_viewer()

func _back_from_viewer() -> void:
	match _viewer_back:
		"results":
			hud.visible = true
			results.reopen()
		"attempt_results":
			hud.visible = true
			attempt_results.reopen()
		_:
			goto("Progress")
			progress.show_replays()

## Hand the field back to the game. The viewer left every body frozen where
## the recording put it; the world is re-staged rather than resumed, because
## a replay's poses are a picture, not a run.
func _leave_replay_world() -> void:
	mm.abort()
	for r in robots:
		if is_instance_valid(r):
			r.enabled = false
	BB.set_viewing(false)
	for r2 in robots:
		if is_instance_valid(r2):
			r2.release_from_restore(Vector3.ZERO, Vector3.ZERO)
	for a in field.hives:
		(field.hives[a] as Hive).release_from_restore({})
	await stage()
	rig.mode = CameraRig.Mode.MENU
	hud.visible = true
