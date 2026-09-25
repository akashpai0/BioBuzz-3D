class_name OpponentOverlay
extends Node3D
##
## WHAT A PRACTICE OPPONENT IS DOING, DRAWN ON THE FIELD.
##
## Two uses, one drawing:
##
##   * in the Scenario Creator, always, from the DRAFT's settings — so the
##     route you are placing and the area you are sizing are visible as you
##     edit them;
##   * in practice, ONLY when the player turns it on (Settings -> Camera &
##     display -> Opponent overlay), from the RUNNING brain — so the current
##     waypoint is highlighted and the status line is the state that brain is
##     actually in this tick.
##
## Nothing here has a collision shape, so it can never push a robot or catch a
## ball. Everything is drawn a few millimetres above the tiles.

const LIFT := 0.006

## Live mode: the brain to follow. Null in the editor.
var brain: AIDriver
var _cfg: Dictionary = {}
var _alliance := 0
var _wp_marks: Array[MeshInstance3D] = []
var _status: Label3D
var _lit := -1

static func for_config(cfg: Dictionary, alliance: int, robot_pos := Vector3.INF) -> OpponentOverlay:
	var o := OpponentOverlay.new()
	o._cfg = cfg
	o._alliance = alliance
	o.name = "OpponentOverlay"
	o._draw_static(robot_pos)
	return o

static func for_brain(b: AIDriver) -> OpponentOverlay:
	var o := for_config(b.config, b.robot.alliance)
	o.brain = b
	o._status = Label3D.new()
	o._status.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	o._status.no_depth_test = true
	o._status.fixed_size = true
	o._status.pixel_size = 0.0011
	o._status.font_size = 22
	o._status.outline_size = 8
	o._status.modulate = Gui.INK
	o._status.outline_modulate = Color(0, 0, 0, 0.85)
	o.add_child(o._status)
	return o

func _enter_tree() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF   # drawn per frame

func _process(_d: float) -> void:
	if brain == null or not is_instance_valid(brain) or not is_instance_valid(brain.robot):
		return
	_status.global_position = brain.robot.global_position + Vector3(0, BB.m(26.0), 0)
	_status.text = "%s\n%s" % [OpponentConfig.NAMES[brain.behavior()], brain.status]
	if brain.behavior() == OpponentConfig.Behavior.ROUTE and brain._wp != _lit:
		_highlight(brain._wp)

func _highlight(i: int) -> void:
	for k in _wp_marks.size():
		var on := k == i
		_wp_marks[k].material_override = _mat(Gui.ACCENT if on else _ink(), 0.95 if on else 0.55)
		_wp_marks[k].scale = Vector3.ONE * (1.35 if on else 1.0)
	_lit = i

# ================================================================= drawing ==

func _ink() -> Color:
	return Gui.alliance_ink(_alliance)

func _draw_static(robot_pos: Vector3) -> void:
	match int(_cfg.get("behavior", 0)):
		OpponentConfig.Behavior.ROUTE:
			_draw_route(robot_pos)
		OpponentConfig.Behavior.DEFEND:
			var a: Dictionary = _cfg.get("area", {})
			_ring(Vector2(float(a.get("x", 0.0)), float(a.get("y", 0.0))),
				OpponentConfig.get_f(_cfg, "radius"), _ink(), "DEFENSE AREA")
		OpponentConfig.Behavior.COLLECT:
			var r := OpponentConfig.get_f(_cfg, "collect_r")
			if r > 0.0:
				var a2: Dictionary = _cfg.get("area", {})
				_ring(Vector2(float(a2.get("x", 0.0)), float(a2.get("y", 0.0))),
					r, Gui.GOOD, "COLLECTION AREA")

func _draw_route(robot_pos: Vector3) -> void:
	var wps: Array = _cfg.get("waypoints", [])
	var pts: Array[Vector2] = []
	for w in wps:
		pts.append(Vector2(float(w["x"]), float(w["y"])))
	# from the robot to the first waypoint, dashed-light, so you can see where
	# it will go first
	if robot_pos != Vector3.INF and not pts.is_empty():
		_segment(Vector2(robot_pos.x / BB.IN, -robot_pos.z / BB.IN), pts[0],
			Color(_ink().r, _ink().g, _ink().b, 0.35))
	for i in pts.size() - 1:
		_segment(pts[i], pts[i + 1], _ink())
	var mode := int(OpponentConfig.get_f(_cfg, "route_mode"))
	if mode == OpponentConfig.RouteMode.LOOP and pts.size() > 2:
		_segment(pts[-1], pts[0], Color(_ink().r, _ink().g, _ink().b, 0.6))
	for i in pts.size():
		var disc := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = BB.m(4.0)
		cyl.bottom_radius = BB.m(4.0)
		cyl.height = 0.004
		disc.mesh = cyl
		disc.material_override = _mat(_ink(), 0.55)
		add_child(disc)
		disc.position = BB.fp(pts[i].x, pts[i].y, 0.0) + Vector3(0, LIFT, 0)
		_wp_marks.append(disc)
		var lab := _label("%d" % (i + 1), 30)
		lab.position = BB.fp(pts[i].x, pts[i].y, 7.0)
		var wait := float(wps[i].get("wait", 0.0))
		if wait > 0.0:
			# beside the number, not on top of it: from above, height alone does
			# not separate two labels
			var wl := _label("wait %.1f s" % wait, 18)
			wl.position = BB.fp(pts[i].x + 11.0, pts[i].y - 6.0, 7.0)

## A floor stripe from a to b with an arrowhead half way, pointing a -> b.
func _segment(a: Vector2, b: Vector2, c: Color) -> void:
	var d := b - a
	var n := d.length()
	if n < 0.5:
		return
	var bar := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(BB.m(1.2), 0.003, BB.m(n))
	bar.mesh = box
	bar.material_override = _mat(c, c.a)
	add_child(bar)
	var mid := (a + b) * 0.5
	bar.position = BB.fp(mid.x, mid.y, 0.0) + Vector3(0, LIFT, 0)
	# field +y is Godot -Z, so the heading is measured the same way the robots' is
	bar.rotation.y = atan2(-d.x, d.y)
	var tip := MeshInstance3D.new()
	var pm := PrismMesh.new()
	pm.size = Vector3(BB.m(5.0), BB.m(5.0), 0.003)
	tip.mesh = pm
	tip.material_override = _mat(c, maxf(c.a, 0.8))
	add_child(tip)
	tip.position = BB.fp(mid.x, mid.y, 0.0) + Vector3(0, LIFT * 1.5, 0)
	# lay the prism flat and point its apex along a -> b
	tip.rotation = Vector3(-PI * 0.5, atan2(-d.x, d.y), 0.0)

func _ring(c: Vector2, r: float, col: Color, text: String) -> void:
	var fill := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = BB.m(r)
	cyl.bottom_radius = BB.m(r)
	cyl.height = 0.003
	fill.mesh = cyl
	fill.material_override = _mat(col, 0.12)
	add_child(fill)
	fill.position = BB.fp(c.x, c.y, 0.0) + Vector3(0, LIFT, 0)
	var ring := MeshInstance3D.new()
	var tor := TorusMesh.new()
	tor.inner_radius = BB.m(r) - BB.m(0.9)
	tor.outer_radius = BB.m(r)
	ring.mesh = tor
	ring.material_override = _mat(col, 0.95)
	add_child(ring)
	ring.position = BB.fp(c.x, c.y, 0.0) + Vector3(0, LIFT * 1.5, 0)
	var dot := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = BB.m(1.5)
	cm.bottom_radius = BB.m(1.5)
	cm.height = 0.004
	dot.mesh = cm
	dot.material_override = _mat(col, 0.95)
	add_child(dot)
	dot.position = BB.fp(c.x, c.y, 0.0) + Vector3(0, LIFT * 2.0, 0)
	var lab := _label(text, 18)
	lab.position = BB.fp(c.x, c.y + r + 4.0, 3.0)

func _label(t: String, size: int) -> Label3D:
	var l := Label3D.new()
	l.text = t
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.fixed_size = true
	l.pixel_size = 0.0011
	l.font_size = size
	l.outline_size = 6
	l.modulate = Gui.INK
	l.outline_modulate = Color(0, 0, 0, 0.85)
	add_child(l)
	return l

func _mat(c: Color, alpha: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(c.r, c.g, c.b, alpha)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.no_depth_test = true
	return m
