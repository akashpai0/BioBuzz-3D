class_name ReplayTimeline
extends Control
##
## THE SCRUB BAR. Click or drag anywhere to seek. Draws the recorded length,
## every checkpoint (when they are far enough apart to see), a marker per
## event, and the playhead. It never changes anything but the viewer's time.
##

signal seek_requested(t: float)

var duration := 1.0
var t := 0.0
var checkpoints: Array = []
var events: Array = []
## [t0, t1] ranges that could not be decoded
var gaps: Array = []
var _drag := false

const TRACK_H := 10.0

func _ready() -> void:
	custom_minimum_size = Vector2(0, 46)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

func _x_of(tt: float) -> float:
	return clampf(tt / maxf(duration, 0.001), 0.0, 1.0) * size.x

func _t_of(x: float) -> float:
	return clampf(x / maxf(size.x, 1.0), 0.0, 1.0) * duration

func _draw() -> void:
	var mid := size.y * 0.62
	var track := Rect2(0, mid - TRACK_H * 0.5, size.x, TRACK_H)
	draw_rect(track, Gui.SOFT)
	draw_rect(Rect2(0, track.position.y, _x_of(t), TRACK_H), Gui.ACCENT.darkened(0.25))
	for g in gaps:
		draw_rect(Rect2(_x_of(float(g[0])), track.position.y,
			maxf(2.0, _x_of(float(g[1])) - _x_of(float(g[0]))), TRACK_H), Gui.RED_INK)
	# checkpoints, only when at least 4 px apart
	if checkpoints.size() > 1 and size.x / float(checkpoints.size()) >= 4.0:
		for c in checkpoints:
			var x := _x_of(float(c))
			draw_line(Vector2(x, mid + TRACK_H * 0.5), Vector2(x, mid + TRACK_H * 0.5 + 5),
				Gui.MUTED, 1.0)
	for ev in events:
		var x2 := _x_of(float(ev.get("t", 0.0)))
		var col := Gui.INK
		match String(ev.get("type", "")):
			"shot": col = Gui.MUTED
			"made": col = Gui.GOOD
			"tip": col = Gui.ACCENT
			"foul": col = Gui.RED_INK
			"phase", "start": col = Gui.BLUE_INK
			"objective": col = Gui.WARN
		var top := mid - TRACK_H * 0.5 - 3.0
		draw_colored_polygon(PackedVector2Array([Vector2(x2 - 4, top - 8),
			Vector2(x2 + 4, top - 8), Vector2(x2, top)]), col)
	var px := _x_of(t)
	draw_rect(Rect2(px - 2, 2, 4, size.y - 4), Gui.INK)
	if has_focus():
		draw_rect(Rect2(Vector2.ZERO, size), Gui.ACCENT, false, 2.0)

func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_drag = (ev as InputEventMouseButton).pressed
		if _drag:
			grab_focus()
			seek_requested.emit(_t_of((ev as InputEventMouseButton).position.x))
		accept_event()
	elif ev is InputEventMouseMotion and _drag:
		seek_requested.emit(_t_of((ev as InputEventMouseMotion).position.x))
		accept_event()

func set_state(tt: float) -> void:
	t = tt
	queue_redraw()
