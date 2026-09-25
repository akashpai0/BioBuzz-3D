class_name ObjectiveHud
extends CanvasLayer
##
## THE PRACTICE HUD.
##
## A compact card in the corner while an objective attempt is running: what you
## are trying to do, how far along you are, the clock, the constraints and
## which attempt this is. Deliberately separate from the match scoreboard —
## the score is the game's, this is the drill's.
##
## Status is never colour alone: every state carries a mark as well, so it
## reads the same to someone who cannot tell the yellow from the green.
##

var attempt: Attempt

var _root: Control
var _title: Label
var _progress: Label
var _clock: Label
var _constraints: VBoxContainer
var _foot: Label
var _card: PanelContainer

## The scoreboard this card must never cover. Set by main.
var hud: Hud

## Clear air between the bottom of the scoreboard and the top of this card,
## and the fallback top offset when there is no scoreboard to measure.
const GAP_UNDER_SCOREBOARD := 12.0
const FALLBACK_TOP := 150.0

func build() -> void:
	layer = 18
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = false
	add_child(_root)

	_card = PanelContainer.new()
	_card.anchor_left = 0.0
	_card.anchor_top = 0.0
	_card.offset_left = 24
	# A STARTING VALUE ONLY. _place() measures the scoreboard every frame and
	# puts the card under whatever height it actually came out at; a fixed 150
	# assumed the scoreboard's declared minimum height and overlapped it.
	_card.offset_top = GAP_UNDER_SCOREBOARD
	_card.custom_minimum_size = Vector2(330, 0)
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Gui.PANEL.r, Gui.PANEL.g, Gui.PANEL.b, 0.88)
	sb.border_color = Gui.LINE
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(Gui.R_PANEL)
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	_card.add_theme_stylebox_override("panel", sb)
	_root.add_child(_card)

	var v := Gui.vbox(Gui.S8)
	_card.add_child(v)
	v.add_child(Gui.eyebrow("Objective"))
	_title = Gui.label("", Gui.T_SMALL, Gui.INK, true)
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_title)

	var row := Gui.hbox(Gui.S16)
	_progress = Gui.label("", Gui.T_SECTION, Gui.ACCENT)
	Gui.weight(_progress, 1)
	row.add_child(_progress)
	row.add_child(Gui.spacer())
	_clock = Gui.label("", Gui.T_BODY, Gui.INK)
	_clock.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_clock)
	v.add_child(row)

	_constraints = Gui.vbox(2)
	v.add_child(_constraints)
	v.add_child(Gui.divider())
	_foot = Gui.label("", Gui.T_SMALL, Gui.MUTED)
	v.add_child(_foot)

## Start showing this attempt. Passing null hides the card.
func follow(a: Attempt) -> void:
	attempt = a
	_root.visible = a != null
	if a == null:
		return
	_title.text = Objective.describe(a.objective, _robot_label(a))
	_rebuild_constraints()
	_place()
	_tick()

func _robot_label(a: Attempt) -> String:
	var i := int(a.objective.get("robot", 0))
	if a.main and i < a.main.robots.size() and is_instance_valid(a.main.robots[i]):
		return String(a.main.robots[i].driver_label)
	return ""

func _rebuild_constraints() -> void:
	for c in _constraints.get_children():
		c.queue_free()
	if attempt == null:
		return
	var t := float(attempt.objective.get("time_limit", 0.0))
	if t > 0.0:
		_constraints.add_child(Gui.label("", Gui.T_SMALL, Gui.MUTED))
	if bool(attempt.objective.get("no_foul", false)):
		_constraints.add_child(Gui.label("", Gui.T_SMALL, Gui.MUTED))

func _process(_d: float) -> void:
	if _root.visible:
		_place()
		_tick()

## Keep the card clear of the scoreboard, whatever size the scoreboard is at
## this resolution and with this much text in it.
func _place() -> void:
	var below := FALLBACK_TOP
	if hud != null and is_instance_valid(hud):
		var edge := hud.left_panel_bottom()
		if edge > 0.0:
			below = edge + GAP_UNDER_SCOREBOARD
	if not is_equal_approx(_card.offset_top, below):
		_card.offset_top = below

func _tick() -> void:
	if attempt == null or not is_instance_valid(attempt):
		_root.visible = false
		return
	_progress.text = attempt.status_text()
	_clock.text = attempt.time_text()
	_progress.add_theme_color_override("font_color",
		Gui.GOOD if attempt.succeeded() else Gui.ACCENT)

	var i := 0
	var t := float(attempt.objective.get("time_limit", 0.0))
	if t > 0.0 and i < _constraints.get_child_count():
		var left := maxf(0.0, t - attempt.elapsed)
		var lbl := _constraints.get_child(i) as Label
		lbl.text = ("%s  time limit %s — %.1f s left"
			% ["!" if left < 5.0 else "•", Objective._secs(t), left])
		lbl.add_theme_color_override("font_color",
			Gui.WARN if left < 5.0 else Gui.MUTED)
		i += 1
	if bool(attempt.objective.get("no_foul", false)) and i < _constraints.get_child_count():
		var lbl2 := _constraints.get_child(i) as Label
		var clean := attempt.fouls_gained <= 0
		lbl2.text = ("%s  no new fouls — %s" % ["✓" if clean else "✗",
			"clean so far" if clean else "%d foul call%s" % [
				attempt.fouls_gained, "" if attempt.fouls_gained == 1 else "s"]])
		lbl2.add_theme_color_override("font_color", Gui.GOOD if clean else Gui.RED_INK)

	var hint := "%s retry · %s menu" % [
		_key("retry_scenario"), "Start" if BB.has_pad() else "Esc"]
	var extra := ""
	if attempt.pending_confirmation():
		extra = "  ·  provisional, settling"
	_foot.text = "Attempt %d%s     %s" % [attempt.attempt_no, extra, hint]

func _key(action: String) -> String:
	if BB.has_pad():
		return "menu →"
	var ks: Array = BB.keys_for(action)
	return OS.get_keycode_string(int(ks[0])) if not ks.is_empty() else "—"

func hide_card() -> void:
	_root.visible = false
	attempt = null
