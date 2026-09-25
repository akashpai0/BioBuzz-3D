class_name ProgressScreen
extends CanvasLayer
##
## PROGRESS — how the practice is actually going.
##
## Three headline numbers and a readable table of recent matches, both built
## from the records the game already writes after every full match and teleop
## run. Nothing here is a sample: an empty history says so plainly instead of
## showing invented scores.
##
## The local leaderboard lives behind a button rather than on the front, since
## it answers a different question — best run ever, by robot variant — and it
## is local: there is no server, so sharing is a copy-and-paste share code.
##

signal navigate(page: String)
## Open the replay viewer on `id`; `practise` opens it ready to pick a moment.
signal watch_requested(id: String, practise: bool)

## Set by the world: is a run paused behind the menus (so watching must wait),
## and is a recording being written (so the folder must not change).
var session_suspended: Callable
var replay_folder_busy: Callable
var _page := "overview"
var replays := ReplayLibrary.new()
var _tabs := {}

var _root: Control
var _s: Dictionary = {}
var _body: VBoxContainer
var _board := false
var _note_line: Label
## The Play screen, for the footer summary.
var play: Menu

func build() -> void:
	layer = 27
	_s = Gui.shell("Progress", func(p: String) -> void: navigate.emit(p))
	_root = _s["root"]
	_root.visible = false
	add_child(_root)
	_s["eyebrow"].text = "YOUR PRACTICE"
	_s["title"].text = "See your progress."
	_note_line = Gui.label("", Gui.T_SMALL, Gui.MUTED)
	_s["head_right"].add_child(_note_line)
	replays.host = self
	for pg in [["overview", "Overview"], ["replays", "Replays"], ["board", "Leaderboard"]]:
		var tb := Gui.button(pg[1], Gui.Look.TAB, Vector2(0, 44))
		tb.pressed.connect(func() -> void:
			SFX.play("select", -16.0)
			_page = pg[0]
			_board = _page == "board"
			if _page == "replays":
				replays.reload()
			refresh())
		_s["head_right"].add_child(tb)
		_tabs[pg[0]] = tb

	_body = Gui.vbox(Gui.S24)
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_s["body"].add_child(_body)

	_s["foot_btn"].text = "Back to Play"
	_s["foot_btn"].pressed.connect(func() -> void:
		SFX.play("click", -14.0)
		navigate.emit("Play"))
	RobotShop.changed.connect(func() -> void:
		if _root.visible:
			refresh())
	refresh()

func refresh() -> void:
	for c in _body.get_children():
		c.queue_free()
	if play:
		_s["foot_line"].text = play.summary_line()
	if _board:
		_page = "board"
	elif _page == "board":
		_page = "overview"
	for k in _tabs:
		Gui.select(_tabs[k], k == _page)
	if _page == "board":
		_leaderboard()
	elif _page == "replays":
		_s["title"].text = "Your replays."
		_note_line.text = ""
		replays.build(_body)
	else:
		_overview()

# ================================================================ overview ===

func _overview() -> void:
	_s["title"].text = "See your progress."
	_note_line.text = "Saved on this computer"
	var rows := RobotShop.history()

	var metrics := Gui.hbox(Gui.S16)
	metrics.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(metrics)

	if rows.is_empty():
		metrics.add_child(Gui.metric("Matches played", "0", "Nothing recorded yet"))
		metrics.add_child(Gui.metric("Average score", "—", "All recorded matches"))
		metrics.add_child(Gui.metric("Shot accuracy", "—", "Shots that scored"))
		var pair := Gui.card(Gui.S16)
		_body.add_child(pair[0])
		pair[1].add_child(Gui.section("No matches yet"))
		pair[1].add_child(Gui.para(
			"Full matches and teleop runs are recorded here automatically as "
			+ "soon as you finish one. Free practice is not, because it never "
			+ "ends."))
		pair[1].add_child(_board_button())
		return

	var total := 0.0
	var made := 0
	var shots := 0
	for r in rows:
		total += float(r.get("score", 0))
		made += int(r.get("made", 0))
		shots += int(r.get("shots", 0))
	metrics.add_child(Gui.metric("Matches played", str(rows.size()),
		"Full matches and teleop"))
	metrics.add_child(Gui.metric("Average score",
		"%.0f" % (total / float(rows.size())), "All recorded matches"))
	metrics.add_child(Gui.metric("Shot accuracy",
		"%.0f%%" % (100.0 * float(made) / float(maxi(shots, 1))),
		"%d of %d shots scored" % [made, shots]))

	# ---- recent matches
	var pair2 := Gui.card(Gui.S16)
	_body.add_child(pair2[0])
	var v: VBoxContainer = pair2[1]
	var head := Gui.hbox(Gui.S16)
	head.add_child(Gui.section("Recent matches"))
	head.add_child(Gui.spacer())
	head.add_child(_board_button())
	v.add_child(head)

	var cols := [["Session", 210, false], ["Robot", 170, false],
		["Mode", 150, false], ["Made / shots", 150, false],
		["Score", 0, true]]
	v.add_child(Gui.table_head(cols))
	var shown := rows.slice(maxi(0, rows.size() - 8))
	shown.reverse()
	for r in shown:
		v.add_child(Gui.divider())
		v.add_child(Gui.table_row([
			[_when(String(r.get("when", ""))), 210, false],
			[String(r.get("robot", "—")), 170, false],
			[Gui.sentence(String(r.get("mode", ""))), 150, false],
			["%d / %d" % [int(r.get("made", 0)), int(r.get("shots", 0))], 150, false],
			[str(int(r.get("score", 0))), 0, true],
		]))

	# ---- everything else, kept but out of the way
	var pair3 := Gui.card(Gui.S16)
	_body.add_child(pair3[0])
	var d: VBoxContainer = pair3[1]
	d.add_child(Gui.section("Detail"))
	var t := RobotShop.trend()
	var recent: Dictionary = t.get("recent", {})
	var older: Dictionary = t.get("older", {})
	var list: Array = []
	list.append(_trend("Average score", float(recent.get("score", 0.0)),
		float(older.get("score", 0.0)), "%.0f", true))
	list.append(_trend("Shot accuracy", float(recent.get("accuracy", 0.0)),
		float(older.get("accuracy", 0.0)), "%.0f%%", true))
	list.append(_trend("Time between scored shots",
		float(recent.get("cycle_avg", 0.0)), float(older.get("cycle_avg", 0.0)),
		"%.1f s", false))
	list.append(_trend("Hive tips", float(recent.get("tips", 0.0)),
		float(older.get("tips", 0.0)), "%.1f", true))
	var dist := 0.0
	for r in rows:
		dist += float(r.get("distance_ft", 0.0))
	list.append(Gui.row("Distance driven",
		Gui.label("%.0f ft" % dist, Gui.T_BODY, Gui.ACCENT)))
	var lbox := Gui.vbox(0)
	d.add_child(lbox)
	Gui.rows(lbox, list)
	d.add_child(Gui.para(
		"Averages are your last five matches, compared against everything "
		+ "before them. Time between scored shots is measured from one scored "
		+ "shot to the next — it is not a full collect-and-score cycle."))

	var clear := Gui.button("Clear history")
	clear.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	clear.pressed.connect(_confirm_clear)
	d.add_child(clear)

func _when(raw: String) -> String:
	# "2026-09-20T05:34:12" -> "Sep 20 · 05:34"
	if raw.length() < 16:
		return raw
	var months := ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
		"Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	var mi := clampi(int(raw.substr(5, 2)) - 1, 0, 11)
	return "%s %s · %s" % [months[mi], raw.substr(8, 2), raw.substr(11, 5)]

func _trend(label: String, now: float, before: float, fmt: String,
		higher_is_better: bool) -> HBoxContainer:
	var right := Gui.hbox(Gui.S16)
	right.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	right.add_child(Gui.label(fmt % now, Gui.T_BODY, Gui.ACCENT))
	var delta := now - before
	if before > 0.0 and absf(delta) > 0.001:
		var better := (delta > 0.0) == higher_is_better
		var arrow := "%s %s" % ["▲" if delta > 0.0 else "▼", fmt % absf(delta)]
		right.add_child(Gui.label(arrow, Gui.T_SMALL,
			Gui.GOOD if better else Gui.WARN))
	return Gui.row(label, right)

func _confirm_clear() -> void:
	SFX.play("click", -16.0)
	var d := ConfirmationDialog.new()
	d.title = "Clear history"
	d.dialog_text = "Delete every recorded match? This cannot be undone.\nYour leaderboard scores are kept."
	d.ok_button_text = "Clear"
	add_child(d)
	d.confirmed.connect(func() -> void:
		RobotShop.clear_history()
		refresh())
	d.close_requested.connect(func() -> void: d.queue_free())
	d.popup_centered()

func _board_button() -> Button:
	var b := Gui.button("Local leaderboard")
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.pressed.connect(func() -> void:
		SFX.play("select", -16.0)
		_board = true
		refresh())
	return b

# ============================================================= leaderboard ===

func _leaderboard() -> void:
	_s["title"].text = "Local leaderboard."
	var me := Leaderboard.player_name()
	_note_line.text = "Signed in as %s" % (me if me != "" else "—")

	var back := Gui.button("←  Back to progress")
	back.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	back.pressed.connect(func() -> void:
		SFX.play("click", -16.0)
		_board = false
		refresh())
	_body.add_child(back)

	var tables := Gui.hbox(Gui.S16)
	tables.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(tables)
	_table(tables, 1, "One intake", me)
	_table(tables, 2, "Two intakes", me)

	var pair := Gui.card(Gui.S16)
	_body.add_child(pair[0])
	var v: VBoxContainer = pair[1]
	v.add_child(Gui.section("Sharing"))
	v.add_child(Gui.para(
		"This board is on this computer only — there is no server, so scores "
		+ "do not sync on their own. Copy yours to a share code, send it to "
		+ "anyone else who has the game, and paste theirs back in."))
	var row := Gui.hbox(Gui.S8)
	row.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var copy := Gui.button("Copy my scores")
	copy.pressed.connect(func() -> void:
		DisplayServer.clipboard_set(Leaderboard.to_code())
		_s["foot_note"].text = "Copied. Paste that into a message to share it."
		SFX.play("select", -16.0))
	row.add_child(copy)
	var paste := Gui.button("Paste shared scores")
	paste.pressed.connect(func() -> void:
		var n := Leaderboard.merge_code(DisplayServer.clipboard_get())
		if n < 0:
			_s["foot_note"].text = "That clipboard text is not a share code."
			SFX.play("foul", -18.0)
			return
		_s["foot_note"].text = "Merged %d run%s." % [n, "" if n == 1 else "s"]
		SFX.play("select", -16.0)
		refresh())
	row.add_child(paste)
	v.add_child(row)

func _table(into: Control, intakes: int, title: String, me: String) -> void:
	var pair := Gui.card(Gui.S8)
	pair[0].size_flags_horizontal = Control.SIZE_EXPAND_FILL
	into.add_child(pair[0])
	var v: VBoxContainer = pair[1]
	v.add_child(Gui.section(title))
	var rows := Leaderboard.table(intakes)
	if rows.is_empty():
		v.add_child(Gui.para("No runs on this variant yet — play a match."))
		return
	v.add_child(Gui.table_head([["#", 44, true], ["Name", 0, false],
		["Points", 110, true]]))
	for i in rows.size():
		var r: Dictionary = rows[i]
		var nm := str(r.get("name", "?"))
		v.add_child(Gui.divider())
		v.add_child(Gui.table_row([
			[str(i + 1), 44, true], [nm, 0, false],
			[str(int(r.get("points", 0))), 110, true],
		], Gui.ACCENT if nm == me else Gui.INK))

# ===================================================================== open ==

func open() -> void:
	_board = false
	_page = "overview"
	refresh()
	_root.visible = true
	_s["foot_btn"].grab_focus()

func close() -> void:
	_root.visible = false

func is_open() -> bool:
	return _root.visible

# ================================================================= replays ===

func show_replays() -> void:
	_board = false
	_page = "replays"
	replays.reload()
	refresh()
	if not _root.visible:
		_root.visible = true

func show_note(text: String) -> void:
	_s["foot_note"].text = text

func request_watch(id: String, practise: bool) -> void:
	if session_suspended.is_valid() and bool(session_suspended.call()):
		show_note("A run is paused behind this screen. Resume it or end it from "
			+ "the pause menu before watching a replay — it has not been touched.")
		SFX.play("foul", -18.0)
		return
	SFX.play("select", -12.0)
	watch_requested.emit(id, practise)
