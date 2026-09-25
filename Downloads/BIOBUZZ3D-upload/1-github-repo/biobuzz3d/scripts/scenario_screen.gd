class_name ScenarioScreen
extends CanvasLayer
##
## THE SITUATION LIBRARY.
##
## Part of Play's practice flow rather than a page of its own: the navigation
## still shows Play, because picking a situation is one of the ways you start
## driving. Every row is a real file on disk with a real name, and the actions
## do what they say — Play from here loads it, Duplicate gives you a copy to
## ruin, Delete asks first.
##

signal navigate(page: String)
## Play this situation from its saved instant.
signal play_requested(id: String)
## Start a new draft: "staged", "empty", or a library id to copy.
signal create_requested(source: String)
## Open a saved situation in the editor, writing back to the same entry.
signal edit_requested(id: String)

var _root: Control
var _s: Dictionary = {}
var _list: VBoxContainer
var _editing := ""                  # id of the row being renamed
## The Play screen, for the footer summary.
var play: Menu

func build() -> void:
	layer = 26
	_s = Gui.shell("Play", func(p: String) -> void: navigate.emit(p))
	_root = _s["root"]
	_root.visible = false
	add_child(_root)
	_s["eyebrow"].text = "PRACTICE"
	_s["title"].text = "Saved situations."
	_s["head_right"].add_child(
		Gui.label("Saved on this computer", Gui.T_SMALL, Gui.MUTED))

	_list = Gui.vbox(Gui.S16)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_s["body"].add_child(_list)

	_s["foot_btn"].text = "Back to Play"
	_s["foot_btn"].pressed.connect(func() -> void:
		SFX.play("click", -14.0)
		navigate.emit("Play"))
	refresh()

func refresh() -> void:
	for c in _list.get_children():
		c.queue_free()
	if play:
		_s["foot_line"].text = play.summary_line()
	_list.add_child(_create_card())
	var all := ScenarioLibrary.list_all()
	if all.is_empty():
		_empty_state()
		return
	_s["foot_note"].text = "%d situation%s saved." % [
		all.size(), "" if all.size() == 1 else "s"]
	for entry in all:
		_list.add_child(_row(entry))

## The three ways to start authoring one.
func _create_card() -> Control:
	var pair := Gui.card(Gui.S8)
	var v: VBoxContainer = pair[1]
	var head := Gui.hbox(Gui.S16)
	head.add_child(Gui.section("Create a scenario"))
	head.add_child(Gui.spacer())
	var staged := Gui.primary("Standard staged field", Vector2(0, 48))
	staged.pressed.connect(func() -> void:
		SFX.play("select", -14.0)
		create_requested.emit("staged"))
	head.add_child(staged)
	var empty := Gui.button("Empty practice field", Gui.Look.SECONDARY, Vector2(0, 48))
	empty.pressed.connect(func() -> void:
		SFX.play("select", -14.0)
		create_requested.emit("empty"))
	head.add_child(empty)
	v.add_child(head)
	v.add_child(Gui.para(
		"A staged field starts exactly where a match does. An empty field "
		+ "keeps the walls, HIVEs and FLOWERs and your robot, and clears every "
		+ "loose ball so you can place only what you want to practise. To "
		+ "start from something you already saved, use Edit or Duplicate and "
		+ "edit on a situation below."))
	return pair[0]

## No situations yet is a normal state, not an error — say what one is and how
## to make the first.
func _empty_state() -> void:
	_s["foot_note"].text = ""
	var pair := Gui.card(Gui.S16)
	_list.add_child(pair[0])
	var v: VBoxContainer = pair[1]
	v.add_child(Gui.section("No saved situations yet"))
	v.add_child(Gui.para(
		"A situation is the whole field frozen at one instant — the clock, the "
		+ "score, where every robot and every ball is, what is in your hopper. "
		+ "Save one from a moment you want to practise and you can drive it "
		+ "again from exactly there, as many times as you like."))
	v.add_child(Gui.divider())
	var how := Gui.vbox(Gui.S8)
	how.add_child(Gui.label("To make one:", Gui.T_BODY, Gui.INK))
	how.add_child(Gui.para("1.  Start a match or a free practice run."))
	how.add_child(Gui.para(
		"2.  When you reach a moment worth repeating, press %s, or press %s "
		% [_key("save_situation"), _key("pause")]
		+ "and choose Save situation."))
	how.add_child(Gui.para("3.  Give it a name. It is saved for good."))
	v.add_child(how)
	v.add_child(Gui.divider())
	v.add_child(Gui.para(
		"Once a situation is loaded, %s puts it straight back to its saved "
		% _key("retry_scenario")
		+ "instant, however badly the attempt went."))

func _key(action: String) -> String:
	var ks: Array = BB.keys_for(action)
	return OS.get_keycode_string(int(ks[0])) if not ks.is_empty() else "—"

# ==================================================================== rows ===

func _row(entry: Dictionary) -> Control:
	var pair := Gui.card(Gui.S8)
	var v: VBoxContainer = pair[1]
	var id := String(entry["id"])

	if String(entry["error"]) != "":
		v.add_child(Gui.section(id))
		var bad := Gui.para(String(entry["error"]))
		bad.add_theme_color_override("font_color", Gui.WARN)
		v.add_child(bad)
		var row := Gui.hbox(Gui.S8)
		row.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		row.add_child(_action("Delete", func() -> void: _confirm_delete(entry)))
		v.add_child(row)
		return pair[0]

	var head := Gui.hbox(Gui.S16)
	if _editing == id:
		var edit := Gui.line_edit("situation name", String(entry["name"]))
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.add_child(edit)
		head.add_child(_action("Save name", func() -> void:
			ScenarioLibrary.rename_to(id, edit.text)
			_editing = ""
			SFX.play("select", -16.0)
			refresh()))
		head.add_child(_action("Cancel", func() -> void:
			_editing = ""
			refresh()))
		v.add_child(head)
		edit.text_submitted.connect(func(t: String) -> void:
			ScenarioLibrary.rename_to(id, t)
			_editing = ""
			refresh())
		edit.call_deferred("grab_focus")
	else:
		head.add_child(Gui.section(String(entry["name"])))
		head.add_child(Gui.spacer())
		var start := Gui.primary("Play from here", Vector2(190, 48))
		start.pressed.connect(func() -> void:
			SFX.play("select", -12.0)
			play_requested.emit(id))
		head.add_child(start)
		head.add_child(_action("Edit", func() -> void:
			SFX.play("select", -14.0)
			edit_requested.emit(id)))
		head.add_child(_action("Duplicate & edit", func() -> void:
			SFX.play("select", -14.0)
			create_requested.emit(id)))
		head.add_child(_action("Rename", func() -> void:
			_editing = id
			SFX.play("click", -18.0)
			refresh()))
		head.add_child(_action("Delete", func() -> void: _confirm_delete(entry)))
		v.add_child(head)

	var note := String(entry["note"])
	v.add_child(Gui.para(note if note != "" else "No description."))

	# ---- the objective and how the practice has gone
	var data: Dictionary = entry["data"]
	var obj: Dictionary = data.get("objective", {})
	var objline := Gui.label(Objective.describe(obj), Gui.T_BODY,
		Gui.ACCENT if Objective.is_set(obj) else Gui.MUTED)
	objline.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(objline)
	if Objective.is_set(obj):
		var sig := AttemptLog.signature(data, obj)
		var sum := AttemptLog.summary(sig)
		var best: Dictionary = sum["best"]
		var line := ""
		if int(sum["attempts"]) == 0:
			line = "No attempts yet."
		elif best.is_empty():
			line = "%d attempt%s, none completed yet." % [
				int(sum["attempts"]), "" if int(sum["attempts"]) == 1 else "s"]
		else:
			line = "Best %.1f s  ·  %d of %d attempts completed (%.0f%%)" % [
				float(best.get("elapsed", 0.0)), int(sum["succeeded"]),
				int(sum["attempts"]), float(sum["rate"])]
		v.add_child(Gui.label(line, Gui.T_SMALL, Gui.MUTED))

	var facts := Gui.hbox(28)
	var d := Snapshot.describe(entry["data"])
	facts.add_child(Gui.fact(String(d["phase"]), "Phase"))
	facts.add_child(Gui.fact(_clock(float(d["time_left"]), String(d["phase"])),
		"Time left"))
	facts.add_child(Gui.fact("%d" % int(d["robots"]), "Robots"))
	var ally := Gui.fact(BB.alliance_name(int(d["alliance"])).capitalize(), "Alliance")
	(ally.get_child(0) as Label).add_theme_color_override(
		"font_color", Gui.alliance_ink(int(d["alliance"])))
	facts.add_child(ally)
	facts.add_child(Gui.fact("%d" % int(d["elements"]), "Elements"))
	facts.add_child(Gui.spacer())
	facts.add_child(Gui.fact(_when(String(entry["updated"])), "Saved"))
	v.add_child(facts)
	return pair[0]

func _clock(t: float, phase: String) -> String:
	if phase == "Pre-match" or phase == "Finished":
		return "—"
	if t <= 0.0:
		return "no clock"
	return "%d:%02d" % [int(t) / 60, int(t) % 60]

func _when(raw: String) -> String:
	if raw.length() < 16:
		return "—"
	var months := ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
		"Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	var mi := clampi(int(raw.substr(5, 2)) - 1, 0, 11)
	return "%s %s · %s" % [months[mi], raw.substr(8, 2), raw.substr(11, 5)]

func _action(text: String, cb: Callable) -> Button:
	var b := Gui.button(text, Gui.Look.SECONDARY, Vector2(0, 48))
	b.add_theme_font_size_override("font_size", Gui.T_SMALL)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.pressed.connect(cb)
	return b

## Deleting is not undoable, so it asks — and says which one.
func _confirm_delete(entry: Dictionary) -> void:
	SFX.play("click", -16.0)
	var d := ConfirmationDialog.new()
	d.title = "Delete situation"
	d.dialog_text = 'Delete "%s"? This cannot be undone.' % String(entry["name"])
	d.ok_button_text = "Delete"
	add_child(d)
	d.confirmed.connect(func() -> void:
		ScenarioLibrary.delete_one(String(entry["id"]))
		SFX.play("click", -14.0)
		refresh())
	d.close_requested.connect(func() -> void: d.queue_free())
	d.popup_centered()

# ==================================================================== open ===

func open() -> void:
	_editing = ""
	refresh()
	_root.visible = true
	_s["foot_btn"].grab_focus()

func close() -> void:
	_root.visible = false

func is_open() -> bool:
	return _root.visible
