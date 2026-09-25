class_name Flower
extends Node3D
##
## One FLOWER (S9.7, Fig 9-12), built the way the real one is built.
##
##   top ring      a ~5 in rounded-square plate at 21.5 in with the 4.0 in
##                 opening, and a 1.25 in backstop on the field side
##   4 HIPS pipes  joining the top ring down to the middle ring — these ARE the
##                 wall of the tube. Their radius is set so a 3.6 in NECTAR
##                 still drops past them but a 2.8 in POLLEN cannot squeeze out
##                 sideways between two of them, which is exactly how the real
##                 cage behaves.
##   middle ring   at 3.55-3.98; its top is the floor of the scoring volume
##   lower ring    0.43 in tall with a 2.79 in hole, so a 2.8 in POLLEN settles
##                 INTO it and is cradled rather than rolling out
##   retrieval     the 3.55 in gap under the middle ring, open to the field:
##                 a POLLEN fits out, a 3.6 in NECTAR does not (G418, by size)
##
## A robot-only guard hull wraps the whole thing so a bumper cannot wedge
## between two pipes; elements pass through it untouched.
##

var id: String = "F1"
var near_alliance: int = BB.Alliance.RED
var wall_normal: Vector2 = Vector2(-1, 0)   # manual frame, pointing out of the field
var volume: Area3D

const PIPE_R := 2.30              # pipe centre radius: bore 3.85 (nectar fits),
const PIPE_D := 0.75              # gap between pipes 2.50 (pollen cannot escape)
const BORE := 2.05
## Radius of the smooth outer shell that wraps the pipes. The four pipes hold
## balls INSIDE the tube, but from the outside the gaps between them are a
## perfect place for a ball to jam. The shell closes the outside off, and the
## middle ring and top plate cap the void top and bottom, so a ball that misses
## the opening slides down the outside to the tiles instead of sticking.
const SHELL_R := 2.72

static func make(spec: Dictionary) -> Flower:
	var f := Flower.new()
	f.id = spec["id"]
	f.near_alliance = spec["near"]
	f.wall_normal = spec["wall"]
	f.name = "Flower" + f.id
	f.position = BB.fp(spec["x"], spec["y"], 0.0)
	f._build()
	return f

func _build() -> void:
	var body := StaticBody3D.new()
	body.name = "Shell"
	body.set_collision_mask_value(BB.LAYER_ELEMENT, true)
	# same reasoning as the CELL: a FLOWER should keep what is dropped into it
	var pm := PhysicsMaterial.new()
	pm.friction = 0.55
	pm.bounce = BB.ELEMENT_BOUNCE - 0.12
	pm.absorbent = true
	body.physics_material_override = pm
	add_child(body)
	var inward := -BB.fd(wall_normal)
	var inward_ang := atan2(inward.x, inward.z)
	var steel := BB.mat(Color(0.82, 0.84, 0.86), 0.35, 0.45)
	var pipe_mat := BB.mat(Color(0.93, 0.93, 0.95), 0.30, 0.10)
	var accent := BB.mat(BB.alliance_colour(near_alliance), 0.35, 0.30)

	# --- lower ring: annulus with the 2.79 in hole that cradles a POLLEN
	_annulus(body, 0.0, 0.43, BB.FLOWER_LOWER_HOLE * 0.5, 2.6, steel)

	# --- square extrusion joining the lower and middle rings, WALL SIDE only,
	#     which is what leaves the retrieval opening facing the field
	var ext := BoxShape3D.new()
	ext.size = Vector3(1.1, BB.FLOWER_MID_Y, 1.1) * BB.IN
	var ecs := CollisionShape3D.new()
	ecs.shape = ext
	ecs.position = -inward * 2.2 * BB.IN + Vector3(0, BB.FLOWER_MID_Y * 0.5 * BB.IN, 0)
	body.add_child(ecs)
	_mesh_box(ecs.position, ext.size, 0.0, steel)

	# --- middle ring: its TOP is the floor of the scoring volume (S10.5.2).
	# Widened to SHELL_R so it caps the void between the pipes and the outer
	# shell — see _ring_shell below.
	_annulus(body, 3.55, BB.FLOWER_MID_Y, 1.90, SHELL_R + 0.2, steel)

	# --- the four HIPS pipes: the tube wall from the middle ring to the top
	for i in BB.FLOWER_PIPES:
		var a := TAU * float(i) / float(BB.FLOWER_PIPES) + deg_to_rad(45.0) + inward_ang
		var pos := Vector3(sin(a) * PIPE_R * BB.IN,
			(BB.FLOWER_MID_Y + BB.FLOWER_TOP_Y) * 0.5 * BB.IN,
			cos(a) * PIPE_R * BB.IN)
		var cyl := CylinderShape3D.new()
		cyl.radius = PIPE_D * 0.5 * BB.IN
		cyl.height = (BB.FLOWER_TOP_Y - BB.FLOWER_MID_Y) * BB.IN
		var pcs := CollisionShape3D.new()
		pcs.shape = cyl
		pcs.position = pos
		body.add_child(pcs)
		var cm := CylinderMesh.new()
		cm.top_radius = cyl.radius
		cm.bottom_radius = cyl.radius
		cm.height = cyl.height
		var mi := MeshInstance3D.new()
		mi.mesh = cm
		mi.position = pos
		mi.material_override = pipe_mat
		add_child(mi)

	# --- smooth outer shell, and the top ring plate that caps it
	_ring_shell(body, BB.FLOWER_MID_Y, BB.FLOWER_TOP_Y, steel)
	_annulus(body, BB.FLOWER_TOP_Y, BB.FLOWER_TOP_Y + 0.45, BB.FLOWER_RING_DIA * 0.5,
		2.5, accent)
	# A sloped collar around the rim. The flat top plate is a ledge a ball can
	# balance on — especially leaning against the backstop — and a ball parked
	# up there is neither scored nor retrievable. The collar caps the void
	# between the pipes and the shell AND sheds anything that lands on it.
	_chamfer(body, BB.FLOWER_TOP_Y + 0.45, 2.4, SHELL_R + 0.75, steel)
	_wall_fillet(body, inward, BB.mat(Color(0.26, 0.27, 0.30), 0.6, 0.2))
	var bs := BoxShape3D.new()
	bs.size = Vector3(BB.FLOWER_PLATE, 1.25, 0.45) * BB.IN
	var bcs := CollisionShape3D.new()
	bcs.shape = bs
	bcs.position = inward * (BB.FLOWER_PLATE * 0.5 - 0.3) * BB.IN + Vector3(0, (BB.FLOWER_TOP_Y + 1.07) * BB.IN, 0)
	bcs.rotation.y = inward_ang
	body.add_child(bcs)
	_mesh_box(bcs.position, bs.size, inward_ang, accent)

	# --- scoring volume: top ring down to the middle ring
	volume = Area3D.new()
	volume.name = "ScoreVolume"
	var cyl2 := CylinderShape3D.new()
	cyl2.radius = (BORE + 0.2) * BB.IN
	cyl2.height = (BB.FLOWER_SCORE_HI - BB.FLOWER_SCORE_LO) * BB.IN
	var vcs := CollisionShape3D.new()
	vcs.shape = cyl2
	vcs.position = Vector3(0, (BB.FLOWER_SCORE_LO + BB.FLOWER_SCORE_HI) * 0.5 * BB.IN, 0)
	volume.add_child(vcs)
	volume.monitorable = false
	volume.collision_mask = 0
	volume.set_collision_mask_value(BB.LAYER_ELEMENT, true)
	add_child(volume)

	_guard_hull(inward)

## A smooth shell a ROBOT collides with and an ELEMENT does not, so a bumper
## can never end up jammed between two pipes. Elements keep their mask on
## layer 1 only, so they pass straight through this and stack inside normally.
func _guard_hull(inward: Vector3) -> void:
	var guard := StaticBody3D.new()
	guard.name = "RobotGuard"
	guard.collision_layer = 0
	guard.set_collision_layer_value(BB.LAYER_GUARD, true)
	guard.collision_mask = 0
	var sh := BoxShape3D.new()
	sh.size = Vector3(BB.FLOWER_BOX_W, BB.FLOWER_TOP_Y + 2.0, BB.FLOWER_BOX_D) * BB.IN
	var cs := CollisionShape3D.new()
	cs.shape = sh
	cs.position = inward * (BB.FLOWER_BOX_D * 0.5 - BB.FLOWER_OFF_WALL) * BB.IN \
		+ Vector3(0, (BB.FLOWER_TOP_Y + 2.0) * 0.5 * BB.IN, 0)
	cs.rotation.y = atan2(inward.x, inward.z)
	guard.add_child(cs)
	add_child(guard)

## A ring of tilted plates forming a cone around the rim, so a ball landing on
## the top of the FLOWER slides off instead of perching there.
func _chamfer(body: StaticBody3D, y_top: float, r_in: float, r_out: float,
		mat: StandardMaterial3D) -> void:
	# 55 degrees, not 45: the friction angle between a ball and the structure is
	# around 32-36 degrees, so a 45 degree face is close enough to it that a ball
	# can sit on the slope instead of sliding off.
	var n := 18
	var run := r_out - r_in
	var drop := run * 1.428                      # tan(55)
	var slope := sqrt(run * run + drop * drop)
	var r_mid := (r_in + r_out) * 0.5
	var y_mid := y_top - drop * 0.5
	var seg_w := 2.0 * r_out * tan(PI / n) * 1.15
	for i in n:
		var a := TAU * float(i) / n
		var u := Vector3(sin(a), 0.0, cos(a))
		var down_out := (u * 0.5736 - Vector3.UP * 0.8192).normalized()
		var tangent := Vector3(cos(a), 0.0, -sin(a))
		var up_n := tangent.cross(down_out).normalized()
		var sh := BoxShape3D.new()
		sh.size = Vector3(seg_w, 0.4 * BB.IN / BB.IN, slope) * BB.IN
		var cs := CollisionShape3D.new()
		cs.shape = sh
		cs.transform = Transform3D(Basis(tangent, up_n, down_out),
			u * r_mid * BB.IN + Vector3(0, y_mid * BB.IN, 0))
		body.add_child(cs)
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = sh.size
		mi.mesh = bm
		mi.transform = cs.transform
		mi.material_override = mat
		add_child(mi)

## The smooth outer wall of the FLOWER: a closed ring of segments just outside
## the pipes, so nothing can wedge into the gaps between them from the field.
func _ring_shell(body: StaticBody3D, y0: float, y1: float, mat: StandardMaterial3D) -> void:
	var n := 20
	var seg_w := 2.0 * SHELL_R * tan(PI / n) * 1.1
	for i in n:
		var a := TAU * float(i) / n
		var sh := BoxShape3D.new()
		sh.size = Vector3(seg_w, y1 - y0, 0.5) * BB.IN
		var cs := CollisionShape3D.new()
		cs.shape = sh
		var r := (SHELL_R + 0.25) * BB.IN
		cs.position = Vector3(sin(a) * r, (y0 + y1) * 0.5 * BB.IN, cos(a) * r)
		cs.rotation.y = a
		body.add_child(cs)

## Fills the CREVICE where the round FLOWER meets the flat perimeter wall.
##
## A cylinder standing against a plane makes a narrowing V on either side, and a
## ball that rolls into one gets pinched and held there by friction — halfway up
## the structure, not touching the floor. That is the "stuck in the walls" bug.
## This fills both Vs with solid material flush to the wall, and caps it at 65
## degrees so the fillet itself never becomes somewhere to rest.
func _wall_fillet(body: StaticBody3D, inward: Vector3, mat: StandardMaterial3D) -> void:
	var h := BB.FLOWER_TOP_Y + 0.6
	var sh := BoxShape3D.new()
	sh.size = Vector3(BB.FLOWER_BOX_W + 2.0, h, 3.1) * BB.IN
	var cs := CollisionShape3D.new()
	cs.shape = sh
	cs.position = -inward * (SHELL_R + 0.55) * BB.IN + Vector3(0, h * 0.5 * BB.IN, 0)
	cs.rotation.y = atan2(inward.x, inward.z)
	body.add_child(cs)
	_mesh_box(cs.position, sh.size, cs.rotation.y, mat)

	# steep, short cap: enough to shed a ball, too small to hold one
	var tangent := Vector3(inward.z, 0.0, -inward.x).normalized()
	var slope := (inward * 0.4226 - Vector3.UP * 0.9063).normalized()    # 65 degrees
	var up_n := tangent.cross(slope).normalized()
	var cap := BoxShape3D.new()
	cap.size = Vector3(BB.FLOWER_BOX_W + 2.2, 0.4, 3.3) * BB.IN
	var ccs := CollisionShape3D.new()
	ccs.shape = cap
	ccs.transform = Transform3D(Basis(tangent, up_n, slope),
		-inward * (SHELL_R + 0.75) * BB.IN + Vector3(0, (h + 0.7) * BB.IN, 0))
	body.add_child(ccs)
	var cmi := MeshInstance3D.new()
	var cbm := BoxMesh.new()
	cbm.size = cap.size
	cmi.mesh = cbm
	cmi.transform = ccs.transform
	cmi.material_override = mat
	add_child(cmi)

## A flat ring built from wedge boxes: hole of `hole_r`, outer edge `out_r`.
func _annulus(body: StaticBody3D, y0: float, y1: float, hole_r: float, out_r: float,
		mat: StandardMaterial3D) -> void:
	var n := 14
	var seg_w := 2.0 * hole_r * tan(PI / n) * 1.08
	for i in n:
		var a := TAU * float(i) / n
		var sh := BoxShape3D.new()
		sh.size = Vector3(maxf(seg_w, 0.4), y1 - y0, out_r - hole_r) * BB.IN
		var cs := CollisionShape3D.new()
		cs.shape = sh
		var r := (hole_r + (out_r - hole_r) * 0.5) * BB.IN
		cs.position = Vector3(sin(a) * r, (y0 + y1) * 0.5 * BB.IN, cos(a) * r)
		cs.rotation.y = a
		body.add_child(cs)
		_mesh_box(cs.position, sh.size, a, mat)

func _mesh_box(pos: Vector3, size: Vector3, yaw: float, mat: StandardMaterial3D) -> void:
	var bm := BoxMesh.new()
	bm.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = bm
	mi.position = pos
	mi.rotation.y = yaw
	mi.material_override = mat
	add_child(mi)

# ------------------------------------------------------------------ scoring --

func scoring_elements() -> Array:
	var out: Array = []
	for b in volume.get_overlapping_bodies():
		if b is GameElement and not (b as GameElement).held_by:
			out.append(b)
	return out

## OWNER = alliance of the TOP-MOST scoring NECTAR (S10.5.2). No nectar, no owner.
func owner_alliance() -> int:
	var best: GameElement = null
	for e: GameElement in scoring_elements():
		if e.kind != BB.Kind.NECTAR:
			continue
		if best == null or e.global_position.y > best.global_position.y:
			best = e
	return best.alliance if best else -1

## Bottom NECTAR Bonus: 5 to the alliance of the BOTTOM-MOST scoring NECTAR.
func bottom_nectar_alliance() -> int:
	var best: GameElement = null
	for e: GameElement in scoring_elements():
		if e.kind != BB.Kind.NECTAR:
			continue
		if best == null or e.global_position.y < best.global_position.y:
			best = e
	return best.alliance if best else -1

## Where a shot has to land to score here.
func aim_point() -> Vector3:
	return global_position + Vector3(0, (BB.FLOWER_TOP_Y + 3.0) * BB.IN, 0)
