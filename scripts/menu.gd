class_name Menu
extends CanvasLayer
##
## PLAY — the page the game opens on.
##
## Mode and match configuration on the left, the robot you are taking out on
## the right, and a bar across the bottom that always holds Start. Laid out to
## the design reference: the same top navigation as every other page, panels on
## #191C19, one yellow action, and nothing that says "example".
##
## Everything on it is live. The controller line reads the devices that are
## actually plugged in and the seats they are assigned to; the robot facts come
## from the current profile rather than a hardcoded 68 and 460; the autonomous
## line names the routine that will actually run.
##

signal started(mode: int, alliance: int, intakes: int, opts: Dictionary)
## Pressed Start while a match was only paused behind the menus.
signal resumed
signal settings_changed
signal navigate(page: String)
## Kept for the rest of the project, which wires these to the same screens.
signal open_settings
signal open_robot
signal open_controls
## Jump straight to one Garage tab: 0 hardware, 1 appearance, 2 autonomous.
signal open_garage_tab(tab: int)
## The saved-situations library, which is part of this page's practice flow.
signal open_scenarios
## Play -> Online practice
signal open_online
## Save the field as it stands. An empty `overwrite` means a NEW situation.
signal save_situation(name: String, note: String, overwrite: String)
## Put the loaded situation back to its saved instant.
signal retry_situation
## Give up on the paused match and come back to the setup screen.
signal end_match
## Back to the scenario editor, after testing a draft.
signal return_to_editor

var mode: int = BB.Mode.FULL_MATCH
var alliance: int = BB.Alliance.RED
## The stock robot's feel. Fixed for everyone; a measured profile overrides it.
const DRIVE_SPEED := BB.DRIVE_SPEED_IN_S
const TURN_RATE := BB.TURN_RATE_DEG_S
## 1 or 2 intakes, and whether the intake takes NECTAR too. Both chosen in the
## Garage; Play shows what they currently are.
var robot_intakes := 1
var takes_nectar := false
## How many robots YOUR alliance fields, and who drives the second one.
var robots := 1
var mate_is_ai := false
## One person doing everything, or a driver and an operator.
var per_robot := 1
## AI robots on the other alliance: 0, 1 or 2.
var opponents := 0
## The routine that will run in AUTO, owned by the Garage.
var garage: RobotMenu
## True while a match is paused behind the menus: Start becomes Resume, so
## opening the menu mid-match never costs you the match.
var match_running := false
## One line describing the paused match, pushed in by the world.
var pause_line := ""
## The loaded situation, if this run came from one: Retry goes back to it and
## saving can overwrite it instead of making yet another copy.
var scenario_id := ""
var scenario_name := ""
## True while the player is naming a situation they just captured.
var naming := false

enum Left { SETUP, PAUSED, NAMING }
var _left_mode := Left.SETUP
var _setup_box: VBoxContainer
var _paused_box: VBoxContainer
var _naming_box: VBoxContainer
var _pause_status: Label
var _retry_btn: Button
var _editor_btn: Button
## True while the running match is a test of an editor draft.
var testing_draft := false
var _retry_note: Label
var _name_edit: LineEdit
var _note_edit: LineEdit
var _overwrite_btn: Button
var _scenario_count: Label

var _root: Control
var _s: Dictionary = {}
var _mode_buttons: Array[Button] = []
var _rows: Dictionary = {}
var _preview: RobotPreview
var _robot_name: Label
var _robot_sub: Label
var _fact_speed: VBoxContainer
var _fact_turn: VBoxContainer
var _facts: HBoxContainer
var _auto_line: Label
var _seat_note: Label
var _head_status: HBoxContainer
var _pads_seen := -1

const MODES := [
	{"m": BB.Mode.FULL_MATCH, "t": "Full match", "d": "Auto + 2 min teleop",
	 "go": "Start match  →", "sum": "Full match"},
	{"m": BB.Mode.TELEOP_ONLY, "t": "Teleop", "d": "2 min driving",
	 "go": "Start match  →", "sum": "Teleop"},
	{"m": BB.Mode.FREE_PRACTICE, "t": "Free practice", "d": "No time limit",
	 "go": "Start practice  →", "sum": "Free practice"},
]

## The team that built this. Opens the team's site in the browser.
const TEAM_SITE := "https://pandara.org"
## The purple from the team panda, lifted enough to read on the dark page.
const PANDARA_PURPLE := Color("b86ff7")

func _team_credit() -> Button:
	var b := Gui.button("", Gui.Look.GHOST)
	b.tooltip_text = "Open %s in your browser" % TEAM_SITE.trim_prefix("https://")
	b.focus_mode = Control.FOCUS_ALL
	b.size_flags_horizontal = Control.SIZE_SHRINK_END
	var row := Gui.hbox(8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	# the team panda, in a rounded frame
	var frame := Panel.new()
	frame.custom_minimum_size = Vector2(40, 40)
	frame.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	var fsb := StyleBoxFlat.new()
	fsb.bg_color = Color.WHITE
	fsb.set_corner_radius_all(8)
	frame.add_theme_stylebox_override("panel", fsb)
	var pic := TextureRect.new()
	pic.texture = load("res://assets/pandara_panda.png")
	pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	pic.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	pic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(pic)
	var by := Gui.label("BUILT BY", Gui.T_SMALL, Gui.MUTED)
	var num := Gui.label("506", Gui.T_BODY, PANDARA_PURPLE)
	Gui.weight(num, 1)
	var team := Gui.label("PANDARA", Gui.T_BODY, Gui.INK)
	Gui.weight(team, 1)
	var site := Gui.label("·  pandara.org ↗", Gui.T_SMALL, Gui.MUTED)
	for l in [frame, by, num, team, site]:
		(l as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(l)
	b.add_child(row)
	b.custom_minimum_size = Vector2(row.get_combined_minimum_size().x + 28, 50)
	row.minimum_size_changed.connect(func() -> void:
		b.custom_minimum_size.x = row.get_combined_minimum_size().x + 28)
	b.pressed.connect(func() -> void:
		SFX.play("click", -16.0)
		OS.shell_open(TEAM_SITE))
	return b

# ==================================================================== build ==

func build() -> void:
	layer = 20
	_s = Gui.shell("Play", func(p: String) -> void: navigate.emit(p))
	_root = _s["root"]
	add_child(_root)
	_s["eyebrow"].text = "YOUR NEXT SESSION"
	_s["title"].text = "Take the field."

	# the team credit sits above the controller status, top right of the page
	var right_stack := Gui.vbox(6)
	right_stack.alignment = BoxContainer.ALIGNMENT_CENTER
	_s["head_right"].add_child(right_stack)
	right_stack.add_child(_team_credit())
	_head_status = Gui.status("", Gui.GOOD)
	_head_status.size_flags_horizontal = Control.SIZE_SHRINK_END
	right_stack.add_child(_head_status)

	var cols := Gui.two_columns(_s["body"])
	var left: VBoxContainer = cols[0]
	var right: VBoxContainer = cols[1]

	# The left column has three faces: the match you are about to set up, the
	# pause menu when one is already running, and the naming card after you
	# capture a situation. Only one is ever visible.
	_setup_box = Gui.vbox(Gui.S24)
	_setup_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_child(_setup_box)

	# ---- modes, three across
	var modes := Gui.hbox(10)
	modes.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_setup_box.add_child(modes)
	for spec in MODES:
		var b := Gui.mode_card(String(spec["t"]), String(spec["d"]),
			int(spec["m"]) == mode, _pick_mode.bind(int(spec["m"])))
		modes.add_child(b)
		_mode_buttons.append(b)

	# ---- DRILLS FIRST.
	#
	# This used to sit at the bottom of the column, under Match setup, where at
	# 1600x900 it is below the fold: a new player launching a game called
	# DRIVER PRACTICE had no way of knowing the drills existed. It is now the
	# first thing under the mode cards, and it names what is on the shelf
	# rather than only counting it.
	var sc := Gui.card(Gui.S8)
	_setup_box.add_child(sc[0])
	var scv: VBoxContainer = sc[1]
	var schead := Gui.hbox(Gui.S16)
	schead.add_child(Gui.section("Practice drills"))
	schead.add_child(Gui.spacer())
	var open_lib := Gui.primary("Open library", Vector2(170, 44))
	open_lib.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	open_lib.pressed.connect(func() -> void:
		SFX.play("select", -16.0)
		open_scenarios.emit())
	schead.add_child(open_lib)
	scv.add_child(schead)
	_scenario_count = Gui.label("", Gui.T_SMALL, Gui.MUTED)
	_scenario_count.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	scv.add_child(_scenario_count)
	_scenario_names = Gui.label("", Gui.T_SMALL, Gui.INK)
	_scenario_names.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	scv.add_child(_scenario_names)

	# ---- online practice: rooms with your team, over the internet
	var oc := Gui.card(Gui.S8)
	_setup_box.add_child(oc[0])
	var ohead := Gui.hbox(Gui.S16)
	var otext := Gui.vbox(2)
	otext.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	otext.add_child(Gui.section("Online practice"))
	otext.add_child(Gui.label("Private rooms: host from your game, send an invite, take seats as driver and operator, practise and retry together.",
		Gui.T_SMALL, Gui.MUTED, true))
	ohead.add_child(otext)
	var online_btn := Gui.button("Create or join", Gui.Look.SECONDARY, Vector2(170, 44))
	online_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	online_btn.pressed.connect(func() -> void:
		SFX.play("select", -16.0)
		open_online.emit())
	ohead.add_child(online_btn)
	oc[1].add_child(ohead)

	# ---- match setup
	var setup := Gui.card(Gui.S16)
	_setup_box.add_child(setup[0])
	var sv: VBoxContainer = setup[1]
	sv.add_child(Gui.section("Match setup"))

	_rows["alliance"] = Gui.options(["Red", "Blue"], alliance,
		func(i: int) -> void: _pick_alliance(i),
		[Gui.alliance_ink(BB.Alliance.RED), Gui.alliance_ink(BB.Alliance.BLUE)])
	_rows["robots"] = Gui.options(["1 robot", "2 robots"], robots - 1,
		func(i: int) -> void:
			robots = i + 1
			refresh())
	_rows["mate"] = Gui.options(["A person", "AI teammate"],
		1 if mate_is_ai else 0,
		func(i: int) -> void:
			mate_is_ai = i == 1
			refresh())
	_rows["opponents"] = Gui.options(["None", "1", "2"], opponents,
		func(i: int) -> void:
			opponents = i
			refresh())
	_rows["per_robot"] = Gui.options(["Solo", "Driver + operator"], per_robot - 1,
		func(i: int) -> void:
			per_robot = i + 1
			refresh())

	var list: Array = [
		Gui.row("Alliance", _rows["alliance"]),
		Gui.row("Our robots", _rows["robots"]),
		Gui.row("Second robot", _rows["mate"]),
		Gui.row("Opponent bots", _rows["opponents"]),
		Gui.row("People per robot", _rows["per_robot"]),
	]
	_rows["mate_row"] = list[2]
	var rowbox := Gui.vbox(0)
	sv.add_child(rowbox)
	Gui.rows(rowbox, list)

	sv.add_child(Gui.divider())
	var assign := Gui.button("Assign controllers")
	assign.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	assign.pressed.connect(func() -> void:
		SFX.play("select", -14.0)
		open_controls.emit())
	var abox := Gui.vbox(Gui.S8)
	abox.add_child(assign)
	_seat_note = Gui.label("", Gui.T_SMALL, Gui.MUTED)
	abox.add_child(_seat_note)
	sv.add_child(abox)

	_build_paused(left)
	_build_naming(left)

	# ---- the robot
	var rob := Gui.card(Gui.S8)
	rob[0].size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(rob[0])
	var rv: VBoxContainer = rob[1]
	rv.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var rhead := Gui.hbox(Gui.S16)
	rhead.add_child(Gui.section("Your robot"))
	rhead.add_child(Gui.spacer())
	var change := Gui.button("Change")
	change.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	change.pressed.connect(func() -> void:
		SFX.play("select", -16.0)
		open_garage_tab.emit(0))
	rhead.add_child(change)
	rv.add_child(rhead)

	_preview = RobotPreview.new(200)
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_preview.alliance = alliance
	_preview.intakes = robot_intakes
	rv.add_child(_preview)
	_preview.build()

	_robot_name = Gui.label("", Gui.T_SECTION, Gui.INK)
	Gui.weight(_robot_name, 1)
	rv.add_child(_robot_name)
	_robot_sub = Gui.label("", Gui.T_SMALL, Gui.MUTED)
	rv.add_child(_robot_sub)

	_facts = Gui.hbox(24)
	_fact_speed = Gui.fact("", "Top speed")
	_fact_turn = Gui.fact("", "Turn rate")
	_facts.add_child(_fact_speed)
	_facts.add_child(_fact_turn)
	rv.add_child(_facts)

	rv.add_child(Gui.divider())
	rv.add_child(Gui.label("Autonomous", Gui.T_SMALL, Gui.MUTED))
	var arow := Gui.hbox(Gui.S16)
	_auto_line = Gui.label("", Gui.T_BODY, Gui.INK)
	_auto_line.clip_text = true
	_auto_line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	arow.add_child(_auto_line)
	var setup_btn := Gui.button("Set up")
	setup_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	setup_btn.pressed.connect(func() -> void:
		SFX.play("select", -16.0)
		open_garage_tab.emit(2))
	arow.add_child(setup_btn)
	rv.add_child(arow)

	_s["foot_btn"].pressed.connect(_go)
	refresh()
	_mode_buttons[0].grab_focus()

# ==================================================================== state ==

func _pick_mode(m: int) -> void:
	SFX.play("select", -16.0)
	mode = m
	refresh()

func _pick_alliance(i: int) -> void:
	alliance = i
	if _preview:
		_preview.rebuild(alliance, robot_intakes)
	refresh()

## Re-reads everything the page shows from the systems that own it. Called on
## open, after the Garage changes the robot, and when a controller is plugged
## in or pulled out.
func refresh() -> void:
	# ---- which face the left column is showing, and what the footer does
	_left_mode = Left.NAMING if naming else (Left.PAUSED if match_running
		else Left.SETUP)
	_setup_box.visible = _left_mode == Left.SETUP
	_paused_box.visible = _left_mode == Left.PAUSED
	_naming_box.visible = _left_mode == Left.NAMING

	var spec: Dictionary = MODES[0]
	for i in _mode_buttons.size():
		var on := int(MODES[i]["m"]) == mode
		Gui.select(_mode_buttons[i], on)
		if on:
			spec = MODES[i]

	(_rows["mate_row"] as Control).visible = robots > 1
	Gui.set_options(_rows["alliance"], alliance)
	Gui.set_options(_rows["robots"], robots - 1)
	Gui.set_options(_rows["mate"], 1 if mate_is_ai else 0)
	Gui.set_options(_rows["opponents"], opponents)
	Gui.set_options(_rows["per_robot"], per_robot - 1)

	if _preview and _preview.intakes != robot_intakes:
		_preview.rebuild(alliance, robot_intakes)

	_robot_name.text = RobotShop.robot_name
	_robot_sub.text = "%s · %s · %s" % [
		RobotShop.profile_name(),
		"Front intake" if robot_intakes == 1 else "Front + rear intakes",
		"Pollen + nectar" if takes_nectar else "Pollen only"]
	(_fact_speed.get_child(0) as Label).text = "%.0f in/s" % RobotShop.top_speed_in_s()
	(_fact_turn.get_child(0) as Label).text = "%.0f°/s" % RobotShop.turn_deg_s()

	var auto_name: String = garage.active_auto if garage else ""
	if mode != BB.Mode.FULL_MATCH:
		_auto_line.text = "Not used in this mode"
		_auto_line.add_theme_color_override("font_color", Gui.MUTED)
	elif auto_name == "":
		_auto_line.text = "No routine selected"
		_auto_line.add_theme_color_override("font_color", Gui.MUTED)
	else:
		_auto_line.text = auto_name
		_auto_line.add_theme_color_override("font_color", Gui.INK)

	if _left_mode == Left.SETUP:
		_refresh_devices()
	elif _left_mode == Left.NAMING:
		Gui.set_status(_head_status, "Field frozen — nothing saved yet", Gui.ACCENT)
	else:
		Gui.set_status(_head_status, "Clock stopped", Gui.GOOD)

	var shelf := ScenarioLibrary.list_all()
	var n_saved := shelf.size()
	if n_saved == 0:
		_scenario_count.text = ("Nothing saved yet — press %s mid-match to "
			% _key_text("save_situation") + "keep a moment.")
		_scenario_names.text = ""
	else:
		_scenario_count.text = ("Start from a saved moment with a goal to hit, "
			+ "instead of a whole match. %d on the shelf:" % n_saved)
		var names: Array[String] = []
		for e in shelf:
			if names.size() >= 4:
				break
			names.append(String(e["name"]))
		_scenario_names.text = (", ".join(names)
			+ (", plus %d more." % (n_saved - names.size())
				if n_saved > names.size() else "."))
	_refresh_controls()

	# the page says what it is actually for right now
	match _left_mode:
		Left.NAMING:
			_s["eyebrow"].text = "SAVE A SITUATION"
			_s["title"].text = "Name this moment."
		Left.PAUSED:
			_s["eyebrow"].text = "MATCH IN PROGRESS"
			_s["title"].text = "Paused."
		_:
			_s["eyebrow"].text = "YOUR NEXT SESSION"
			_s["title"].text = "Take the field."

	match _left_mode:
		Left.NAMING:
			_s["foot_line"].text = "Naming a saved situation"
			_s["foot_note"].text = "Nothing is written to disk until you choose."
			_s["foot_btn"].text = "Save situation"
			_overwrite_btn.visible = scenario_id != ""
			_overwrite_btn.text = 'Overwrite "%s"' % scenario_name
		Left.PAUSED:
			_s["foot_line"].text = "Match paused · " + summary_line()
			_s["foot_btn"].text = "Resume match  →"
			_pause_status.text = pause_line
			(_editor_btn.get_parent() as Control).visible = testing_draft
			_retry_btn.disabled = scenario_id == ""
			if scenario_id == "":
				_retry_note.text = ("This run did not start from a saved "
					+ "situation, so there is nothing to go back to. Save one "
					+ "and Retry will work.")
			elif testing_draft:
				_retry_note.text = ("Puts this test back to the start of the "
					+ "draft you are editing. %s does the same without opening "
					% _key_text("retry_scenario") + "this menu.")
			else:
				_retry_note.text = ("Puts \"%s\" straight back to its saved "
					% scenario_name + "instant, however this attempt went. %s "
					% _key_text("retry_scenario") + "does the same without "
					+ "opening this menu.")
		_:
			_s["foot_line"].text = summary_line()
			_s["foot_btn"].text = String(spec["go"])

## The real device picture: which seats exist, what they have been given, and
## whether anybody is left holding nothing.
func _refresh_devices() -> void:
	var pool := DriverInput.devices()
	var pads := Input.get_connected_joypads().size()
	var plan := Settings.seat_plan(robots, mate_is_ai, per_robot)
	var devices := Settings.allocate_devices(seats_needed(), pool)
	var missing: Array[String] = []
	var lines: Array[String] = []
	for entry in plan:
		if bool(entry["ai"]):
			continue
		var si := int(entry["seat"])
		var dev: int = devices[si] if si < devices.size() else DriverInput.NONE
		if dev > DriverInput.NONE:
			lines.append("Robot %d %s · %s" % [
				int(entry["robot"]), String(entry["role"]).to_lower(),
				DriverInput.device_name(dev).capitalize()])
		else:
			missing.append("Robot %d %s" % [
				int(entry["robot"]), String(entry["role"]).to_lower()])

	if missing.is_empty():
		Gui.set_status(_head_status, "%d controller%s connected" % [
			pads, "" if pads == 1 else "s"] if pads > 0
			else "Keyboard only", Gui.GOOD)
		_seat_note.text = "  ·  ".join(lines)
		_seat_note.add_theme_color_override("font_color", Gui.MUTED)
		_s["foot_note"].text = ""
	else:
		Gui.set_status(_head_status, "%d seat%s without a device" % [
			missing.size(), "" if missing.size() == 1 else "s"], Gui.WARN)
		_seat_note.text = "Nothing left for %s — plug in a controller or use fewer people." \
			% Gui.join_list(missing)
		_seat_note.add_theme_color_override("font_color", Gui.WARN)
		_s["foot_note"].text = "%s %s no device." % [Gui.join_list(missing),
			"has" if missing.size() == 1 else "have"]

## The one-line description of the session that is set up, shown in the footer
## of every page so you always know what Start would do.
func summary_line() -> String:
	var sum := "Full match"
	for spec in MODES:
		if int(spec["m"]) == mode:
			sum = String(spec["sum"])
	return "%s · %s alliance · %s" % [
		sum, BB.alliance_name(alliance).capitalize(),
		"Solo" if per_robot == 1 else "Driver + operator"]

## What key an action is currently on, for the on-screen prompts.
func _key_text(action: String) -> String:
	var ks: Array = BB.keys_for(action)
	return OS.get_keycode_string(int(ks[0])) if not ks.is_empty() else "—"

## How many human seats the current setup needs.
func seats_needed() -> int:
	var human_robots := robots - (1 if (robots > 1 and mate_is_ai) else 0)
	return human_robots * per_robot

func _go() -> void:
	if naming:
		_commit_name("")
		return
	if match_running:
		resumed.emit()
		return
	started.emit(mode, alliance, robot_intakes, {
		"robots": robots,
		"mate_is_ai": mate_is_ai,
		"per_robot": per_robot,
		"opponents": opponents,
		"takes_nectar": takes_nectar,
	})

# ===================================================================== open ==

func open() -> void:
	refresh()
	_root.visible = true
	_mode_buttons[0].grab_focus()

func close() -> void:
	_root.visible = false

func is_open() -> bool:
	return _root.visible

func _process(_d: float) -> void:
	if not _root.visible:
		return
	# keep the device picture honest while the menu is up
	var pads := Input.get_connected_joypads().size()
	if pads != _pads_seen:
		_pads_seen = pads
		_refresh_devices()

# =============================================================== pause menu ==

## What you get when you press the menu key mid-match. The match is paused, not
## abandoned: everything here is a choice about the run in progress.
## The pause menu's controls card: a one-line reminder plus the full list.
var _scenario_names: Label
var _controls_line: Label
var _controls_full: VBoxContainer


## Fill the controls card from the live input map, so a rebind shows here too.
func _refresh_controls() -> void:
	if _controls_line == null:
		return
	if BB.has_pad():
		_controls_line.text = ("Left stick drives, right stick turns, "
			+ "right trigger shoots, A fires one, Y changes camera.")
	else:
		# read from the live map, so a rebind in Settings shows up here
		_controls_line.text = ("%s%s%s%s drive and strafe  ·  %s / %s turn  ·  "
			% [_key_text("drive_fwd"), _key_text("strafe_left"),
				_key_text("drive_back"), _key_text("strafe_right"),
				_key_text("turn_left"), _key_text("turn_right")]
			+ "%s shoot  ·  %s auto-aim  ·  %s camera"
			% [_key_text("fire"), _key_text("aim_assist"),
				_key_text("cam_toggle")])
	if _controls_full.get_child_count() > 0:
		return                      # built once; bindings refresh the line above
	for group in [["Driving", SettingsMenu.DRIVING],
			["Mechanisms", SettingsMenu.MECHANISMS],
			["This session", SettingsMenu.SESSION]]:
		_controls_full.add_child(Gui.label(String(group[0]), Gui.T_SMALL, Gui.MUTED))
		for pair in (group[1] as Array):
			var row := Gui.hbox(Gui.S8)
			var nm := Gui.label(String(pair[1]), Gui.T_SMALL, Gui.INK)
			nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			nm.autowrap_mode = TextServer.AUTOWRAP_OFF
			row.add_child(nm)
			row.add_child(Gui.key_chip(_key_text(String(pair[0]))))
			_controls_full.add_child(row)

func _build_paused(left: VBoxContainer) -> void:
	_paused_box = Gui.vbox(Gui.S24)
	_paused_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_paused_box.visible = false
	left.add_child(_paused_box)

	var pair := Gui.card(Gui.S16)
	_paused_box.add_child(pair[0])
	var v: VBoxContainer = pair[1]
	v.add_child(Gui.section("Match paused"))
	_pause_status = Gui.label("", Gui.T_BODY, Gui.INK)
	v.add_child(_pause_status)
	v.add_child(Gui.para(
		"The clock is stopped and the robots are switched off. Nothing about "
		+ "the run changes while you are in here."))
	v.add_child(Gui.divider())

	var save_row := Gui.hbox(Gui.S16)
	var save_btn := Gui.button("Save situation", Gui.Look.SECONDARY, Vector2(0, 52))
	save_btn.pressed.connect(func() -> void:
		SFX.play("select", -14.0)
		begin_naming())
	save_row.add_child(save_btn)
	var save_note := Gui.para(
		"Keeps the field exactly as it is now — clock, score, every robot and "
		+ "every ball — so you can drive this moment again.")
	save_row.add_child(save_note)
	v.add_child(save_row)

	var retry_row := Gui.hbox(Gui.S16)
	_retry_btn = Gui.button("Retry situation", Gui.Look.SECONDARY, Vector2(0, 52))
	_retry_btn.pressed.connect(func() -> void:
		SFX.play("select", -12.0)
		retry_situation.emit())
	retry_row.add_child(_retry_btn)
	_retry_note = Gui.para("")
	retry_row.add_child(_retry_note)
	v.add_child(retry_row)

	var ed_row := Gui.hbox(Gui.S16)
	_editor_btn = Gui.button("Return to editor", Gui.Look.SECONDARY, Vector2(0, 52))
	_editor_btn.pressed.connect(func() -> void:
		SFX.play("select", -12.0)
		return_to_editor.emit())
	ed_row.add_child(_editor_btn)
	ed_row.add_child(Gui.para(
		"Back to the scenario creator with your draft exactly as you left it. "
		+ "Nothing that happened in this test is kept."))
	v.add_child(ed_row)

	v.add_child(Gui.divider())
	var end_row := Gui.hbox(Gui.S16)
	var end_btn := Gui.button("End the match", Gui.Look.SECONDARY, Vector2(0, 52))
	end_btn.pressed.connect(func() -> void:
		SFX.play("click", -14.0)
		end_match.emit())
	end_row.add_child(end_btn)
	end_row.add_child(Gui.para(
		"Throws this run away and comes back to the setup screen."))
	v.add_child(end_row)

	# HOW DO I DRIVE. The full binding list lives in Settings -> Controls, three
	# clicks and a page change away; a first-time driver who stops to ask gets
	# the answer here instead, on the screen Esc already put in front of them.
	var ctl := Gui.card(Gui.S8)
	_paused_box.add_child(ctl[0])
	var cv: VBoxContainer = ctl[1]
	cv.add_child(Gui.section("Controls"))
	_controls_line = Gui.label("", Gui.T_SMALL, Gui.MUTED)
	cv.add_child(_controls_line)
	var disc := Gui.disclosure("Show every control")
	cv.add_child(disc[0])
	cv.add_child(disc[1])
	_controls_full = disc[1]

	var lib := Gui.card(Gui.S8)
	_paused_box.add_child(lib[0])
	var lv: VBoxContainer = lib[1]
	var lhead := Gui.hbox(Gui.S16)
	lhead.add_child(Gui.section("Practice situations"))
	lhead.add_child(Gui.spacer())
	var lb := Gui.button("Open library")
	lb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lb.pressed.connect(func() -> void:
		SFX.play("select", -16.0)
		open_scenarios.emit())
	lhead.add_child(lb)
	lv.add_child(lhead)
	lv.add_child(Gui.para(
		"Loading another situation from here ends this run and starts that one."))

## Naming a situation you just captured. The field is already frozen; nothing
## is written to disk until you choose a name.
func _build_naming(left: VBoxContainer) -> void:
	_naming_box = Gui.vbox(Gui.S24)
	_naming_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_naming_box.visible = false
	left.add_child(_naming_box)

	var pair := Gui.card(Gui.S16)
	_naming_box.add_child(pair[0])
	var v: VBoxContainer = pair[1]
	v.add_child(Gui.section("Save this situation"))
	v.add_child(Gui.para(
		"The field is frozen exactly as it was when you pressed save: the "
		+ "clock, the score and the fouls, where every robot is and how fast "
		+ "it was moving, what is in each hopper, every loose ball, the hives "
		+ "mid-swing and what the human players still owe you."))

	# Label above, field across the full column: a text field squeezed into the
	# right-hand third of a row is a text field you cannot read what you typed in.
	_name_edit = Gui.line_edit("name this situation")
	_name_edit.max_length = 48
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(Gui.label("Name", Gui.T_BODY, Gui.INK))
	v.add_child(_name_edit)
	_note_edit = Gui.line_edit("what you want to practise here (optional)")
	_note_edit.max_length = 120
	_note_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(Gui.label("Description", Gui.T_BODY, Gui.INK))
	v.add_child(_note_edit)

	v.add_child(Gui.divider())
	var row := Gui.hbox(Gui.S8)
	row.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var save_new := Gui.primary("Save as new situation", Vector2(240, 52))
	save_new.pressed.connect(func() -> void: _commit_name(""))
	row.add_child(save_new)
	_overwrite_btn = Gui.button("Overwrite", Gui.Look.SECONDARY, Vector2(0, 52))
	_overwrite_btn.pressed.connect(func() -> void: _commit_name(scenario_id))
	row.add_child(_overwrite_btn)
	var cancel := Gui.button("Cancel", Gui.Look.SECONDARY, Vector2(0, 52))
	cancel.pressed.connect(func() -> void:
		SFX.play("click", -18.0)
		naming = false
		refresh())
	row.add_child(cancel)
	v.add_child(row)
	v.add_child(Gui.para(
		"Saving a later moment always makes a NEW situation unless you choose "
		+ "to overwrite, so the one you have been retrying stays as it was."))

## Freeze the naming card over the paused match, with a name already filled in.
func begin_naming() -> void:
	naming = true
	_name_edit.text = _suggested_name()
	_note_edit.text = ""
	refresh()
	_name_edit.grab_focus()

func _suggested_name() -> String:
	if scenario_name != "":
		return scenario_name + " (moment 2)"
	var stamp := Time.get_datetime_string_from_system(true)
	return "Situation %s" % stamp.substr(5, 11).replace("T", " ")

func _commit_name(overwrite: String) -> void:
	var n := _name_edit.text.strip_edges()
	if n == "":
		_s["foot_note"].text = "Give the situation a name first."
		SFX.play("foul", -20.0)
		_name_edit.grab_focus()
		return
	SFX.play("select", -12.0)
	naming = false
	save_situation.emit(n, _note_edit.text.strip_edges(), overwrite)
