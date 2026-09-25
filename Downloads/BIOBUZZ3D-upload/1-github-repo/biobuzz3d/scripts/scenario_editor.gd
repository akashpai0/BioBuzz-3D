class_name ScenarioEditor
extends CanvasLayer
##
## THE SCENARIO CREATOR.
##
## Arrange a practice situation by hand, test it, come back and keep editing.
## It edits the REAL field with the game paused — the walls, HIVES and FLOWERS
## you see are the ones you will drive against, not a diagram of them — and it
## reads and writes the SAME saved-situation format the checkpoint system
## already uses. There is no second save format and no second capture path.
##
## The field is the screen. Panels sit over the edges: the palette on the left,
## the selected object's properties on the right, the name and history along
## the top, and the validation state with Save and Test along the bottom.
##
## Nothing here touches the snapshot dictionary directly: every change goes
## through ScenarioDraft, which is what gives undo, ownership and validation
## one place to live.
##

signal closed
signal test_requested(snapshot: Dictionary)
signal saved(id: String)

## What a left click does.
enum Tool { SELECT, POLLEN, NECTAR_RED, NECTAR_BLUE, ROBOT_OURS, ROBOT_FOE, AREA }

const TOOL_NAMES := {
	Tool.SELECT: "Select",
	Tool.POLLEN: "Pollen",
	Tool.NECTAR_RED: "Nectar (red)",
	Tool.NECTAR_BLUE: "Nectar (blue)",
	Tool.ROBOT_OURS: "Robot (ours)",
	Tool.ROBOT_FOE: "Robot (opponent)",
	Tool.AREA: "Target area",
}
const SNAP_IN := 2.0

var main: Node3D
var draft: ScenarioDraft

var _root: Control
var _centre: Control                 # the see-through hole the field shows in
var _left: VBoxContainer
var _props: VBoxContainer
var _status: HBoxContainer
var _name_edit: LineEdit
var _undo_btn: Button
var _redo_btn: Button
var _snap_btn: Button
var _help: PanelContainer
var _save_btn: Button
var _copy_btn: Button
var _test_btn: Button
var _tool_buttons: Dictionary = {}

var _tool: int = Tool.SELECT
var _selected := ""
var _snap := true
## "Stop motion when moved", on by default: dragging a ball that was flying
## normally means you want it placed, not launched.
var _stop_on_move := true

var _cam: Camera3D
var _prev_cam: Camera3D
var _focus := Vector3.ZERO
var _dist := 5.0
var _pitch := PI * 0.5               # straight down
var _yaw := 0.0
var _pan := Vector2.ZERO
var _dragging := false
var _panning := false
var _drag_offset := Vector3.ZERO

var _marker: MeshInstance3D
var _area: Node3D
var _ghost: MeshInstance3D
var _problems: Array = []

# ==================================================================== build ==

func build() -> void:
	layer = 32
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.visible = false
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# The hole in the middle forwards clicks to the field: anything over a
	# panel is UI, anything over this is the world. It goes in FIRST so the
	# panels sit above it and keep their own clicks.
	_centre = Control.new()
	_centre.anchor_left = 0.0
	_centre.anchor_right = 1.0
	_centre.anchor_top = 0.0
	_centre.anchor_bottom = 1.0
	_centre.offset_left = 268
	_centre.offset_right = -396
	_centre.offset_top = 84
	_centre.offset_bottom = -92
	_centre.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(_centre)
	_centre.gui_input.connect(_on_field_input)
	_centre.resized.connect(_fit_view)

	_build_top()
	_build_left()
	_build_right()
	_build_bottom()
	_build_help()

func _panel(w: int) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Gui.PANEL.r, Gui.PANEL.g, Gui.PANEL.b, 0.96)
	sb.border_color = Gui.LINE
	sb.set_border_width_all(1)
	sb.content_margin_left = Gui.S16
	sb.content_margin_right = Gui.S16
	sb.content_margin_top = Gui.S16
	sb.content_margin_bottom = Gui.S16
	p.add_theme_stylebox_override("panel", sb)
	if w > 0:
		p.custom_minimum_size = Vector2(w, 0)
	return p

func _build_top() -> void:
	var bar := _panel(0)
	bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	bar.offset_bottom = 84
	_root.add_child(bar)
	var row := Gui.hbox(Gui.S16)
	bar.add_child(row)

	var brand := Gui.vbox(0)
	brand.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	brand.add_child(Gui.eyebrow("SCENARIO CREATOR"))
	brand.add_child(Gui.label("Arrange the field", Gui.T_SMALL, Gui.MUTED))
	row.add_child(brand)

	_name_edit = Gui.line_edit("situation name")
	_name_edit.custom_minimum_size = Vector2(320, 44)
	_name_edit.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_name_edit.text_changed.connect(func(t: String) -> void:
		draft.name = t
		draft.dirty = true
		_refresh_status())
	row.add_child(_name_edit)
	row.add_child(Gui.spacer())

	var top := Gui.button("Top-down")
	top.pressed.connect(func() -> void: _set_view(true))
	row.add_child(top)
	var ang := Gui.button("Angled")
	ang.pressed.connect(func() -> void: _set_view(false))
	row.add_child(ang)

	_undo_btn = Gui.button("Undo")
	_undo_btn.pressed.connect(_undo)
	row.add_child(_undo_btn)
	_redo_btn = Gui.button("Redo")
	_redo_btn.pressed.connect(_redo)
	row.add_child(_redo_btn)
	var helpb := Gui.button("Controls")
	helpb.pressed.connect(func() -> void: _help.visible = not _help.visible)
	row.add_child(helpb)

func _build_left() -> void:
	var p := _panel(252)
	p.clip_contents = true
	p.anchor_top = 0.0
	p.anchor_bottom = 1.0
	p.offset_top = 84
	p.offset_bottom = -92
	p.offset_right = 252
	_root.add_child(p)
	var sc := Gui.make_scroll()
	p.add_child(sc)
	var gut := MarginContainer.new()
	gut.add_theme_constant_override("margin_right", 12)
	gut.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(gut)
	_left = Gui.vbox(Gui.S8)
	_left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gut.add_child(_left)

	_left.add_child(Gui.eyebrow("Palette"))
	for t in [Tool.SELECT, Tool.POLLEN, Tool.NECTAR_RED, Tool.NECTAR_BLUE,
			Tool.ROBOT_OURS, Tool.ROBOT_FOE, Tool.AREA]:
		var b := Gui.button(String(TOOL_NAMES[t]), Gui.Look.SIDE, Vector2(0, 44))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.pressed.connect(func() -> void: _pick_tool(t))
		_left.add_child(b)
		_tool_buttons[t] = b
	_left.add_child(Gui.para(
		"Pick a tool, then click the field to place. Select is the arrow: "
		+ "click something to edit it, drag to move it."))

	_left.add_child(Gui.divider())
	_left.add_child(Gui.eyebrow("Placing"))
	_snap_btn = Gui.button("Snap to 2 in grid", Gui.Look.SIDE, Vector2(0, 44))
	_snap_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_snap_btn.pressed.connect(func() -> void:
		_snap = not _snap
		Gui.select(_snap_btn, _snap))
	_left.add_child(_snap_btn)
	Gui.select(_snap_btn, _snap)

	var stop := Gui.button("Stop motion when moved", Gui.Look.SIDE, Vector2(0, 44))
	stop.alignment = HORIZONTAL_ALIGNMENT_LEFT
	stop.pressed.connect(func() -> void:
		_stop_on_move = not _stop_on_move
		Gui.select(stop, _stop_on_move))
	_left.add_child(stop)
	Gui.select(stop, _stop_on_move)
	_left.add_child(Gui.para(
		"With this on, dragging a ball that was flying stops it where you put "
		+ "it. Turn it off to move something without disturbing its motion."))

func _build_right() -> void:
	var p := _panel(380)
	p.clip_contents = true
	p.anchor_left = 1.0
	p.anchor_right = 1.0
	p.anchor_top = 0.0
	p.anchor_bottom = 1.0
	p.offset_left = -380
	p.offset_top = 84
	p.offset_bottom = -92
	_root.add_child(p)
	var sc := Gui.make_scroll()
	p.add_child(sc)
	var gut := MarginContainer.new()
	gut.add_theme_constant_override("margin_right", 12)
	gut.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(gut)
	_props = Gui.vbox(Gui.S8)
	_props.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gut.add_child(_props)

func _build_bottom() -> void:
	var bar := _panel(0)
	bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bar.offset_top = -92
	_root.add_child(bar)
	var row := Gui.hbox(Gui.S16)
	bar.add_child(row)
	_status = Gui.status("", Gui.GOOD)
	_status.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_status)
	row.add_child(Gui.spacer())

	var back := Gui.button("Back", Gui.Look.SECONDARY, Vector2(0, 52))
	back.pressed.connect(_try_close)
	row.add_child(back)
	_copy_btn = Gui.button("Save as copy", Gui.Look.SECONDARY, Vector2(0, 52))
	_copy_btn.pressed.connect(func() -> void: _save(true))
	row.add_child(_copy_btn)
	_test_btn = Gui.button("Test scenario", Gui.Look.SECONDARY, Vector2(0, 52))
	_test_btn.tooltip_text = "Test a copy of this draft. Press Esc to return to the editor."
	_test_btn.pressed.connect(_test)
	row.add_child(_test_btn)
	_save_btn = Gui.primary("Save", Vector2(170, 52))
	_save_btn.pressed.connect(func() -> void: _save(false))
	row.add_child(_save_btn)

func _build_help() -> void:
	_help = _panel(0)
	_help.anchor_left = 0.0
	_help.anchor_top = 1.0
	_help.anchor_bottom = 1.0
	_help.offset_left = 268
	_help.offset_right = 690
	_help.offset_top = -330
	_help.offset_bottom = -104
	_help.visible = false
	_help.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(_help)
	var v := Gui.vbox(Gui.S8)
	_help.add_child(v)
	v.add_child(Gui.section("Editing controls"))
	for line in [
		"Left click — select, or place with a palette tool",
		"Left drag — move the selected object",
		"Right or middle drag — pan the view",
		"Mouse wheel — zoom",
		"Q / E — rotate the selection by 15°",
		"Delete — remove the selection",
		"Ctrl+Z / Ctrl+Y — undo and redo",
		"G — grid snapping on or off",
		"Escape — back to the library",
	]:
		v.add_child(Gui.label(line, Gui.T_SMALL, Gui.MUTED))
	v.add_child(Gui.para(
		"Precise placement is mouse and keyboard. Every panel — the palette, "
		+ "the properties and the buttons along the bottom — is reachable with "
		+ "a controller or the Tab key, and every position and heading can be "
		+ "typed in as a number."))

# ===================================================================== open ==

## Take over the field with `d`. The world is posed from the draft and left
## frozen: no clock, no gravity, no intake, no AI.
func open(d: ScenarioDraft) -> void:
	draft = d
	_selected = ""
	_tool = Tool.SELECT
	_name_edit.text = draft.name
	_root.visible = true
	await _sync_world()
	_install_camera()
	_set_view(true)
	_refresh_all()

## Come back from a test run with the draft exactly as it was left.
func reopen() -> void:
	_root.visible = true
	await _sync_world()
	_install_camera()
	_refresh_all()

func close() -> void:
	_root.visible = false
	_release_camera()
	BB.editing = false
	# the editing overlays belong to the editor; practice has its own, optional
	_placing = Place.NONE
	for o in _opp_overlays:
		if is_instance_valid(o):
			o.queue_free()
	_opp_overlays.clear()

func is_open() -> bool:
	return _root.visible

# =================================================================== world ===

## Put the draft on the field. Structural changes go through here; dragging
## does not, because a full rebuild per mouse move would be unusable.
func _sync_world() -> void:
	await Snapshot.restore(main, draft.data, true)
	_make_helpers()
	_draw_opponent_overlays()
	_refresh_marker()

func _node_for(id: String) -> Node3D:
	if id.begins_with("robot:"):
		var i := int(id.trim_prefix("robot:"))
		if i >= 0 and i < main.robots.size() and is_instance_valid(main.robots[i]):
			return main.robots[i]
		return null
	if id.begins_with("hive:"):
		var a := int(id.trim_prefix("hive:"))
		return main.field.hives.get(a, null)
	for n in main.get_tree().get_nodes_in_group("element"):
		if String((n as Node).get_meta("sid", "")) == id:
			return n
	return null

func _id_for(n: Node) -> String:
	if n is Robot:
		for i in main.robots.size():
			if main.robots[i] == n:
				return "robot:%d" % i
	if n is GameElement:
		return String(n.get_meta("sid", ""))
	return ""

## The selection ring and the placement ghost. Rebuilt whenever the world is,
## because a restore frees everything under main.
func _make_helpers() -> void:
	if is_instance_valid(_marker):
		_marker.queue_free()
	if is_instance_valid(_ghost):
		_ghost.queue_free()
	_marker = MeshInstance3D.new()
	var ring := TorusMesh.new()
	ring.inner_radius = BB.m(5.0)
	ring.outer_radius = BB.m(6.2)
	_marker.mesh = ring
	_marker.material_override = _flat(Gui.ACCENT, 1.0, true)
	_marker.visible = false
	main.add_child(_marker)

	_ghost = MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = BB.m(BB.POLLEN_DIA * 0.5)
	s.height = BB.m(BB.POLLEN_DIA)
	_ghost.mesh = s
	_ghost.material_override = _flat(Gui.ACCENT, 0.35, false)
	_ghost.visible = false
	main.add_child(_ghost)

	# the practice target, drawn exactly as it is drawn while driving
	if is_instance_valid(_area):
		_area.queue_free()
	_area = null
	if int(draft.objective().get("kind", 0)) == Objective.Kind.REACH:
		_area = Attempt.Objective_area(draft.objective().get("area", {}))
		main.add_child(_area)
		Attempt.place_area(_area, draft.objective().get("area", {}))

func _flat(c: Color, alpha: float, on_top := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(c.r, c.g, c.b, alpha)
	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.no_depth_test = on_top
	return m

func _refresh_marker() -> void:
	if not is_instance_valid(_marker):
		return
	var n := _node_for(_selected)
	if n == null:
		_marker.visible = false
		return
	var r := BB.m(6.0)
	if n is GameElement:
		r = BB.m((n as GameElement).radius_in + 1.2)
	elif n is Robot:
		r = BB.m(Robot.HALF + 2.0)
	var ring := _marker.mesh as TorusMesh
	ring.inner_radius = r * 0.88
	ring.outer_radius = r
	_marker.global_position = n.global_position * Vector3(1, 0, 1) + Vector3(0, 0.004, 0)
	_marker.visible = true

# ================================================================== camera ===

func _install_camera() -> void:
	if _cam == null:
		_cam = Camera3D.new()
		_cam.fov = 48.0
		_cam.far = 400.0
		main.add_child(_cam)
	_prev_cam = main.rig.cam if main.rig else null
	_cam.current = true

func _release_camera() -> void:
	if is_instance_valid(_prev_cam):
		_prev_cam.current = true

var _top_down := true

func _set_view(top_down: bool) -> void:
	_top_down = top_down
	_pitch = PI * 0.5 if top_down else deg_to_rad(52.0)
	_yaw = 0.0
	_zoom = 1.0
	_pan = Vector2.ZERO
	_fit_view()

var _zoom := 1.0

## FIT THE FIELD INTO THE GAP, not into the window.
##
## The 3D camera fills the whole viewport, but the panels cover its edges, so
## centring on the field centres it behind the palette. This works out the
## distance that puts all 144 inches inside the visible strip, and slides the
## focus sideways by however much the two panels are out of balance.
func _fit_view() -> void:
	if _cam == null:
		return
	var vp := _root.get_viewport_rect().size
	var gap := _centre.get_global_rect()
	var gap_top := gap.position.y
	var gap_bottom := vp.y - gap.end.y
	var gap_left := gap.position.x
	var gap_right := vp.x - gap.end.x
	var gap_h := maxf(120.0, gap.size.y)
	var gap_w := maxf(120.0, gap.size.x)
	var want_in := 176.0 * _zoom              # the field plus a margin
	# what the whole viewport must span for `want_in` to fit in the gap
	var span := want_in * vp.y / minf(gap_h, gap_w)
	_dist = BB.m(span * 0.5) / tan(deg_to_rad(_cam.fov * 0.5))
	if not _top_down:
		_dist *= 1.15
	# slide so the field sits in the gap rather than behind a panel
	var per_px := BB.m(span) / vp.y
	_focus = Vector3((gap_right - gap_left) * 0.5 * per_px, 0.0,
		(gap_bottom - gap_top) * 0.5 * per_px)
	_place_camera()

func _place_camera() -> void:
	if _cam == null:
		return
	var at := _focus + Vector3(_pan.x, 0.0, _pan.y)
	var y := sin(_pitch) * _dist
	var flat := cos(_pitch) * _dist
	_cam.global_position = at + Vector3(sin(_yaw) * flat, y, cos(_yaw) * flat)
	_cam.look_at(at, Vector3.UP if _pitch < PI * 0.49 else Vector3.FORWARD)

## Where a screen point lands on the tiles.
func _ground_at(screen: Vector2) -> Vector3:
	if _cam == null:
		return Vector3.ZERO
	var from := _cam.project_ray_origin(screen)
	var dir := _cam.project_ray_normal(screen)
	if absf(dir.y) < 0.0001:
		return Vector3.ZERO
	var t := -from.y / dir.y
	return from + dir * t

## What is under a screen point, if anything editable is.
func _pick(screen: Vector2) -> Node3D:
	if _cam == null:
		return null
	var from := _cam.project_ray_origin(screen)
	var to := from + _cam.project_ray_normal(screen) * BB.m(600.0)
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = (1 << (BB.LAYER_WORLD - 1)) | (1 << (BB.LAYER_ELEMENT - 1))
	q.collide_with_areas = false
	var hit := main.get_world_3d().direct_space_state.intersect_ray(q)
	var who: Variant = hit.get("collider", null)
	if who is GameElement or who is Robot:
		return who
	return null

# =================================================================== input ===

func _on_field_input(ev: InputEvent) -> void:
	# gui_input positions are local to the field panel. Camera ray projection
	# expects viewport coordinates. Convert once for every placement/pick/drag.
	if ev is InputEventMouseButton:
		var mb: InputEventMouseButton = ev
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_zoom = maxf(0.25, _zoom * 0.88)
				_fit_view()
			MOUSE_BUTTON_WHEEL_DOWN:
				_zoom = minf(2.4, _zoom / 0.88)
				_fit_view()
			MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE:
				_panning = mb.pressed
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					_press(_centre.get_global_transform_with_canvas() * mb.position)
				else:
					_release()
		_centre.accept_event()
	elif ev is InputEventMouseMotion:
		var mm: InputEventMouseMotion = ev
		if _panning:
			var scale := _dist * 0.0016
			_pan -= Vector2(mm.relative.x, mm.relative.y) * scale
			_pan.x = clampf(_pan.x, -BB.m(110.0), BB.m(110.0))
			_pan.y = clampf(_pan.y, -BB.m(110.0), BB.m(110.0))
			_place_camera()
		elif _dragging:
			_drag_to(_centre.get_global_transform_with_canvas() * mm.position)
		elif _tool != Tool.SELECT:
			_show_ghost(_centre.get_global_transform_with_canvas() * mm.position)
		_centre.accept_event()

func _press(where: Vector2) -> void:
	if _placing != Place.NONE and _selected.begins_with("robot:"):
		var p := _clamp_field(BB.to_field(_ground_at(where)))
		if _snap:
			p.x = snappedf(p.x, SNAP_IN)
			p.y = snappedf(p.y, SNAP_IN)
		_place_opponent(p)
		return
	if _tool != Tool.SELECT:
		_place_at(where)
		return
	var hit := _pick(where)
	_selected = _id_for(hit) if hit != null else ""
	_refresh_marker()
	_refresh_props()
	if hit != null:
		_dragging = true
		_drag_offset = hit.global_position - _ground_at(where)
		_drag_offset.y = 0.0

func _release() -> void:
	if not _dragging:
		return
	_dragging = false
	var n := _node_for(_selected)
	if n == null:
		return
	# ONE undo entry per drag, written when the mouse comes up.
	var p := BB.to_field(n.global_position)
	draft.set_position(_selected, p, _stop_on_move)
	_refresh_all()

func _drag_to(where: Vector2) -> void:
	var n := _node_for(_selected)
	if n == null:
		return
	var g := _ground_at(where) + _drag_offset
	var p := BB.to_field(g)
	p = _clamp_field(p)
	# KEEP IT ON THE SURFACE. Dragging works on the floor plane, so the height
	# comes from what the object is, not from where the mouse ray happened to
	# cross — which is how things end up buried in the tiles.
	if n is GameElement:
		p.z = ScenarioDraft.rest_height((n as GameElement).kind)
	else:
		p.z = 0.0
	if _snap:
		p.x = snappedf(p.x, SNAP_IN)
		p.y = snappedf(p.y, SNAP_IN)
	n.global_position = BB.fp(p.x, p.y, p.z)
	_refresh_marker()

func _clamp_field(p: Vector3) -> Vector3:
	var lim := BB.FIELD_HALF - 2.0
	return Vector3(clampf(p.x, -lim, lim), clampf(p.y, -lim, lim), p.z)

func _show_ghost(where: Vector2) -> void:
	if not is_instance_valid(_ghost):
		return
	var p := _clamp_field(BB.to_field(_ground_at(where)))
	if _snap:
		p.x = snappedf(p.x, SNAP_IN)
		p.y = snappedf(p.y, SNAP_IN)
	p.z = _tool_height()
	_ghost.global_position = BB.fp(p.x, p.y, p.z)
	_ghost.visible = true

func _tool_height() -> float:
	match _tool:
		Tool.NECTAR_RED, Tool.NECTAR_BLUE:
			return ScenarioDraft.rest_height(BB.Kind.NECTAR)
		Tool.POLLEN:
			return ScenarioDraft.rest_height(BB.Kind.POLLEN)
		Tool.AREA:
			return 0.5
	return BB.ROBOT_CUBE * 0.5

func _place_at(where: Vector2) -> void:
	var p := _clamp_field(BB.to_field(_ground_at(where)))
	if _snap:
		p.x = snappedf(p.x, SNAP_IN)
		p.y = snappedf(p.y, SNAP_IN)
	match _tool:
		Tool.POLLEN:
			p.z = ScenarioDraft.rest_height(BB.Kind.POLLEN)
			_selected = draft.add_element(BB.Kind.POLLEN, -1, p)
		Tool.NECTAR_RED:
			p.z = ScenarioDraft.rest_height(BB.Kind.NECTAR)
			_selected = draft.add_element(BB.Kind.NECTAR, BB.Alliance.RED, p)
		Tool.NECTAR_BLUE:
			p.z = ScenarioDraft.rest_height(BB.Kind.NECTAR)
			_selected = draft.add_element(BB.Kind.NECTAR, BB.Alliance.BLUE, p)
		Tool.AREA:
			if int(draft.objective().get("kind", 0)) != Objective.Kind.REACH:
				_flash("Set the objective to Reach an area first.")
				return
			draft.set_area("x", p.x)
			draft.set_area("y", p.y)
			_selected = ""
		Tool.ROBOT_OURS, Tool.ROBOT_FOE:
			var ours := _tool == Tool.ROBOT_OURS
			var a := int(draft.setup().get("alliance", BB.Alliance.RED))
			var side := a if ours else (BB.Alliance.BLUE if a == BB.Alliance.RED
				else BB.Alliance.RED)
			var id := draft.add_robot(side, not ours)
			if id == "":
				_flash("The roster is already as big as the game supports.")
				return
			draft.set_position(id, Vector3(p.x, p.y, 0.0))
			_selected = id
	SFX.play("click", -20.0)
	await _sync_world()
	_refresh_all()

func _unhandled_input(ev: InputEvent) -> void:
	if not _root.visible:
		return
	if not (ev is InputEventKey) or not ev.pressed or ev.echo:
		return
	var k: InputEventKey = ev
	var handled := true
	if k.ctrl_pressed and k.keycode == KEY_Z:
		_undo()
	elif k.ctrl_pressed and (k.keycode == KEY_Y \
			or (k.keycode == KEY_Z and k.shift_pressed)):
		_redo()
	elif k.keycode == KEY_DELETE or k.keycode == KEY_BACKSPACE:
		_delete_selected()
	elif k.keycode == KEY_Q:
		_nudge_yaw(-15.0)
	elif k.keycode == KEY_E:
		_nudge_yaw(15.0)
	elif k.keycode == KEY_G:
		_snap = not _snap
		Gui.select(_snap_btn, _snap)
	elif k.keycode == KEY_ESCAPE and _placing != Place.NONE:
		_placing = Place.NONE
		_flash("")
		_refresh_props()
	elif k.keycode == KEY_ESCAPE:
		_try_close()
	else:
		handled = false
	if handled:
		get_viewport().set_input_as_handled()

func _nudge_yaw(by: float) -> void:
	if _selected == "" or draft.kind_of(_selected) == "hive":
		return
	draft.set_yaw(_selected, draft.yaw_of(_selected) + by)
	await _sync_world()
	_refresh_all()

func _delete_selected() -> void:
	if _selected == "":
		return
	var err := draft.remove_object(_selected)
	if err != "":
		_flash(err)
		return
	_selected = ""
	SFX.play("click", -18.0)
	await _sync_world()
	_refresh_all()

func _pick_tool(t: int) -> void:
	_tool = t
	for key in _tool_buttons:
		Gui.select(_tool_buttons[key], key == t)
	if is_instance_valid(_ghost):
		_ghost.visible = false
	if t != Tool.SELECT:
		var s := _ghost.mesh as SphereMesh
		var rad := _tool_height()
		s.radius = BB.m(rad)
		s.height = BB.m(rad * 2.0)

# =============================================================== properties ==

func _refresh_all() -> void:
	_refresh_props()
	_refresh_status()
	_refresh_marker()
	_undo_btn.disabled = not draft.can_undo()
	_redo_btn.disabled = not draft.can_redo()

func _undo() -> void:
	if draft.undo():
		_selected = ""
		SFX.play("click", -20.0)
		await _sync_world()
		_refresh_all()

func _redo() -> void:
	if draft.redo():
		_selected = ""
		SFX.play("click", -20.0)
		await _sync_world()
		_refresh_all()

func _refresh_props() -> void:
	for c in _props.get_children():
		c.queue_free()
	if _selected == "":
		_scenario_props()
		return
	match draft.kind_of(_selected):
		"robot": _robot_props()
		"element": _element_props()
		"hive": _hive_props()

func _head(t: String) -> void:
	_props.add_child(Gui.eyebrow(t))

## A labelled control in the properties column.
##
## The column is narrow, so anything wider than a number field goes UNDER its
## label instead of beside it. A segmented row of three buttons next to a
## label is wider than the panel, and a control that overflows the panel is a
## control you cannot click.
func _row(label: String, c: Control) -> void:
	if c.get_combined_minimum_size().x > 150.0:
		_props.add_child(Gui.label(label, Gui.T_SMALL, Gui.MUTED))
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_props.add_child(c)
		return
	_props.add_child(Gui.row(label, c))

## A number you can type. Applies on enter or when focus leaves, never on every
## keystroke, so typing "-12" does not first place something at minus one.
func _num(value: float, on_set: Callable, suffix := "") -> LineEdit:
	var e := Gui.line_edit(suffix, "%.1f" % value)
	e.custom_minimum_size = Vector2(92, 42)
	var commit := func() -> void:
		var t := e.text.strip_edges().to_float()
		on_set.call(t)
	e.text_submitted.connect(func(_t: String) -> void: commit.call())
	e.focus_exited.connect(func() -> void: commit.call())
	return e

func _options(values: Array, chosen: int, on_pick: Callable) -> HBoxContainer:
	return Gui.options(values, chosen, on_pick)

# ---- scenario-wide

func _scenario_props() -> void:
	_head("Scenario")
	_props.add_child(Gui.para(
		"Nothing selected. Click an object on the field to edit it."))
	_props.add_child(Gui.divider())

	var note := Gui.line_edit("what to practise here (optional)", draft.note)
	note.text_changed.connect(func(t: String) -> void:
		draft.note = t
		draft.dirty = true)
	_props.add_child(Gui.label("Description", Gui.T_SMALL, Gui.MUTED))
	_props.add_child(note)

	# The objective comes first: it is what the scenario is FOR.
	_props.add_child(Gui.divider())
	_objective_props()

	_props.add_child(Gui.divider())
	_head("Starting phase")
	var phases := ["Pre-match", "Autonomous", "Teleop"]
	var phase_vals := [BB.Phase.PRE, BB.Phase.AUTO, BB.Phase.TELEOP]
	var now := int(draft.match_block().get("phase", BB.Phase.PRE))
	_props.add_child(_options(phases, maxi(0, phase_vals.find(now)),
		func(i: int) -> void:
			draft.set_scenario("phase", phase_vals[i])
			if phase_vals[i] == BB.Phase.PRE:
				draft.set_scenario("time_left", 0.0)
			_refresh_all()))

	if now != BB.Phase.PRE:
		_row("Time left (s)", _num(float(draft.match_block().get("time_left", 0.0)),
			func(v: float) -> void:
				draft.set_scenario("time_left", maxf(0.0, v))
				_refresh_status()))

	_props.add_child(Gui.divider())
	_head("Mode")
	var modes := ["Full match", "Teleop", "Free practice"]
	_props.add_child(_options(modes, int(draft.setup().get("mode", 0)),
		func(i: int) -> void:
			draft.set_scenario("mode", i)
			_refresh_status()))

	_props.add_child(Gui.divider())
	_head("Roster")
	var ours := 0
	var foes := 0
	for r in draft.robots():
		if int(r.get("alliance", 0)) == int(draft.setup().get("alliance", 0)):
			ours += 1
		else:
			foes += 1
	_props.add_child(Gui.label("%d on your alliance, %d opponent%s" % [
		ours, foes, "" if foes == 1 else "s"], Gui.T_BODY, Gui.INK))
	_props.add_child(Gui.para(
		"Add or remove robots with the palette on the left. Opponent robots "
		+ "use the game's existing AI driver; there is no other behaviour to "
		+ "choose from yet."))

	_props.add_child(Gui.divider())
	_head("Human players")
	var q: Dictionary = draft.match_block().get("human_queue", {})
	var pending := 0
	for a in q.keys():
		pending += (q[a] as Array).size()
	_props.add_child(Gui.label("%d ball%s still to be fed in" % [
		pending, "" if pending == 1 else "s"], Gui.T_BODY, Gui.INK))
	_props.add_child(Gui.para(
		"Pending feeds are kept exactly as the situation had them, with the "
		+ "delay each one had left."))

	_props.add_child(Gui.divider())
	_head("Score")
	var sc: Dictionary = draft.match_block().get("scoring", {})
	var tips: Array = sc.get("tips", [0, 0])
	_props.add_child(Gui.label("%d red tip%s, %d blue" % [
		int(tips[0]), "" if int(tips[0]) == 1 else "s", int(tips[1])],
		Gui.T_BODY, Gui.INK))
	_props.add_child(Gui.para(
		"These are HISTORICAL events — tips and fouls that already happened. "
		+ "Everything else on the scoreboard is worked out from what is on the "
		+ "field, so there is no separate number here to contradict it."))

## THE OBJECTIVE. One goal, at most two constraints, and only the targets each
## goal can honestly be measured against.
func _objective_props() -> void:
	var o := draft.objective()
	var kind := int(o.get("kind", Objective.Kind.NONE))
	_head("Objective")
	for p in _problems:
		if String(p.get("where", "")) != "objective":
			continue
		var l := Gui.para(String(p.get("msg", "")))
		l.add_theme_color_override("font_color",
			Gui.RED_INK if String(p.get("severity", "")) == "error" else Gui.WARN)
		_props.add_child(l)

	var kinds: Array = []
	for k in 5:
		kinds.append(Objective.kind_name(k))
	var kd := Gui.dropdown(kinds, kind, func(i: int) -> void:
		draft.set_objective("kind", i)
		_resync(), 180)
	kd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_props.add_child(kd)

	if kind == Objective.Kind.NONE:
		_props.add_child(Gui.para(
			"Free practice: the situation loads and you drive it, and the game "
			+ "does not decide whether you succeeded. Pick a goal above to "
			+ "make attempts measurable."))
		return

	var line := Gui.para(Objective.describe(o, _target_label(o)))
	line.add_theme_color_override("font_color", Gui.INK)
	_props.add_child(line)

	# ---- who it is measured for
	var allowed := Objective.targets_for(kind)
	if allowed.size() > 1:
		var names: Array = []
		for t in allowed:
			names.append("My alliance" if t == Objective.Target.ALLIANCE
				else "One robot")
		var at := maxi(0, allowed.find(int(o.get("target", 0))))
		_row("Measured for", _options(names, at, func(i: int) -> void:
			draft.set_objective("target", allowed[i])
			_refresh_props()
			_refresh_status()))
	if int(o.get("target", 0)) == Objective.Target.ROBOT:
		var labels: Array = []
		var idxs: Array = []
		for r in draft.robots():
			if bool(r.get("ai", false)):
				continue
			if int(r.get("alliance", 0)) != int(draft.setup().get("alliance", 0)):
				continue
			labels.append("Robot %d" % (int(r.get("index", 0)) + 1))
			idxs.append(int(r.get("index", 0)))
		if not labels.is_empty():
			var cur := maxi(0, idxs.find(int(o.get("robot", 0))))
			_row("Which robot", _options(labels, cur, func(i: int) -> void:
				draft.set_objective("robot", idxs[i])
				_refresh_props()
				_refresh_status()))

	# ---- how much
	if kind != Objective.Kind.REACH:
		var what := {Objective.Kind.POINTS: "Points", Objective.Kind.TIPS: "Tips",
			Objective.Kind.SHOTS: "Shots"}
		_row(String(what.get(kind, "Amount")), _num(float(o.get("amount", 1)),
			func(v: float) -> void:
				draft.set_objective("amount", maxi(1, int(round(v))))
				_refresh_props()
				_refresh_status()))
	else:
		var a: Dictionary = o.get("area", {})
		_row("Area X (in)", _num(float(a.get("x", 0.0)), func(v: float) -> void:
			draft.set_area("x", v)
			_resync()))
		_row("Area Y (in)", _num(float(a.get("y", 0.0)), func(v: float) -> void:
			draft.set_area("y", v)
			_resync()))
		_row("Radius (in)", _num(float(a.get("r", 18.0)), func(v: float) -> void:
			draft.set_area("r", clampf(v, 4.0, 72.0))
			_resync()))
		_props.add_child(Gui.para(
			"Place the circle with the Target area tool on the left, or type "
			+ "the numbers here."))

	# ---- constraints
	_props.add_child(Gui.divider())
	_head("Constraints")
	_row("Time limit (s)", _num(float(o.get("time_limit", 0.0)),
		func(v: float) -> void:
			draft.set_objective("time_limit", maxf(0.0, v))
			_refresh_props()
			_refresh_status()))
	_props.add_child(Gui.label("0 means no time limit", Gui.T_SMALL, Gui.MUTED))
	_row("Without a foul", _options(["Allowed", "No new fouls"],
		1 if bool(o.get("no_foul", false)) else 0, func(i: int) -> void:
			draft.set_objective("no_foul", i == 1)
			_refresh_props()
			_refresh_status()))

	_props.add_child(Gui.para(Objective.metric_note(kind)))
	_props.add_child(Gui.para(
		"Progress is measured from a baseline taken when the attempt starts, "
		+ "so points, tips and balls already on the field at the beginning do "
		+ "not count towards it."))

func _target_label(o: Dictionary) -> String:
	if int(o.get("target", 0)) != Objective.Target.ROBOT:
		return ""
	return "robot %d" % (int(o.get("robot", 0)) + 1)

# ---- robots

func _robot_props() -> void:
	var r := draft.find(_selected)
	if r.is_empty():
		return
	var idx := int(r.get("index", 0))
	_head("Robot %d" % (idx + 1))
	_problem_notes(_selected)

	var a := int(r.get("alliance", BB.Alliance.RED))
	_row("Alliance", _options(["Red", "Blue"], a, func(i: int) -> void:
		draft.set_prop(_selected, "alliance", i)
		_resync()))
	_row("Driven by", _options(["Me", "AI"], 1 if bool(r.get("ai", false)) else 0,
		func(i: int) -> void:
			draft.set_prop(_selected, "ai", i == 1)
			_resync()))
	if bool(r.get("ai", false)):
		_opponent_props(r)

	_props.add_child(Gui.divider())
	_head("Where")
	var p := draft.position_of(_selected)
	_row("X (in)", _num(p.x, func(v: float) -> void:
		var q := draft.position_of(_selected)
		draft.set_position(_selected, Vector3(v, q.y, q.z), _stop_on_move)
		_resync()))
	_row("Y (in)", _num(p.y, func(v: float) -> void:
		var q := draft.position_of(_selected)
		draft.set_position(_selected, Vector3(q.x, v, q.z), _stop_on_move)
		_resync()))
	_row("Heading (°)", _num(draft.yaw_of(_selected), func(v: float) -> void:
		draft.set_yaw(_selected, v)
		_resync()))

	_props.add_child(Gui.divider())
	_head("Mechanisms")
	_row("Intakes", _options(["Front", "Both ends"],
		int(r.get("intakes", 1)) - 1, func(i: int) -> void:
			draft.set_prop(_selected, "intakes", i + 1)
			_resync()))
	_row("Collects", _options(["Pollen", "Pollen + nectar"],
		1 if bool(r.get("takes_nectar", false)) else 0, func(i: int) -> void:
			draft.set_prop(_selected, "takes_nectar", i == 1)
			_refresh_all()))
	_row("Launcher (in/s)", _num(float(r.get("launch_speed",
		BB.LAUNCH_SPEED_DEFAULT)), func(v: float) -> void:
			draft.set_prop(_selected, "launch_speed", clampf(v, 80.0, 400.0))
			_refresh_all()))
	_row("Hood (°)", _num(float(r.get("hood_deg", 55.0)), func(v: float) -> void:
		draft.set_prop(_selected, "hood_deg", clampf(v, 5.0, 84.0))
		_refresh_all()))

	_props.add_child(Gui.divider())
	_head("Battery")
	var bv := float(r.get("battery_v", BB.BATTERY_NOMINAL))
	var sl := Gui.slider(11.0, 13.5, bv, 0.05)
	var box := Gui.slider_row("Charge", sl,
		func(v: float) -> String: return "%.2f V" % v)
	sl.drag_ended.connect(func(_c: bool) -> void:
		draft.set_prop(_selected, "battery_v", sl.value)
		draft.set_prop(_selected, "open_circuit", sl.value)
		_refresh_status())
	_props.add_child(box)
	_props.add_child(Gui.para(
		"A tired battery is slower off the line and takes longer to spin the "
		+ "launcher back up — which is what a late-match robot feels like."))

	_props.add_child(Gui.divider())
	_head("Hopper")
	var hop: Array = r.get("hopper", [])
	for slot in BB.HOPPER_MAX:
		var row := Gui.hbox(Gui.S8)
		row.add_child(Gui.label("Slot %d" % (slot + 1), Gui.T_SMALL, Gui.MUTED))
		row.add_child(Gui.spacer())
		if slot < hop.size():
			var eid := String(hop[slot])
			var e := draft.find(eid)
			var kind := int(e.get("kind", 0))
			row.add_child(Gui.label(
				"Pollen" if kind == BB.Kind.POLLEN else "Nectar",
				Gui.T_SMALL, Gui.INK))
			var out := Gui.button("Eject", Gui.Look.SECONDARY, Vector2(0, 38))
			out.add_theme_font_size_override("font_size", Gui.T_SMALL)
			out.pressed.connect(func() -> void:
				draft.take_from_hopper(eid)
				var pos := draft.position_of(_selected)
				draft.set_position(eid, Vector3(pos.x, pos.y - 14.0,
					ScenarioDraft.rest_height(kind)))
				_resync())
			row.add_child(out)
		else:
			var addp := Gui.button("+ Pollen", Gui.Look.SECONDARY, Vector2(0, 38))
			addp.add_theme_font_size_override("font_size", Gui.T_SMALL)
			addp.pressed.connect(func() -> void:
				var err := draft.fill_hopper_slot(idx, BB.Kind.POLLEN, -1)
				if err != "":
					_flash(err)
				_resync())
			row.add_child(addp)
			var addn := Gui.button("+ Nectar", Gui.Look.SECONDARY, Vector2(0, 38))
			addn.add_theme_font_size_override("font_size", Gui.T_SMALL)
			addn.pressed.connect(func() -> void:
				var err := draft.fill_hopper_slot(idx, BB.Kind.NECTAR, a)
				if err != "":
					_flash(err)
				_resync())
			row.add_child(addn)
		_props.add_child(row)

	if not bool(r.get("ai", false)):
		_props.add_child(Gui.divider())
		_head("Autonomous")
		var routines := AutoRoutine.list_saved()
		var names: Array = ["None"] + routines
		var cur := String(draft.setup().get("auto_routine", ""))
		var at := maxi(0, names.find(cur)) if cur != "" else 0
		var ad := Gui.dropdown(names, at, func(i: int) -> void:
			draft.set_scenario("auto_routine", "" if i == 0 else String(names[i])),
			180)
		ad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_props.add_child(ad)
		_props.add_child(Gui.para(
			"Only used when the situation starts in autonomous."))

	_props.add_child(Gui.divider())
	var del := Gui.button("Remove this robot", Gui.Look.SECONDARY, Vector2(0, 46))
	del.pressed.connect(_delete_selected)
	_props.add_child(del)

# ================================================================ OPPONENT ===
#
# Everything an AI robot is told to do, edited where every other property of
# that robot is edited. Only the settings the chosen behavior actually USES
# are shown: a setting that changes nothing is not offered.

## While not SELECT, clicks on the field edit the SELECTED robot's route or
## area instead of placing new objects.
enum Place { NONE, WAYPOINT, DEFENSE_AREA, COLLECT_AREA }
var _placing: int = Place.NONE
## Untyped on purpose: iterating a typed array casts each entry, and casting
## an overlay that has already been freed is an error rather than a null.
var _opp_overlays: Array = []

func _opponent_props(r: Dictionary) -> void:
	var cfg := draft.opponent(_selected)
	var b := int(cfg.get("behavior", OpponentConfig.Behavior.COLLECT))
	var idx := int(r.get("index", 0))
	var problems := OpponentConfig.check(cfg, idx, draft.robots())

	_props.add_child(Gui.divider())
	_head("Opponent behavior")
	var beh := Gui.dropdown(OpponentConfig.NAMES, b, func(i: int) -> void:
		_placing = Place.NONE
		draft.set_opponent(_selected, "behavior", i)
		_after_opponent_edit(), 220)
	beh.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_props.add_child(beh)
	_props.add_child(Gui.para(String(OpponentConfig.HELP[b])))

	# ---- preset: a NAME for a set of the values shown below, nothing more
	var pname := OpponentConfig.preset_name(cfg)
	var pi := OpponentConfig.PRESET_ORDER.find(pname)
	_row("Preset", _options(["Gentle", "Standard", "Challenging"], pi,
		func(i: int) -> void:
			draft.set_opponent(_selected, "preset", OpponentConfig.PRESET_ORDER[i])
			_after_opponent_edit()))
	if pname == "Custom":
		var cu := Gui.para("Custom — the values below no longer match a preset.")
		cu.add_theme_color_override("font_color", Gui.ACCENT)
		_props.add_child(cu)
	_props.add_child(Gui.para(
		"A preset is only a name for the values below. None of them changes "
		+ "the robot's grip, power, top speed, battery or accuracy."))

	for key in OpponentConfig.KEYS.get(b, []):
		_opponent_setting(cfg, String(key))
		_setting_problems(problems, String(key))

	match b:
		OpponentConfig.Behavior.STATIONARY:
			_props.add_child(Gui.para(
				"The heading it holds is this robot's own heading — set it in "
				+ "Where above, or with Q and E."))
		OpponentConfig.Behavior.ROUTE:
			_route_editor(cfg, problems)
		OpponentConfig.Behavior.DEFEND:
			_defend_editor(cfg, idx, problems)
		OpponentConfig.Behavior.COLLECT:
			_collect_editor(cfg)

	_props.add_child(Gui.divider())
	var test := Gui.primary("Test scenario", Vector2(0, 46))
	test.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	test.pressed.connect(func() -> void:
		_placing = Place.NONE
		_test())
	_props.add_child(test)
	_props.add_child(Gui.para(
		"Runs a copy with this opponent. Retry restores it exactly as placed; "
		+ "Return to editor brings you back with nothing changed."))

## One setting: a slider (or a two/three-way choice) with its explanation.
func _opponent_setting(cfg: Dictionary, key: String) -> void:
	var spec: Array = OpponentConfig.FIELDS[key]
	var label := String(spec[3])
	var unit := String(spec[5])
	if key == "route_mode":
		_row(label, _options(OpponentConfig.ROUTE_MODES,
			int(OpponentConfig.get_f(cfg, key)), func(i: int) -> void:
				draft.set_opponent(_selected, key, float(i))
				_after_opponent_edit()))
	elif key == "hold_heading":
		_row(label, _options(["Off", "On"],
			int(OpponentConfig.get_f(cfg, key)), func(i: int) -> void:
				draft.set_opponent(_selected, key, float(i))
				_after_opponent_edit()))
	else:
		var step := 0.01 if unit == "%" or unit == "s" else 1.0
		var sl := Gui.slider(float(spec[1]), float(spec[2]),
			OpponentConfig.get_f(cfg, key), step)
		var box := Gui.slider_row(label, sl, func(v: float) -> String:
			if unit == "%":
				return "%.0f%%" % (v * 100.0)
			if unit == "s":
				return "%.2f s" % v
			if key == "collect_r" and v <= 0.0:
				return "whole field"
			return "%.0f %s" % [v, unit])
		# commit once, when the drag ends, so undo is one step per change
		sl.drag_ended.connect(func(_c: bool) -> void:
			draft.set_opponent(_selected, key, sl.value)
			_after_opponent_edit())
		_props.add_child(box)
	_props.add_child(Gui.para(String(spec[4])))

## Validation messages, placed beside the setting they are about.
func _setting_problems(problems: Array, key: String) -> void:
	for p in problems:
		if String(p.get("setting", "")) != key:
			continue
		var l := Gui.para(("⚠ " if String(p["severity"]) == "warning" else "✗ ")
			+ String(p["msg"]))
		l.add_theme_color_override("font_color",
			Gui.WARN if String(p["severity"]) == "warning" else Gui.RED_INK)
		_props.add_child(l)

# ---- route

func _route_editor(cfg: Dictionary, problems: Array) -> void:
	_props.add_child(Gui.divider())
	_head("Route")
	var wps: Array = cfg.get("waypoints", [])
	var add := Gui.button(
		"Done adding" if _placing == Place.WAYPOINT else "Add waypoints on the field",
		Gui.Look.PRIMARY if _placing == Place.WAYPOINT else Gui.Look.SECONDARY,
		Vector2(0, 42))
	add.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add.pressed.connect(func() -> void:
		_placing = Place.NONE if _placing == Place.WAYPOINT else Place.WAYPOINT
		_flash("Click the field to add waypoints in order. Esc or Done to stop."
			if _placing == Place.WAYPOINT else "")
		_refresh_props())
	_props.add_child(add)
	if wps.is_empty():
		_props.add_child(Gui.para("No waypoints yet."))
	for i in wps.size():
		_waypoint_row(i, wps)
	_setting_problems(problems, "waypoints")

func _waypoint_row(i: int, wps: Array) -> void:
	var w: Dictionary = wps[i]
	var head := Gui.hbox(Gui.S8)
	head.add_child(Gui.label("Waypoint %d" % (i + 1), Gui.T_SMALL, Gui.INK))
	head.add_child(Gui.spacer())
	for spec in [["↑", -1], ["↓", 1]]:
		var mv := Gui.button(String(spec[0]), Gui.Look.SECONDARY, Vector2(38, 34))
		mv.disabled = (i == 0 and int(spec[1]) < 0) or (i == wps.size() - 1 and int(spec[1]) > 0)
		mv.pressed.connect(func() -> void:
			var list: Array = (draft.opponent(_selected)["waypoints"] as Array).duplicate(true)
			var j := i + int(spec[1])
			var tmp: Variant = list[i]
			list[i] = list[j]
			list[j] = tmp
			draft.set_opponent(_selected, "waypoints", list)
			_after_opponent_edit())
		head.add_child(mv)
	var rm := Gui.button("✕", Gui.Look.SECONDARY, Vector2(38, 34))
	rm.pressed.connect(func() -> void:
		var list: Array = (draft.opponent(_selected)["waypoints"] as Array).duplicate(true)
		list.remove_at(i)
		draft.set_opponent(_selected, "waypoints", list)
		_after_opponent_edit())
	head.add_child(rm)
	_props.add_child(head)
	for f in [["X (in)", "x"], ["Y (in)", "y"], ["Wait (s)", "wait"]]:
		var key := String(f[1])
		_row(String(f[0]), _num(float(w.get(key, 0.0)), func(v: float) -> void:
			var list: Array = (draft.opponent(_selected)["waypoints"] as Array).duplicate(true)
			var lim := 30.0 if key == "wait" else BB.FIELD_HALF
			(list[i] as Dictionary)[key] = clampf(v, 0.0 if key == "wait" else -lim, lim)
			draft.set_opponent(_selected, "waypoints", list)
			_after_opponent_edit()))

# ---- defend

func _defend_editor(cfg: Dictionary, idx: int, problems: Array) -> void:
	_props.add_child(Gui.divider())
	_head("Defends against")
	var me_alliance := -1
	for rr in draft.robots():
		if int(rr.get("index", -1)) == idx:
			me_alliance = int(rr.get("alliance", -1))
	var names: Array = []
	var ids: Array = []
	for rr2 in draft.robots():
		if int(rr2.get("alliance", -1)) != me_alliance:
			names.append("Robot %d%s" % [int(rr2["index"]) + 1,
				" (AI)" if bool(rr2.get("ai", false)) else ""])
			ids.append(int(rr2["index"]))
	if ids.is_empty():
		_props.add_child(Gui.para("There is no robot on the other alliance to defend against."))
	else:
		var cur: int = maxi(0, ids.find(int(cfg.get("target", -1))))
		var dd := Gui.dropdown(names, cur, func(i: int) -> void:
			draft.set_opponent(_selected, "target", int(ids[i]))
			_after_opponent_edit(), 220)
		dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_props.add_child(dd)
	_setting_problems(problems, "target")
	_area_editor(cfg, Place.DEFENSE_AREA, "Defense area")
	_props.add_child(Gui.para(OpponentConfig.AREA_NOTE))
	var rules := Gui.para(OpponentConfig.DEFEND_RULES_NOTE)
	rules.add_theme_color_override("font_color", Gui.WARN)
	_props.add_child(rules)

func _collect_editor(cfg: Dictionary) -> void:
	_props.add_child(Gui.para(
		"Scores by shooting POLLEN at its own alliance's CELL — the only CELL "
		+ "it can score in, so there is no scoring target to choose. It never "
		+ "goes for NECTAR."))
	if OpponentConfig.get_f(cfg, "collect_r") > 0.0:
		_area_editor(cfg, Place.COLLECT_AREA, "Collection area")

func _area_editor(cfg: Dictionary, mode: int, title: String) -> void:
	_props.add_child(Gui.divider())
	_head(title)
	var a: Dictionary = cfg.get("area", {})
	var place := Gui.button(
		"Click the field…" if _placing == mode else "Place on the field",
		Gui.Look.PRIMARY if _placing == mode else Gui.Look.SECONDARY, Vector2(0, 42))
	place.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	place.pressed.connect(func() -> void:
		_placing = Place.NONE if _placing == mode else mode
		_refresh_props())
	_props.add_child(place)
	for f in [["Centre X (in)", "x"], ["Centre Y (in)", "y"]]:
		var key := String(f[1])
		_row(String(f[0]), _num(float(a.get(key, 0.0)), func(v: float) -> void:
			var ar: Dictionary = (draft.opponent(_selected).get("area", {}) as Dictionary).duplicate()
			ar[key] = clampf(v, -BB.FIELD_HALF, BB.FIELD_HALF)
			draft.set_opponent(_selected, "area", ar)
			_after_opponent_edit()))

## A click on the field while a route or area is being placed.
func _place_opponent(p: Vector3) -> void:
	var cfg := draft.opponent(_selected)
	match _placing:
		Place.WAYPOINT:
			var list: Array = (cfg.get("waypoints", []) as Array).duplicate(true)
			if list.size() >= OpponentConfig.MAX_WAYPOINTS:
				_flash("A route can have at most %d waypoints." % OpponentConfig.MAX_WAYPOINTS)
				return
			list.append({"x": p.x, "y": p.y, "wait": 0.0})
			draft.set_opponent(_selected, "waypoints", list)
			_flash("Waypoint %d placed. Keep clicking, or Done." % list.size())
		Place.DEFENSE_AREA, Place.COLLECT_AREA:
			draft.set_opponent(_selected, "area", {"x": p.x, "y": p.y})
			_placing = Place.NONE
	SFX.play("click", -20.0)
	_after_opponent_edit()

func _after_opponent_edit() -> void:
	_draw_opponent_overlays()
	_refresh_all()

## Every AI robot's route or area, drawn while editing — not only the
## selected one, because traffic is about how they cross.
func _draw_opponent_overlays() -> void:
	for o in _opp_overlays:
		if is_instance_valid(o):
			o.queue_free()
	_opp_overlays.clear()
	if draft == null:
		return
	for r in draft.robots():
		if not bool(r.get("ai", false)):
			continue
		var id := "robot:%d" % int(r.get("index", 0))
		var ov := OpponentOverlay.for_config(draft.opponent(id),
			int(r.get("alliance", 0)),
			Snapshot.unpack_v3(r.get("origin", [])))
		main.add_child(ov)
		_opp_overlays.append(ov)

# ---- elements

func _element_props() -> void:
	var e := draft.find(_selected)
	if e.is_empty():
		return
	var kind := int(e.get("kind", 0))
	_head("Pollen" if kind == BB.Kind.POLLEN else "Nectar")
	_problem_notes(_selected)

	_row("Type", _options(["Pollen", "Nectar"], kind, func(i: int) -> void:
		draft.set_prop(_selected, "kind", i)
		if i == BB.Kind.POLLEN:
			draft.set_prop(_selected, "alliance", -1)
		_resync()))
	if int(draft.find(_selected).get("kind", 0)) == BB.Kind.NECTAR:
		var al := int(e.get("alliance", BB.Alliance.RED))
		_row("Belongs to", _options(["Red", "Blue"], maxi(0, al),
			func(i: int) -> void:
				draft.set_prop(_selected, "alliance", i)
				_resync()))

	_props.add_child(Gui.divider())
	_head("Where")
	var p := draft.position_of(_selected)
	_row("X (in)", _num(p.x, func(v: float) -> void:
		var q := draft.position_of(_selected)
		draft.set_position(_selected, Vector3(v, q.y, q.z), _stop_on_move)
		_resync()))
	_row("Y (in)", _num(p.y, func(v: float) -> void:
		var q := draft.position_of(_selected)
		draft.set_position(_selected, Vector3(q.x, v, q.z), _stop_on_move)
		_resync()))

	var holder := String(e.get("held", ""))
	if holder.begins_with("robot:"):
		_props.add_child(Gui.para(
			"This ball is in %s's hopper. Eject it there to put it back on "
			% holder.replace("robot:", "robot ") + "the field."))
		return

	_props.add_child(Gui.divider())
	var adv: Array = Gui.disclosure("Advanced: height and motion")
	_props.add_child(adv[0])
	var advbox: VBoxContainer = adv[1]
	_props.add_child(advbox)
	advbox.add_child(Gui.row("Height (in)", _num(p.z, func(v: float) -> void:
		var q := draft.position_of(_selected)
		draft.set_position(_selected, Vector3(q.x, q.y, maxf(0.0, v)),
			_stop_on_move)
		_resync())))
	var vel := Snapshot.unpack_v3(e.get("lin", []))
	var fv := BB.to_field(vel)
	advbox.add_child(Gui.row("Speed X (in/s)", _num(fv.x, func(v: float) -> void:
		var cur := BB.to_field(Snapshot.unpack_v3(draft.find(_selected).get("lin", [])))
		draft.set_velocity(_selected, BB.fp(v, cur.y, cur.z))
		_refresh_status())))
	advbox.add_child(Gui.row("Speed Y (in/s)", _num(fv.y, func(v: float) -> void:
		var cur := BB.to_field(Snapshot.unpack_v3(draft.find(_selected).get("lin", [])))
		draft.set_velocity(_selected, BB.fp(cur.x, v, cur.z))
		_refresh_status())))
	advbox.add_child(Gui.row("Speed up (in/s)", _num(fv.z, func(v: float) -> void:
		var cur := BB.to_field(Snapshot.unpack_v3(draft.find(_selected).get("lin", [])))
		draft.set_velocity(_selected, BB.fp(cur.x, cur.y, v))
		_refresh_status())))
	advbox.add_child(Gui.para(
		"New balls are placed at rest. A ball with speed starts the situation "
		+ "already moving, which is how a mid-flight moment comes back."))

	_props.add_child(Gui.divider())
	var row := Gui.hbox(Gui.S8)
	var dup := Gui.button("Duplicate", Gui.Look.SECONDARY, Vector2(0, 46))
	dup.pressed.connect(func() -> void:
		_selected = draft.duplicate_object(_selected)
		_resync())
	row.add_child(dup)
	var del := Gui.button("Delete", Gui.Look.SECONDARY, Vector2(0, 46))
	del.pressed.connect(_delete_selected)
	row.add_child(del)
	_props.add_child(row)

# ---- hives

func _hive_props() -> void:
	var h := draft.find(_selected)
	_head("HIVE")
	_props.add_child(Gui.para(
		"The HIVEs, FLOWERS and walls are field structures: they stay where "
		+ "the manual puts them, so a situation is always a legal field. What "
		+ "you can set is the state they start in."))
	_props.add_child(Gui.divider())
	_head("Raised cell")
	var sign_ := int(h.get("stable_sign", 1))
	_row("Tilted", _options(["One way", "The other"], 0 if sign_ > 0 else 1,
		func(i: int) -> void:
			draft.set_prop(_selected, "stable_sign", 1 if i == 0 else -1)
			_flash("Set the tilt with the palette on a future pass — this "
				+ "records the latch state only.")))
	_props.add_child(Gui.label("Tips so far: %d" % int(h.get("tip_count", 0)),
		Gui.T_BODY, Gui.INK))
	_props.add_child(Gui.para(
		"Balls already in a CELL are ordinary elements: move them like any "
		+ "other, and the score follows what is actually in there."))

# ---- problems

func _problem_notes(id: String) -> void:
	for p in _problems:
		if String(p.get("id", "")) != id:
			continue
		# opponent problems are shown BESIDE THE SETTING they are about, in the
		# Opponent behavior section; listing them here too says it twice
		if String(p.get("where", "")) == "opponent":
			continue
		var l := Gui.para(String(p.get("msg", "")))
		l.add_theme_color_override("font_color",
			Gui.RED_INK if String(p.get("severity", "")) == "error" else Gui.WARN)
		_props.add_child(l)

func _resync() -> void:
	await _sync_world()
	_refresh_all()

# ================================================================== status ===

func _refresh_status() -> void:
	_problems = draft.check()
	var errs := 0
	var warns := 0
	for p in _problems:
		if String(p.get("severity", "")) == "error":
			errs += 1
		else:
			warns += 1
	if errs > 0:
		var first := ""
		for p in _problems:
			if String(p.get("severity", "")) == "error":
				first = String(p.get("msg", ""))
				break
		Gui.set_status(_status, "%d problem%s — %s" % [
			errs, "" if errs == 1 else "s", first], Gui.RED_INK)
	elif warns > 0:
		Gui.set_status(_status, "Ready to save · %d unusual setting%s" % [
			warns, "" if warns == 1 else "s"], Gui.WARN)
	else:
		Gui.set_status(_status, "Ready to save", Gui.GOOD)
	_save_btn.disabled = errs > 0
	_test_btn.disabled = errs > 0
	_copy_btn.disabled = errs > 0
	_copy_btn.visible = draft.source_id != ""
	_save_btn.text = "Save changes" if draft.source_id != "" else "Save"

func _flash(msg: String) -> void:
	Gui.set_status(_status, msg, Gui.WARN)
	SFX.play("foul", -22.0)

# =================================================================== actions =

func _save(as_copy: bool) -> void:
	if not draft.errors().is_empty():
		_flash("Fix the problems before saving.")
		return
	var nm := draft.name.strip_edges()
	if nm == "":
		_flash("Give the situation a name first.")
		return
	var id := ScenarioLibrary.save(draft.to_snapshot(), nm, draft.note,
		"" if as_copy else draft.source_id)
	if id == "":
		_flash("Could not write that situation to disk.")
		return
	draft.source_id = id
	draft.dirty = false
	SFX.play("select", -12.0)
	Gui.set_status(_status, 'Saved "%s".' % nm, Gui.GOOD)
	_refresh_status()
	saved.emit(id)

func _test() -> void:
	if not draft.errors().is_empty():
		_flash("Fix the problems before testing.")
		return
	# The test runs from an IMMUTABLE COPY. Whatever happens out there cannot
	# reach back into the draft.
	test_requested.emit(draft.to_snapshot())

func _try_close() -> void:
	if not draft.dirty:
		closed.emit()
		return
	var d := ConfirmationDialog.new()
	d.title = "Unsaved changes"
	d.dialog_text = "This situation has changes you have not saved.\nLeave the editor and lose them?"
	d.ok_button_text = "Discard"
	add_child(d)
	d.confirmed.connect(func() -> void: closed.emit())
	d.close_requested.connect(func() -> void: d.queue_free())
	d.popup_centered()
