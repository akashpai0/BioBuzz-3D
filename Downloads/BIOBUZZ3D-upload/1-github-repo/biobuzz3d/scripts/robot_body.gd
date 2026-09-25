class_name RobotBody
extends RefCounted
##
## The robot's LOOK, in one place.
##
## Both the real Robot and the little model on the title screen build from this,
## so the thing you pick in the menu is the thing you drive. Meshes only — no
## physics — which is why the preview can use it without a physics world.
##
## `intakes` is 1 or 2 and is purely cosmetic: a two-intake robot has a roller
## at each end instead of one at the front. It collects exactly the same, because
## the intake volume already reaches under the whole chassis.
##

static func build(parent: Node3D, alliance: int, intakes: int,
		with_wheels := false, with_turret := false, use_cad := true) -> bool:
	# A team's own CAD REPLACES the stock robot completely: no frame, bumpers,
	# rollers, wheels or turret drawn on top. The model is the robot. (Driving
	# and collisions still come from the profile and the 18 in cube.) Returns
	# true when the CAD was used, so the driven robot can hide its own moving
	# parts too.
	if use_cad and RobotShop.has_model():
		var cad := load_cad()
		if cad != null:
			parent.add_child(cad)
			return true

	var col := BB.alliance_colour(alliance)
	var body_h := BB.ROBOT_BODY_H
	var half := BB.ROBOT_CUBE * 0.5
	var frame := BB.mat(Color(0.16, 0.17, 0.19), 0.5, 0.35)
	var inner := BB.ROBOT_CUBE - 4.0

	# open frame: floor plate, four posts, roof plate — the POLLEN inside shows
	_box(parent, Vector3(0, (BB.WHEEL_R + 0.4) * BB.IN, 0), Vector3(inner, 0.8, inner), frame)
	_box(parent, Vector3(0, (BB.WHEEL_R + body_h - 0.4) * BB.IN, 0),
		Vector3(inner, 0.8, inner), frame)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_box(parent, Vector3(sx * inner * 0.5 * BB.IN,
				(BB.WHEEL_R + body_h * 0.5) * BB.IN, sz * inner * 0.5 * BB.IN),
				Vector3(1.2, body_h, 1.2), frame)

	# Bumpers sit flush INSIDE the 18 in footprint, not straddling it.
	#
	# They used to be centred ON the edge, which put 0.8 in of bumper outside
	# the collision box, and the intake roller below was 2.7 in outside it. The
	# robot stopped in exactly the right place and then LOOKED like it was
	# buried in the wall — and when two robots met, both overhangs added up to
	# more than five inches of interpenetrated geometry. That reads as phasing
	# through, and it is also just wrong: R102 says a robot starts inside an
	# 18 in cube, so nothing should poke out of one.
	var bump := BB.mat(col, 0.45, 0.15)
	var by := (BB.WHEEL_R + 3.0) * BB.IN
	var bz := (half - 0.8) * BB.IN
	for spec in [
		[Vector3(0, by, -bz), Vector3(BB.ROBOT_CUBE, 4.0, 1.6)],
		[Vector3(0, by, bz), Vector3(BB.ROBOT_CUBE, 4.0, 1.6)],
		[Vector3(-bz, by, 0), Vector3(1.6, 4.0, BB.ROBOT_CUBE)],
		[Vector3(bz, by, 0), Vector3(1.6, 4.0, BB.ROBOT_CUBE)],
	]:
		_box(parent, spec[0], spec[1], bump)

	# ---- the intakes: one at the front, or one at each end
	# Rollers tucked just inside the bumper line, for the same reason.
	var roller_mat := BB.mat(Color(0.95, 0.80, 0.15), 0.55)
	var rz := half - ROLLER_R - 0.1
	_roller(parent, -rz, roller_mat)
	if intakes >= 2:
		_roller(parent, rz, roller_mat)

	if with_wheels:
		_wheels(parent)
	if with_turret:
		_turret_shell(parent, alliance)
	return false

## The team's model, turned and scaled into the 18 in cube, or null.
static func load_cad() -> Node3D:
	var errs: Array = []
	var cad := CadImport.load_model(RobotShop.model_path, errs)
	if cad != null:
		cad.name = "TeamCAD"
		cad.set_meta("team_cad", true)     # the name can change if an old copy is still leaving the tree
		CadImport.fit_to_robot(cad, RobotShop.model_scale, RobotShop.model_rot)
	return cad

## Four mecanum wheels, for the stock robot's look.
static func _wheels(parent: Node3D) -> void:
	var half := BB.ROBOT_CUBE * 0.5
	var tyre := BB.mat(Color(0.14, 0.14, 0.15), 0.6)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var mi := MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = BB.WHEEL_R * BB.IN
			cm.bottom_radius = cm.top_radius
			cm.height = 2.0 * BB.IN
			mi.mesh = cm
			mi.position = Vector3(sx * (half - 1.1), BB.WHEEL_R, sz * (half - 3.0)) * BB.IN
			mi.rotation.z = PI * 0.5
			mi.material_override = tyre
			parent.add_child(mi)

static func _turret_shell(parent: Node3D, alliance: int) -> void:
	var col := BB.alliance_colour(alliance)
	var base := MeshInstance3D.new()
	var bc := CylinderMesh.new()
	bc.top_radius = 3.0 * BB.IN
	bc.bottom_radius = 3.4 * BB.IN
	bc.height = 2.0 * BB.IN
	base.mesh = bc
	base.position = Vector3(0, (BB.WHEEL_R + BB.ROBOT_BODY_H + 1.0) * BB.IN, 0)
	base.material_override = BB.mat(Color(0.25, 0.26, 0.28), 0.4, 0.5)
	parent.add_child(base)

	var barrel := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(4.0, 2.8, 8.0) * BB.IN
	barrel.mesh = bm
	barrel.material_override = BB.mat(col, 0.35, 0.4)
	barrel.position = base.position + Vector3(0, 3.0 * BB.IN, -2.6 * BB.IN)
	barrel.rotation.x = deg_to_rad(52.0)
	parent.add_child(barrel)

## Alliance bumpers around an imported shape. No longer drawn: the CAD is
## shown on its own, and opponents keep the stock robot so the alliances are
## still told apart on the field. Kept for tools that want it.
static func _accent(parent: Node3D, alliance: int) -> void:
	var half := BB.ROBOT_CUBE * 0.5
	var bump := BB.mat(BB.alliance_colour(alliance), 0.45, 0.15)
	var by := (BB.WHEEL_R + 3.0) * BB.IN
	for spec in [
		[Vector3(0, by, -half * BB.IN), Vector3(BB.ROBOT_CUBE, 4.0, 1.6)],
		[Vector3(0, by, half * BB.IN), Vector3(BB.ROBOT_CUBE, 4.0, 1.6)],
		[Vector3(-half * BB.IN, by, 0), Vector3(1.6, 4.0, BB.ROBOT_CUBE)],
		[Vector3(half * BB.IN, by, 0), Vector3(1.6, 4.0, BB.ROBOT_CUBE)],
	]:
		_box(parent, spec[0], spec[1], bump)

## Radius of the intake roller, in inches. Named because the placement above
## has to subtract it to keep the roller inside the chassis footprint.
const ROLLER_R := 1.5

static func _roller(parent: Node3D, z_in: float, mat: StandardMaterial3D) -> void:
	var roll := MeshInstance3D.new()
	var rc := CylinderMesh.new()
	rc.top_radius = ROLLER_R * BB.IN
	rc.bottom_radius = rc.top_radius
	rc.height = (BB.ROBOT_CUBE - 3.0) * BB.IN
	roll.mesh = rc
	roll.position = Vector3(0, 1.9 * BB.IN, z_in * BB.IN)
	roll.rotation.z = PI * 0.5
	roll.material_override = mat
	parent.add_child(roll)

static func _box(parent: Node3D, pos: Vector3, size_in: Vector3, mat: StandardMaterial3D) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size_in * BB.IN
	mi.mesh = bm
	mi.position = pos
	mi.material_override = mat
	parent.add_child(mi)
