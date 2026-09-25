class_name ResultsScreen
extends CanvasLayer
##
## THE MATCH REPORT.
##
## Two pages. SCORE is the official breakdown, laid out the way a real FTC match
## report is: every line shows the COUNT on the left of its label and the POINTS
## on the right, per alliance, so "6" under CELL contents is visibly 3 elements
## at 2 each and not a number you have to take on faith. STATS is the part that
## is actually useful for practice — accuracy, cycle time, how long you sat on
## a full hopper — which the score cannot tell you.
##
## The whole SCORE page is generated from `Scoring.REPORT`, so adding a scoring
## element means editing one table rather than this file.
##

signal closed
signal replay
## Offered only when the attempt was a test of a scenario draft.
signal return_to_editor
## Watch this run's replay.
signal watch_requested
var offer_editor := false
var _editor_btn: Button

var _root: Control
var _body: VBoxContainer
var _tabs: Array[Button] = []
var _page := 0
var _b: Dictionary = {}
var _rp: Dictionary = {}
var _stats: Array = []            # [summary dict, ...] in robot order
var _winner := ""
var _title: Label

const ACCENT := Gui.ACCENT
const DIM := Gui.MUTED

func build() -> void:
	layer = 25
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.visible = false
	add_child(_root)

	var bg := ColorRect.new()
	bg.color = Gui.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(bg)

	var col := Gui.vbox(0)
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(col)

	var toppad := MarginContainer.new()
	toppad.add_theme_constant_override("margin_left", Gui.PAD_PAGE)
	toppad.add_theme_constant_override("margin_right", Gui.PAD_PAGE)
	toppad.add_theme_constant_override("margin_top", Gui.S24)
	toppad.add_theme_constant_override("margin_bottom", Gui.S24)
	col.add_child(toppad)

	var head := Gui.hbox(Gui.S16)
	toppad.add_child(head)
	var heads := Gui.vbox(2)
	heads.add_child(Gui.eyebrow("MATCH REPORT"))
	_title = Gui.title("")
	heads.add_child(_title)
	head.add_child(heads)
	head.add_child(Gui.spacer())
	for spec in [["Score", 0], ["Stats", 1]]:
		var b := Gui.button(String(spec[0]), Gui.Look.TAB, Vector2(120, 46))
		b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		b.pressed.connect(_show_page.bind(int(spec[1])))
		head.add_child(b)
		_tabs.append(b)
	col.add_child(Gui.divider())

	var mainpad := MarginContainer.new()
	mainpad.add_theme_constant_override("margin_left", Gui.PAD_PAGE)
	mainpad.add_theme_constant_override("margin_right", Gui.PAD_PAGE)
	mainpad.add_theme_constant_override("margin_top", Gui.S24)
	mainpad.add_theme_constant_override("margin_bottom", Gui.S24)
	mainpad.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(mainpad)

	var pair := Gui.scroll_card(Gui.S8)
	mainpad.add_child(pair[0])
	_body = pair[1]

	col.add_child(Gui.divider())
	var footwrap := PanelContainer.new()
	var fb := StyleBoxFlat.new()
	fb.bg_color = Gui.PANEL
	fb.content_margin_left = Gui.PAD_PAGE
	fb.content_margin_right = Gui.PAD_PAGE
	fb.content_margin_top = Gui.S16
	fb.content_margin_bottom = Gui.S16
	footwrap.add_theme_stylebox_override("panel", fb)
	col.add_child(footwrap)

	var foot := Gui.hbox(Gui.S16)
	footwrap.add_child(foot)
	_foot_note = Gui.label(
		"Scored from the field at rest, 2.8 s after the buzzer (S10.5).",
		Gui.T_SMALL, Gui.MUTED, true)
	_foot_note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(_foot_note)
	var watch := Gui.button("Watch replay", Gui.Look.SECONDARY, Vector2(170, 56))
	watch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	watch.tooltip_text = "Watch this run, then practise from any moment in it"
	watch.pressed.connect(func() -> void:
		SFX.play("select", -12.0)
		watch_requested.emit())
	foot.add_child(watch)
	var back := Gui.button("Back to Play", Gui.Look.SECONDARY, Vector2(170, 56))
	back.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	back.pressed.connect(func() -> void:
		SFX.play("click", -14.0)
		close()
		closed.emit())
	foot.add_child(back)
	_editor_btn = Gui.button("Return to editor", Gui.Look.SECONDARY, Vector2(0, 56))
	_editor_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_editor_btn.visible = false
	_editor_btn.pressed.connect(func() -> void:
		SFX.play("select", -12.0)
		close()
		return_to_editor.emit())
	foot.add_child(_editor_btn)

	var again := Gui.primary("Run it again  →", Vector2(210, 56))
	again.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	again.pressed.connect(func() -> void:
		SFX.play("select", -12.0)
		close()
		replay.emit())
	foot.add_child(again)

# =================================================================== show ====

func show_result(breakdown: Dictionary, rp: Dictionary, scoring: Scoring,
		summaries: Array) -> void:
	_b = breakdown
	_rp = rp
	_stats = summaries
	var r := int(breakdown[BB.Alliance.RED]["total"])
	var bl := int(breakdown[BB.Alliance.BLUE]["total"])
	_winner = "Tie" if r == bl else ("Red wins" if r > bl else "Blue wins")
	_title.text = "%s — %d to %d" % [_winner, maxi(r, bl), mini(r, bl)]
	_scoring = scoring
	_root.visible = true
	if _editor_btn:
		_editor_btn.visible = offer_editor
	_show_page(0)

var _scoring: Scoring

func _show_page(i: int) -> void:
	_page = i
	for c in _body.get_children():
		c.queue_free()
	for t in _tabs.size():
		Gui.select(_tabs[t], t == i)
	if i == 0:
		_page_score()
	else:
		_page_stats()

# ============================================================== score page ===

func _page_score() -> void:
	_body.add_child(_scoreline())
	_body.add_child(_spacer(10))

	# The table is held to a readable width and centred rather than stretched
	# edge to edge: on a wide monitor a full-width row puts RED at one side of
	# the screen and BLUE at the other with three feet of nothing between them,
	# and you cannot read a line across it.
	var table := VBoxContainer.new()
	table.custom_minimum_size = Vector2(1020, 0)
	table.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	table.add_theme_constant_override("separation", 2)
	_body.add_child(table)

	table.add_child(_column_header())
	for row in Scoring.REPORT:
		var key := String(row[0])
		if key == "_h":
			table.add_child(_section(String(row[1])))
			continue
		var pending := Scoring.END_ONLY.has(key) and not _is_final()
		table.add_child(_row(String(row[1]), key, String(row[2]), pending))

	table.add_child(_section("RANKING POINTS"))
	var rows_r: Array = _scoring.rp_rows(BB.Alliance.RED, _b)
	var rows_b: Array = _scoring.rp_rows(BB.Alliance.BLUE, _b)
	for i in rows_r.size():
		table.add_child(_rp_row(rows_r[i], rows_b[i]))

	table.add_child(_spacer(6))
	table.add_child(_rule())
	table.add_child(_total_row())

## Big red/blue scoreboard, with who won between them.
func _scoreline() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(_score_chip(BB.Alliance.RED))
	var mid := Label.new()
	mid.text = _winner
	mid.add_theme_font_size_override("font_size", 17)
	mid.add_theme_color_override("font_color", Color(0.55, 0.85, 0.68))
	mid.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(mid)
	row.add_child(_score_chip(BB.Alliance.BLUE))
	return row

func _score_chip(a: int) -> Control:
	var won := _winner.begins_with(BB.alliance_name(a))
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(230, 82)
	var sb := StyleBoxFlat.new()
	var c := BB.alliance_colour(a)
	sb.bg_color = Color(c.r, c.g, c.b, 0.95 if won else 0.55)
	sb.border_color = Color(1, 1, 1, 0.85) if won else Color(1, 1, 1, 0.12)
	sb.set_border_width_all(3 if won else 1)
	sb.set_corner_radius_all(10)
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", sb)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	panel.add_child(v)
	var name := Label.new()
	name.text = BB.alliance_name(a)
	name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name.add_theme_font_size_override("font_size", 15)
	name.add_theme_color_override("font_color", Color(1, 1, 1, 0.92))
	v.add_child(name)
	var pts := Label.new()
	pts.text = str(int(_b[a]["total"]))
	pts.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pts.add_theme_font_size_override("font_size", 38)
	pts.add_theme_color_override("font_color", Color.WHITE)
	v.add_child(pts)
	return panel

func _column_header() -> Control:
	var row := HBoxContainer.new()
	for spec in [[BB.Alliance.RED, HORIZONTAL_ALIGNMENT_LEFT],
			[-1, HORIZONTAL_ALIGNMENT_CENTER],
			[BB.Alliance.BLUE, HORIZONTAL_ALIGNMENT_RIGHT]]:
		var l := Label.new()
		var a := int(spec[0])
		l.text = "" if a < 0 else BB.alliance_name(a)
		l.horizontal_alignment = int(spec[1])
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.size_flags_stretch_ratio = 1.0 if a >= 0 else 1.6
		l.add_theme_font_size_override("font_size", 13)
		l.add_theme_color_override("font_color",
			DIM if a < 0 else Gui.alliance_ink(a))
		row.add_child(l)
	return row

## One scoring line: red count and points, the label, blue count and points.
func _row(label: String, key: String, unit: String, pending: bool) -> Control:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, 24)
	row.add_child(_cell(_value(BB.Alliance.RED, key, unit, pending),
		HORIZONTAL_ALIGNMENT_LEFT, 1.0, Color(0.88, 0.91, 0.95)))
	var mid := Label.new()
	mid.text = label if unit == "" else "%s (%s)" % [label, unit]
	mid.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.size_flags_stretch_ratio = 1.6
	mid.add_theme_font_size_override("font_size", 14)
	mid.add_theme_color_override("font_color", Color(0.72, 0.77, 0.83))
	row.add_child(mid)
	row.add_child(_cell(_value(BB.Alliance.BLUE, key, unit, pending),
		HORIZONTAL_ALIGNMENT_RIGHT, 1.0, Color(0.88, 0.91, 0.95)))
	return row

## A count row shows the count; a points row shows the points. Rows that are
## only assessed once the field is at rest read "--" until then.
func _value(a: int, key: String, unit: String, pending: bool) -> String:
	if pending:
		return "--"
	var d: Dictionary = _b[a]
	if unit == "":
		return str(int(d.get(key, 0)))
	return "%d   %s" % [int(d.get(key + "_n", 0)), _pts(int(d.get(key, 0)))]

func _pts(v: int) -> String:
	return "%d pt" % v if absi(v) == 1 else "%d pts" % v

func _rp_row(r: Array, b: Array) -> Control:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, 24)
	row.add_child(_cell("EARNED" if bool(r[1]) else String(r[2]),
		HORIZONTAL_ALIGNMENT_LEFT, 1.0,
		Color(0.55, 0.85, 0.68) if bool(r[1]) else DIM))
	var mid := Label.new()
	mid.text = String(r[0])
	mid.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.size_flags_stretch_ratio = 1.6
	mid.add_theme_font_size_override("font_size", 14)
	mid.add_theme_color_override("font_color", Color(0.72, 0.77, 0.83))
	row.add_child(mid)
	row.add_child(_cell("EARNED" if bool(b[1]) else String(b[2]),
		HORIZONTAL_ALIGNMENT_RIGHT, 1.0,
		Color(0.55, 0.85, 0.68) if bool(b[1]) else DIM))
	return row

func _total_row() -> Control:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, 40)
	row.add_child(_cell(str(int(_b[BB.Alliance.RED]["total"])),
		HORIZONTAL_ALIGNMENT_LEFT, 1.0, Color.WHITE, 24))
	var mid := Label.new()
	mid.text = "TOTAL"
	mid.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.size_flags_stretch_ratio = 1.6
	mid.add_theme_font_size_override("font_size", 18)
	mid.add_theme_color_override("font_color", Color(0.88, 0.91, 0.95))
	row.add_child(mid)
	row.add_child(_cell(str(int(_b[BB.Alliance.BLUE]["total"])),
		HORIZONTAL_ALIGNMENT_RIGHT, 1.0, Color.WHITE, 24))
	return row

# ============================================================== stats page ===

func _page_stats() -> void:
	if _stats.is_empty():
		_body.add_child(_section("NO ROBOT DATA"))
		return
	# side by side when two people drove, one column when one did
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 60)
	cols.custom_minimum_size = Vector2(1020, 0)
	cols.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_body.add_child(cols)
	for s in _stats:
		cols.add_child(_stat_column(s))

func _stat_column(s: Dictionary) -> Control:
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 2)

	var head := Label.new()
	head.text = "%s  ·  %s  ·  %d intake%s" % [
		String(s["label"]), BB.alliance_name(int(s["alliance"])),
		int(s["intakes"]), "" if int(s["intakes"]) == 1 else "s"]
	head.add_theme_font_size_override("font_size", 16)
	head.add_theme_color_override("font_color", Gui.alliance_ink(int(s["alliance"])))
	v.add_child(head)
	v.add_child(_spacer(6))

	for row in MatchStats.rows(s):
		var r := HBoxContainer.new()
		r.custom_minimum_size = Vector2(0, 23)
		var l := Label.new()
		l.text = String(row[0])
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.add_theme_font_size_override("font_size", 14)
		l.add_theme_color_override("font_color", Color(0.78, 0.82, 0.88))
		r.add_child(l)
		var val := Label.new()
		val.text = String(row[1])
		val.custom_minimum_size = Vector2(110, 0)
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		val.add_theme_font_size_override("font_size", 14)
		val.add_theme_color_override("font_color", ACCENT)
		r.add_child(val)
		v.add_child(r)
		if String(row[2]) != "":
			var hint := Label.new()
			hint.text = String(row[2])
			hint.add_theme_font_size_override("font_size", 11)
			hint.add_theme_color_override("font_color", Color(0.45, 0.49, 0.56))
			v.add_child(hint)
	return v

# ================================================================== chrome ===

func _is_final() -> bool:
	return true      # this screen only ever shows a finished match

func _cell(text: String, align: int, ratio: float, col: Color, size := 14) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = align
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.size_flags_stretch_ratio = ratio
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l

func _section(t: String) -> Control:
	var l := Label.new()
	l.text = Gui.sentence(t)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.custom_minimum_size = Vector2(0, 30)
	l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.50, 0.55, 0.62))
	return l

func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c

func _rule() -> Control:
	return Gui.divider()

func _button(text: String, size: Vector2, cb: Callable) -> Button:
	var b := Gui.button(text, Gui.Look.SECONDARY, size)
	if cb.is_valid():
		b.pressed.connect(cb)
	return b

func _mark(b: Button, on: bool) -> void:
	Gui.select(b, on)

var _foot_note: Label

## A problem with the replay, shown where the button was pressed.
func show_note(text: String) -> void:
	_foot_note.text = text
	_foot_note.add_theme_color_override("font_color", Gui.WARN)

## Show the same result again, after the replay viewer.
func reopen() -> void:
	_root.visible = true

func close() -> void:
	_root.visible = false

func is_open() -> bool:
	return _root.visible
