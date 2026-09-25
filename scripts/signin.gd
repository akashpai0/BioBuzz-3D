class_name SignIn
extends CanvasLayer
##
## Asked once, the first time the game is opened: what to call you. The name is
## kept in `user://profile.cfg` and is what appears on the leaderboard, so this
## never shows again unless the profile is deleted.
##

signal done(name: String)

var _field: LineEdit
var _root: Control

func build() -> void:
	layer = 30
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)

	var bg := ColorRect.new()
	bg.color = Gui.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(bg)

	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(centre)

	var pair := Gui.card(Gui.S16, 40)
	var cardw: PanelContainer = pair[0]
	cardw.custom_minimum_size = Vector2(560, 0)
	centre.add_child(cardw)
	var v: VBoxContainer = pair[1]

	var logo := RichTextLabel.new()
	logo.bbcode_enabled = true
	logo.fit_content = true
	logo.scroll_active = false
	logo.add_theme_font_size_override("normal_font_size", Gui.T_LOGO)
	logo.text = "[color=#EEF1E9]BIO[/color][color=#FFD139]BUZZ[/color][color=#EEF1E9] / 3D[/color]"
	v.add_child(logo)
	v.add_child(Gui.eyebrow("DRIVER PRACTICE"))
	v.add_child(Gui.divider())

	v.add_child(Gui.title("Who's driving?"))
	v.add_child(Gui.para(
		"This is the name on your leaderboard runs. It is stored on this "
		+ "computer only and nothing is sent anywhere."))

	_field = Gui.line_edit("driver name")
	_field.max_length = 18
	v.add_child(_field)
	_field.text_submitted.connect(func(_t: String) -> void: _go())

	var b := Gui.primary("Continue  →", Vector2(0, 56))
	b.pressed.connect(_go)
	v.add_child(b)

	_field.grab_focus()

func _go() -> void:
	var n := _field.text.strip_edges()
	if n == "":
		n = "Driver"
	Leaderboard.set_player_name(n)
	_root.visible = false
	done.emit(n)

func is_open() -> bool:
	return _root != null and _root.visible
