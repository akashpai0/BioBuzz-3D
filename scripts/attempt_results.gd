class_name AttemptResults
extends CanvasLayer
##
## HOW THE ATTEMPT WENT.
##
## Shown when an objective attempt finishes: what was asked, what happened,
## the numbers behind it, and one factual line comparing it with the best
## attempt at the same setup. Nothing here is generated: every sentence comes
## from a recorded value.
##

signal retry_requested
signal edit_requested(scenario_id: String)
signal library_requested
signal editor_requested
## Watch the replay of the attempt that just ended.
signal watch_requested

var _root: Control
var _s: Dictionary = {}
var _body: VBoxContainer
var _rec: Dictionary = {}
var _prev: Dictionary = {}
var _summary: Dictionary = {}
var _offer_editor := false

func build() -> void:
	# above the editor: an attempt can finish while the creator is open
	layer = 34
	_s = Gui.shell("Play", func(_p: String) -> void: library_requested.emit())
	_root = _s["root"]
	_root.visible = false
	add_child(_root)
	_s["eyebrow"].text = "PRACTICE ATTEMPT"

	_body = Gui.vbox(Gui.S24)
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_s["body"].add_child(_body)

	# Watch replay sits in the footer too, beside Back to library, so it is
	# visible without scrolling past the numbers.
	_foot_watch = Gui.button("Watch replay", Gui.Look.SECONDARY, Vector2(0, 56))
	_foot_watch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_foot_watch.tooltip_text = "Watch this attempt, then practise from any moment in it"
	_foot_watch.pressed.connect(func() -> void:
		SFX.play("select", -12.0)
		watch_requested.emit())
	var foot_row: Node = _s["foot_alt"].get_parent()
	foot_row.add_child(_foot_watch)
	foot_row.move_child(_foot_watch, _s["foot_alt"].get_index())
	_s["foot_btn"].text = "Retry  →"
	_s["foot_btn"].pressed.connect(func() -> void:
		SFX.play("select", -12.0)
		close()
		retry_requested.emit())

func show_attempt(rec: Dictionary, previous_best: Dictionary,
		summary: Dictionary, offer_editor: bool) -> void:
	_rec = rec
	_prev = previous_best
	_summary = summary
	_offer_editor = offer_editor
	_fill()
	_root.visible = true
	_s["foot_btn"].grab_focus()

func _fill() -> void:
	for c in _body.get_children():
		c.queue_free()
	var state := String(_rec.get("state", "failed"))
	var ok := state == "succeeded"
	var quit := state == "abandoned"

	# ---- the verdict. A mark as well as a colour, always.
	_s["title"].text = "Objective complete." if ok else (
		"Attempt abandoned." if quit else "Not this time.")
	var col := Gui.GOOD if ok else (Gui.MUTED if quit else Gui.WARN)
	var mark := "✓" if ok else ("—" if quit else "✗")
	# the mark carries the meaning; the colour only reinforces it
	var head := Gui.label("%s   %s" % [mark,
		AttemptLog.compare_line(_rec, _prev)], Gui.T_BODY, col)
	_body.add_child(head)

	# ---- what was asked, and how far it got
	var pair := Gui.card(Gui.S16)
	_body.add_child(pair[0])
	var v: VBoxContainer = pair[1]
	v.add_child(Gui.section("The objective"))
	v.add_child(Gui.label(Objective.describe(_rec.get("objective", {})),
		Gui.T_BODY, Gui.INK))
	var metrics := Gui.hbox(Gui.S16)
	metrics.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(metrics)
	metrics.add_child(Gui.metric("Progress", "%d / %d" % [
		maxi(0, int(_rec.get("progress", 0))), int(_rec.get("goal", 1))],
		"reached" if ok else "when it ended"))
	metrics.add_child(Gui.metric("Time", "%.1f s" % float(_rec.get("elapsed", 0.0)),
		"driving time, menus excluded"))
	var bestrec: Dictionary = _summary.get("best", {})
	metrics.add_child(Gui.metric("Your best",
		"%.1f s" % float(bestrec.get("elapsed", 0.0)) if not bestrec.is_empty()
			else "—",
		"fastest success" if not bestrec.is_empty() else "no success yet"))

	# ---- the numbers behind it
	var pair2 := Gui.card(Gui.S16)
	_body.add_child(pair2[0])
	var v2: VBoxContainer = pair2[1]
	v2.add_child(Gui.section("What happened"))
	var made := int(_rec.get("made", 0))
	var shots := int(_rec.get("shots", 0))
	var rows: Array = []
	rows.append(Gui.row("Successful shots", Gui.label("%d of %d%s" % [made, shots,
		"  ·  %.0f%%" % (100.0 * float(made) / float(shots)) if shots > 0 else ""],
		Gui.T_BODY, Gui.ACCENT)))
	rows.append(Gui.row("Points gained", Gui.label("%d" % int(_rec.get("points", 0)),
		Gui.T_BODY, Gui.ACCENT)))
	var fouls := int(_rec.get("fouls", 0))
	rows.append(Gui.row("New fouls", Gui.label("%d" % fouls, Gui.T_BODY,
		Gui.RED_INK if fouls > 0 else Gui.ACCENT)))
	var box := Gui.vbox(0)
	v2.add_child(box)
	Gui.rows(box, rows)
	v2.add_child(Gui.para(
		"Points gained are FINAL — scored after the field settled, the way the "
		+ "match itself scores. A successful shot is %s." % Objective.SHOT_METRIC))
	# balls already flying when the attempt began: say so rather than letting
	# the driver wonder where the points came from
	var flying := int(_rec.get("airborne_at_start", 0))
	if flying > 0:
		var okind := int((_rec.get("objective", {}) as Dictionary)
			.get("kind", Objective.Kind.NONE))
		var tail := ""
		if okind == Objective.Kind.POINTS:
			tail = " " + Objective.FLIGHT_RULE_POINTS
		elif okind == Objective.Kind.SHOTS:
			tail = " " + Objective.FLIGHT_RULE_SHOTS
		v2.add_child(Gui.para("%d ball%s already in the air when this attempt "
			% [flying, "" if flying == 1 else "s were"]
			+ "started.%s" % tail))

	# ---- how it compares
	var pair3 := Gui.card(Gui.S8)
	_body.add_child(pair3[0])
	var v3: VBoxContainer = pair3[1]
	v3.add_child(Gui.section("This setup"))
	if int(_summary.get("attempts", 0)) == 0:
		v3.add_child(Gui.para("No attempts recorded yet."))
	else:
		var m := Gui.hbox(Gui.S16)
		m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		v3.add_child(m)
		m.add_child(Gui.metric("Attempts", "%d" % int(_summary["attempts"]), ""))
		m.add_child(Gui.metric("Completed", "%d" % int(_summary["succeeded"]), ""))
		m.add_child(Gui.metric("Success rate",
			"%.0f%%" % float(_summary["rate"]),
			"of every attempt, abandoned ones included"))
		v3.add_child(Gui.para(
			"%d failed, %d abandoned. Abandoned attempts are counted so "
			% [int(_summary["failed"]), int(_summary["abandoned"])]
			+ "restarting the moment a run goes wrong cannot look like a "
			+ "perfect record."))

	# ---- what next
	var row := Gui.hbox(Gui.S8)
	row.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	if _offer_editor:
		var back := Gui.button("Return to editor", Gui.Look.SECONDARY, Vector2(0, 52))
		back.pressed.connect(func() -> void:
			SFX.play("select", -12.0)
			close()
			editor_requested.emit())
		row.add_child(back)
	elif String(_rec.get("scenario", "")) != "":
		var edit := Gui.button("Edit scenario", Gui.Look.SECONDARY, Vector2(0, 52))
		edit.pressed.connect(func() -> void:
			SFX.play("select", -12.0)
			close()
			edit_requested.emit(String(_rec.get("scenario", ""))))
		row.add_child(edit)
	var lib := Gui.button("Back to library", Gui.Look.SECONDARY, Vector2(0, 52))
	lib.pressed.connect(func() -> void:
		SFX.play("click", -14.0)
		close()
		library_requested.emit())
	row.add_child(lib)
	_body.add_child(row)

	# the same two actions as the row above, in the footer where they are always
	# reachable without scrolling past the numbers
	var alt: Button = _s["foot_alt"]
	for c in alt.pressed.get_connections():
		alt.pressed.disconnect(c["callable"])
	alt.visible = true
	if _offer_editor:
		alt.text = "Return to editor"
		alt.pressed.connect(func() -> void:
			SFX.play("select", -12.0)
			close()
			editor_requested.emit())
	else:
		alt.text = "Back to library"
		alt.pressed.connect(func() -> void:
			SFX.play("click", -14.0)
			close()
			library_requested.emit())

	_s["foot_line"].text = _rec.get("name", "Practice attempt")
	_s["foot_note"].text = "Attempt %d · %s" % [int(_rec.get("attempt_no", 1)),
		"editor test — not saved against a scenario"
			if bool(_rec.get("from_editor", false)) else "saved to your practice history"]

var _foot_watch: Button

## A problem with the replay, shown in the footer.
func show_note(text: String) -> void:
	_s["foot_note"].text = text
	_s["foot_note"].add_theme_color_override("font_color", Gui.WARN)

## The same card again, after the replay viewer.
func reopen() -> void:
	_root.visible = true

func close() -> void:
	_root.visible = false

func is_open() -> bool:
	return _root.visible
