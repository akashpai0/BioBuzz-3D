extends Node
## THE PRACTICE WORKFLOW, WALKED THE WAY A NEW PLAYER WALKS IT.
##
## Not a unit test of one system: the path from a cold launch to a saved drill
## and back, with every step asked the only question that matters — could
## someone who has never seen this game get through it?
##
##   launch -> Play -> pick a drill -> know the goal -> drive -> result ->
##   retry -> edit the situation -> test it -> back to the editor -> save ->
##   quit -> come back and find it all still there
##
## Phase two is a SEPARATE PROCESS, because "it is still there when you come
## back" cannot be proved by the process that put it there.

var main: Node3D
var fails := 0
var notes: Array[String] = []

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(2.5).timeout
	var args := OS.get_cmdline_user_args()
	var phase := String(args[0]) if args.size() > 0 else "walk"
	if phase == "walk":
		await _walk()
	else:
		_return()
	if not notes.is_empty():
		print("\n  FRICTION LOG")
		for n in notes:
			print("    - %s" % n)
	print("  %s  (%d failure%s)" % [
		"WORKFLOW WORKS" if fails == 0 else "WORKFLOW BROKEN",
		fails, "" if fails == 1 else "s"])
	get_tree().quit(1 if fails > 0 else 0)

# ===================================================================== walk ==

func _walk() -> void:
	print("\n--- WORKFLOW: FIRST RUN ---")
	await _arrive()
	await _pick_a_drill()
	await _understand_the_goal()
	await _see_the_constraints()
	await _fail_and_read_it()
	await _retry_is_the_same_field()
	await _paused_time_is_not_practice_time()
	await _edit_test_return_save()

## 1. You launch the game. Where are you, and can you find practice?
func _arrive() -> void:
	main.goto("Play")
	await get_tree().create_timer(0.3).timeout
	_ok("Play is where you land", main.menu.is_open(), true)
	_ok("  with the situation library on the same page",
		main.scenarios != null, true)

	var shelf := ScenarioLibrary.list_all()
	_ok("there are situations to practise without making one",
		shelf.size() >= 4, true)
	var described := 0
	var named := 0
	for e in shelf:
		var obj: Dictionary = (e["data"] as Dictionary).get("objective", {})
		if Objective.is_set(obj):
			described += 1
		if String(e["note"]) != "":
			named += 1
	_ok("  every starter drill states its goal before you start it",
		described >= 4, true)
	_ok("  and explains itself in words", named >= 4, true)

## 2. You pick one. Does it start, and does the game tell you what you are doing?
func _pick_a_drill() -> void:
	var id := _drill("Collect and shoot")
	_ok("the first drill is on the shelf", id != "", true)
	await main.play_situation(id)
	await get_tree().create_timer(0.3).timeout
	_ok("picking it takes you straight to the field",
		main.menu.is_open(), false)
	_ok("  with an attempt armed", main.attempt != null, true)
	_ok("  and the match actually running",
		main.mm.phase == BB.Phase.TELEOP or main.mm.phase == BB.Phase.AUTO, true)
	_ok("  not paused behind anything", main.mm.paused, false)

## 3. The card in the corner has to answer "what am I meant to do".
func _understand_the_goal() -> void:
	var oh = main.objective_hud
	_ok("the objective card is up", oh._root.visible, true)
	var title: String = oh._title.text
	_ok("  and says the goal in a sentence", title.length() > 12, true)
	_ok("  naming what to do", title.findn("shot") >= 0 or title.findn("point") >= 0
		or title.findn("tip") >= 0 or title.findn("area") >= 0, true)
	_ok("  with live progress on it", oh._progress.text != "", true)
	_ok("  a clock", oh._clock.text != "", true)
	_ok("  which attempt this is", oh._foot.text.findn("Attempt") >= 0, true)
	_ok("  and how to retry without opening a menu",
		oh._foot.text.findn("retry") >= 0, true)
	_ok("the match HUD is up too, so the score is visible",
		main.hud.visible, true)


## 3b. A drill WITH constraints has to show them counting down, not bury them.
func _see_the_constraints() -> void:
	var id := _drill("Final twenty seconds")
	_ok("the constrained drill is on the shelf", id != "", true)
	await main.play_situation(id)
	await get_tree().create_timer(0.4).timeout
	var oh = main.objective_hud
	_ok("both constraints are on the card", oh._constraints.get_child_count(), 2)
	var c0: String = (oh._constraints.get_child(0) as Label).text
	var c1: String = (oh._constraints.get_child(1) as Label).text
	_ok("  the time limit says how long is left", c0.findn("left") >= 0, true)
	_ok("  the foul constraint says whether you are still clean",
		c1.findn("clean") >= 0, true)
	_ok("  neither relies on colour alone to say pass or fail",
		(c0.begins_with("\u2022") or c0.begins_with("!"))
		and (c1.begins_with("\u2713") or c1.begins_with("\u2717")), true)
	_ok("  and the goal sentence carries them too",
		oh._title.text.findn("without a foul") >= 0
		and oh._title.text.findn("within") >= 0, true)
	# back to the drill the rest of the walk uses
	await main.play_situation(_drill("Collect and shoot"))
	await get_tree().create_timer(0.4).timeout

## 4. It goes wrong. Does the game say what happened, and offer the way back?
func _fail_and_read_it() -> void:
	var a: Attempt = main.attempt
	a.objective["time_limit"] = 1.0
	a.elapsed = 1.5
	a._evaluate(0.2, false)
	await get_tree().create_timer(0.4).timeout
	_ok("running out of time ends the attempt", a.state, Attempt.State.FAILED)
	_ok("  and the result comes up on its own",
		main.attempt_results.is_open(), true)
	var txt := _text_of(main.attempt_results)
	_ok("  saying it was not completed", txt.findn("not completed") >= 0
		or txt.findn("Out of time") >= 0 or txt.findn("Failed") >= 0, true)
	_ok("  saying WHY", txt.findn("time") >= 0, true)
	_ok("  offering a retry right there", _has_button(main.attempt_results,
		["Retry", "Try again"]), true)
	_ok("  and a way out that is not the retry",
		_has_button(main.attempt_results, ["Library", "Situations", "Play",
			"Back", "Close", "Keep driving", "Free practice"]), true)
	_ok("  it explains how the goal is measured, not just pass/fail",
		txt.findn("successful shot") >= 0 or txt.findn("scoreboard") >= 0
		or txt.findn("CELL") >= 0, true)

## 5. Retry has to put the SAME field back, not a similar one.
func _retry_is_the_same_field() -> void:
	var want: Dictionary = main.scenario_source.duplicate(true)
	await main.retry_situation()
	var got := Snapshot.capture(main)        # before the world runs on
	var clock: float = main.attempt.elapsed if main.attempt else -1.0
	_ok("retry starts a new attempt", main.attempt != null, true)
	_ok("  numbered", main.attempt.attempt_no >= 2, true)
	_ok("  from zero", main.attempt.progress, 0)
	_ok("  with the clock back at zero", clock < 0.05, true)

	_ok("  and the same number of elements on the field",
		(got["elements"] as Array).size(), (want["elements"] as Array).size())
	var worst := 0.0
	var by_id := {}
	for e in want["elements"]:
		by_id[String(e["id"])] = e
	for e in got["elements"]:
		var w: Dictionary = by_id.get(String(e["id"]), {})
		if w.is_empty():
			continue
		var d := Snapshot.unpack_v3(e["origin"]).distance_to(
			Snapshot.unpack_v3(w["origin"]))
		worst = maxf(worst, d / BB.IN)
	_ok("  every ball back within a hundredth of an inch",
		"%.4f" % worst, "0.0000")
	var rw: Dictionary = (want["robots"] as Array)[0]
	var rg: Dictionary = (got["robots"] as Array)[0]
	var rd := Snapshot.unpack_v3(rg["origin"]).distance_to(
		Snapshot.unpack_v3(rw["origin"])) / BB.IN
	_ok("  and the robot on its mark", "%.4f" % rd, "0.0000")
	_ok("  the ORIGINAL snapshot is untouched by the attempt",
		Snapshot.describe(main.scenario_source), Snapshot.describe(want))

## 6. Time you spend in a menu is not time you spent driving.
func _paused_time_is_not_practice_time() -> void:
	await get_tree().create_timer(0.5).timeout
	var a: Attempt = main.attempt
	var ran: float = a.elapsed
	_ok("the clock runs while you drive", ran > 0.2, true)
	main._open_pause_menu()
	await get_tree().create_timer(0.8).timeout
	_ok("the pause menu stops the attempt clock",
		absf(a.elapsed - ran) < 0.01, true)
	_ok("  and the pause menu is what is on screen", main.menu.is_open(), true)
	_ok("  offering the way back to the same attempt",
		_has_button(main.menu, ["Resume", "Keep driving", "Back to the match"]),
		true)
	main._resume_match()
	await get_tree().create_timer(0.5).timeout
	_ok("resuming carries on where you were", a.elapsed > ran + 0.2, true)
	_ok("  and does not restart the attempt", a.attempt_no >= 2, true)

## 7. Change a situation, try it, come back, save it.
func _edit_test_return_save() -> void:
	var id := _drill("Collect and shoot")
	await main._edit_scenario(id)
	await get_tree().create_timer(0.5).timeout
	_ok("a saved situation opens in the editor", main.editor.is_open(), true)
	var d: ScenarioDraft = main.editor.draft
	_ok("  writing back to the same entry", d.source_id, id)
	_ok("  and starting clean, not dirty", d.dirty, false)

	var before: int = int(d.objective().get("amount", 0))
	d.set_objective("amount", before + 1)
	_ok("changing the goal marks it unsaved", d.dirty, true)

	var snap := d.to_snapshot()
	await main._test_scenario(snap)
	await get_tree().create_timer(0.5).timeout
	_ok("Test drops you onto the field", main.editor.is_open(), false)
	_ok("  running the draft you just changed",
		main.attempt.goal, before + 1)
	_ok("  marked as an editor test, not a practice rep",
		main.attempt.from_editor, true)
	_ok("  and the way back is offered", main.editor_return, true)

	await main.return_to_editor()
	await get_tree().create_timer(0.5).timeout
	_ok("returning puts you back in the editor", main.editor.is_open(), true)
	_ok("  with the change still there",
		int(main.editor.draft.objective().get("amount", 0)), before + 1)
	_ok("  still unsaved, so nothing was written behind your back",
		main.editor.draft.dirty, true)
	_ok("  and no test attempt left running", main.attempt, null)
	_ok("  and the test's attempt clock is not still running",
		main.objective_hud._root.visible, false)

	var n0: int = ScenarioLibrary.list_all().size()
	main.editor._save(false)
	await get_tree().create_timer(0.4).timeout
	_ok("saving writes back rather than making a duplicate",
		ScenarioLibrary.list_all().size(), n0)
	_ok("  and clears the unsaved mark", main.editor.draft.dirty, false)
	var saved := ScenarioLibrary.load_one(id)
	_ok("  with the new goal on disk",
		int((saved["data"] as Dictionary).get("objective", {}).get("amount", 0)),
		before + 1)
	main.editor._try_close()
	await get_tree().create_timer(0.4).timeout

	# put it back the way the drill shipped, so a rerun starts from the same shelf
	await main._edit_scenario(id)
	await get_tree().create_timer(0.4).timeout
	main.editor.draft.set_objective("amount", before)
	main.editor._save(false)
	await get_tree().create_timer(0.3).timeout
	main.editor._try_close()
	await get_tree().create_timer(0.3).timeout

# =================================================================== return ==

## Phase two: a cold start. Everything you did has to still be here.
func _return() -> void:
	print("\n--- WORKFLOW: COMING BACK (cold start) ---")
	var shelf := ScenarioLibrary.list_all()
	_ok("the situations are still on the shelf", shelf.size() >= 4, true)
	var broken := 0
	for e in shelf:
		if String(e["error"]) != "":
			broken += 1
	_ok("  and none of them failed to load", broken, 0)
	var rows := AttemptLog.all()
	_ok("the practice history came back too", rows.size() > 0, true)
	var with_sig := 0
	for r in rows:
		if String(r.get("signature", "")) != "":
			with_sig += 1
	_ok("  every row still knows which setup it belongs to",
		with_sig, rows.size())
	var id := _drill("Collect and shoot")
	if id != "":
		var e := ScenarioLibrary.load_one(id)
		var obj: Dictionary = (e["data"] as Dictionary).get("objective", {})
		var sum := AttemptLog.summary(AttemptLog.signature(e["data"], obj))
		_ok("  and the drill can still show how you have been doing",
			int(sum["attempts"]) >= 0, true)

# ================================================================== helpers ==

func _drill(want: String) -> String:
	for e in ScenarioLibrary.list_all():
		if String(e["name"]) == want:
			return String(e["id"])
	return ""

## Every scrap of text on a screen, so a check can ask whether it SAYS something.
func _text_of(screen: Node) -> String:
	var out := ""
	for n in _walk_nodes(screen):
		if n is Label:
			out += (n as Label).text + "\n"
		elif n is Button:
			out += (n as Button).text + "\n"
		elif n is RichTextLabel:
			out += (n as RichTextLabel).get_parsed_text() + "\n"
	return out

func _has_button(screen: Node, any_of: Array) -> bool:
	for n in _walk_nodes(screen):
		if not (n is Button):
			continue
		var t: String = (n as Button).text
		for w in any_of:
			if t.findn(String(w)) >= 0:
				return true
	return false

func _walk_nodes(n: Node) -> Array:
	var out: Array = [n]
	for c in n.get_children():
		out.append_array(_walk_nodes(c))
	return out

func _note(s: String) -> void:
	notes.append(s)

func _ok(what: String, got: Variant, want: Variant) -> void:
	var pass_: bool = str(got) == str(want)
	if not pass_:
		fails += 1
		notes.append("FRICTION: %s  (got %s, wanted %s)" % [what, str(got), str(want)])
	print("  %s %-58s got %s   want %s" % [
		"PASS" if pass_ else "FAIL", what, str(got), str(want)])
