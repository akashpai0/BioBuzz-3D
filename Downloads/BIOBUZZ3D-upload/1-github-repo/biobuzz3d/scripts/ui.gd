extends Node
##
## THE SHARED VISUAL LANGUAGE.
##
## Autoloaded as `Gui` (not `UI`: the Epic Online Services plugin has a class
## named `EOS.UI`, and Godot refuses an autoload that shares an inner class name).
## Every menu screen is built from these factories, so the
## four pages cannot drift apart. The values come straight from the design
## reference (#101211 page, #191C19 panels, #FFD139 accent, 12px panel corners,
## 8px control corners, an 8/16/24/32 spacing rhythm) scaled up from the 736 px
## reference width to the game's 1600x900 design canvas: ordinary text is 18 px
## here, not 14.
##
## The project stretches with `canvas_items` + `expand` on a 1600x900 base, so
## these are real sizes at every window size.
##

# ---------------------------------------------------------------- palette --
const BG        := Color(0.0627, 0.0706, 0.0667)   # #101211 page
const PANEL     := Color(0.0980, 0.1098, 0.0980)   # #191C19 panels
const SOFT      := Color(0.1333, 0.1529, 0.1333)   # #222722 hover / secondary
const INK       := Color(0.9333, 0.9451, 0.9137)   # #EEF1E9 primary text
const MUTED     := Color(0.6667, 0.7059, 0.6471)   # #AAB4A5 secondary text
const LINE      := Color(0.2000, 0.2314, 0.1961)   # #333B32 borders, dividers
const ACCENT    := Color(1.0000, 0.8196, 0.2235)   # #FFD139
const ON_ACCENT := Color(0.0902, 0.1059, 0.0784)   # #171B14 text on yellow
const RED_INK   := Color(1.0000, 0.5216, 0.5333)   # #FF8588
const BLUE_INK  := Color(0.5529, 0.7059, 1.0000)   # #8DB4FF
const GOOD      := Color(0.6627, 0.8510, 0.5804)   # #A9D994 status dot
const WARN      := Color(1.0000, 0.6902, 0.4000)
const STAGE     := Color(0.2039, 0.2392, 0.1725)   # preview backdrop centre

# ------------------------------------------------------------------ scale --
const S8 := 8
const S16 := 16
const S24 := 24
const S32 := 32
const PAD_PAGE := 36        # .bb-main padding 28 -> 36
const PAD_PANEL := 26       # .bb-box padding 20 -> 26
const GAP_COL := 30         # .bb-grid gap 24 -> 30
const R_PANEL := 14         # ~12px corners, scaled
const R_CTRL := 10          # ~8px corners, scaled
const R_KEY := 8

# ------------------------------------------------------------------- type --
const T_LOGO := 28
const T_EYEBROW := 13
const T_TITLE := 38         # h2 29 -> 38
const T_SECTION := 22       # h3 17 -> 22
const T_BODY := 18          # base 14 -> 18
const T_SMALL := 15         # small 12 -> 15
const T_TABLE := 16
const T_METRIC := 36

## Column split from the reference grid: minmax(0,1.35fr) / minmax(260px,1fr).
const SETUP_RATIO := 1.35
const PREVIEW_RATIO := 1.0

var _grabber: ImageTexture

## Symbols the built-in font lacks (arrows, stars, checks). On the desktop the
## system fonts fill these in; a browser has none, so the game carries them.
var symbols: Font

func _ready() -> void:
	_grabber = _round_dot(20, ACCENT)
	symbols = load("res://assets/fonts/symbols_fallback.ttf") as Font
	var base := ThemeDB.fallback_font
	if symbols and base and not base.fallbacks.has(symbols):
		var fb := base.fallbacks.duplicate()
		fb.append(symbols)
		base.fallbacks = fb

# ==================================================================== text ==

## Embolden the font's glyphs, rather than painting an outline over the text.
## An outline swallows counters and looks soft at fractional display scales.
func weight(l: Control, px := 1) -> void:
	var font := FontVariation.new()
	font.base_font = ThemeDB.fallback_font
	font.variation_embolden = float(px) * 0.6
	if symbols:
		font.fallbacks = [symbols]
	l.add_theme_font_override("font", font)
	l.add_theme_constant_override("outline_size", 0)

func label(t: String, size: int, col: Color, wrap := false) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if wrap \
		else TextServer.AUTOWRAP_OFF
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return l

## Small, spaced, quiet — the line above a page title.
func eyebrow(t: String) -> Label:
	var l := label(t.to_upper(), T_EYEBROW, MUTED)
	l.add_theme_constant_override("line_spacing", 2)
	return l

func title(t: String) -> Label:
	var l := label(t, T_TITLE, INK)
	weight(l, 1)
	return l

## Section title inside a panel.
func section(t: String) -> Label:
	var l := label(t, T_SECTION, INK)
	weight(l, 1)
	return l

func body(t: String, col := INK) -> Label:
	return label(t, T_BODY, col)

func note(t: String, col := MUTED) -> Label:
	var l := label(t, T_SMALL, col, true)
	l.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	return l

## A wrapped paragraph that will not force its container wider than the column.
func para(t: String, col := MUTED) -> Label:
	var l := label(t, T_SMALL, col, true)
	l.custom_minimum_size = Vector2(0, 0)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	return l

## Sentence case: "FULL MATCH" -> "Full match". Godot's capitalize() title-cases
## every word, which is not how any of these labels should read.
func sentence(t: String) -> String:
	var low := t.to_lower()
	return low.substr(0, 1).to_upper() + low.substr(1)

## "a", "a and b", "a, b and c" — the way a person writes a list.
func join_list(items: Array) -> String:
	if items.is_empty():
		return ""
	if items.size() == 1:
		return String(items[0])
	var head: Array = items.slice(0, items.size() - 1)
	return "%s and %s" % [", ".join(head), String(items[-1])]

func alliance_ink(a: int) -> Color:
	if BB.colorblind:
		return BB.alliance_colour(a).lightened(0.35)
	return RED_INK if a == BB.Alliance.RED else BLUE_INK

# ================================================================ boxes =====

func vbox(gap := S16) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", gap)
	return v

func hbox(gap := S16) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", gap)
	return h

func spacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c

func vspacer() -> Control:
	var c := Control.new()
	c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return c

func divider() -> ColorRect:
	var r := ColorRect.new()
	r.color = LINE
	r.custom_minimum_size = Vector2(0, 1)
	return r

## A raised panel: #191C19 on a thin #333B32 border, 14px corners.
func panel(pad := PAD_PANEL) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _panel_box(pad))
	return p

func _panel_box(pad: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL
	sb.border_color = LINE
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(R_PANEL)
	sb.content_margin_left = pad
	sb.content_margin_right = pad
	sb.content_margin_top = pad
	sb.content_margin_bottom = pad
	return sb

## Panel plus a vertical stack inside it, which is what every panel wants.
func card(gap := S16, pad := PAD_PANEL) -> Array:
	var p := panel(pad)
	var v := vbox(gap)
	p.add_child(v)
	return [p, v]

## A panel whose CONTENTS scroll while the panel itself stays put — the
## "bounded panel" the reference uses for Settings, and what keeps a long list
## of key bindings from pushing the category list off the bottom of the page.
func scroll_card(gap := S16, pad := PAD_PANEL) -> Array:
	var p := panel(pad)
	p.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var sc := make_scroll()
	p.add_child(sc)
	var m := MarginContainer.new()
	# room for the scrollbar, so it never sits on top of a dropdown's arrow
	m.add_theme_constant_override("margin_right", 14)
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(m)
	var v := vbox(gap)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	m.add_child(v)
	return [p, v]

## A vertical scroll region with a scrollbar that matches everything else:
## a thin rounded grabber on nothing, rather than the default grey slab.
func make_scroll() -> ScrollContainer:
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.follow_focus = true
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var bar := sc.get_v_scroll_bar()
	var empty := StyleBoxEmpty.new()
	bar.add_theme_stylebox_override("scroll", empty)
	bar.add_theme_stylebox_override("scroll_focus", empty)
	var grab := StyleBoxFlat.new()
	grab.bg_color = LINE
	grab.set_corner_radius_all(3)
	grab.content_margin_left = 3
	grab.content_margin_right = 3
	bar.add_theme_stylebox_override("grabber", grab)
	var grab2 := grab.duplicate() as StyleBoxFlat
	grab2.bg_color = LINE.lightened(0.25)
	bar.add_theme_stylebox_override("grabber_highlight", grab2)
	bar.add_theme_stylebox_override("grabber_pressed", grab2)
	bar.custom_minimum_size = Vector2(8, 0)
	return sc

# ============================================================== buttons =====
#
# Five looks, one behaviour contract. Every button carries normal, hover,
# pressed, selected, disabled and a focus ring, because a controller user has
# no cursor and has to see where they are.

enum Look { SECONDARY, PRIMARY, NAV, OPTION, TAB, SIDE, MODE, GHOST }

func button(text: String, look := Look.SECONDARY, min_size := Vector2.ZERO) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = min_size
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.set_meta("look", look)
	b.add_theme_font_size_override("font_size",
		T_SMALL if look == Look.OPTION else T_BODY)
	dress(b, false)
	if look == Look.PRIMARY:
		weight(b, 1)
	return b

func primary(text: String, min_size := Vector2(210, 54)) -> Button:
	return button(text, Look.PRIMARY, min_size)

func select(b: Button, on: bool) -> void:
	dress(b, on)

func selected(b: Button) -> bool:
	return bool(b.get_meta("selected", false))

func tint(b: Button, c: Color) -> void:
	b.set_meta("ink", c)
	dress(b, selected(b))

## Builds the whole state set for one button.
func dress(b: Button, on: bool) -> void:
	var look: int = b.get_meta("look", Look.SECONDARY)
	var ink: Color = b.get_meta("ink", INK)

	var pad_x := 14
	var pad_y := 10
	if look == Look.OPTION:
		pad_x = 14
		pad_y = 8
	elif look == Look.PRIMARY:
		pad_x = 26
		pad_y = 14

	var n := StyleBoxFlat.new()
	n.set_corner_radius_all(R_CTRL)
	n.content_margin_left = pad_x
	n.content_margin_right = pad_x
	n.content_margin_top = pad_y
	n.content_margin_bottom = pad_y
	n.bg_color = PANEL
	n.border_color = LINE
	n.set_border_width_all(1)
	var fg := ink

	match look:
		Look.PRIMARY:
			n.bg_color = ACCENT
			n.border_color = ACCENT
			fg = ON_ACCENT
		Look.NAV:
			# transparent until selected; selected gets the soft surface and a
			# 2px accent UNDERLINE rather than a box or a slab of yellow
			n.bg_color = SOFT if on else Color(0, 0, 0, 0)
			n.set_border_width_all(0)
			n.border_color = ACCENT
			if on:
				n.border_width_bottom = 2
			fg = INK if on else MUTED
		Look.OPTION:
			n.border_color = ACCENT if on else LINE
			if on:
				n.border_width_bottom = 3
			fg = ink
			n.content_margin_top = 7
			n.content_margin_bottom = 6
		Look.TAB, Look.SIDE:
			n.border_color = ACCENT if on else LINE
			fg = INK
		Look.MODE:
			n.border_color = ACCENT if on else LINE
			n.bg_color = PANEL.lerp(ACCENT, 0.09) if on else PANEL
			n.content_margin_left = 20
			n.content_margin_right = 20
			n.content_margin_top = 18
			n.content_margin_bottom = 18
		Look.GHOST:
			n.bg_color = Color(0, 0, 0, 0)
			n.border_color = Color(0, 0, 0, 0)
			fg = MUTED

	var h := n.duplicate() as StyleBoxFlat
	if look == Look.PRIMARY:
		h.bg_color = ACCENT.lightened(0.10)
	else:
		h.bg_color = SOFT
		if look != Look.OPTION and look != Look.NAV:
			h.border_color = ACCENT if on else LINE.lightened(0.25)

	var p := h.duplicate() as StyleBoxFlat
	if look == Look.PRIMARY:
		p.bg_color = ACCENT.darkened(0.10)
	else:
		p.bg_color = SOFT.lightened(0.06)

	# Keep focus inside the control's allocated bounds: ScrollContainers clip
	# outside outlines at their top/left edges. A hollow inset ring also keeps
	# the selected fill/underline visible beneath focus.
	var f := n.duplicate() as StyleBoxFlat
	f.draw_center = false
	f.border_color = ACCENT
	f.set_border_width_all(2)
	for side in [SIDE_LEFT, SIDE_RIGHT, SIDE_TOP, SIDE_BOTTOM]:
		f.set_expand_margin(side, -3.0)

	var d := n.duplicate() as StyleBoxFlat
	d.bg_color = PANEL.darkened(0.25)
	d.border_color = LINE.darkened(0.3)

	b.add_theme_stylebox_override("normal", n)
	b.add_theme_stylebox_override("hover", h)
	b.add_theme_stylebox_override("pressed", p)
	b.add_theme_stylebox_override("focus", f)
	b.add_theme_stylebox_override("disabled", d)
	b.add_theme_color_override("font_color", fg)
	b.add_theme_color_override("font_hover_color",
		ON_ACCENT if look == Look.PRIMARY else (ink if look == Look.OPTION else INK))
	b.add_theme_color_override("font_pressed_color",
		ON_ACCENT if look == Look.PRIMARY else INK)
	b.add_theme_color_override("font_focus_color", fg)
	b.add_theme_color_override("font_disabled_color", MUTED.darkened(0.35))
	b.set_meta("selected", on)

# ============================================================ composites ====

## A row: label on the left, controls on the right, with the reference's 14px
## vertical breathing room. `rows()` puts dividers between them.
func row(label_text: String, right: Control, label_w := 0) -> HBoxContainer:
	var h := hbox(S16)
	h.custom_minimum_size = Vector2(0, 48)
	var l := body(label_text)
	if label_w > 0:
		l.custom_minimum_size = Vector2(label_w, 0)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(l)
	h.add_child(spacer())
	right.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(right)
	return h

## Adds each row to `into`, separated by hairlines, the way .bb-row+.bb-row does.
func rows(into: Control, list: Array) -> void:
	for i in list.size():
		if i > 0:
			into.add_child(divider())
		into.add_child(list[i])

## A set of mutually exclusive small buttons. `on_pick` gets the index.
func options(values: Array, chosen: int, on_pick: Callable,
		inks: Array = []) -> HBoxContainer:
	var h := hbox(6)
	h.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var made: Array[Button] = []
	for i in values.size():
		var b := button(String(values[i]), Look.OPTION)
		if i < inks.size():
			b.set_meta("ink", inks[i])
		b.pressed.connect(func() -> void:
			for j in made.size():
				select(made[j], j == i)
			SFX.play("click", -18.0)
			on_pick.call(i))
		h.add_child(b)
		made.append(b)
	for j in made.size():
		select(made[j], j == chosen)
	h.set_meta("buttons", made)
	return h

func set_options(h: Control, chosen: int) -> void:
	var made: Array = h.get_meta("buttons", [])
	for j in made.size():
		select(made[j], j == chosen)

## A big mode card: title, then a quiet line under it.
func mode_card(t: String, sub: String, on: bool, pick: Callable) -> Button:
	var b := button("", Look.MODE, Vector2(0, 104))
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var v := vbox(S8)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.offset_left = 20
	v.offset_right = -20
	v.offset_top = 18
	v.offset_bottom = -18
	var head := label(t, T_BODY, INK)
	weight(head, 1)
	v.add_child(head)
	v.add_child(vspacer())
	var s := label(sub, T_SMALL, MUTED, true)
	s.size_flags_vertical = Control.SIZE_SHRINK_END
	v.add_child(s)
	b.add_child(v)
	b.pressed.connect(pick)
	select(b, on)
	return b

## Value over caption, the .bb-facts block.
func fact(value: String, caption: String) -> VBoxContainer:
	var v := vbox(2)
	v.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var a := label(value, T_BODY, INK)
	weight(a, 1)
	v.add_child(a)
	v.add_child(label(caption, T_SMALL, MUTED))
	return v

## Big number in a panel, for Progress.
func metric(caption: String, value: String, hint := "") -> PanelContainer:
	var pair := card(S8)
	var p: PanelContainer = pair[0]
	var v: VBoxContainer = pair[1]
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(label(caption, T_BODY, INK))
	var big := label(value, T_METRIC, INK)
	weight(big, 1)
	v.add_child(big)
	v.add_child(label(hint, T_SMALL, MUTED))
	return p

## A coloured dot followed by text: the live status lines.
func status(text: String, col: Color) -> HBoxContainer:
	var h := hbox(S8)
	h.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var dot := Panel.new()
	dot.custom_minimum_size = Vector2(9, 9)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.set_corner_radius_all(5)
	dot.add_theme_stylebox_override("panel", sb)
	h.add_child(dot)
	h.add_child(label(text, T_SMALL, MUTED))
	h.set_meta("dot", dot)
	return h

func set_status(h: Control, text: String, col: Color) -> void:
	var dot: Panel = h.get_meta("dot")
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.set_corner_radius_all(5)
	dot.add_theme_stylebox_override("panel", sb)
	(h.get_child(1) as Label).text = text

## A keycap: the binding chips on the Controls page.
func key_chip(text: String) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = SOFT
	sb.border_color = LINE
	sb.set_border_width_all(1)
	sb.border_width_bottom = 3
	sb.set_corner_radius_all(R_KEY)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 5
	sb.content_margin_bottom = 4
	p.add_theme_stylebox_override("panel", sb)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.add_child(label(text, T_SMALL, INK))
	return p

# ============================================================== controls ====

func _round_dot(px: int, col: Color) -> ImageTexture:
	var img := Image.create(px, px, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var c := (px - 1) * 0.5
	for y in px:
		for x in px:
			var d := Vector2(x - c, y - c).length()
			var a := clampf((c - d) + 0.5, 0.0, 1.0)
			if a > 0.0:
				img.set_pixel(x, y, Color(col.r, col.g, col.b, a))
	return ImageTexture.create_from_image(img)

## A real HSlider in the reference's shape: yellow filled track, round yellow
## grabber, grey remainder.
func slider(lo: float, hi: float, value: float, step: float) -> HSlider:
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = value
	s.custom_minimum_size = Vector2(0, 26)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.focus_mode = Control.FOCUS_ALL

	var track := StyleBoxFlat.new()
	track.bg_color = LINE
	track.set_corner_radius_all(3)
	track.content_margin_top = 3
	track.content_margin_bottom = 3
	var fill := StyleBoxFlat.new()
	fill.bg_color = ACCENT
	fill.set_corner_radius_all(3)
	fill.content_margin_top = 3
	fill.content_margin_bottom = 3
	s.add_theme_stylebox_override("slider", track)
	s.add_theme_stylebox_override("grabber_area", fill)
	s.add_theme_stylebox_override("grabber_area_highlight", fill)
	s.add_theme_icon_override("grabber", _grabber)
	s.add_theme_icon_override("grabber_highlight", _grabber)
	s.add_theme_icon_override("grabber_disabled", _grabber)
	return s

## Label and live value above a full-width slider, as the reference lays it out.
func slider_row(label_text: String, s: HSlider, fmt: Callable) -> VBoxContainer:
	var v := vbox(S8)
	var head := label("%s %s" % [label_text, fmt.call(s.value)], T_BODY, INK)
	v.add_child(head)
	v.add_child(s)
	s.value_changed.connect(func(val: float) -> void:
		head.text = "%s %s" % [label_text, fmt.call(val)])
	v.set_meta("head", head)
	return v

## A dropdown, styled to match the buttons.
func dropdown(items: Array, chosen: int, on_pick: Callable,
		min_w := 210) -> OptionButton:
	var o := OptionButton.new()
	for it in items:
		o.add_item(String(it))
	o.selected = clampi(chosen, 0, maxi(0, items.size() - 1))
	o.focus_mode = Control.FOCUS_ALL
	o.custom_minimum_size = Vector2(min_w, 46)
	o.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	o.add_theme_font_size_override("font_size", T_BODY)
	o.set_meta("look", Look.SECONDARY)
	dress(o, false)
	o.alignment = HORIZONTAL_ALIGNMENT_LEFT

	var pop := o.get_popup()
	var pb := StyleBoxFlat.new()
	pb.bg_color = PANEL
	pb.border_color = LINE
	pb.set_border_width_all(1)
	pb.set_corner_radius_all(R_CTRL)
	pb.content_margin_left = 6
	pb.content_margin_right = 6
	pb.content_margin_top = 6
	pb.content_margin_bottom = 6
	pop.add_theme_stylebox_override("panel", pb)
	var hov := StyleBoxFlat.new()
	hov.bg_color = SOFT
	hov.set_corner_radius_all(R_KEY)
	pop.add_theme_stylebox_override("hover", hov)
	pop.add_theme_color_override("font_color", INK)
	pop.add_theme_color_override("font_hover_color", ACCENT)
	pop.add_theme_font_size_override("font_size", T_BODY)

	o.item_selected.connect(func(i: int) -> void:
		SFX.play("click", -18.0)
		on_pick.call(i))
	return o

## A single-line text field in the same language.
func line_edit(placeholder: String, text := "") -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.text = text
	e.custom_minimum_size = Vector2(0, 46)
	e.add_theme_font_size_override("font_size", T_BODY)
	e.add_theme_color_override("font_color", INK)
	e.add_theme_color_override("font_placeholder_color", MUTED.darkened(0.2))
	e.add_theme_color_override("caret_color", ACCENT)
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL
	sb.border_color = LINE
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(R_CTRL)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	e.add_theme_stylebox_override("normal", sb)
	var f := sb.duplicate() as StyleBoxFlat
	f.border_color = ACCENT
	f.set_border_width_all(2)
	e.add_theme_stylebox_override("focus", f)
	return e

## A disclosure: one quiet line you can ignore, and a box of detail a click
## away. Returns [button, box]; the caller fills the box and it starts hidden.
func disclosure(summary: String) -> Array:
	var b := button("▾  " + summary, Look.GHOST, Vector2(0, 36))
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.add_theme_font_size_override("font_size", T_SMALL)
	var box := vbox(S8)
	box.visible = false
	b.pressed.connect(func() -> void:
		box.visible = not box.visible
		b.text = ("▴  " if box.visible else "▾  ") + summary
		SFX.play("click", -22.0))
	return [b, box]

# ================================================================= tables ===

## Header row for a data table. `cols` is [[text, width, right_aligned], ...];
## width 0 means "take the slack".
func table_head(cols: Array) -> HBoxContainer:
	var h := hbox(S16)
	for c in cols:
		h.add_child(_cell(String(c[0]), int(c[1]), bool(c[2]), MUTED, T_SMALL))
	return h

func table_row(cols: Array, col := INK) -> HBoxContainer:
	var h := hbox(S16)
	h.custom_minimum_size = Vector2(0, 46)
	for c in cols:
		h.add_child(_cell(String(c[0]), int(c[1]), bool(c[2]), col, T_TABLE))
	return h

func _cell(t: String, w: int, right: bool, col: Color, size: int) -> Label:
	var l := label(t, size, col)
	l.clip_text = true
	if w > 0:
		l.custom_minimum_size = Vector2(w, 0)
	else:
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if right \
		else HORIZONTAL_ALIGNMENT_LEFT
	return l

# ================================================================== shell ===
#
# Every page is this shape: a top bar that never moves, a heading, a scrolling
# body, and a footer that always holds the primary action. `shell()` builds it
# and hands back the parts a page fills in.

const NAV := ["Play", "Garage", "Progress", "Settings"]

func shell(active: String, go: Callable) -> Dictionary:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bg)

	var col := vbox(0)
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(col)

	# ---- top bar
	var toppad := MarginContainer.new()
	toppad.add_theme_constant_override("margin_left", PAD_PAGE)
	toppad.add_theme_constant_override("margin_right", PAD_PAGE)
	toppad.add_theme_constant_override("margin_top", S24)
	toppad.add_theme_constant_override("margin_bottom", S24)
	col.add_child(toppad)

	var top := hbox(S16)
	toppad.add_child(top)

	var brand := vbox(0)
	brand.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var logo := RichTextLabel.new()
	logo.bbcode_enabled = true
	logo.fit_content = true
	logo.scroll_active = false
	logo.custom_minimum_size = Vector2(230, 0)
	logo.add_theme_font_size_override("normal_font_size", T_LOGO)
	logo.text = "[color=#EEF1E9]BIO[/color][color=#FFD139]BUZZ[/color][color=#EEF1E9] / 3D[/color]"
	brand.add_child(logo)
	var sub := label("DRIVER PRACTICE", T_EYEBROW, MUTED)
	sub.add_theme_constant_override("line_spacing", 0)
	brand.add_child(sub)
	top.add_child(brand)
	top.add_child(spacer())

	var nav := hbox(6)
	nav.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top.add_child(nav)
	var nav_buttons := {}
	for page in NAV:
		var b := button(page, Look.NAV, Vector2(0, 44))
		b.pressed.connect(func() -> void:
			if page == active:
				return
			SFX.play("select", -16.0)
			go.call(page))
		select(b, page == active)
		nav.add_child(b)
		nav_buttons[page] = b
	col.add_child(divider())

	# ---- heading + body
	var mainpad := MarginContainer.new()
	mainpad.add_theme_constant_override("margin_left", PAD_PAGE)
	mainpad.add_theme_constant_override("margin_right", PAD_PAGE)
	mainpad.add_theme_constant_override("margin_top", S24)
	mainpad.add_theme_constant_override("margin_bottom", S24)
	mainpad.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(mainpad)

	var main := vbox(S24)
	mainpad.add_child(main)

	var headrow := hbox(S16)
	main.add_child(headrow)
	var heads := vbox(2)
	var eyeb := eyebrow("")
	var ttl := title("")
	heads.add_child(eyeb)
	heads.add_child(ttl)
	headrow.add_child(heads)
	headrow.add_child(spacer())
	var head_right := hbox(S8)
	head_right.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	headrow.add_child(head_right)

	var scroll := make_scroll()
	main.add_child(scroll)

	# keep the page content clear of the scrollbar's gutter
	var gutter := MarginContainer.new()
	gutter.add_theme_constant_override("margin_right", 14)
	gutter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gutter.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(gutter)

	var body_box := vbox(S24)
	body_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	gutter.add_child(body_box)

	# ---- footer
	col.add_child(divider())
	var footwrap := PanelContainer.new()
	var fb := StyleBoxFlat.new()
	fb.bg_color = PANEL
	fb.content_margin_left = PAD_PAGE
	fb.content_margin_right = PAD_PAGE
	fb.content_margin_top = S16
	fb.content_margin_bottom = S16
	footwrap.add_theme_stylebox_override("panel", fb)
	col.add_child(footwrap)

	var foot := hbox(S24)
	footwrap.add_child(foot)
	var foot_text := vbox(2)
	foot_text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var foot_line := label("", T_BODY, INK)
	var foot_note := label("", T_SMALL, MUTED)
	foot_text.add_child(foot_line)
	foot_text.add_child(foot_note)
	foot.add_child(foot_text)
	foot.add_child(spacer())
	# A SECOND FOOTER ACTION, hidden unless a screen asks for it. A page whose
	# only way onward is the primary button strands anyone who wants the other
	# one: on the attempt result, "Retry" sat in the footer while "Back to the
	# library" was below the fold.
	var foot_alt := button("", Look.SECONDARY, Vector2(0, 56))
	foot_alt.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	foot_alt.visible = false
	foot.add_child(foot_alt)
	var foot_btn := primary("", Vector2(230, 56))
	foot_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	foot.add_child(foot_btn)

	return {
		"root": root, "nav": nav_buttons, "head_right": head_right,
		"eyebrow": eyeb, "title": ttl, "body": body_box,
		"foot_line": foot_line, "foot_note": foot_note, "foot_btn": foot_btn,
		"foot_alt": foot_alt, "scroll": scroll,
	}

## The two-column body both Play and Garage use: setup on the left at ~57%,
## preview on the right.
func two_columns(into: Control) -> Array:
	var h := hbox(GAP_COL)
	h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.size_flags_vertical = Control.SIZE_EXPAND_FILL
	into.add_child(h)
	var left := vbox(S24)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = SETUP_RATIO
	h.add_child(left)
	var right := vbox(S24)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.size_flags_stretch_ratio = PREVIEW_RATIO
	right.custom_minimum_size = Vector2(340, 0)
	h.add_child(right)
	return [left, right]
