class_name Field
extends Node3D
##
## The ARENA (S9): tiles, perimeter wall, tape, the HIVE structure frame and the
## four FLOWERS. Everything is generated from the constants in bb.gd, so a Team
## Update that moves a number changes one line and the field follows.
##

var hives: Dictionary = {}          # alliance -> Hive
var flowers: Array[Flower] = []
var frame_body: StaticBody3D

func build() -> void:
	name = "Field"
	_tiles()
	_walls()
	_tape()
	_hive_structure()
	for spec in BB.FLOWERS:
		var f := Flower.make(spec)
		add_child(f)
		flowers.append(f)

# --------------------------------------------------------------------- tiles
func _tiles() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.name = "Tiles"
	var pm := PhysicsMaterial.new()
	pm.friction = 0.95              # soft foam tiles: grippy
	pm.bounce = BB.TILE_BOUNCE      # and springy: see BB.TILE_BOUNCE
	floor_body.physics_material_override = pm
	floor_body.set_collision_mask_value(BB.LAYER_ELEMENT, true)
	var sh := BoxShape3D.new()
	sh.size = Vector3(BB.FIELD_HALF * 2.0, 4.0, BB.FIELD_HALF * 2.0) * BB.IN
	var cs := CollisionShape3D.new()
	cs.shape = sh
	cs.position = Vector3(0, -2.0 * BB.IN, 0)
	floor_body.add_child(cs)
	add_child(floor_body)

	for ix in 6:
		for iy in 6:
			var x := -BB.FIELD_HALF + BB.TILE * (float(ix) + 0.5)
			var y := -BB.FIELD_HALF + BB.TILE * (float(iy) + 0.5)
			var mi := MeshInstance3D.new()
			var pm2 := PlaneMesh.new()
			pm2.size = Vector2(BB.TILE - 0.25, BB.TILE - 0.25) * BB.IN
			mi.mesh = pm2
			mi.position = BB.fp(x, y, 0.02)
			mi.material_override = BB.mat(BB.C_TILE_A if (ix + iy) % 2 == 0 else BB.C_TILE_B, 0.95)
			add_child(mi)

# --------------------------------------------------------------------- walls
func _walls() -> void:
	var body := StaticBody3D.new()
	body.name = "Perimeter"
	var pm := PhysicsMaterial.new()
	pm.friction = 0.35
	pm.bounce = 0.30
	body.physics_material_override = pm
	body.set_collision_mask_value(BB.LAYER_ELEMENT, true)
	add_child(body)
	var h := BB.FIELD_HALF
	var t := BB.WALL_T
	for spec in [
		[0.0, h + t * 0.5, h * 2.0 + t * 2.0, t],
		[0.0, -h - t * 0.5, h * 2.0 + t * 2.0, t],
		[-h - t * 0.5, 0.0, t, h * 2.0],
		[h + t * 0.5, 0.0, t, h * 2.0],
	]:
		# COLLISION is one solid box the full 12 in, exactly as before. Only the
		# way it is DRAWN changes below, so nothing about how a ball or a robot
		# meets the wall is affected by making it see-through.
		var sh := BoxShape3D.new()
		sh.size = Vector3(spec[2], BB.WALL_H, spec[3]) * BB.IN
		var cs := CollisionShape3D.new()
		cs.shape = sh
		cs.position = BB.fp(spec[0], spec[1], BB.WALL_H * 0.5)
		body.add_child(cs)

		# A real field perimeter is a black extruded rail along the bottom, a
		# clear polycarbonate panel, and another black rail along the top. You
		# watch the match THROUGH it, which matters here because the driver
		# camera sits outside the field looking in.
		var bot := BB.WALL_RAIL_BOTTOM
		var top := BB.WALL_RAIL_TOP
		var glass_h := BB.WALL_H - bot - top
		_wall_band(spec, bot, bot * 0.5, BB.mat(BB.C_RAIL, 0.55, 0.35), true)
		_wall_band(spec, top, BB.WALL_H - top * 0.5, BB.mat(BB.C_RAIL, 0.55, 0.35), true)
		# the panel is slightly thinner than the rails, so the rails read as
		# capping it rather than being flush with it
		_wall_band(spec, glass_h, bot + glass_h * 0.5, BB.glass(), false, 0.62)

## One horizontal band of the perimeter, drawn only — `spec` is the same
## [x, y, width, depth] the collision box uses.
func _wall_band(spec: Array, height_in: float, centre_z_in: float,
		material: Material, shadows: bool, thickness_scale := 1.0) -> void:
	var bm := BoxMesh.new()
	bm.size = Vector3(
		float(spec[2]) * (thickness_scale if float(spec[2]) < float(spec[3]) else 1.0),
		height_in,
		float(spec[3]) * (thickness_scale if float(spec[3]) < float(spec[2]) else 1.0)
	) * BB.IN
	var mi := MeshInstance3D.new()
	mi.mesh = bm
	mi.position = BB.fp(float(spec[0]), float(spec[1]), centre_z_in)
	mi.material_override = material
	if not shadows:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

# ---------------------------------------------------------------------- tape
func _tape() -> void:
	# tile seams (Fig 9-4), cosmetic
	for v in [-48.0, -24.0, 0.0, 24.0, 48.0]:
		_strip(v, 0.0, 0.35, BB.FIELD_HALF * 2.0, Color(0.20, 0.21, 0.22))
		_strip(0.0, v, BB.FIELD_HALF * 2.0, 0.35, Color(0.20, 0.21, 0.22))
	for a in [BB.Alliance.RED, BB.Alliance.BLUE]:
		_rect_tape(BB.loading_zone(a), BB.alliance_colour(a), 1.0)
		_rect_tape(BB.garden(a), BB.alliance_colour(a), 0.9)

func _rect_tape(r: Array, c: Color, alpha: float) -> void:
	var col := Color(c.r, c.g, c.b, alpha)
	var w: float = r[2] - r[0]
	var h: float = r[3] - r[1]
	var cx: float = (r[0] + r[2]) * 0.5
	var cy: float = (r[1] + r[3]) * 0.5
	_strip(cx, r[1], w, 1.0, col)
	_strip(cx, r[3], w, 1.0, col)
	_strip(r[0], cy, 1.0, h, col)
	_strip(r[2], cy, 1.0, h, col)

func _strip(x: float, y: float, w: float, h: float, c: Color) -> void:
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(w, h) * BB.IN
	mi.mesh = pm
	mi.position = BB.fp(x, y, 0.06)
	var m := BB.mat(c, 0.9)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = m
	add_child(mi)

# ------------------------------------------------------------ HIVE structure
## Two triangular frames at |x| = 24.5 joined by an apex crossbar, feet at
## y = +-19.4. Bottom of a HIVE is 25.5 in up, so an 18 in robot drives under.
func _hive_structure() -> void:
	frame_body = StaticBody3D.new()
	frame_body.name = "HiveFrame"
	frame_body.set_collision_mask_value(BB.LAYER_ELEMENT, true)
	add_child(frame_body)

	var apex := BB.HIVE_PIVOT_Y + 3.0
	for sx in [-1.0, 1.0]:
		var x: float = BB.HIVE_FRAME_X * sx
		for sy in [-1.0, 1.0]:
			var foot: float = BB.HIVE_FRAME_FOOT * sy
			_leg(BB.fp(x, foot, 0.0), BB.fp(x, 0.0, apex))
		# base bar: bent sheet metal, effectively 1 in thick, sitting ON the tile
		# seam. It is a real 1 in lip a robot drives over, not a curb.
		_bar(frame_body, BB.fp(x, -BB.HIVE_FRAME_FOOT, 0.5), BB.fp(x, BB.HIVE_FRAME_FOOT, 0.5), 1.0)
	_bar(frame_body, BB.fp(-BB.HIVE_FRAME_X, 0.0, apex), BB.fp(BB.HIVE_FRAME_X, 0.0, apex), 2.0)

	for a in [BB.Alliance.RED, BB.Alliance.BLUE]:
		var hv := Hive.make(a, frame_body)
		add_child(hv)
		hives[a] = hv

func _leg(from: Vector3, to: Vector3) -> void:
	_bar(frame_body, from, to, 1.6)

func _bar(body: StaticBody3D, from: Vector3, to: Vector3, thick_in: float) -> void:
	var mid := (from + to) * 0.5
	var dir := to - from
	var len := dir.length()
	var t := thick_in * BB.IN
	var basis := _basis_towards(dir)

	var sh := BoxShape3D.new()
	sh.size = Vector3(t, t, len)
	var cs := CollisionShape3D.new()
	cs.shape = sh
	cs.transform = Transform3D(basis, mid)
	body.add_child(cs)

	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = sh.size
	mi.mesh = bm
	mi.transform = cs.transform
	mi.material_override = BB.mat(BB.C_FRAME, 0.45, 0.6)
	add_child(mi)

func _basis_towards(dir: Vector3) -> Basis:
	var z := dir.normalized()
	var up := Vector3.UP
	if absf(z.dot(up)) > 0.99:
		up = Vector3.FORWARD
	var x := up.cross(z).normalized()
	var y := z.cross(x).normalized()
	return Basis(x, y, z)
