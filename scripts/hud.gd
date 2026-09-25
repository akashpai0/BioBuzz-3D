class_name Hud
extends CanvasLayer
##
## Driver-station overlay: clock, live score, mechanism readout and event log.
## Built in code so there is no .tscn to keep in sync with the game.
##
## The pre-match screen lives in menu.gd now, so this only has to be good at the
## thing a driver actually looks at mid-match: time, score, and whether the
## launcher is on target.
##

var mm: MatchManager
## The robot this overlay is about — robot 1, the one the camera follows.
var robot: Robot
## Everyone on the field. Used only to draw the second driver's strip.
var robots: Array[Robot] = []
var field: Field
var rig: CameraRig
var menu: Menu

var _clock: Label
var _phase: Label
var _red: RichTextLabel
var _blue: RichTextLabel
var _tele: RichTextLabel
var _log: RichTextLabel
var _target: Label
var _mate: RichTextLabel
var _results: RichTextLabel
var _root: Control
## True once the match has finished and the field has settled — the only time
## CELL contents are on the board (S10.5.C).
var _final := false

## Same ink as the menus, so the overlay and the screens you came from are
## recognisably the same product.
const INK := Gui.INK
const DIM := Gui.MUTED

func build() -> void:
	layer = 10
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# ------------------------------------------------------------- top bar
	var bar := _panel(Vector2(-215, 8), Vector2(430, 92), Control.PRESET_CENTER_TOP)
	var barcol := VBoxContainer.new()
	barcol.add_theme_constant_override("separation", 0)
	bar.add_child(barcol)

	_clock = Label.new()
	_clock.add_theme_font_size_override("font_size", 46)
	_clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	barcol.add_child(_clock)

	_phase = Label.new()
	_phase.add_theme_font_size_override("font_size", 14)
	_phase.add_theme_color_override("font_color", DIM)
	_phase.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	barcol.add_child(_phase)

	# ------------------------------------------------------------ notices
	# One line under the clock for things the player must not miss but that
	# must not stop the run — a replay recording that could not be written.
	_notice = Label.new()
	_notice.set_anchors_preset(Control.PRESET_CENTER_TOP, true)
	_notice.offset_left = -420
	_notice.offset_right = 420
	_notice.offset_top = 108
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice.add_theme_font_size_override("font_size", 16)
	_notice.add_theme_color_override("font_color", Gui.WARN)
	_notice.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_notice.add_theme_constant_override("outline_size", 6)
	_notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_notice)

	# --------------------------------------------------------- score chips
	_red = _rich(_panel(Vector2(18, 10), Vector2(290, 176), Control.PRESET_TOP_LEFT))
	_blue = _rich(_panel(Vector2(-308, 10), Vector2(290, 176), Control.PRESET_TOP_RIGHT))

	# ------------------------------------------------------------- bottom
	# Second driver's strip, above robot 1's telemetry. Hidden outright when
	# only one person is driving, rather than sitting there empty.
	_mate = _rich(_panel(Vector2(18, -300), Vector2(340, 86), Control.PRESET_BOTTOM_LEFT))
	(_mate.get_meta("panel") as PanelContainer).visible = false

	_tele = _rich(_panel(Vector2(18, -206), Vector2(340, 188), Control.PRESET_BOTTOM_LEFT))
	_log = _rich(_panel(Vector2(-378, -206), Vector2(360, 188), Control.PRESET_BOTTOM_RIGHT))

	_target = Label.new()
	_target.set_anchors_preset(Control.PRESET_CENTER_BOTTOM, true)
	_target.offset_left = -240
	_target.offset_right = 240
	_target.offset_top = -56
	_target.offset_bottom = -26
	_target.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_target.add_theme_font_size_override("font_size", 18)
	_root.add_child(_target)

	var rp := _panel(Vector2(-300, -150), Vector2(600, 300), Control.PRESET_CENTER)
	_results = _rich(rp)
	rp.visible = false
	_results.set_meta("panel", rp)

## A rounded translucent card. Every readout sits in one of these so the HUD
## stays legible over a bright field.
func _panel(pos: Vector2, size: Vector2, preset: int) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Gui.PANEL.r, Gui.PANEL.g, Gui.PANEL.b, 0.78)
	sb.border_color = Gui.LINE
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	p.add_theme_stylebox_override("panel", sb)
	# Anchors first, then EXPLICIT offsets. Setting `position` after a preset
	# does not survive a container-less parent reliably, which is how the clock
	# ended up pinned to the left edge instead of centred.
	p.set_anchors_preset(preset, true)
	p.offset_left = pos.x
	p.offset_top = pos.y
	p.offset_right = pos.x + size.x
	p.offset_bottom = pos.y + size.y
	p.custom_minimum_size = size
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(p)
	return p

## WHERE THE LEFT SCOREBOARD ACTUALLY ENDS, in canvas coordinates.
##
## `_panel()` is given a minimum size, but a PanelContainer sizes itself to its
## contents, so the declared 176 px is a floor and not the truth. Anything that
## wants to sit under the scoreboard has to ask it how tall it ended up —
## assuming the declared height is how the practice card came to overlap it.
func left_panel_bottom() -> float:
	var p: Variant = _red.get_meta("panel", null) if _red != null else null
	if p == null or not is_instance_valid(p) or not (p as Control).visible:
		return 0.0
	return (p as Control).get_global_rect().end.y

func _rich(parent: Control) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.scroll_active = false
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.add_theme_font_size_override("normal_font_size", 14)
	r.add_theme_font_size_override("bold_font_size", 14)
	r.add_theme_color_override("default_color", INK)
	r.set_meta("panel", parent)
	parent.add_child(r)
	return r

var _notice: Label
var _notice_left := 0.0

## Show a warning under the clock for `secs` seconds of real time.
func notice(text: String, secs := 12.0) -> void:
	if _notice == null:
		return
	_notice.text = text
	_notice_left = secs

func notice_text() -> String:
	return _notice.text if _notice else ""

func _process(_d: float) -> void:
	if _notice_left > 0.0:
		_notice_left -= _d
		if _notice_left <= 0.0 and _notice:
			_notice.text = ""
	if mm == null:
		return
	var hide := (menu != null and menu.is_open()) or not Settings.is_on("game/show_hud")
	_root.visible = not hide
	if hide:
		return

	# A guided auto recording takes over the clock: what matters then is how
	# much of your thirty seconds is left, not the practice clock.
	var main_node := get_parent()
	var rec: float = main_node.recording_left if main_node and "recording_left" in main_node else 0.0
	if rec > 0.0:
		_clock.text = "%0.1f" % rec
		_phase.text = "RECORDING AUTO"
	else:
		_clock.text = "--:--" if mm.free_practice() else BB.clock_text(mm.time_left)
		_phase.text = _phase_text()
	var hot := (mm.phase == BB.Phase.TELEOP and not mm.free_practice()
		and mm.time_left <= BB.ENDGAME_S) or rec > 0.0
	_clock.add_theme_color_override("font_color", Color(1, 0.48, 0.36) if hot else INK)

	# cell contents are only on the board once the match has finished
	_final = mm.phase == BB.Phase.SETTLE or mm.phase == BB.Phase.DONE
	var b := mm.scoring.breakdown(field, _final)
	_red.text = _alliance_panel(BB.Alliance.RED, b)
	_blue.text = _alliance_panel(BB.Alliance.BLUE, b)
	_tele.text = _telemetry()
	_log.text = "[b]EVENT LOG[/b]\n[font_size=13]" + "\n".join(mm.events) + "[/font_size]"
	_target.text = _target_text()
	_target.add_theme_color_override("font_color", _target_colour())

	var mate := _second_driver()
	var mp: PanelContainer = _mate.get_meta("panel")
	mp.visible = mate != null
	if mate != null:
		_mate.text = _mate_text(mate)

	# The full report is its own screen now (results_screen.gd). This card only
	# appears in free practice, which never "finishes" and so never opens one.
	var rp: PanelContainer = _results.get_meta("panel")
	rp.visible = mm.phase == BB.Phase.DONE and mm.free_practice()
	if rp.visible:
		_results.text = _results_text(mm.scoring.breakdown(field, true))

## The other person's robot, if a person is driving one. The AI opponent is
## deliberately not shown here: you get to watch it like you would at an event.
func _second_driver() -> Robot:
	for r in robots:
		if is_instance_valid(r) and r != robot and not r.ai_driver:
			return r
	return null

func _mate_text(r: Robot) -> String:
	var pips := ""
	for i in BB.HOPPER_MAX:
		if i < r.hopper.size():
			pips += "●" if i < BB.HOPPER_CAP else "[color=#ff5a4a]●[/color]"
		elif i < BB.HOPPER_CAP:
			pips += "○"
	var where := "PAD %d" % r.device if r.device >= 0 else DriverInput.device_name(r.device)
	return ("[b]%s[/b]  [color=#9aa3ad][font_size=13]%s[/font_size][/color]\n[font_size=13]" % [
			r.driver_label, where]
		+ "hopper [font_size=16]%s[/font_size]   intake %s   %.1f V\n" % [
			pips,
			"[color=#7fd67f]ON[/color]" if r.intake_on else "[color=#d67f7f]OFF[/color]",
			r.battery_v]
		+ "speed %5.1f in/s   x %6.1f  y %6.1f\n" % [r.speed_in_s(), r.fx(), r.fy()]
		+ "[/font_size]")

func _phase_text() -> String:
	match mm.phase:
		BB.Phase.PRE: return "READY"
		BB.Phase.AUTO: return "AUTONOMOUS  ·  K or D-PAD to skip"
		BB.Phase.TRANSITION: return "TRANSITION — no powered movement"
		BB.Phase.TELEOP:
			if mm.free_practice(): return "FREE PRACTICE"
			if mm.time_left <= BB.ENDGAME_S: return "ENDGAME"
			if mm.flowers_unlocked(): return "TELEOP — flowers unlocked"
			return "TELEOP — flowers locked (G410)"
		BB.Phase.SETTLE: return "SETTLING — scoring the field at rest"
		_: return "MATCH OVER"

func _alliance_panel(a: int, b: Dictionary) -> String:
	var c := BB.alliance_colour(a).to_html(false)
	var d: Dictionary = b[a]
	var h := field.hives[a] as Hive
	return ("[color=#%s][b]%s[/b][/color]   [font_size=26][b]%d[/b][/font_size]\n" % [
			c, BB.alliance_name(a), d["total"]]
		+ "[font_size=13][color=#9aa3ad]"
		+ "LEAVE %-4d PARK %-5d TIPS %d\n" % [d["leave"], d["park"], mm.scoring.tips[a]]
		+ "IN CELL %-3s GARDEN %-4d FOUL %d\n" % [
			str(d["cell"]) if _final else "--", d["garden"], d["foul"]]
		+ "FLOWERS %-3s BOTTOM NECTAR %s\n" % [
			str(d["flower"]) if _final else "--",
			str(d["bottom"]) if _final else "--"]
		+ "[/color]cell load %.2f / %.2f lb  %s\n" % [
			h.cell_mass(h.up_cell()) / BB.LB, BB.TIP_LB, _tip_bar(h)]
		+ "[/font_size]")

## A load bar for the raised CELL. The hive lets go at a MASS, so showing how
## close it is beats making the driver count balls.
func _tip_bar(h: Hive) -> String:
	var n := int(round(h.tip_progress() * 10.0))
	return "[" + "=".repeat(n).rpad(10, ".") + "]"

func _telemetry() -> String:
	if robot == null:
		return ""
	# pips past the legal four are drawn in red: that is the G407 line
	var pips := ""
	for i in BB.HOPPER_MAX:
		if i < robot.hopper.size():
			pips += "●" if i < BB.HOPPER_CAP else "[color=#ff5a4a]●[/color]"
		elif i < BB.HOPPER_CAP:
			pips += "○"

	var loads := robot.wheel_loads()
	var bars := ""
	for l in loads:
		bars += "[" + "|".repeat(int(clampf(l / 45.0, 0.0, 8.0))).rpad(8, ".") + "]"
	return ("[b]ROBOT[/b]  [color=#9aa3ad][font_size=13]%s[/font_size][/color]\n[font_size=13]\n" % (
			"CONTROLLER" if BB.has_pad() else "KEYBOARD")
		+ "hopper  [font_size=17]%s[/font_size]   intake %s\n" % [
			pips, "[color=#7fd67f]ON[/color]" if robot.intake_on else "[color=#d67f7f]OFF[/color]"]
		+ ("[color=#ff9a3a]%s[/color]\n" % mm.control_warning if mm.control_warning != "" else "\n")
		+ "speed %5.1f in/s      x %6.1f  y %6.1f\n" % [robot.speed_in_s(), robot.fx(), robot.fy()]
		+ "launcher %3.0f in/s    hood %4.1f°\n" % [robot.launch_speed_in_s, robot.hood_deg]
		+ "battery %s %.1f V   power %3.0f%%\n" % [
			_batt_bar(robot.battery_v), robot.battery_v, robot.power_factor() * 100.0]
		+ "%s      cam %s\n" % [
			"FIELD-CENTRIC" if robot.field_centric else "ROBOT-CENTRIC",
			rig.mode_name() if rig else "-"]
		+ "turret %s\n" % _turret_status()
		+ "wheel load %s\n" % bars
		+ "[/font_size]")

## A real robot browns out at the end of a match, and a driver who can see it
## coming drives differently. 13.0 V full, 10.8 V the floor the FTC SDK warns at.
func _batt_bar(v: float) -> String:
	var f := clampf((v - BB.BATTERY_FLOOR) / (BB.BATTERY_NOMINAL - BB.BATTERY_FLOOR), 0.0, 1.0)
	var n := int(round(f * 8.0))
	var col := "#7fd67f" if f > 0.55 else ("#ffc24a" if f > 0.25 else "#ff5a4a")
	return "[color=%s][%s][/color]" % [col, "|".repeat(n).rpad(8, ".")]

## Turret health, so a driver can see at a glance whether the launcher is
## tracking, being steered by hand, or has had to reset itself.
func _turret_status() -> String:
	if robot.manual_aim():
		return "[color=#ffc24a]MANUAL[/color] — auto-aim resumes shortly"
	if not robot.auto_aim:
		return "[color=#ffc24a]AUTO-AIM OFF[/color] (C or R3)"
	var extra := ""
	if robot.turret_faults > 0:
		extra = "  [color=#9aa3ad](recalibrated %dx)[/color]" % robot.turret_faults
	return "[color=#7fd67f]TRACKING[/color]%s" % extra

func _target_text() -> String:
	if robot == null:
		return ""
	if mm.control_warning != "":
		return mm.control_warning
	if robot.manual_aim():
		return "TURRET ON MANUAL — auto-aim takes back over in a moment"
	if not robot.auto_aim:
		return "AUTO-AIM OFF — press C (or R3) to re-engage"
	if robot.aim_blocked:
		return "NO LINE INTO THE CELL — drive around to its open side"
	if robot.aim_locked:
		return "◎  LOCKED ON %s CELL" % BB.alliance_name(robot.alliance)
	# Distinguish the two ways a shot can fail to exist. Close in, the arc has
	# to be so steep that it lands on the CELL's roof, and no aiming fixes that
	# — the driver has to back up, which is the opposite of the usual advice.
	if robot.aim_dist_in < 46.0:
		return "TOO CLOSE — no arc clears the roof, back up"
	return "OUT OF RANGE — get closer"

func _target_colour() -> Color:
	if mm != null and mm.control_warning != "":
		return Gui.WARN
	if robot == null or not robot.auto_aim:
		return DIM
	if robot.aim_locked:
		return Gui.GOOD
	return Gui.ACCENT

func _results_text(b: Dictionary) -> String:
	var s := "[font_size=22][b]MATCH OVER[/b][/font_size]\n[color=#9aa3ad][font_size=13]scored from the field at rest (S10.5)[/font_size][/color]\n\n"
	for a in [BB.Alliance.RED, BB.Alliance.BLUE]:
		var d: Dictionary = b[a]
		var rp: Array = mm.last_result.get("rp", {}).get(a, [])
		s += "[color=#%s][b]%-5s[/b][/color]  [font_size=24][b]%4d[/b][/font_size]   %s\n" % [
			BB.alliance_colour(a).to_html(false), BB.alliance_name(a), d["total"],
			("RP: " + ", ".join(rp)) if rp.size() else ""]
	s += "\n[font_size=13][color=#9aa3ad]BACKSPACE to run it again  ·  ESC for the menu[/color][/font_size]"
	return s
