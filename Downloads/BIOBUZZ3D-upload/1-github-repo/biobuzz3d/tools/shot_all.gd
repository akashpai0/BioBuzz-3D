extends Node
## CAPTURES EVERY MENU SCREEN AND SUBTAB, and checks that nothing interactive
## falls off the canvas. One window size per run (--resolution), because
## resizing from inside under a virtual display is not reliable enough to test
## with.
##
## It fakes a match history and a saved routine so the populated states can be
## looked at, and puts the real files back before it exits.

var main: Node3D
var fails := 0
var win: Vector2i
var rect: Rect2

const HIST := "user://robot_history.json"
const HIST_BAK := "user://robot_history.bak"

## THE PROFILE STATE IS DECLARED, NEVER INHERITED.
##
## An independent review ran this harness against a clean profile and got a
## folder of screenshots that were all the first-run name dialog with the
## intended screen behind it — and the harness reported PASS for every one of
## them, because every widget it measured was on the canvas. It was measuring
## bounds and calling that a screenshot.
##
## So: run with `-- fresh` to capture the first-run state deliberately, or with
## no argument to capture the signed-in game. Either way the harness SAYS which
## it is, forces it rather than hoping, and every capture now checks that the
## screen it named is the screen actually in front.
var fresh_profile := false
var _saved_name := ""
const NAME_FOR_SHOTS := "Screenshot"

func _ready() -> void:
	fresh_profile = OS.get_cmdline_user_args().has("fresh")
	_saved_name = Leaderboard.player_name()
	if fresh_profile:
		Leaderboard.set_player_name("")
	elif not Leaderboard.signed_in():
		Leaderboard.set_player_name(NAME_FOR_SHOTS)
	_fake_history()
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(2.0).timeout
	print("\n  PROFILE: %s" % ("FIRST RUN (no name saved)" if fresh_profile
		else "signed in as \"%s\"" % Leaderboard.player_name()))
	if fresh_profile:
		await _first_run_only()
		return
	_ok_true("no first-run dialog is covering the game",
		main.signin == null or not main.signin.is_open())
	win = DisplayServer.window_get_size()
	rect = get_viewport().get_visible_rect()
	print("\n=== MENUS AT %dx%d (canvas %dx%d) ===" % [
		win.x, win.y, int(rect.size.x), int(rect.size.y)])

	# ---- PLAY, one shot per mode
	main.goto("Play")
	await _shot("play_full", main.menu._root)
	main.menu._pick_mode(BB.Mode.TELEOP_ONLY)
	await _shot("play_teleop", main.menu._root)
	main.menu._pick_mode(BB.Mode.FREE_PRACTICE)
	await _shot("play_free", main.menu._root)
	main.menu._pick_mode(BB.Mode.FULL_MATCH)
	# the busy roster: two robots, two people each, two opponents, blue
	main.menu.robots = 2
	main.menu.per_robot = 2
	main.menu.opponents = 2
	main.menu._pick_alliance(BB.Alliance.BLUE)
	await _shot("play_busy", main.menu._root)
	main.menu.robots = 1
	main.menu.per_robot = 1
	main.menu.opponents = 0
	main.menu._pick_alliance(BB.Alliance.RED)

	# ---- GARAGE
	main.goto("Garage", 0)
	await _shot("garage_hardware", main.robot_menu._root)
	RobotShop.source = RobotShop.Source.MEASURED
	RobotShop.use_specs = true
	main.robot_menu.show_tab(0)
	await _shot("garage_calibrate", main.robot_menu._root)
	RobotShop.source = RobotShop.Source.STOCK
	RobotShop.use_specs = false
	RobotShop.save_cfg()
	main.robot_menu.show_tab(1)
	await _shot("garage_appearance", main.robot_menu._root)
	main.robot_menu.show_tab(2)
	await _shot("garage_auto_empty", main.robot_menu._root)
	_fake_routine()
	main.robot_menu.active_auto = "practice-left"
	main.robot_menu.show_tab(2)
	await _shot("garage_auto_saved", main.robot_menu._root)

	# ---- PROGRESS
	main.goto("Progress")
	await _shot("progress", main.progress._root)
	main.progress._board = true
	main.progress.refresh()
	await _shot("progress_board", main.progress._root)

	# ---- SETTINGS
	for i in 4:
		main.goto("Settings", i)
		await _shot("settings_%d" % i, main.settings_menu._root)
	# the Controls sub-tabs, one capture each: seats, feel, buttons, profiles
	for t in main.settings_menu.CTL_TABS.size():
		main.settings_menu.show_controls_tab(t)
		await _shot("controls_%s" % String(main.settings_menu.CTL_TABS[t]).to_lower(),
			main.settings_menu._root)
	main.settings_menu.show_controls_tab(0)

	# ---- SITUATIONS: the empty shelf, then a stocked one
	for entry in ScenarioLibrary.list_all():
		ScenarioLibrary.delete_one(String(entry["id"]))
	main.goto("Scenarios")
	await _shot("situations_empty", main.scenarios._root)
	_fake_situations()
	main.scenarios.refresh()
	await _shot("situations", main.scenarios._root)

	# ---- the pause menu and the naming card, over a running match
	main.goto("Play")
	main._on_menu_start(BB.Mode.FULL_MATCH, BB.Alliance.RED, 1,
		{"robots": 1, "mate_is_ai": false, "per_robot": 1, "opponents": 0,
		 "takes_nectar": false})
	await get_tree().create_timer(2.5).timeout
	main.scenario_id = ScenarioLibrary.list_all()[0]["id"]
	main.scenario_source = ScenarioLibrary.list_all()[0]["data"]
	main.scenario_run = true
	main.mm.pause()
	main._open_pause_menu()
	await _shot("play_paused", main.menu._root)
	main.menu.begin_naming()
	await _shot("play_naming", main.menu._root)
	main.menu.naming = false
	main.mm.abort()
	main._forget_scenario()
	main.menu.match_running = false
	for entry2 in ScenarioLibrary.list_all():
		ScenarioLibrary.delete_one(String(entry2["id"]))

	# ---- THE SCENARIO CREATOR
	for entry3 in ScenarioLibrary.list_all():
		ScenarioLibrary.delete_one(String(entry3["id"]))
	await main._create_scenario("staged")
	main.editor.draft.name = "Endgame scramble"
	main.editor._name_edit.text = "Endgame scramble"
	main.editor.draft.set_scenario("phase", BB.Phase.TELEOP)
	main.editor.draft.set_scenario("time_left", 20.0)
	main.editor._refresh_all()
	await _shot("editor", main.editor._root)

	main.editor._selected = "robot:0"
	main.editor._refresh_all()
	await _shot("editor_robot", main.editor._root)

	# ---- practice opponents: one capture per behavior, with its route or area
	var dr: ScenarioDraft = main.editor.draft
	var al := int(dr.setup().get("alliance", BB.Alliance.RED))
	var oid := dr.add_robot(BB.Alliance.BLUE if al == BB.Alliance.RED
		else BB.Alliance.RED, true)
	dr.set_position(oid, Vector3(46.0, -50.0, 0.0))
	await main.editor._sync_world()
	main.editor._selected = oid
	dr.set_opponent(oid, "behavior", OpponentConfig.Behavior.STATIONARY)
	main.editor._after_opponent_edit()
	await _shot("editor_opp_stationary", main.editor._root)
	dr.set_opponent(oid, "behavior", OpponentConfig.Behavior.ROUTE)
	dr.set_opponent(oid, "waypoints", [
		{"x": 46.0, "y": -50.0, "wait": 1.5}, {"x": 58.0, "y": 0.0, "wait": 0.0},
		{"x": 46.0, "y": 48.0, "wait": 0.0}, {"x": 36.0, "y": 0.0, "wait": 0.0}])
	main.editor._after_opponent_edit()
	await _shot("editor_opp_route", main.editor._root)
	main.editor._placing = main.editor.Place.WAYPOINT
	main.editor._refresh_props()
	await _shot("editor_opp_route_adding", main.editor._root)
	main.editor._placing = main.editor.Place.NONE
	dr.set_opponent(oid, "behavior", OpponentConfig.Behavior.DEFEND)
	dr.set_opponent(oid, "area", {"x": 44.0, "y": -30.0})
	dr.set_opponent(oid, "target", 0)
	main.editor._after_opponent_edit()
	await _shot("editor_opp_defend", main.editor._root)
	# the same panel scrolled to its settings, so the validation message can be
	# seen sitting under the setting it is about
	var sc: Node = main.editor._props
	while sc != null and not (sc is ScrollContainer):
		sc = sc.get_parent()
	if sc != null:
		(sc as ScrollContainer).scroll_vertical = 560
		await _shot("editor_opp_defend_settings", main.editor._root)
		(sc as ScrollContainer).scroll_vertical = 0
	dr.set_opponent(oid, "pace", 0.72)
	main.editor._after_opponent_edit()
	await _shot("editor_opp_custom", main.editor._root)
	dr.set_opponent(oid, "behavior", OpponentConfig.Behavior.COLLECT)
	main.editor._after_opponent_edit()
	await _shot("editor_opp_collect", main.editor._root)
	dr.remove_object(oid)
	await main.editor._sync_world()
	main.editor._selected = ""
	main.editor._refresh_all()

	var loose := ""
	for e3 in main.editor.draft.elements():
		if String(e3.get("held", "")) == "":
			loose = String(e3["id"])
			break
	main.editor._selected = loose
	main.editor._refresh_all()
	await _shot("editor_element", main.editor._root)

	# the Objectives section, with a real goal on it
	main.editor._selected = ""
	main.editor.draft.set_objective("kind", Objective.Kind.SHOTS)
	main.editor.draft.set_objective("target", Objective.Target.ROBOT)
	main.editor.draft.set_objective("amount", 8)
	main.editor.draft.set_objective("time_limit", 30.0)
	main.editor.draft.set_objective("no_foul", true)
	main.editor._refresh_all()
	await _shot("editor_objective", main.editor._root)

	main.editor._selected = ""
	main.editor._pick_tool(ScenarioEditor.Tool.POLLEN)
	main.editor._help.visible = true
	main.editor._refresh_all()
	await _shot("editor_help", main.editor._root)
	main.editor._help.visible = false
	main.editor._pick_tool(ScenarioEditor.Tool.SELECT)

	# ---- test it: the practice HUD, then the way back
	await main._test_scenario(main.editor.draft.to_snapshot())
	main.mm.resume()
	main.rig.mode = CameraRig.Mode.DRIVER
	await get_tree().create_timer(1.2).timeout
	await _shot("objective_hud", main.objective_hud._root)
	main.mm.pause()
	main._open_pause_menu()
	await _shot("editor_testing", main.menu._root)
	await main.return_to_editor()
	await _shot("editor_returned", main.editor._root)

	# ---- the attempt results screen
	main.editor.draft.dirty = false
	main.editor.close()
	main.mm.abort()
	await get_tree().create_timer(0.3).timeout
	var fake_rec := {
		"rev": BB.RULES_REV, "scenario": "", "name": "Collect and shoot",
		"signature": "demo", "from_editor": false,
		"objective": {"kind": Objective.Kind.SHOTS,
			"target": Objective.Target.ROBOT, "robot": 0, "amount": 8,
			"time_limit": 30.0, "no_foul": true, "area": {}},
		"state": "succeeded", "reason": "completed", "progress": 8, "goal": 8,
		"elapsed": 24.6, "points": 40, "made": 8, "shots": 11, "fouls": 0,
		"attempt_no": 4, "when": "2026-09-20T18:00:00",
	}
	var fake_prev := {"state": "succeeded", "elapsed": 26.7}
	var fake_sum := {"attempts": 6, "succeeded": 3, "failed": 2,
		"abandoned": 1, "rate": 50.0, "best": fake_prev}
	main.attempt_results.show_attempt(fake_rec, fake_prev, fake_sum, false)
	await _shot("attempt_results", main.attempt_results._root)
	main.attempt_results.close()
	await main.editor.reopen()
	main.editor.draft.dirty = false
	main.editor._try_close()
	await get_tree().create_timer(0.3).timeout
	for entry4 in ScenarioLibrary.list_all():
		ScenarioLibrary.delete_one(String(entry4["id"]))

	# ---- the screens the reference does not show
	main.goto("Play")
	var b: Dictionary = main.mm.scoring.breakdown(main.field, true)
	var res: Dictionary = {"breakdown": b, "rp": {}}
	main.results.show_result(res.get("breakdown", {}), res.get("rp", {}),
		main.mm.scoring, [])
	await _shot("results", main.results._root)
	main.results.close()

	var si := SignIn.new()
	add_child(si)
	si.build()
	await _shot("signin", si._root)
	si.queue_free()

	# ---- focus walk on Play: START has to be reachable without a mouse
	main.goto("Play")
	await get_tree().create_timer(0.3).timeout
	main.menu._mode_buttons[0].grab_focus()
	var seen: Array[String] = []
	var cur: Control = main.menu._mode_buttons[0]
	for i in 200:
		if cur is Button:
			seen.append((cur as Button).text if (cur as Button).text != ""
				else cur.name)
		var nxt := cur.find_next_valid_focus()
		if nxt == null or nxt == main.menu._mode_buttons[0]:
			break
		cur = nxt
	print("  FOCUS: %d stops, Start reachable: %s" % [
		seen.size(), "yes" if _has(seen, "Start match") else "NO"])
	if not _has(seen, "Start match"):
		print("    chain: %s" % ", ".join(seen.slice(0, 30)))
	if not _has(seen, "Start match"):
		fails += 1

	_restore()
	print("  %s (%d failure%s)" % [
		"EVERY SCREEN FITS" if fails == 0 else "SOMETHING IS CLIPPED",
		fails, "" if fails == 1 else "s"])
	get_tree().quit(1 if fails > 0 else 0)

## The first-run pass. The only screen that exists before you have a name is
## the name dialog, so that is the only thing this pass claims to capture.
func _first_run_only() -> void:
	win = DisplayServer.window_get_size()
	rect = get_viewport().get_visible_rect()
	print("=== FIRST RUN AT %dx%d ===" % [win.x, win.y])
	_ok_true("the first-run dialog is up",
		main.signin != null and main.signin.is_open())
	if main.signin != null:
		await _shot("firstrun_signin", main.signin._root)
	# SELF-TEST. The whole point of the occlusion check is that a screen hidden
	# behind this dialog must not be reported as captured. Prove it can fail
	# rather than trusting that it would.
	main.goto("Play")
	await get_tree().create_timer(0.3).timeout
	var hidden := _occluders(main.menu._root)
	_ok_true("a screen behind the dialog is reported as covered",
		not hidden.is_empty())
	_restore()
	print("  %s (%d failure%s)" % [
		"FIRST RUN LOOKS RIGHT" if fails == 0 else "FIRST RUN IS WRONG",
		fails, "" if fails == 1 else "s"])
	get_tree().quit(1 if fails > 0 else 0)

## ANYTHING DRAWN OVER THE SCREEN BEING CAPTURED is a failed capture, whatever
## the bounds say. `root` is the screen that is supposed to be in front.
func _occluders(root: Control) -> Array[String]:
	var over: Array[String] = []
	var mine: int = _layer_of(root)
	for layer in [main.signin, main.menu, main.robot_menu, main.progress,
			main.settings_menu, main.scenarios, main.results,
			main.attempt_results, main.editor]:
		if layer == null or not is_instance_valid(layer):
			continue
		var r: Control = layer._root if "_root" in layer else null
		if r == null or r == root or not r.is_visible_in_tree():
			continue
		if int(layer.layer) >= mine:
			over.append(layer.get_class() + ":" + String(layer.name))
	return over

func _layer_of(root: Control) -> int:
	var n: Node = root
	while n != null:
		if n is CanvasLayer:
			return int((n as CanvasLayer).layer)
		n = n.get_parent()
	return 0

func _ok_true(what: String, cond: bool) -> void:
	if not cond:
		fails += 1
	print("  %s %s" % ["PASS" if cond else "FAIL", what])

func _has(a: Array[String], needle: String) -> bool:
	for s in a:
		if s.begins_with(needle):
			return true
	return false

func _shot(nm: String, root: Control) -> void:
	await get_tree().create_timer(0.45).timeout
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_shots"))
	get_viewport().get_texture().get_image().save_png(
		"res://_shots/%s_%dx%d.png" % [nm, win.x, win.y])
	var bad: Array[String] = []
	scrolled = 0
	_walk(root, bad)
	var over := _occluders(root)
	if not bad.is_empty():
		fails += 1
		print("  FAIL %-18s off canvas: %s" % [nm, ", ".join(bad)])
	elif not over.is_empty():
		fails += 1
		print("  FAIL %-18s covered by: %s" % [nm, ", ".join(over)])
	else:
		print("  PASS %-18s %s" % [nm,
			"" if scrolled == 0 else "(%d below the fold, scroll reaches them)" % scrolled])

## Every control a person can actually hit has to be REACHABLE. On the canvas
## is best; inside a scroll region that can bring it on is fine and is counted
## separately. Off the side is always a failure, because horizontal scrolling
## is disabled everywhere.
var scrolled := 0

func _walk(n: Node, bad: Array[String]) -> void:
	for c in n.get_children():
		if c is Control and (c as Control).is_visible_in_tree():
			var ctl := c as Control
			if ctl is Button or ctl is OptionButton or ctl is HSlider \
					or ctl is LineEdit:
				var r := Rect2(ctl.global_position, ctl.size)
				if not rect.encloses(r):
					var nm: String = (ctl as Button).text if ctl is Button else String(ctl.name)
					var off_side := r.position.x < rect.position.x - 0.5 \
						or r.end.x > rect.end.x + 0.5
					if not off_side and _in_scroll(ctl):
						scrolled += 1
					else:
						bad.append("%s @%s %s" % [nm, str(r.position), str(r.size)])
		_walk(c, bad)

func _in_scroll(ctl: Control) -> bool:
	var p := ctl.get_parent()
	while p != null:
		if p is ScrollContainer:
			return true
		p = p.get_parent()
	return false

# ------------------------------------------------------------------ fixtures

func _fake_history() -> void:
	if FileAccess.file_exists(HIST):
		DirAccess.copy_absolute(HIST, HIST_BAK)
	var rows: Array = []
	var when := ["2026-09-19T20:25:04", "2026-09-20T04:51:38",
		"2026-09-20T04:53:12", "2026-09-20T05:34:20"]
	var mades := [59, 86, 84, 4]
	var shots := [64, 93, 88, 4]
	var scores := [140, 187, 202, 23]
	var modes := ["TELEOP", "FULL MATCH", "FULL MATCH", "TELEOP"]
	for i in 4:
		rows.append({
			"when": when[i], "robot": "Our Robot", "mode": modes[i],
			"score": scores[i], "shots": shots[i], "made": mades[i],
			"accuracy": 100.0 * float(mades[i]) / float(shots[i]),
			"cycle_avg": 6.4 - i * 0.3, "tips": 2 + i % 2,
			"distance_ft": 210.0 + i * 40.0,
		})
	var f := FileAccess.open(HIST, FileAccess.WRITE)
	f.store_string(JSON.stringify(rows))
	f.close()

## Two situations on the shelf, so the library can be looked at stocked.
func _fake_situations() -> void:
	var snap := Snapshot.capture(main)
	snap["match"]["phase"] = BB.Phase.TELEOP
	snap["match"]["time_left"] = 47.0
	ScenarioLibrary.save(snap, "Endgame scramble",
		"Two hives up, 47 seconds left, hopper half full.")
	var snap2 := Snapshot.capture(main)
	snap2["match"]["phase"] = BB.Phase.AUTO
	snap2["match"]["time_left"] = 18.0
	ScenarioLibrary.save(snap2, "Auto handoff",
		"Straight after the auto routine finishes, so I can practise the switch.")

func _fake_routine() -> void:
	var rt := AutoRoutine.new()
	rt.start_recording()
	for i in 90:
		rt.capture(Vector3(0, 0, 1), false, false, false, false)
	rt.save_as("practice-left")

func _restore() -> void:
	Leaderboard.set_player_name(_saved_name)
	DirAccess.remove_absolute(HIST)
	if FileAccess.file_exists(HIST_BAK):
		DirAccess.copy_absolute(HIST_BAK, HIST)
		DirAccess.remove_absolute(HIST_BAK)
	AutoRoutine.delete_named("practice-left")
