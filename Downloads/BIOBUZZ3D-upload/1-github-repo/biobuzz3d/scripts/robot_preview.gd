class_name RobotPreview
extends PanelContainer
##
## THE ROBOT, SHOWN RATHER THAN DESCRIBED.
##
## A lit 3D view of the actual robot as it is currently configured — built by
## RobotBody, the same code the driven robot uses, so an imported CAD model,
## the alliance colour and the intake layout all show up here. It renders into
## its own SubViewport with its own World3D: nothing here touches the match, and
## no extra robot exists in the physics world.
##
## Drag it to orbit; let go and it drifts back to turning on its own.
##

var holder: Node3D
var _vp: SubViewport
var _cam: Camera3D
var _spin := 0.6
var _yaw := 0.0
var _pitch := 0.42
var _dragging := false
var _idle := 0.0
var alliance := BB.Alliance.RED
var intakes := 1
var _texture: TextureRect
## Show the orientation guides around an imported model (the Garage turns
## this on while you line the model up): the 18 in cube, which end is the
## FRONT with the intake, the BACK, and where the launcher sits.
var guides := false:
	set(v):
		if guides == v:
			return
		guides = v
		_spin = 0.25 if v else 0.6
		if v:
			# start looking at the FRONT from the front-left, a little closer
			_yaw = PI - 0.7
			_idle = -2.0
		rebuild(alliance, intakes)
		if _cam:
			_place()

func _init(min_h := 300) -> void:
	# its camera and model are moved per frame, not by physics
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	custom_minimum_size = Vector2(0, min_h)
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true

func build() -> void:
	# the panel itself: same surface as every other card, with the reference's
	# soft pool of light behind the robot
	var sb := StyleBoxFlat.new()
	sb.bg_color = Gui.PANEL
	sb.border_color = Gui.LINE
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(Gui.R_PANEL)
	add_theme_stylebox_override("panel", sb)

	var glow := TextureRect.new()
	glow.texture = _radial(Gui.STAGE, Gui.PANEL)
	glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glow.stretch_mode = TextureRect.STRETCH_SCALE
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(glow)

	_vp = SubViewport.new()
	_vp.size = Vector2i(760, 460)
	_vp.transparent_bg = true
	_vp.own_world_3d = true
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)

	holder = Node3D.new()
	_vp.add_child(holder)

	# A faint grid that fades out, plus a soft contact shadow. No opaque floor
	# slab: the reference shows the robot standing in a pool of light, and a lit
	# plane reads as a grey box with edges.
	var floor_mesh := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(2.0, 2.0)
	floor_mesh.mesh = pm
	var fmat := StandardMaterial3D.new()
	fmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fmat.albedo_texture = _grid()
	fmat.albedo_color = Color(1, 1, 1, 1)
	floor_mesh.material_override = fmat
	floor_mesh.position.y = 0.0
	_vp.add_child(floor_mesh)

	var shadow := MeshInstance3D.new()
	var sq := QuadMesh.new()
	sq.size = Vector2(0.95, 0.95)
	shadow.mesh = sq
	var smat := StandardMaterial3D.new()
	smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smat.albedo_texture = _radial(Color(0, 0, 0, 0.6), Color(0, 0, 0, 0))
	shadow.material_override = smat
	shadow.rotation_degrees = Vector3(-90, 0, 0)
	shadow.position.y = 0.005
	_vp.add_child(shadow)

	_cam = Camera3D.new()
	_cam.fov = 36.0
	_vp.add_child(_cam)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-44, -36, 0)
	key.light_energy = 1.7
	key.shadow_enabled = true
	_vp.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-12, 145, 0)
	fill.light_energy = 0.55
	fill.light_color = Color(0.85, 0.92, 1.0)
	_vp.add_child(fill)
	var rim := DirectionalLight3D.new()
	rim.rotation_degrees = Vector3(-8, 20, 0)
	rim.light_energy = 0.4
	rim.light_color = Gui.ACCENT
	_vp.add_child(rim)

	var tex := TextureRect.new()
	_texture = tex
	tex.texture = _vp.get_texture()
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(tex)
	tex.resized.connect(_resize_render_target)

	rebuild(alliance, intakes)
	_place()

## Rebuild the model — alliance colour, intake count or an imported CAD model.
func rebuild(a: int, n: int) -> void:
	alliance = a
	intakes = n
	if holder == null:
		return
	for c in holder.get_children():
		c.queue_free()
	var cad := RobotBody.build(holder, a, n, true, true)
	if cad and guides:
		_add_guides(holder, n)

## The orientation guides. They turn with the model, so "the intake end goes
## where FRONT is" holds from any angle.
func _add_guides(parent: Node3D, n: int) -> void:
	var g := Node3D.new()
	g.name = "Guides"
	parent.add_child(g)
	var cube := BB.m(BB.ROBOT_CUBE)
	var h := cube * 0.5
	# the 18 in cube the robot has to fit in (R102)
	var lines := ImmediateMesh.new()
	var line_mat := StandardMaterial3D.new()
	line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_mat.albedo_color = Color(1, 1, 1, 0.35)
	line_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	lines.surface_begin(Mesh.PRIMITIVE_LINES, line_mat)
	var corners: Array[Vector3] = []
	for i in 8:
		corners.append(Vector3(h if i & 1 else -h, cube if i & 2 else 0.0, h if i & 4 else -h))
	for e in [[0, 1], [2, 3], [4, 5], [6, 7], [0, 2], [1, 3], [4, 6], [5, 7], [0, 4], [1, 5], [2, 6], [3, 7]]:
		lines.surface_add_vertex(corners[e[0]])
		lines.surface_add_vertex(corners[e[1]])
	lines.surface_end()
	var box := MeshInstance3D.new()
	box.mesh = lines
	g.add_child(box)
	# FRONT: a yellow strip along the front edge and an arrow on the floor
	var yellow := Gui.ACCENT
	var strip := MeshInstance3D.new()
	var sm := BoxMesh.new()
	sm.size = Vector3(cube, BB.m(0.25), BB.m(0.8))
	strip.mesh = sm
	strip.position = Vector3(0, BB.m(0.12), -h)
	strip.material_override = _flat(yellow)
	g.add_child(strip)
	var arrow := MeshInstance3D.new()
	var am := PrismMesh.new()
	am.size = Vector3(BB.m(9.0), BB.m(7.0), BB.m(0.2))
	arrow.mesh = am
	arrow.rotation.x = -PI * 0.5            # lie flat, point toward -Z
	arrow.position = Vector3(0, BB.m(0.1), -h - BB.m(4.5))
	arrow.material_override = _flat(yellow)
	g.add_child(arrow)
	# FRONT and BACK hide behind the model, so you only read the one facing you
	g.add_child(_tag("FRONT · INTAKE", Vector3(0, BB.m(1.0), -h - BB.m(10.0)), yellow, 40, true))
	g.add_child(_tag("BACK · INTAKE" if n >= 2 else "BACK",
		Vector3(0, BB.m(1.0), h + BB.m(5.0)), yellow if n >= 2 else Gui.MUTED, 34, true))
	# the launcher is the turret on top, in the middle: it aims itself
	g.add_child(_tag("LAUNCHER · turret, top middle",
		Vector3(0, BB.m(BB.ROBOT_CUBE + 1.5), 0), Color(1, 0.6, 0.5), 26))

func _flat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	return m

func _tag(t: String, at: Vector3, c: Color, px: int, hide_behind := false) -> Label3D:
	var l := Label3D.new()
	l.text = t
	l.position = at
	l.modulate = c
	l.font_size = px
	l.outline_size = 10
	l.outline_modulate = Color(0, 0, 0, 0.85)
	l.pixel_size = 0.0011
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = not hide_behind
	l.render_priority = 10
	return l

func _place() -> void:
	var r := 1.4 if guides else 1.45
	var y := sin(_pitch) * r
	var flat := cos(_pitch) * r
	_cam.position = Vector3(sin(_yaw) * flat, y, cos(_yaw) * flat)
	_cam.look_at(Vector3(0, 0.2 if guides else 0.14, 0), Vector3.UP)

func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		_dragging = ev.pressed
		_idle = 0.0
		accept_event()
	elif ev is InputEventMouseMotion and _dragging:
		_yaw -= ev.relative.x * 0.01
		_pitch = clampf(_pitch + ev.relative.y * 0.006, 0.08, 1.25)
		_idle = 0.0
		_place()
		accept_event()

func _process(d: float) -> void:
	if not is_visible_in_tree():
		return
	_resize_render_target()
	if _dragging:
		return
	# idle for a moment after a drag, then resume the slow turn
	_idle += d
	if _idle > 1.2:
		_yaw += d * _spin
		_place()

## Keep the preview's original framing, but render at the displayed pixel
## density instead of stretching the fixed 760x460 texture on large screens.
func _resize_render_target() -> void:
	if _vp == null or not is_instance_valid(_texture):
		return
	var transform_to_screen := _texture.get_screen_transform()
	var pixels := _texture.size * Vector2(
		transform_to_screen.x.length(), transform_to_screen.y.length())
	var scale_factor := maxf(0.1, minf(pixels.x / 760.0, pixels.y / 460.0))
	var target := Vector2i(ceili(760.0 * scale_factor), ceili(460.0 * scale_factor))
	if _vp.size != target:
		_vp.size = target

## A radial gradient as a texture: the pool of light behind the robot and the
## soft contact shadow under it are the same shape at different colours.
func _radial(centre: Color, edge: Color) -> ImageTexture:
	var n := 96
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var c := (n - 1) * 0.5
	for y in n:
		for x in n:
			var t := clampf(Vector2(x - c, y - c).length() / c, 0.0, 1.0)
			t = t * t
			img.set_pixel(x, y, centre.lerp(edge, t))
	return ImageTexture.create_from_image(img)

## A tile grid that fades out towards the edges, so the floor has no border.
func _grid() -> ImageTexture:
	var n := 256
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var c := (n - 1) * 0.5
	var step := n / 8
	for y in n:
		for x in n:
			var on_line := (x % step) < 2 or (y % step) < 2
			var t := clampf(Vector2(x - c, y - c).length() / c, 0.0, 1.0)
			var fade := clampf(1.0 - t * 1.25, 0.0, 1.0)
			fade = fade * fade
			var a := (0.55 if on_line else 0.16) * fade
			img.set_pixel(x, y, Color(0.36, 0.42, 0.34, a))
	return ImageTexture.create_from_image(img)
