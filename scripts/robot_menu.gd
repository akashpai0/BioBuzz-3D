class_name RobotMenu
extends CanvasLayer
##
## GARAGE — everything about the robot rather than the match.
##
## Three tabs beside a live 3D preview, matching the design reference:
##
##   Hardware     which driving profile, how many intakes, what it collects,
##                and the calibration wizard behind "Calibrate my robot"
##   Appearance   your team's CAD model, its scale and its orientation
##   Autonomous   the real routine library: record, choose, test, delete
##
## Everything applies immediately and is saved immediately, the same as
## Settings, because a robot page you have to confirm is one you cannot see
## yourself changing.
##

signal closed
signal navigate(page: String)
signal record_requested(name: String)

const TABS := ["Hardware", "Appearance", "Autonomous"]

var _root: Control
var _s: Dictionary = {}
var _panel_box: VBoxContainer
var _tabs: Array[Button] = []
var _tab := 0
var _file: FileDialog
## Why the last import was refused, shown under the Import button ("" = none).
var _import_msg := ""
var _preview: RobotPreview
var _facts: HBoxContainer
var _title_edit: LineEdit
## Which saved routine runs in AUTO. Empty means the robot sits still.
var active_auto := ""
## The Play screen, which owns the intake choices and the session summary.
var play: Menu

# ==================================================================== build ==

func build() -> void:
	layer = 28
	_s = Gui.shell("Garage", func(p: String) -> void: navigate.emit(p))
	_root = _s["root"]
	_root.visible = false
	add_child(_root)
	_s["eyebrow"].text = "ROBOT GARAGE"

	var rename := Gui.button("Rename")
	rename.pressed.connect(_begin_rename)
	_s["head_right"].add_child(rename)

	var page := Gui.vbox(Gui.S24)
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_s["body"].add_child(page)

	var tabrow := Gui.hbox(Gui.S8)
	page.add_child(tabrow)
	for i in TABS.size():
		var b := Gui.button(TABS[i], Gui.Look.TAB, Vector2(0, 46))
		b.pressed.connect(func() -> void:
			SFX.play("select", -16.0)
			show_tab(i))
		tabrow.add_child(b)
		_tabs.append(b)

	var cols := Gui.two_columns(page)
	var left: VBoxContainer = cols[0]
	var right: VBoxContainer = cols[1]

	var box := Gui.scroll_card(Gui.S16)
	left.add_child(box[0])
	_panel_box = box[1]
	_panel_box.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var pv := Gui.card(Gui.S16)
	pv[0].size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(pv[0])
	var pvv: VBoxContainer = pv[1]
	pvv.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pvv.add_child(Gui.section("Robot preview"))
	_preview = RobotPreview.new(200)
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pvv.add_child(_preview)
	_preview.build()
	_facts = Gui.hbox(24)
	pvv.add_child(_facts)

	_file = FileDialog.new()
	_file.access = FileDialog.ACCESS_FILESYSTEM
	_file.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file.filters = PackedStringArray([
		"*.glb, *.gltf ; glTF from CAD", "*.stl ; STL mesh"])
	_file.size = Vector2i(900, 620)
	_file.file_selected.connect(_on_file)
	add_child(_file)

	_s["foot_btn"].text = "Back to Play"
	_s["foot_btn"].pressed.connect(func() -> void:
		SFX.play("click", -14.0)
		navigate.emit("Play"))
	RobotShop.changed.connect(_on_shop_changed)
	show_tab(0)

func _on_shop_changed() -> void:
	if _preview:
		_preview.rebuild(_preview.alliance, _preview.intakes)
	_refresh_chrome()

## Title, preview and the fact strip — everything outside the tab body.
func _refresh_chrome() -> void:
	_s["title"].text = RobotShop.robot_name
	var a := play.alliance if play else BB.Alliance.RED
	var n := play.robot_intakes if play else 1
	if _preview and (_preview.alliance != a or _preview.intakes != n):
		_preview.rebuild(a, n)
	for c in _facts.get_children():
		c.queue_free()
	_facts.add_child(Gui.fact("%.0f in/s" % RobotShop.top_speed_in_s(), "Top speed"))
	_facts.add_child(Gui.fact("%.0f°/s" % RobotShop.turn_deg_s(), "Turn rate"))
	_facts.add_child(Gui.fact("Front" if n == 1 else "Both ends", "Intake"))
	if play:
		_s["foot_line"].text = play.summary_line()

func _begin_rename() -> void:
	if _title_edit != null:
		return
	SFX.play("select", -16.0)
	_title_edit = Gui.line_edit("robot name", RobotShop.robot_name)
	_title_edit.max_length = 24
	_title_edit.custom_minimum_size = Vector2(340, 52)
	_title_edit.add_theme_font_size_override("font_size", Gui.T_SECTION)
	_s["title"].visible = false
	_s["title"].get_parent().add_child(_title_edit)
	_title_edit.grab_focus()
	_title_edit.text_submitted.connect(func(t: String) -> void: _end_rename(t))
	_title_edit.focus_exited.connect(func() -> void: _end_rename(_title_edit.text))

func _end_rename(t: String) -> void:
	if _title_edit == null:
		return
	var n := t.strip_edges()
	if n != "":
		RobotShop.robot_name = n
		RobotShop.save_cfg()
	_title_edit.queue_free()
	_title_edit = null
	_s["title"].visible = true
	_refresh_chrome()

# ===================================================================== tabs ==

func show_tab(i: int) -> void:
	_tab = i
	for c in _panel_box.get_children():
		c.queue_free()
	for t in _tabs.size():
		Gui.select(_tabs[t], t == i)
	if _preview:
		_preview.guides = i == 1
	match i:
		0: _tab_hardware()
		1: _tab_appearance()
		2: _tab_autonomous()
	_refresh_chrome()
	# keep the focus ring on the tab you are actually looking at
	if _root.visible:
		_tabs[i].grab_focus()

func _note(t: String) -> void:
	_panel_box.add_child(Gui.para(t))

# ------------------------------------------------------------------ hardware

func _tab_hardware() -> void:
	_panel_box.add_child(Gui.section("Driving profile"))

	var rows: Array = []
	rows.append(Gui.row("Profile", Gui.dropdown(
		["Stock robot", "From measurements"],
		0 if RobotShop.source == RobotShop.Source.STOCK else 1,
		func(i: int) -> void:
			RobotShop.source = RobotShop.Source.STOCK if i == 0 \
				else RobotShop.Source.MEASURED
			RobotShop.use_specs = i == 1
			RobotShop.save_cfg()
			RobotShop.changed.emit()
			show_tab(0), 240)))
	Gui.rows(_panel_box, rows)

	if RobotShop.source == RobotShop.Source.STOCK:
		_note("Stock handling keeps practice runs comparable: %.0f in/s and "
			% BB.DRIVE_SPEED_IN_S
			+ "%.0f°/s for everyone, which is what the leaderboard is measured on."
			% BB.TURN_RATE_DEG_S)
	else:
		_note("Your own numbers are driving the robot. Switch back to Stock "
			+ "robot for a run that compares with everyone else's.")

	var layout: Array = []
	layout.append(Gui.row("Intakes", Gui.dropdown(
		["Front only", "Front and rear"],
		(play.robot_intakes - 1) if play else 0,
		func(i: int) -> void:
			if play:
				play.robot_intakes = i + 1
				play.refresh()
			_refresh_chrome(), 240)))
	layout.append(Gui.row("Collects", Gui.dropdown(
		["Pollen only", "Pollen + nectar"],
		1 if (play and play.takes_nectar) else 0,
		func(i: int) -> void:
			if play:
				play.takes_nectar = i == 1
				play.refresh(), 240)))
	var lbox := Gui.vbox(0)
	_panel_box.add_child(lbox)
	Gui.rows(lbox, layout)
	_note("A second intake collects from either end. Neither choice changes "
		+ "how the robot drives, how fast it shoots or the four balls it may "
		+ "hold — and the leaderboard keeps one-intake and two-intake runs in "
		+ "separate tables, because they are not the same contest.")

	_panel_box.add_child(Gui.divider())

	if RobotShop.source == RobotShop.Source.STOCK:
		var cal := Gui.button("Calibrate my robot")
		cal.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		cal.pressed.connect(func() -> void:
			RobotShop.source = RobotShop.Source.MEASURED
			RobotShop.use_specs = true
			RobotShop.save_cfg()
			RobotShop.changed.emit()
			SFX.play("select", -14.0)
			show_tab(0))
		_panel_box.add_child(cal)
		_note("Six numbers you can get in one practice session with a stopwatch "
			+ "and a tape measure. Every one of them overrides what the motor "
			+ "catalogue would have predicted.")
		return

	_calibration()

## THE CALIBRATION WIZARD. Every field is a stopwatch or a tape measure, so it
## is usable before anyone has measured anything and gets more accurate as they
## do — nobody should have to finish a measuring session before they can drive.
func _calibration() -> void:
	_panel_box.add_child(Gui.section("What your robot actually does"))
	_measure("Top speed, forward", "meas_fwd", "%.0f in/s",
		"flat out down the long side of the field")
	_measure("Top speed, sideways", "meas_strafe", "%.0f in/s",
		"the same run, strafing")
	_measure("Standstill to top speed", "meas_accel", "%.2f s",
		"stopwatch from the moment you push the stick")
	_measure("Stopping distance", "meas_stop", "%.0f in",
		"let go at full speed and measure how far it carries")
	_measure("Turn rate", "meas_turn", "%.0f°/s",
		"time a full spin and divide 360 by it")
	_measure("Robot weight", "weight_lb", "%.0f lb", "with the battery in")

	_panel_box.add_child(Gui.divider())
	_panel_box.add_child(Gui.section("What the simulator does with that"))
	for r in RobotShop.measured_rows():
		_readout(String(r[0]), String(r[1]), String(r[2]))
	_note("Stopping distance is the one you will feel. It is the difference "
		+ "between knowing when to let go on the approach to a cell and "
		+ "sailing past it every time.")

func _measure(label: String, key: String, fmt: String, hint: String) -> void:
	var spec: Array = RobotShop.SPEC[key]
	var s := Gui.slider(float(spec[1]), float(spec[2]), RobotShop.get_spec(key),
		0.01 if float(spec[2]) <= 5.0 else 1.0)
	var box := Gui.slider_row(label, s, func(v: float) -> String: return fmt % v)
	s.value_changed.connect(func(v: float) -> void:
		RobotShop.set_spec(key, v)
		_refresh_chrome())
	s.drag_ended.connect(func(_c: bool) -> void:
		SFX.play("click", -20.0)
		if _tab == 0:
			show_tab(0))
	box.add_child(Gui.label(hint, Gui.T_SMALL, Gui.MUTED))
	_panel_box.add_child(box)

func _readout(label: String, value: String, hint: String) -> void:
	var v := Gui.vbox(2)
	v.size_flags_horizontal = Control.SIZE_SHRINK_END
	var val := Gui.label(value, Gui.T_BODY, Gui.ACCENT)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.add_child(val)
	if hint != "":
		var h := Gui.label(hint, Gui.T_SMALL, Gui.MUTED)
		h.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		v.add_child(h)
	_panel_box.add_child(Gui.row(label, v))

# ---------------------------------------------------------------- appearance

func _tab_appearance() -> void:
	var has := RobotShop.model_path != ""
	_panel_box.add_child(Gui.section("Make it your robot"))
	_note("Bring in your team's CAD model.")

	var row := Gui.hbox(Gui.S8)
	row.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var imp := Gui.primary("Import model", Vector2(190, 50))
	imp.pressed.connect(func() -> void:
		SFX.play("select", -16.0)
		_file.popup_centered(Vector2i(900, 620)))
	row.add_child(imp)
	if OS.has_feature("web"):
		# a browser page cannot browse the computer's folders
		imp.disabled = true
		imp.tooltip_text = "Importing CAD needs the downloadable version."
	if has:
		var rm := Gui.button("Remove")
		rm.pressed.connect(func() -> void:
			RobotShop.model_path = ""
			RobotShop.save_cfg()
			RobotShop.changed.emit()
			SFX.play("click", -14.0)
			show_tab(1))
		row.add_child(rm)
	_panel_box.add_child(row)
	if OS.has_feature("web"):
		_panel_box.add_child(Gui.label("Importing your team's CAD needs the downloadable version of the game.",
			Gui.T_SMALL, Gui.MUTED, true))
	if _import_msg != "":
		# a refused import says why right under the button, in red — not in
		# the small print at the bottom of the screen
		_panel_box.add_child(Gui.label(_import_msg, Gui.T_BODY, Gui.RED_INK, true))

	if has:
		_panel_box.add_child(Gui.divider())
		_panel_box.add_child(Gui.row("Current model",
			Gui.label(RobotShop.model_path.get_file(), Gui.T_BODY, Gui.ACCENT)))
		var sc := Gui.slider(0.25, 2.5, RobotShop.model_scale, 0.01)
		sc.value_changed.connect(func(v: float) -> void:
			RobotShop.model_scale = v
			RobotShop.save_cfg()
			RobotShop.changed.emit())
		_panel_box.add_child(Gui.slider_row("Scale", sc,
			func(v: float) -> String: return "%.2fx" % v))
		_panel_box.add_child(Gui.divider())
		var th := Gui.label("Line it up", Gui.T_BODY, Gui.INK)
		Gui.weight(th, 1)
		_panel_box.add_child(th)
		_note("Turn the model until your intake faces the yellow FRONT arrow and "
			+ "it stands on the floor the right way up. Drag the preview to look "
			+ "around it. The launcher is the turret on top in the middle; it aims "
			+ "itself, so point your shooter's side wherever it really is.")
		for axis in [["Tip forward / back", "x"], ["Turn left / right", "y"], ["Roll side to side", "z"]]:
			_panel_box.add_child(_rot_row(axis[0], axis[1]))
		var reset := Gui.button("Reset rotation")
		reset.pressed.connect(func() -> void:
			RobotShop.model_rot = CadImport.up_rotation(CadImport.default_up(RobotShop.model_path))
			RobotShop.save_cfg()
			RobotShop.changed.emit()
			SFX.play("click", -14.0)
			show_tab(1))
		var rr := Gui.hbox(Gui.S8)
		rr.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		rr.add_child(reset)
		_panel_box.add_child(rr)

	_panel_box.add_child(Gui.divider())
	var h := Gui.label("Appearance only", Gui.T_BODY, Gui.INK)
	Gui.weight(h, 1)
	_panel_box.add_child(h)
	_note("Importing changes the visual model. Driving and collisions use your "
		+ "robot profile: collision stays the 18 inch cube R102 requires, and "
		+ "the drivetrain still comes from the profile above.")
	_note("Wheels, the turret and your alliance bumpers are still drawn on top, "
		+ "because they move and an imported mesh is one rigid lump. GLB and "
		+ "glTF keep their colours; STL is triangles only, so it arrives grey. "
		+ "The model is scaled to sit inside the 18 inch cube whatever units it "
		+ "was drawn in.")
	_panel_box.add_child(Gui.label("Supported: GLB, glTF, STL", Gui.T_SMALL, Gui.MUTED))

## One rotation axis: a fine slider and quarter-turn buttons (a CAD file is
## almost always off by a quarter turn, and dragging to exactly 90 is fiddly).
func _rot_row(title: String, axis: String) -> Control:
	var v := Gui.vbox(4)
	var cur: float = RobotShop.model_rot[axis]
	var sl := Gui.slider(-180.0, 180.0, _wrap180(cur), 1.0)
	var set_axis := func(deg: float) -> void:
		var r := RobotShop.model_rot
		r[axis] = _wrap180(deg)
		RobotShop.model_rot = r
		RobotShop.save_cfg()
		RobotShop.changed.emit()
	sl.value_changed.connect(func(d: float) -> void: set_axis.call(d))
	v.add_child(Gui.slider_row(title, sl, func(d: float) -> String: return "%.0f°" % d))
	var btns := Gui.hbox(Gui.S8)
	btns.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	for step in [-90.0, 90.0]:
		var b := Gui.button("%+d°" % int(step))
		b.pressed.connect(func() -> void:
			var nv := _wrap180(RobotShop.model_rot[axis] + step)
			sl.value = nv            # moves the slider, its label and the model
			SFX.play("click", -18.0))
		btns.add_child(b)
	v.add_child(btns)
	return v

static func _wrap180(d: float) -> float:
	return fposmod(d + 180.0, 360.0) - 180.0

func _on_file(path: String) -> void:
	var errs: Array = []
	var model := CadImport.load_model(path, errs)
	if model == null:
		_import_msg = "%s: %s" % [path.get_file(), String(errs[0]) if not errs.is_empty()
			else "Could not read that file."]
		_s["foot_note"].text = "Import failed — see the Appearance tab."
		SFX.play("foul", -16.0)
		show_tab(1)
		return
	_import_msg = ""
	var tris := CadImport.triangle_count(model)
	model.queue_free()
	var stashed := CadImport.stash(path)
	if stashed == "":
		_s["foot_note"].text = "Could not copy that file into the game's folder."
		return
	RobotShop.model_path = stashed
	# a new file starts standing upright for its kind (CAD STL is Z-up)
	RobotShop.model_rot = CadImport.up_rotation(CadImport.default_up(stashed))
	RobotShop.save_cfg()
	RobotShop.changed.emit()
	_s["foot_note"].text = "Imported %s — %s triangles." % [
		path.get_file(), _commas(tris)]
	SFX.play("select", -12.0)
	show_tab(1)

# --------------------------------------------------------------- autonomous

func _tab_autonomous() -> void:
	var saved := AutoRoutine.list_saved()
	if saved.is_empty():
		_panel_box.add_child(Gui.section("Your first autonomous"))
		_note("Record up to %d seconds of driving, then use it at the start of "
			% int(BB.AUTO_S)
			+ "a full match while you sit on your hands like a real driver.")
		_panel_box.add_child(Gui.divider())
		_panel_box.add_child(_record_button())
		_note("No saved routines yet. What gets saved is your INPUT, not your "
			+ "path: the robot replays the commands you gave, so if a ball is "
			+ "somewhere different the run goes differently — the same way a "
			+ "real encoder auto drifts on a different battery.")
		return

	_panel_box.add_child(Gui.section("Saved routines"))
	var list := Gui.vbox(0)
	_panel_box.add_child(list)
	var made: Array = []
	for n in saved:
		var rt := AutoRoutine.load_named(n)
		var right := Gui.hbox(Gui.S8)
		right.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var pick := Gui.button("In use" if active_auto == n else "Use")
		Gui.select(pick, active_auto == n)
		pick.pressed.connect(func() -> void:
			active_auto = "" if active_auto == n else n
			SFX.play("select", -16.0)
			show_tab(2)
			if play:
				play.refresh())
		right.add_child(pick)
		var test := Gui.button("Test")
		test.pressed.connect(func() -> void:
			active_auto = n
			SFX.play("select", -12.0)
			if play:
				play.refresh()
			navigate.emit("Play"))
		right.add_child(test)
		var del := Gui.button("Delete")
		del.pressed.connect(func() -> void: _confirm_delete(n))
		right.add_child(del)
		var label := "%s   ·   %.1f s" % [n, rt.length_s() if rt else 0.0]
		made.append(Gui.row(label, right))
	Gui.rows(list, made)

	_panel_box.add_child(Gui.divider())
	var row := Gui.hbox(Gui.S8)
	row.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	row.add_child(_record_button())
	if active_auto != "":
		var none := Gui.button("Run no auto")
		none.pressed.connect(func() -> void:
			active_auto = ""
			SFX.play("click", -16.0)
			show_tab(2)
			if play:
				play.refresh())
		row.add_child(none)
	_panel_box.add_child(row)
	_note("Test drops you back on Play with that routine selected — start a "
		+ "full match and watch it run. Playback repeats your controls, so "
		+ "results vary with where the balls end up.")

func _record_button() -> Button:
	var b := Gui.primary("Record routine", Vector2(200, 50))
	b.pressed.connect(func() -> void:
		SFX.play("select", -12.0)
		close()
		record_requested.emit(""))
	return b

## Deleting a routine is not undoable, so it asks first.
func _confirm_delete(n: String) -> void:
	SFX.play("click", -16.0)
	var d := ConfirmationDialog.new()
	d.title = "Delete routine"
	d.dialog_text = 'Delete "%s"? This cannot be undone.' % n
	d.ok_button_text = "Delete"
	add_child(d)
	d.confirmed.connect(func() -> void:
		AutoRoutine.delete_named(n)
		if active_auto == n:
			active_auto = ""
		if play:
			play.refresh()
		show_tab(2))
	d.close_requested.connect(func() -> void: d.queue_free())
	d.popup_centered()

## Shown the moment a recording finishes: name it and keep it, or throw it out.
## Offered rather than saved automatically, because most first takes are bad and
## a folder full of auto-3, auto-4, auto-5 helps nobody.
var _pending: AutoRoutine
var _name_edit: LineEdit

func offer_save(rt: AutoRoutine) -> void:
	_pending = rt
	_root.visible = true
	_tab = 2
	for c in _panel_box.get_children():
		c.queue_free()
	for t in _tabs.size():
		Gui.select(_tabs[t], t == 2)
	_refresh_chrome()
	_panel_box.add_child(Gui.section("Recording finished"))
	_note("%.1f seconds, %d frames of input. Nothing is written to disk until "
		% [rt.length_s(), rt.frames.size()] + "you choose.")
	_name_edit = Gui.line_edit("routine name", "auto-%s"
		% Time.get_datetime_string_from_system(true).substr(5, 11)
			.replace(":", "").replace("T", "-"))
	_panel_box.add_child(Gui.row("Call it", _name_edit))
	_name_edit.custom_minimum_size = Vector2(320, 46)

	var row := Gui.hbox(Gui.S8)
	row.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var save := Gui.primary("Save and use", Vector2(190, 50))
	save.pressed.connect(func() -> void:
		var n := _name_edit.text.strip_edges()
		if n == "":
			_s["foot_note"].text = "Give it a name first."
			return
		if _pending.save_as(n):
			active_auto = n
			_s["foot_note"].text = "Saved. It will run as your autonomous next match."
			SFX.play("select", -10.0)
			if play:
				play.refresh()
			show_tab(2)
		else:
			_s["foot_note"].text = "Could not save that — try a simpler name.")
	row.add_child(save)
	var drop := Gui.button("Discard")
	drop.pressed.connect(func() -> void:
		_pending = null
		SFX.play("click", -16.0)
		show_tab(2))
	row.add_child(drop)
	_panel_box.add_child(row)
	_name_edit.grab_focus()

static func _commas(n: int) -> String:
	var s := str(n)
	var out := ""
	for i in s.length():
		if i > 0 and (s.length() - i) % 3 == 0:
			out += ","
		out += s[i]
	return out

# ===================================================================== open ==

func open() -> void:
	_root.visible = true
	show_tab(_tab)
	_s["foot_note"].text = "Changes apply to the next match you start."
	_tabs[_tab].grab_focus()

func close() -> void:
	_root.visible = false
	closed.emit()

func is_open() -> bool:
	return _root.visible
