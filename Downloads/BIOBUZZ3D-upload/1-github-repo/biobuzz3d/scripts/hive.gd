class_name Hive
extends Node3D
##
## One HIVE: two same-colour CELLS on a bar through a pivot, bi-stable (S9.6).
##
## The TIP IS NOT SCRIPTED. The swing is a RigidBody3D on a hinge whose own
## centre of mass sits exactly on the pivot axis, so the only thing that can
## turn it is the weight of the POLLEN and NECTAR lying in the raised cell. A
## constant detent torque holds it over-centre; when the load torque beats the
## detent, it goes over and slams to the other stop — same as the real seesaw.
## Calibrated so a resting 8-POLLEN load tips an empty cell and 7 does not.
##

signal tipped(alliance: int, hive: Hive)
## An element arrived inside one of this HIVE's CELLS. Carries the element so a
## listener can ask who launched it — which is how a shot is counted as MADE
## rather than merely taken.
signal element_entered(e: GameElement, hive: Hive)

var alliance: int = BB.Alliance.RED
var swing: RigidBody3D
var hinge: HingeJoint3D
var cell_a: Area3D                  # local +Z cell
var cell_b: Area3D                  # local -Z cell
var hold_torque: float = BB.HIVE_HOLD_TORQUE

var _stable_sign: int = 1
var _armed: bool = true
var tip_count: int = 0
## Test hook only. Holds the catch shut no matter how heavy the load is, so a
## harness can let a load SETTLE and then release it on a known frame — the tip
## time is meaningless if it is measured from a ball still bouncing.
var gate_locked := false

const LIMIT := deg_to_rad(BB.HIVE_TILT)

var _anchor: StaticBody3D

static func make(a: int, anchor: StaticBody3D) -> Hive:
	var h := Hive.new()
	h.alliance = a
	h._anchor = anchor
	h.name = "Hive" + BB.alliance_name(a)
	h._build()
	return h

func _build() -> void:
	var px := (-BB.HIVE_PIVOT_X if alliance == BB.Alliance.RED else BB.HIVE_PIVOT_X)
	position = BB.fp(px, 0.0, BB.HIVE_PIVOT_Y)

	swing = RigidBody3D.new()
	swing.name = "Swing"
	swing.mass = 7.0
	swing.angular_damp = BB.HIVE_ANGULAR_DAMP   # the real HIVE has dampers
	swing.linear_damp = 0.5
	swing.can_sleep = false
	swing.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	swing.center_of_mass = Vector3.ZERO      # balanced on the pivot, by construction
	# Jolt wants the mask relationship to be mutual: without LAYER_ELEMENT here
	# the load rests in the CELL but never presses on it, and the hive cannot be
	# tipped by anything at all.
	swing.set_collision_mask_value(BB.LAYER_ELEMENT, true)
	# The elements are bouncy on purpose — they are plastic balls on a foam mat.
	# A CELL, though, has to SWALLOW a shot rather than spit it back out, so its
	# material is absorbent: Godot subtracts this bounciness from the ball's
	# instead of adding it, leaving a shot that arrives and stays.
	var cell_pm := PhysicsMaterial.new()
	cell_pm.friction = 0.92
	cell_pm.bounce = BB.ELEMENT_BOUNCE - 0.04
	cell_pm.absorbent = true
	swing.physics_material_override = cell_pm
	add_child(swing)

	# the connecting bar
	_box(swing, Vector3.ZERO, Vector3(3.0, 1.5, BB.CELL_OUTER * 2.0), BB.C_FRAME)

	cell_a = _cell(+1)
	cell_b = _cell(-1)

	hinge = HingeJoint3D.new()
	hinge.name = "Pivot"
	# the joint's own Z axis IS the hinge axis; turn it to run along world X
	hinge.rotation.y = PI * 0.5
	add_child(hinge)
	hinge.set_flag(HingeJoint3D.FLAG_USE_LIMIT, true)
	hinge.set_param(HingeJoint3D.PARAM_LIMIT_UPPER, LIMIT)
	hinge.set_param(HingeJoint3D.PARAM_LIMIT_LOWER, -LIMIT)
	# (bias / softness / relaxation are Godot-Physics-only knobs; Jolt's hinge
	# limits are hard stops already, which is what a real damper behaves like)

## Node paths only resolve once everything is in the tree, so the joint is wired
## here rather than in _build().
func _ready() -> void:
	hinge.node_a = hinge.get_path_to(_anchor)
	hinge.node_b = hinge.get_path_to(swing)
	set_tilt(BB.STAGED_TILT[alliance])

## Build one CELL.
##
## The real CELL is a closed box, 20 wide x 14 tall x 12 deep, with ONE opening:
## the 20 x 14 face perpendicular to the bar at the outer end. Raised, that
## mouth points up-and-outboard, so a shot has to arrive from outboard of the
## cell travelling toward the pivot and drop through the mouth. Lowered, the
## same mouth points down-and-outboard and the load falls out of it on its own,
## which is the TIP spill in G409. Floor, roof, both sides and the inner end are
## all solid: there is no shooting in through the top.
func _cell(dir: int) -> Area3D:
	var cz := BB.CELL_CENTRE * dir
	var w := BB.CELL_WIDTH
	var d := BB.CELL_DEPTH
	var h := BB.CELL_HEIGHT
	var t := BB.CELL_SHELL
	var c := BB.alliance_colour(alliance)
	var inner_z := cz - dir * (d * 0.5)          # the closed end, toward the pivot
	var mid_y := h * 0.5

	# The ROOF carries the alliance colour, because from a driver's view and from
	# the overhead camera the roof is the face you actually see; the walls stay
	# dark so the cell reads as a box rather than a slab.
	_box(swing, Vector3(0, -t * 0.5, cz), Vector3(w + t * 2, t, d), BB.C_FRAME)        # floor
	_box(swing, Vector3(0, h + t * 0.5, cz), Vector3(w + t * 2, t, d), c)              # roof
	_box(swing, Vector3(-(w + t) * 0.5, mid_y, cz), Vector3(t, h, d), BB.C_FRAME)      # side
	_box(swing, Vector3((w + t) * 0.5, mid_y, cz), Vector3(t, h, d), BB.C_FRAME)       # side
	_box(swing, Vector3(0, mid_y, inner_z - dir * t * 0.5), Vector3(w, h, t), c)       # inner end

	# A bright lip around the MOUTH. The mouth is the only way in, so it is the
	# single most important thing on the field to be able to find at a glance.
	var mouth_z := cz + dir * (d * 0.5)
	var lip := BB.C_POLLEN
	_box(swing, Vector3(0, h + t, mouth_z), Vector3(w + t * 2, t, t), lip)
	_box(swing, Vector3(0, -t, mouth_z), Vector3(w + t * 2, t, t), lip)
	_box(swing, Vector3(-(w + t) * 0.5, mid_y, mouth_z), Vector3(t, h + t * 2, t), lip)
	_box(swing, Vector3((w + t) * 0.5, mid_y, mouth_z), Vector3(t, h + t * 2, t), lip)

	var area := Area3D.new()
	area.name = "CellVolume" + ("A" if dir > 0 else "B")
	var box := BoxShape3D.new()
	box.size = Vector3(w - 1.0, h - 1.0, d - 1.0) * BB.IN
	var cs := CollisionShape3D.new()
	cs.shape = box
	area.add_child(cs)
	area.position = Vector3(0, mid_y * BB.IN, cz * BB.IN)
	area.monitorable = false
	# elements live on their own layer now, so every gameplay Area3D has to
	# mask that layer explicitly or it detects nothing at all
	area.collision_mask = 0
	area.set_collision_mask_value(BB.LAYER_ELEMENT, true)
	area.body_entered.connect(func(b: Node3D) -> void:
		# a ball appearing in a CELL because a saved situation is being
		# unpacked is not a shot going in
		if BB.frozen():
			return
		if b is GameElement:
			element_entered.emit(b as GameElement, self))
	swing.add_child(area)
	area.set_meta("dir", dir)
	return area

func _box(parent: Node, pos_in: Vector3, size_in: Vector3, col: Color) -> void:
	var sh := BoxShape3D.new()
	sh.size = size_in * BB.IN
	var cs := CollisionShape3D.new()
	cs.shape = sh
	cs.position = pos_in * BB.IN
	parent.add_child(cs)
	var mesh := BoxMesh.new()
	mesh.size = sh.size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = cs.position
	mi.material_override = BB.mat(col)
	parent.add_child(mi)

## Snap to a stable state without physics (staging, reset).
func set_tilt(sgn: int) -> void:
	_stable_sign = sgn
	var t := swing.global_transform
	t.basis = Basis(Vector3.RIGHT, LIMIT * sgn)
	swing.global_transform = t
	swing.linear_velocity = Vector3.ZERO
	swing.angular_velocity = Vector3.ZERO
	_armed = true

func angle() -> float:
	var f := swing.global_transform.basis.z
	return atan2(-f.y, f.z)

## The cell currently facing up, as an Area3D.
func up_cell() -> Area3D:
	return cell_a if angle() < 0.0 else cell_b

## Where a shot has to actually arrive: just inside the raised CELL's MOUTH.
## The mouth is the outer end face, so the point sits a few inches inboard of
## it on the cell's centreline — a shot that reaches here has come through the
## opening rather than off the roof or a side.
func aim_point() -> Vector3:
	var cell := up_cell()
	var dir: float = float(cell.get_meta("dir", 1))
	# Aim PAST the middle, toward the closed inner end. A ball that lands just
	# inside the mouth can bounce straight back out of it; one that carries to
	# the back of the box is trapped by the inner wall and by whatever is
	# already in there. The aperture check still guarantees it gets in.
	return cell.global_transform * Vector3(0.0, 0.0, -dir * BB.CELL_DEPTH * 0.18 * BB.IN)

## The arrival elevation this CELL's mouth wants, in degrees. The mouth faces
## outboard and 30 deg up, so a shot entering along its normal is descending at
## about 30 deg. A little steeper than that still gets in and is easier to hit,
## so the preference is biased slightly below the ideal.
func preferred_arrival() -> float:
	return -(BB.HIVE_TILT + 12.0)

## Everything the launcher needs to test whether a given arc actually fits
## through the raised CELL's mouth: the cell's frame, its interior size, and
## which way along local Z the opening faces.
func aperture() -> Dictionary:
	var cell := up_cell()
	return {
		"xform": cell.global_transform,
		"w": BB.CELL_WIDTH, "h": BB.CELL_HEIGHT, "d": BB.CELL_DEPTH,
		"dir": float(cell.get_meta("dir", 1)),
	}

## Outward normal of the raised CELL's mouth, in world space. A launch has to
## come from roughly this side of the cell to get in at all.
func mouth_normal() -> Vector3:
	var cell := up_cell()
	var dir: float = float(cell.get_meta("dir", 1))
	return (cell.global_transform.basis * Vector3(0, 0, dir)).normalized()

## Is this point on the open side of the mouth, i.e. can a shot from there reach
## the opening without going through the box? Generous cone, because a lobbed
## ball comes down steeply and only the horizontal bearing really matters.
func has_line_from(p: Vector3) -> bool:
	var to_shooter := p - aim_point()
	to_shooter.y = 0.0
	var n := mouth_normal()
	n.y = 0.0
	if to_shooter.length() < 0.01 or n.length() < 0.01:
		return true
	return to_shooter.normalized().dot(n.normalized()) > -0.10

## Total mass of the scoring elements sitting in a CELL, in kg.
func cell_mass(cell: Area3D) -> float:
	var m := 0.0
	for b in cell.get_overlapping_bodies():
		if b is GameElement and not (b as GameElement).held_by:
			m += (b as GameElement).mass
	return m

## How close the raised CELL is to letting go, 0..1. The HUD shows this so a
## driver can see how many more POLLEN it needs.
func tip_progress() -> float:
	return clampf(cell_mass(up_cell()) / BB.TIP_MASS, 0.0, 1.0)

func up_cell_elements() -> Array:
	var out: Array = []
	for b in up_cell().get_overlapping_bodies():
		if b is GameElement and not (b as GameElement).held_by:
			out.append(b)
	return out

func _physics_process(_d: float) -> void:
	if BB.frozen():
		return
	var a := angle()

	# THE TIP THRESHOLD IS A MASS, NOT A TORQUE.
	#
	# The real HIVE is ballast-calibrated to let go at 0.44 lb in the raised
	# CELL — 8 POLLEN, or 6 NECTAR, or any mix that reaches it. So that is what
	# is tested: the detent holds the seesaw solid while the load is under
	# BB.TIP_MASS and releases completely once it is over. The swing itself is
	# still real physics; only the release is a threshold, which is exactly how
	# an over-centre catch behaves.
	#
	# Letting the tip emerge from ball weight alone was the earlier design, and
	# it made the tip depend on WHERE in the cell the load happened to settle —
	# which is wrong against a hive that is calibrated to a number.
	# Tolerance matters here: 8 POLLEN sum to EXACTLY the threshold by
	# construction, so a bare >= lands on the wrong side of float rounding and
	# a full eight-ball load sits there doing nothing.
	var cell := up_cell()
	var load := cell_mass(cell)
	if load >= BB.TIP_MASS - BB.TIP_EPS and not gate_locked:
		hold_torque = 0.0
		# A SLEEPING rigid body stops pressing on what it is resting on, so a
		# settled load would sit in the cell contributing nothing and the hive
		# would never go over. Keep the load awake while the catch is released.
		for b in cell.get_overlapping_bodies():
			if b is GameElement:
				(b as GameElement).sleeping = false
	else:
		hold_torque = BB.HIVE_HOLD_TORQUE

	# Detent: torque pushing the swing AWAY from centre, so a load has to beat it
	# to get over the top. The PROFILE is what makes it snap rather than creep:
	#   outer half of the travel  -> full strength, so a sub-threshold load sags
	#                                a little and then stops, the way a real
	#                                seesaw sits against its damper;
	#   inner half                 -> falls away as sin() to exactly zero at
	#                                centre, which is the unstable point of any
	#                                over-centre mechanism.
	# So a load that beats `hold_torque` gets past half travel and then finds
	# less and less resisting it: it commits and goes over. That is snap-through,
	# and it is why `hold_torque` still means "the load needed to tip".
	var dir := signf(a) if absf(a) > 0.0005 else float(_stable_sign)
	var u := clampf(absf(a) / LIMIT, 0.0, 1.0)
	var shape := 1.0 if u >= 0.5 else sin(PI * u)
	var t := hold_torque * dir * shape
	swing.apply_torque(Vector3(t, 0.0, 0.0))

	# it has gone over the top and reached the far stop -> that is a TIP
	var s := signi(int(signf(a)))
	if _armed and s != 0 and s != _stable_sign and absf(a) > LIMIT - deg_to_rad(3.0):
		_stable_sign = s
		_armed = false
		tip_count += 1
		SFX.play_at("tip", swing.global_position, -3.0, randf_range(0.95, 1.05))
		tipped.emit(alliance, self)
	elif s == _stable_sign:
		_armed = true

# ============================================================== snapshots ====

## Everything about this HIVE that is not geometry: where the swing is, how
## fast it is moving, and the latch state that decides whether the next tip
## counts. Mid-motion is the interesting case — a hive caught halfway through
## a tip has to come back halfway through a tip.
func save_state() -> Dictionary:
	return {
		"alliance": alliance,
		"basis": Snapshot.pack_basis(swing.global_transform.basis),
		"origin": Snapshot.pack_v3(swing.global_transform.origin),
		"lin": Snapshot.pack_v3(swing.linear_velocity),
		"ang": Snapshot.pack_v3(swing.angular_velocity),
		"stable_sign": _stable_sign,
		"armed": _armed,
		"tip_count": tip_count,
		"gate_locked": gate_locked,
		"hold_torque": hold_torque,
	}

func apply_state(d: Dictionary) -> void:
	var t := Transform3D(
		Snapshot.unpack_basis(d.get("basis", [])),
		Snapshot.unpack_v3(d.get("origin", [])))
	# Frozen until the restore finishes, so the swing does not fall through
	# the angle it was saved at while the rest of the field is still loading.
	swing.freeze = true
	swing.global_transform = t
	swing.linear_velocity = Vector3.ZERO
	swing.angular_velocity = Vector3.ZERO
	_stable_sign = int(d.get("stable_sign", 1))
	_armed = bool(d.get("armed", true))
	tip_count = int(d.get("tip_count", 0))
	gate_locked = bool(d.get("gate_locked", false))
	hold_torque = float(d.get("hold_torque", BB.HIVE_HOLD_TORQUE))

## Let the swing move again, with the motion it was saved with.
func release_from_restore(d: Dictionary) -> void:
	swing.freeze = false
	swing.sleeping = false
	swing.linear_velocity = Snapshot.unpack_v3(d.get("lin", []))
	swing.angular_velocity = Snapshot.unpack_v3(d.get("ang", []))
