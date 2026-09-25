class_name SettingsMenu
extends CanvasLayer
##
## SETTINGS — a category list on the left, one bounded panel on the right.
##
## Every widget is bound to a key in `Settings`, so moving a slider applies
## immediately and is on disk before your hand leaves the mouse. There is no
## OK/Cancel, because a settings screen you have to confirm is one you cannot
## hear yourself adjusting.
##
## Controls is the real device-assignment flow: it lists the seats the current
## setup actually needs, what each one is holding, and every binding that seat
## is responsible for, grouped the way a driver thinks about them.
##

signal closed
signal navigate(page: String)

const CATEGORIES := ["Audio", "Camera & display", "Graphics", "Controls"]

## Bindings by group. Anything in BB.ACTIONS not listed is internal.
const DRIVING := [
	["drive_fwd", "Drive forward"], ["drive_back", "Drive back"],
	["strafe_left", "Strafe left"], ["strafe_right", "Strafe right"],
	["turn_left", "Turn left"], ["turn_right", "Turn right"],
	["slow", "Precision mode (hold)"], ["field_centric", "Field-centric"],
]
const MECHANISMS := [
	["fire", "Fire (hold to empty)"], ["outtake", "Spit one out"],
	["intake_off", "Stop the intake (hold)"],
	["turret_left", "Turret left"], ["turret_right", "Turret right"],
	["hood_up", "Hood up"], ["hood_down", "Hood down"],
	["power_up", "More launcher power"], ["power_down", "Less launcher power"],
	["aim_assist", "Auto-aim"], ["recalibrate", "Recalibrate turret"],
]
const SESSION := [
	["cam_toggle", "Change camera"], ["start_match", "Start the match"],
	["reset", "Reset the field"], ["skip_auto", "Skip auto"],
	["record_auto", "Record an auto"], ["pause", "Menu"],
	["save_situation", "Save this situation"],
	["retry_scenario", "Retry the situation"],
]

var _root: Control
var _s: Dictionary = {}
var _panel_box: VBoxContainer
var _sides: Array[Button] = []
var _page := 0
## While non-empty, the next key pressed is captured for this action.
var _await_action := ""
var _await_button: Button
## The Play screen: the roster the Controls page describes, and the footer.
var play: Menu

func build() -> void:
	layer = 30
	_s = Gui.shell("Settings", func(p: String) -> void: navigate.emit(p))
	_root = _s["root"]
	_root.visible = false
	add_child(_root)
	_s["eyebrow"].text = "PREFERENCES"
	_s["title"].text = "Make it feel right."
	_s["head_right"].add_child(
		Gui.label("Changes save automatically", Gui.T_SMALL, Gui.MUTED))

	var split := Gui.hbox(Gui.GAP_COL)
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_s["body"].add_child(split)

	var side := Gui.vbox(Gui.S8)
	side.custom_minimum_size = Vector2(230, 0)
	split.add_child(side)
	for i in CATEGORIES.size():
		var b := Gui.button(CATEGORIES[i], Gui.Look.SIDE, Vector2(0, 50))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.pressed.connect(func() -> void:
			SFX.play("select", -16.0)
			show_category(i))
		side.add_child(b)
		_sides.append(b)
	side.add_child(Gui.vspacer())
	var reset := Gui.button("Reset to defaults")
	reset.alignment = HORIZONTAL_ALIGNMENT_LEFT
	reset.pressed.connect(_confirm_reset)
	side.add_child(reset)

	var pair := Gui.scroll_card(Gui.S24)
	pair[0].size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(pair[0])
	_panel_box = pair[1]

	_s["foot_btn"].text = "Back to Play"
	_s["foot_btn"].pressed.connect(func() -> void:
		SFX.play("click", -14.0)
		navigate.emit("Play"))
	show_category(0)

# ================================================================ categories =

func show_category(i: int) -> void:
	_page = i
	_await_action = ""
	for c in _panel_box.get_children():
		c.queue_free()
	for t in _sides.size():
		Gui.select(_sides[t], t == i)
	match i:
		0: _page_audio()
		1: _page_camera()
		2: _page_graphics()
		3: _page_controls()
	if play:
		_s["foot_line"].text = play.summary_line()
	_s["foot_note"].text = ""

## Kept so the screenshot harness can still walk the pages by number.
func _show_page(i: int) -> void:
	show_category(i)

func _page_audio() -> void:
	_panel_box.add_child(Gui.section("Audio levels"))
	_volume("Master", "audio/master")
	_volume("Robot & field", "audio/sfx")
	_volume("Crowd", "audio/crowd")
	_panel_box.add_child(Gui.para(
		"Every sound is generated from code at startup — there are no audio "
		+ "files. The flywheel is an oscillator driven by the launcher's real "
		+ "spin-up, so it rises and falls with the mechanism."))

func _page_camera() -> void:
	_panel_box.add_child(Gui.section("Camera & display"))
	var spec: Array = Settings.SPEC["game/fov"]
	var fov := Gui.slider(float(spec[1]), float(spec[2]),
		Settings.get_value("game/fov"), 1.0)
	fov.value_changed.connect(func(v: float) -> void:
		Settings.set_value("game/fov", v))
	_panel_box.add_child(Gui.slider_row("Field of view", fov,
		func(v: float) -> String: return "%.0f°" % v))

	var rows: Array = []
	rows.append(Gui.row("Alliance colours", Gui.dropdown(
		["Standard", "Colourblind"], int(Settings.get_value("game/colorblind")),
		func(i: int) -> void:
			Settings.set_value("game/colorblind", float(i)), 200)))
	rows.append(Gui.row("Match HUD", Gui.dropdown(
		["Hidden", "Visible"], int(Settings.get_value("game/show_hud")),
		func(i: int) -> void:
			Settings.set_value("game/show_hud", float(i)), 200)))
	rows.append(Gui.row("Opponent overlay", Gui.dropdown(
		["Hidden", "Visible"], int(Settings.get_value("game/opponent_overlay")),
		func(i: int) -> void:
			Settings.set_value("game/opponent_overlay", float(i)), 200)))
	var box := Gui.vbox(0)
	_panel_box.add_child(box)
	Gui.rows(box, rows)
	_panel_box.add_child(Gui.para(
		"Colourblind swaps the red/blue alliance pair for an orange/blue one "
		+ "everywhere it appears, including these menus."))
	_panel_box.add_child(Gui.para(
		"Opponent overlay draws each practice opponent's route or area on the "
		+ "field, with a line above it saying what it is doing right now."))

func _page_graphics() -> void:
	_panel_box.add_child(Gui.section("Graphics"))
	var rows: Array = []
	rows.append(Gui.row("Window", Gui.dropdown(["Windowed", "Fullscreen"],
		int(Settings.get_value("video/fullscreen")),
		func(i: int) -> void:
			Settings.set_value("video/fullscreen", float(i)), 200)))
	rows.append(Gui.row("V-sync", Gui.dropdown(["Off", "On"],
		int(Settings.get_value("video/vsync")),
		func(i: int) -> void:
			Settings.set_value("video/vsync", float(i)), 200)))
	var preset := Settings.matching_preset()
	var names: Array = Settings.QUALITY_NAMES.duplicate()
	if preset == 4:
		names.append("Custom")
	rows.append(Gui.row("Quality", Gui.dropdown(names, preset,
		func(i: int) -> void:
			if i < 4:
				Settings.apply_preset(i)
				_rebuild_graphics(), 200)))
	rows.append(Gui.row("Resolution", Gui.dropdown(
		["75% (faster)", "100%", "150% (sharper)", "200% (sharpest)"],
		int(Settings.get_value("video/render_scale")),
		func(i: int) -> void:
			_custom("video/render_scale", i), 200)))
	var aa: Array = ["Off", "2x", "4x", "8x"]
	if OS.has_feature("web"):
		aa = ["Off", "2x", "4x"]
	rows.append(Gui.row("Anti-aliasing", Gui.dropdown(aa,
		mini(int(Settings.get_value("video/msaa")), aa.size() - 1),
		func(i: int) -> void:
			_custom("video/msaa", i), 200)))
	var shadow_idx := 0
	if Settings.is_on("video/shadows"):
		shadow_idx = 1 + int(Settings.get_value("video/shadow_quality"))
	rows.append(Gui.row("Shadows", Gui.dropdown(["Off", "Low", "High", "Ultra"],
		shadow_idx,
		func(i: int) -> void:
			Settings.values["video/shadows"] = 1.0 if i > 0 else 0.0
			if i > 0:
				Settings.values["video/shadow_quality"] = float(i - 1)
			_custom("", 0), 200)))
	var box := Gui.vbox(0)
	_panel_box.add_child(box)
	Gui.rows(box, rows)
	_panel_box.add_child(Gui.para(
		"Max draws the field at twice the screen's resolution and shrinks it "
		+ "down — the sharpest picture, and the most work for the graphics card. "
		+ "If the frame rate struggles (F3 shows it), step down a preset; "
		+ "shadows and resolution cost the most."))

## One of the detail rows changed: store it and let the Quality row show
## whichever preset now matches (or Custom).
func _custom(key: String, v: int) -> void:
	if key != "":
		Settings.values[key] = float(v)
	Settings.set_value("video/quality", float(Settings.matching_preset()))
	_rebuild_graphics()

func _rebuild_graphics() -> void:
	# The rows show derived values (the preset, "Custom"), so redraw the page
	# rather than patching each dropdown.
	call_deferred("_show_graphics_again")

func _show_graphics_again() -> void:
	if _page != 2:
		return
	# keep keyboard/controller focus on the same row across the redraw
	var before := _panel_box.find_children("*", "OptionButton", true, false)
	var had := -1
	var f := get_viewport().gui_get_focus_owner()
	for i in before.size():
		if before[i] == f:
			had = i
	show_category(2)
	if had >= 0:
		await get_tree().process_frame
		var after := _panel_box.find_children("*", "OptionButton", true, false)
		if had < after.size():
			(after[had] as Control).grab_focus()

# ================================================================== controls =

# ================================================================== CONTROLS =
#
# The controller page. Built as five stacked sections, in the order somebody
# setting up a new pad actually needs them:
#
#   1. SEATS		who is holding what, and what to do when nobody is
#   2. TEST		 a live picture of the stick, and a way to go and drive
#   3. TUNING	   deadzones, curves, inversion, precision speed
#   4. BUTTONS	  remapping, grouped the way a driver thinks
#   5. PROFILES	 save the whole lot under a name
#
# EVERYTHING HERE RUNS WHILE THE GAME IS PAUSED. The settings screen is
# PROCESS_MODE_ALWAYS, so the live preview keeps updating with a match frozen
# behind it — and because it reads the pad through DriverInput's RAW path, it
# neither consumes a press nor sends anything to the halted robot.

## The seat whose profile the tuning and buttons below are editing.
var _seat := 0
## While non-empty, the next controller input is captured for this action.
var _await_pad := ""
var _await_pad_button: Button
## Set while the button that OPENED the rebind dialog is still held: a capture
## cannot start until it is released, or the dialog binds its own opening press.
var _await_armed := false
## A pending conflict, awaiting Replace or Cancel.
var _conflict: Dictionary = {}
## The identify flow: seat -> true while waiting for a button on a controller.
var _identify_seat := -1
## Live preview widgets, refreshed every frame while Controls is open.
var _live: Dictionary = {}

## Which sub-tab of Controls is showing. The whole page in one column was
## forty-three controls below the fold, which is not a setup flow, it is a
## scroll. Four short pages in the order somebody actually needs them.
const CTL_TABS := ["Seats", "Feel", "Buttons", "Profiles"]
var _ctl_tab := 0

func show_controls_tab(i: int) -> void:
	_ctl_tab = clampi(i, 0, CTL_TABS.size() - 1)
	show_category(3)

func _page_controls() -> void:
	_panel_box.add_child(Gui.section("Controllers"))
	# The long explanation belongs on the tab you arrive at, not repeated on
	# every one of them eating the top of the fold.
	if _ctl_tab == 0:
		_panel_box.add_child(Gui.para(
			"Set up a controller, see exactly what it is sending, and tune how "
			+ "it feels. None of this changes what the robot can do — the top "
			+ "speed and turn rate stay the same for everyone. It changes how "
			+ "far your thumb has to move to ask for them."))

	var tabs := Gui.hbox(6)
	tabs.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	for i in CTL_TABS.size():
		var b := Gui.button(String(CTL_TABS[i]), Gui.Look.TAB, Vector2(0, 42))
		Gui.select(b, i == _ctl_tab)
		b.pressed.connect(func() -> void:
			SFX.play("select", -18.0)
			show_controls_tab(i))
		tabs.add_child(b)
	_panel_box.add_child(tabs)
	_panel_box.add_child(Gui.divider())

	# The seat being edited is named on every tab, so nobody tunes the wrong
	# person's controller without noticing.
	if _ctl_tab != 0:
		_panel_box.add_child(Gui.label("Editing: %s · %s" % [
			Settings.seat_label(_seat), _editing_profile().name],
			Gui.T_SMALL, Gui.ACCENT))

	match _ctl_tab:
		0:
			_seats_section()
		1:
			_preview_section()
			_panel_box.add_child(Gui.divider())
			_tuning_section()
		2:
			# On Buttons the BINDINGS are what you came for, so the preview is
			# folded away: expanded it pushed every binding row below the fold.
			var disc := Gui.disclosure("Show what the controller is sending")
			_panel_box.add_child(disc[0])
			_panel_box.add_child(disc[1])
			var keep := _panel_box
			_panel_box = disc[1]
			_preview_section()
			_panel_box = keep
			_buttons_section()
		3:
			_profiles_section()

# ==================================================================== seats ==

func _plan() -> Array:
	var n_robots := play.robots if play else 1
	var mate_ai: bool = play.mate_is_ai if play else false
	var per: int = play.per_robot if play else 1
	return Settings.seat_plan(n_robots, mate_ai, per)

func _seat_devices() -> Array:
	var n := 0
	for e in _plan():
		if not bool(e["ai"]):
			n += 1
	return Settings.allocate_devices(n, DriverInput.devices())

func _seats_section() -> void:
	_panel_box.add_child(Gui.section("Seats"))
	var plan := _plan()
	var devices := _seat_devices()
	var pool := DriverInput.devices()
	var per: int = play.per_robot if play else 1
	if per == 1:
		_panel_box.add_child(Gui.para(
			"One person per robot, so the same controller drives and works the "
			+ "mechanisms. That is deliberate — set People per robot to "
			+ "Driver + operator on Play to split them."))

	for entry in plan:
		if bool(entry["ai"]):
			_panel_box.add_child(Gui.row("Robot %d" % int(entry["robot"]),
				Gui.label("AI teammate — no controller needed",
					Gui.T_SMALL, Gui.MUTED)))
			continue
		_seat_row(entry, int(entry["seat"]), devices, pool)

	if play and play.opponents > 0:
		_panel_box.add_child(Gui.label("%d AI opponent%s, no controllers needed."
			% [play.opponents, "" if play.opponents == 1 else "s"],
			Gui.T_SMALL, Gui.MUTED))

func _seat_row(entry: Dictionary, seat: int, devices: Array, pool: Array) -> void:
	var dev: int = devices[seat] if seat < devices.size() else DriverInput.NONE
	var pair := Gui.card(Gui.S8)
	_panel_box.add_child(pair[0])
	var v: VBoxContainer = pair[1]

	var head := Gui.hbox(Gui.S16)
	head.add_child(Gui.label("Robot %d · %s" % [int(entry["robot"]),
		String(entry["role"])], Gui.T_BODY, Gui.INK))
	head.add_child(Gui.spacer())
	var editing := seat == _seat
	var pick := Gui.button("Editing" if editing else "Edit this seat",
		Gui.Look.SECONDARY, Vector2(150, 40))
	if editing:
		Gui.tint(pick, Gui.ACCENT)
	pick.pressed.connect(func() -> void:
		_seat = seat
		SFX.play("select", -16.0)
		show_category(3))
	head.add_child(pick)
	v.add_child(head)

	# ---- what it is holding, and whether that is actually true right now
	if dev <= DriverInput.NONE:
		var warn := Gui.para(
			"No device left for this seat, so this robot will not move. Plug "
			+ "in another controller, pick one below, or set fewer people on "
			+ "Play.")
		warn.add_theme_color_override("font_color", Gui.WARN)
		v.add_child(warn)
	else:
		var connected := dev < 0 or Input.get_connected_joypads().has(dev)
		v.add_child(Gui.status("%s — %s" % [
			Gui.sentence(DriverInput.device_name(dev)),
			"connected" if connected else "NOT CONNECTED"],
			Gui.GOOD if connected else Gui.RED_INK))
		if dev >= 0 and DriverInput.is_ambiguous(dev):
			var amb := Gui.para(
				"Two identical controllers are plugged in and they report the "
				+ "same identity, so the game cannot tell them apart on its "
				+ "own. Use Identify to say which one is this seat's.")
			amb.add_theme_color_override("font_color", Gui.WARN)
			v.add_child(amb)

	# ---- device chooser
	var names: Array = ["Automatic"]
	var ids: Array = [DriverInput.NONE]
	for d in pool:
		names.append(Gui.sentence(DriverInput.device_name(d)) if d < 0
			else "Controller %d · %s" % [d + 1, Input.get_joy_name(d)])
		ids.append(d)
	var chosen := 0
	if Settings.seats.has(seat) and ids.has(int(Settings.seats[seat])):
		chosen = ids.find(int(Settings.seats[seat]))
	v.add_child(Gui.row("Device", Gui.dropdown(names, chosen, func(i: int) -> void:
		_assign_seat(seat, int(ids[i])), 300)))

	# ---- profile chooser
	var profs := ControlProfile.all()
	var pnames: Array = []
	var pids: Array = []
	for p in profs:
		pnames.append((p as ControlProfile).name)
		pids.append((p as ControlProfile).id)
	var pchosen: int = maxi(0, pids.find(Settings.seat_profile(seat)))
	v.add_child(Gui.row("Profile", Gui.dropdown(pnames, pchosen,
		func(i: int) -> void:
			Settings.set_seat_profile(seat, String(pids[i]))
			_seat = seat
			show_category(3), 300)))

	# ---- identify
	var idrow := Gui.hbox(Gui.S8)
	var idbtn := Gui.button(
		"Press a button on it…" if _identify_seat == seat else "Identify",
		Gui.Look.SECONDARY, Vector2(200, 40))
	idbtn.pressed.connect(func() -> void:
		_identify_seat = seat
		DriverInput.gate_all()
		SFX.play("select", -16.0)
		show_category(3))
	idrow.add_child(idbtn)
	idrow.add_child(Gui.label(
		"Hold the controller you want on this seat and press any button."
			if _identify_seat == seat
			else "Not sure which pad is which? Press this, then a button on it.",
		Gui.T_SMALL, Gui.ACCENT if _identify_seat == seat else Gui.MUTED))
	v.add_child(idrow)

## Assign, refusing to hand one device to two people by accident.
func _assign_seat(seat: int, dev: int) -> void:
	if dev > DriverInput.NONE:
		for other in Settings.seats:
			if int(other) != seat and int(Settings.seats[other]) == dev:
				_s["foot_note"].text = ("%s is already assigned to %s. "
					% [Gui.sentence(DriverInput.device_name(dev)),
						Settings.seat_label(int(other))]
					+ "Set that seat to something else first.")
				SFX.play("foul", -18.0)
				show_category(3)
				return
	Settings.set_seat_device(seat, dev)
	DriverInput.require_neutral(dev)
	_s["foot_note"].text = "Assigned."
	show_category(3)

# ================================================================== preview ==

func _preview_section() -> void:
	_panel_box.add_child(Gui.section("What the controller is sending"))
	var dev := _editing_device()
	_panel_box.add_child(Gui.para(
		"Live, straight from the hardware. The left pair is what the stick is "
		+ "actually sending; the right pair is what the robot would be asked "
		+ "for after your tuning below. Reading this does not press anything "
		+ "and does not move a paused robot."))

	_live.clear()
	var pair := Gui.card(Gui.S8)
	_panel_box.add_child(pair[0])
	var v: VBoxContainer = pair[1]
	_live["device"] = Gui.label("", Gui.T_SMALL, Gui.MUTED)
	v.add_child(_live["device"])
	if dev <= DriverInput.NONE:
		v.add_child(Gui.para("This seat has no device, so there is nothing to show."))
		return
	for key in ["move_raw", "move_out", "turn_raw", "turn_out"]:
		_live[key] = Gui.label("", Gui.T_BODY, Gui.INK)
	v.add_child(Gui.row("Driving stick — raw", _live["move_raw"]))
	v.add_child(Gui.row("  after tuning", _live["move_out"]))
	v.add_child(Gui.row("Turning — raw", _live["turn_raw"]))
	v.add_child(Gui.row("  after tuning", _live["turn_out"]))
	for key2 in ["trig_l", "trig_r"]:
		_live[key2] = Gui.label("", Gui.T_BODY, Gui.INK)
	v.add_child(Gui.row("Left trigger", _live["trig_l"]))
	v.add_child(Gui.row("Right trigger", _live["trig_r"]))
	_live["buttons"] = Gui.label("", Gui.T_BODY, Gui.ACCENT)
	_live["buttons"].autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(Gui.row("Pressed now", _live["buttons"]))
	_live["gate"] = Gui.label("", Gui.T_SMALL, Gui.MUTED)
	v.add_child(_live["gate"])

	var row := Gui.hbox(Gui.S8)
	if play != null and play.match_running:
		var apply := Gui.primary("Apply and resume", Vector2(220, 46))
		apply.pressed.connect(func() -> void:
			SFX.play("select", -12.0)
			DriverInput.refresh_profiles()
			DriverInput.gate_all()
			navigate.emit("Play"))
		row.add_child(apply)
		row.add_child(Gui.label(
			"Your match is paused exactly where you left it. This goes back to "
			+ "it with the new settings.", Gui.T_SMALL, Gui.MUTED))
	else:
		var drive := Gui.primary("Test drive", Vector2(200, 46))
		drive.pressed.connect(func() -> void:
			SFX.play("select", -12.0)
			test_drive_requested.emit())
		row.add_child(drive)
		row.add_child(Gui.label(
			"An empty field with no clock. Nothing you do there is recorded.",
			Gui.T_SMALL, Gui.MUTED))
	_panel_box.add_child(row)

signal test_drive_requested

func _editing_device() -> int:
	var devices := _seat_devices()
	if _seat >= 0 and _seat < devices.size():
		return int(devices[_seat])
	return DriverInput.NONE

func _editing_profile() -> ControlProfile:
	return ControlProfile.get_one(Settings.seat_profile(_seat))

## Refreshed every frame while Controls is open. The screen is
## PROCESS_MODE_ALWAYS so this keeps working with a match frozen behind it.
func _process(_d: float) -> void:
	if not _root.visible or _page != 3:
		return
	_tick_identify()
	_poll_pad_capture()
	_tick_preview()

func _tick_preview() -> void:
	# The page is rebuilt on every tab switch, and the old labels are freed a
	# frame before this dictionary is refilled. Casting a freed label is an
	# error, not a null, so check the whole set before touching any of it.
	if not _live.has("device"):
		return
	for v in _live.values():
		if not is_instance_valid(v):
			_live.clear()
			return
	var dev := _editing_device()
	var prof := _editing_profile()
	(_live["device"] as Label).text = "%s · profile: %s" % [
		Gui.sentence(DriverInput.device_name(dev)), prof.name]
	if not _live.has("move_raw") or dev <= DriverInput.NONE:
		return
	var raw := DriverInput.raw_move(dev)
	var out := DriverInput.shape_vector(
		Vector2(-raw.x if prof.is_on("invert_move_x") else raw.x,
			-raw.y if prof.is_on("invert_move_y") else raw.y),
		prof.get_tuning("move_deadzone"), prof.get_tuning("move_curve"))
	(_live["move_raw"] as Label).text = "x %+.2f   y %+.2f   (%.2f from centre)" \
		% [raw.x, raw.y, raw.length()]
	(_live["move_out"] as Label).text = "x %+.2f   y %+.2f   (%.2f of full)" \
		% [out.x, out.y, out.length()]
	var traw := DriverInput.raw_turn(dev)
	if prof.is_on("invert_turn"):
		traw = -traw
	var tout := signf(traw) * DriverInput.shape(absf(traw),
		prof.get_tuning("turn_deadzone"), prof.get_tuning("turn_curve"))
	(_live["turn_raw"] as Label).text = "%+.2f" % traw
	(_live["turn_out"] as Label).text = "%+.2f of full turn" % tout
	if dev >= 0:
		(_live["trig_l"] as Label).text = _bar(
			maxf(0.0, Input.get_joy_axis(dev, JOY_AXIS_TRIGGER_LEFT)))
		(_live["trig_r"] as Label).text = _bar(
			maxf(0.0, Input.get_joy_axis(dev, JOY_AXIS_TRIGGER_RIGHT)))
		var down: Array[String] = []
		for b in 24:
			if Input.is_joy_button_pressed(dev, b):
				down.append(BB.pad_button_name(b))
		(_live["buttons"] as Label).text = ", ".join(down) if not down.is_empty() \
			else "nothing"
	else:
		(_live["trig_l"] as Label).text = "—  (keyboard)"
		(_live["trig_r"] as Label).text = "—  (keyboard)"
		var keys_down: Array[String] = []
		for a: String in BB.ACTIONS:
			if DriverInput.raw_strength(dev, a) > 0.5:
				keys_down.append(a)
		(_live["buttons"] as Label).text = ", ".join(keys_down) \
			if not keys_down.is_empty() else "nothing"
	var gated := DriverInput.is_gated(dev)
	(_live["gate"] as Label).text = ("Waiting for everything to return to "
		+ "neutral before this controller is live again."
		) if gated else "Ready."
	(_live["gate"] as Label).add_theme_color_override("font_color",
		Gui.WARN if gated else Gui.MUTED)

func _bar(v: float) -> String:
	var n := int(round(clampf(v, 0.0, 1.0) * 16.0))
	return "[%s%s] %.2f" % ["=".repeat(n), ".".repeat(16 - n), v]

## Identify: whichever controller sends a button next takes this seat.
func _tick_identify() -> void:
	if _identify_seat < 0:
		return
	for d in Input.get_connected_joypads():
		for b in 24:
			if Input.is_joy_button_pressed(d, b):
				var seat := _identify_seat
				_identify_seat = -1
				_assign_seat(seat, d)
				_s["foot_note"].text = "%s is now %s." % [
					Input.get_joy_name(d), Settings.seat_label(seat)]
				SFX.play("select", -12.0)
				return

# =================================================================== tuning ==

func _tuning_section() -> void:
	var prof := _editing_profile()
	var head := Gui.hbox(Gui.S16)
	head.add_child(Gui.section("Feel — %s" % prof.name))
	head.add_child(Gui.spacer())
	var rst := Gui.button("Reset this tuning", Gui.Look.SECONDARY, Vector2(190, 40))
	rst.pressed.connect(func() -> void:
		prof.reset_tuning()
		ControlProfile.save_one(prof)
		DriverInput.refresh_profiles()
		_s["foot_note"].text = "Feel settings reset. Buttons and other settings untouched."
		SFX.play("click", -16.0)
		show_category(3))
	head.add_child(rst)
	_panel_box.add_child(head)

	for key in ["move_deadzone", "turn_deadzone", "move_curve", "turn_curve"]:
		_tuning_slider(prof, key)
	for key2 in ["precision_scale"]:
		_tuning_slider(prof, key2)
	for key3 in ["invert_move_x", "invert_move_y", "invert_turn"]:
		_tuning_toggle(prof, key3)

func _tuning_slider(prof: ControlProfile, key: String) -> void:
	var spec: Array = ControlProfile.TUNING[key]
	var s := Gui.slider(float(spec[1]), float(spec[2]), prof.get_tuning(key), 0.01)
	s.value_changed.connect(func(v: float) -> void:
		prof.set_tuning(key, v)
		ControlProfile.save_one(prof)
		DriverInput.refresh_profiles())
	var box := Gui.slider_row(String(ControlProfile.TUNING_LABEL[key]), s,
		func(v: float) -> String: return _tuning_text(key, v))
	_panel_box.add_child(box)
	_panel_box.add_child(Gui.para(String(ControlProfile.TUNING_HELP[key])))

func _tuning_text(key: String, v: float) -> String:
	if key.ends_with("curve"):
		if v < 0.95:
			return "%.2f — sharper centre" % v
		if v > 1.05:
			return "%.2f — gentler centre" % v
		return "%.2f — straight line" % v
	if key == "precision_scale":
		return "%.0f%% of full speed" % (v * 100.0)
	return "%.0f%% of stick travel" % (v * 100.0)

func _tuning_toggle(prof: ControlProfile, key: String) -> void:
	var opts := Gui.options(["Normal", "Inverted"],
		1 if prof.is_on(key) else 0,
		func(i: int) -> void:
			prof.set_tuning(key, float(i))
			ControlProfile.save_one(prof)
			DriverInput.refresh_profiles())
	_panel_box.add_child(Gui.row(String(ControlProfile.TUNING_LABEL[key]), opts))
	_panel_box.add_child(Gui.para(String(ControlProfile.TUNING_HELP[key])))

# ================================================================== buttons ==

func _buttons_section() -> void:
	var dev := _editing_device()
	var prof := _editing_profile()
	var head := Gui.hbox(Gui.S16)
	head.add_child(Gui.section("Buttons"))
	head.add_child(Gui.spacer())
	if dev >= 0:
		var rst := Gui.button("Reset buttons", Gui.Look.SECONDARY, Vector2(160, 40))
		rst.pressed.connect(func() -> void:
			prof.reset_bindings()
			ControlProfile.save_one(prof)
			DriverInput.refresh_profiles()
			_s["foot_note"].text = "Back to the standard pad layout. Feel settings untouched."
			show_category(3))
		head.add_child(rst)
	_panel_box.add_child(head)

	if not _conflict.is_empty():
		_conflict_card()

	if dev <= DriverInput.NONE:
		_panel_box.add_child(Gui.para(
			"Give this seat a device above and its buttons will be listed here."))
		return
	if dev < 0:
		_panel_box.add_child(Gui.para(
			"This seat is on the keyboard. Click a key to change it; %s cancels."
			% "Esc"))
		for group in [["Driving", DRIVING], ["Mechanisms", MECHANISMS],
				["Session", SESSION]]:
			_panel_box.add_child(Gui.label(String(group[0]), Gui.T_SMALL, Gui.MUTED))
			_bindings(group[1] as Array, -1)
		return

	_panel_box.add_child(Gui.para(
		"Click a control, then press the button, trigger or stick direction you "
		+ "want. Esc cancels. Changes are saved into \"%s\"." % prof.name))
	for group2 in [["Driving", DRIVING], ["Mechanisms", MECHANISMS],
			["Session", SESSION]]:
		_panel_box.add_child(Gui.label(String(group2[0]), Gui.T_SMALL, Gui.MUTED))
		_pad_bindings(group2[1] as Array, prof)

## One rebindable row per action, on a controller.
func _pad_bindings(group: Array, prof: ControlProfile) -> void:
	var rows: Array = []
	for pair in group:
		var action := String(pair[0])
		var label := String(pair[1])
		var txt := prof.label_for(action)
		var unbound := txt == "—"
		var b := Gui.button("Press an input…" if _await_pad == action
			else (txt if not unbound else "Not bound — click to set"),
			Gui.Look.SECONDARY, Vector2(240, 42))
		b.add_theme_font_size_override("font_size", Gui.T_SMALL)
		if unbound:
			Gui.tint(b, Gui.WARN)
		elif prof.is_custom(action):
			Gui.tint(b, Gui.ACCENT)
		b.pressed.connect(func() -> void:
			_await_pad = action
			_await_pad_button = b
			# THE BUTTON THAT OPENED THIS MUST BE RELEASED FIRST, or the very
			# press that opened the dialog is captured as the new binding.
			_await_armed = false
			b.text = "Release, then press an input…"
			SFX.play("select", -16.0))
		rows.append(Gui.row(label, b))
	var box := Gui.vbox(0)
	_panel_box.add_child(box)
	Gui.rows(box, rows)

## The capture itself, polled rather than driven by events: a controller axis
## has no "pressed" event, and a trigger pulled halfway is a legitimate choice.
func _poll_pad_capture() -> void:
	if _await_pad == "":
		return
	var dev := _editing_device()
	if dev < 0:
		return
	# 1. wait for the hands to come off whatever opened the dialog
	if not _await_armed:
		if DriverInput.at_neutral(dev):
			_await_armed = true
			if is_instance_valid(_await_pad_button):
				_await_pad_button.text = "Press an input…"
		return
	# 2. now take the first thing pressed
	for b in 24:
		if Input.is_joy_button_pressed(dev, b):
			_offer_binding(dev, {"button": b})
			return
	for ax in [JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y, JOY_AXIS_RIGHT_X,
			JOY_AXIS_RIGHT_Y, JOY_AXIS_TRIGGER_LEFT, JOY_AXIS_TRIGGER_RIGHT]:
		var v := Input.get_joy_axis(dev, ax)
		if absf(v) > 0.65:
			_offer_binding(dev, {"axis": ax, "dir": signf(v)})
			return

func _offer_binding(dev: int, input: Dictionary) -> void:
	var action := _await_pad
	var prof := _editing_profile()
	var clash := prof.conflicts(action, input)
	_await_pad = ""
	if clash.is_empty():
		_commit_binding(prof, action, input, dev)
		return
	_conflict = {"action": action, "input": input, "with": clash, "dev": dev}
	SFX.play("foul", -20.0)
	show_category(3)

func _commit_binding(prof: ControlProfile, action: String,
		input: Dictionary, dev: int) -> void:
	prof.bind(action, input)
	ControlProfile.save_one(prof)
	DriverInput.refresh_profiles()
	# NOTHING HELD THROUGH A REBIND COUNTS AS A PRESS. The player is still
	# holding the button they just bound; without this the robot acts on it the
	# instant they leave this screen.
	DriverInput.require_neutral(dev)
	_s["foot_note"].text = "Bound to %s." % prof.label_for(action)
	SFX.play("click", -14.0)
	show_category(3)

func _conflict_card() -> void:
	var pair := Gui.card(Gui.S8)
	_panel_box.add_child(pair[0])
	var v: VBoxContainer = pair[1]
	var prof := _editing_profile()
	var names: Array[String] = []
	for a in _conflict["with"]:
		names.append(_action_label(String(a)))
	var warn := Gui.para("That input already does %s." % Gui.join_list(names))
	warn.add_theme_color_override("font_color", Gui.WARN)
	v.add_child(Gui.section("Already in use"))
	v.add_child(warn)
	v.add_child(Gui.para(
		"Replacing it leaves %s with no button until you give it one."
		% Gui.join_list(names)))
	var row := Gui.hbox(Gui.S8)
	var rep := Gui.primary("Replace", Vector2(150, 44))
	rep.pressed.connect(func() -> void:
		var c := _conflict.duplicate(true)
		_conflict = {}
		for a2 in c["with"]:
			prof.clear_binding(String(a2))
		_commit_binding(prof, String(c["action"]), c["input"], int(c["dev"])))
	row.add_child(rep)
	var cancel := Gui.button("Cancel", Gui.Look.SECONDARY, Vector2(150, 44))
	cancel.pressed.connect(func() -> void:
		_conflict = {}
		_s["foot_note"].text = "Left as it was."
		show_category(3))
	row.add_child(cancel)
	v.add_child(row)

func _action_label(action: String) -> String:
	for group in [DRIVING, MECHANISMS, SESSION]:
		for pair in group:
			if String(pair[0]) == action:
				return String(pair[1])
	return action

# ================================================================= profiles ==

func _profiles_section() -> void:
	_panel_box.add_child(Gui.section("Profiles"))
	_panel_box.add_child(Gui.para(
		"A profile is a saved set of buttons and feel settings. It belongs to "
		+ "a person, not to a controller — assign it to whichever seat that "
		+ "person is sitting in. Profiles are kept on this computer and "
		+ "survive closing the game."))
	var prof := _editing_profile()
	var row := Gui.hbox(Gui.S8)

	var mk := Gui.button("New", Gui.Look.SECONDARY, Vector2(110, 40))
	mk.pressed.connect(func() -> void:
		var p := ControlProfile.create("Profile %d" % (ControlProfile.all().size()))
		Settings.set_seat_profile(_seat, p.id)
		_s["foot_note"].text = "Created \"%s\"." % p.name
		show_category(3))
	row.add_child(mk)

	var dup := Gui.button("Duplicate", Gui.Look.SECONDARY, Vector2(130, 40))
	dup.pressed.connect(func() -> void:
		var p := ControlProfile.create("%s copy" % prof.name, prof.id)
		Settings.set_seat_profile(_seat, p.id)
		_s["foot_note"].text = "Copied to \"%s\"." % p.name
		show_category(3))
	row.add_child(dup)

	var del := Gui.button("Delete", Gui.Look.SECONDARY, Vector2(120, 40))
	del.disabled = prof.id == ControlProfile.STOCK_ID
	del.pressed.connect(func() -> void:
		var gone := prof.name
		if ControlProfile.delete_one(prof.id):
			Settings.set_seat_profile(_seat, ControlProfile.STOCK_ID)
			_s["foot_note"].text = "Deleted \"%s\". This seat is back on the standard layout." % gone
		show_category(3))
	row.add_child(del)
	_panel_box.add_child(row)

	if prof.id == ControlProfile.STOCK_ID:
		_panel_box.add_child(Gui.para(
			"This is the standard layout. It cannot be renamed or deleted, so "
			+ "there is always something to fall back to — press New or "
			+ "Duplicate to make one of your own."))
		return
	var edit := Gui.line_edit("profile name", prof.name)
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.text_submitted.connect(func(t: String) -> void:
		ControlProfile.rename_to(prof.id, t)
		DriverInput.refresh_profiles()
		_s["foot_note"].text = "Renamed."
		show_category(3))
	_panel_box.add_child(Gui.row("Name (press Enter)", edit))

## Binding rows for one device. Keyboard rows are rebindable; controller
## bindings are fixed, because a gamepad layout is a convention and remapping
## it mostly produces controllers nobody else can pick up and use.
func _bindings(group: Array, dev: int) -> void:
	var rows: Array = []
	for pair in group:
		var action := String(pair[0])
		var label := String(pair[1])
		if dev >= 0:
			var txt := _pad_binding(action)
			if txt == "":
				continue
			rows.append(Gui.row(label, Gui.key_chip(txt)))
		else:
			var b := Gui.button(_key_text(action), Gui.Look.SECONDARY,
				Vector2(190, 42))
			b.add_theme_font_size_override("font_size", Gui.T_SMALL)
			b.pressed.connect(func() -> void:
				_await_action = action
				_await_button = b
				b.text = "Press a key…"
				SFX.play("select", -16.0))
			rows.append(Gui.row(label, b))
	var box := Gui.vbox(0)
	_panel_box.add_child(box)
	Gui.rows(box, rows)

func _key_text(action: String) -> String:
	var ks: Array = BB.keys_for(action)
	if ks.is_empty():
		return "—"
	return OS.get_keycode_string(int(ks[0]))

func _pad_binding(action: String) -> String:
	var spec: Dictionary = BB.ACTIONS.get(action, {})
	var parts: Array = []
	for b in spec.get("buttons", []):
		parts.append(_pad_button(int(b)))
	if spec.has("axis"):
		parts.append(_pad_axis(int(spec["axis"][0]), float(spec["axis"][1])))
	return " / ".join(parts)

func _pad_button(b: int) -> String:
	match b:
		JOY_BUTTON_A: return "A"
		JOY_BUTTON_B: return "B"
		JOY_BUTTON_X: return "X"
		JOY_BUTTON_Y: return "Y"
		JOY_BUTTON_LEFT_SHOULDER: return "LB"
		JOY_BUTTON_RIGHT_SHOULDER: return "RB"
		JOY_BUTTON_LEFT_STICK: return "L3"
		JOY_BUTTON_RIGHT_STICK: return "R3"
		JOY_BUTTON_START: return "Start"
		JOY_BUTTON_BACK: return "Back"
		JOY_BUTTON_DPAD_UP: return "D-pad up"
		JOY_BUTTON_DPAD_DOWN: return "D-pad down"
		JOY_BUTTON_DPAD_LEFT: return "D-pad left"
		JOY_BUTTON_DPAD_RIGHT: return "D-pad right"
	return "Button %d" % b

func _pad_axis(axis: int, sign_: float) -> String:
	match axis:
		JOY_AXIS_LEFT_X: return "Left stick"
		JOY_AXIS_LEFT_Y: return "Left stick"
		JOY_AXIS_RIGHT_X: return "Right stick"
		JOY_AXIS_RIGHT_Y: return "Right stick"
		JOY_AXIS_TRIGGER_LEFT: return "LT"
		JOY_AXIS_TRIGGER_RIGHT: return "RT"
	return "Axis %d" % axis

func _input(ev: InputEvent) -> void:
	# ESC ALWAYS GETS YOU OUT of a capture, whichever kind is running. A
	# rebinding screen you cannot back out of with the keyboard is a screen
	# that can be locked up by binding the wrong thing.
	if _await_pad != "" and ev is InputEventKey and (ev as InputEventKey).pressed \
			and (ev as InputEventKey).physical_keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		var was := _await_pad
		_await_pad = ""
		if is_instance_valid(_await_pad_button):
			_await_pad_button.text = _editing_profile().label_for(was)
		_s["foot_note"].text = "Left as it was."
		return
	if _await_action == "" or not _root.visible:
		return
	if not (ev is InputEventKey) or not ev.pressed or ev.echo:
		return
	get_viewport().set_input_as_handled()
	var code: int = (ev as InputEventKey).physical_keycode
	var action := _await_action
	_await_action = ""
	if code == KEY_ESCAPE:
		_await_button.text = _key_text(action)
		return
	if Settings.rebind(action, code):
		_await_button.text = _key_text(action)
		_s["foot_note"].text = "Rebound."
		SFX.play("click", -14.0)
	else:
		_await_button.text = _key_text(action)
		_s["foot_note"].text = "%s is already doing something else." \
			% OS.get_keycode_string(code)
		SFX.play("foul", -18.0)

# ================================================================== widgets ==

func _volume(label: String, key: String) -> void:
	var spec: Array = Settings.SPEC[key]
	var s := Gui.slider(float(spec[1]), float(spec[2]),
		Settings.get_value(key), 0.01)
	s.value_changed.connect(func(v: float) -> void: Settings.set_value(key, v))
	s.drag_ended.connect(func(_c: bool) -> void: SFX.play("click", -20.0))
	_panel_box.add_child(Gui.slider_row(label, s,
		func(v: float) -> String: return "%.0f%%" % (v * 100.0)))

func _confirm_reset() -> void:
	SFX.play("click", -16.0)
	var d := ConfirmationDialog.new()
	d.title = "Reset settings"
	d.dialog_text = "Put every setting, key binding and controller assignment\nback to its default?"
	d.ok_button_text = "Reset"
	add_child(d)
	d.confirmed.connect(func() -> void:
		Settings.reset_to_defaults()
		SFX.play("select", -12.0)
		show_category(_page))
	d.close_requested.connect(func() -> void: d.queue_free())
	d.popup_centered()

# ===================================================================== open ==

func open() -> void:
	_root.visible = true
	show_category(_page)
	_sides[_page].grab_focus()

## Jump straight to one category — Play's "Assign controllers" lands on Controls.
func open_at(i: int) -> void:
	_page = clampi(i, 0, CATEGORIES.size() - 1)
	open()

func close() -> void:
	_root.visible = false
	_await_action = ""
	closed.emit()

func is_open() -> bool:
	return _root.visible
