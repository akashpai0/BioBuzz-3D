class_name GameElement
extends RigidBody3D
##
## A POLLEN or a NECTAR: a real sphere with real mass.
##
## These are perforated plastic balls — pickleballs, essentially, which is what
## the real BIOBUZZ elements look like. Two consequences are modelled:
##   * they are drawn with the hole pattern, from one shared procedural texture
##     rather than hundreds of little hole meshes;
##   * they DO NOT WANDER. A ball that has slowed to a crawl while touching
##     something gets braked hard and is allowed to sleep, so the field stays
##     where the drivers left it instead of slowly drifting for the whole match.
##     Push one and it moves; leave it and it sits.
##

var kind: int = BB.Kind.POLLEN
var alliance: int = -1            # NECTAR only; POLLEN is neutral
var held_by: Node = null          # set while a robot has it in the hopper
var radius_in: float = BB.POLLEN_DIA * 0.5
var last_launcher: Node = null    # for the G410 / foul log

## Emitted when this element has left the FIELD. It is taken out of play at
## that moment and handed to the human player, who walks it back around the
## guardrail and feeds it in through their LOADING ZONE a few seconds later —
## MatchManager runs that clock. Carries the side it went out on.
signal exited_field(side: int, e: GameElement)

static var _tex_cache: Dictionary = {}
## Set by tools/calibrate.gd only, so the harness can sweep NECTAR mass without
## editing bb.gd between runs. Negative means "use the constant".
static var nectar_mass_override := -1.0

static func make(k: int, all_iance: int = -1) -> GameElement:
	var e := GameElement.new()
	e.kind = k
	e.alliance = all_iance
	e._build()
	return e

func _build() -> void:
	var is_nectar := kind == BB.Kind.NECTAR
	radius_in = (BB.NECTAR_DIA if is_nectar else BB.POLLEN_DIA) * 0.5
	var r := radius_in * BB.IN

	mass = BB.POLLEN_MASS
	if is_nectar:
		mass = nectar_mass_override if nectar_mass_override > 0.0 else BB.NECTAR_MASS
	continuous_cd = true                       # launched at 6+ m/s past 1 in walls
	max_contacts_reported = 6
	contact_monitor = true
	can_sleep = true
	sleeping = false
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = BB.ELEMENT_LINEAR_DAMP       # air; the aim solver models this
	angular_damp = BB.ELEMENT_ANGULAR_DAMP
	# own layer, so wheel raycasts can ignore elements (see BB.LAYER_ELEMENT)
	collision_layer = 0
	collision_mask = 0
	set_collision_layer_value(BB.LAYER_ELEMENT, true)
	set_collision_mask_value(BB.LAYER_WORLD, true)
	set_collision_mask_value(BB.LAYER_ELEMENT, true)
	add_to_group("element")
	add_to_group("nectar" if is_nectar else "pollen")

	var pm := PhysicsMaterial.new()
	pm.friction = BB.ELEMENT_FRICTION
	pm.bounce = BB.ELEMENT_BOUNCE
	physics_material_override = pm

	var shape := SphereShape3D.new()
	shape.radius = r
	var cs := CollisionShape3D.new()
	cs.shape = shape
	add_child(cs)

	var mesh := SphereMesh.new()
	mesh.radius = r
	mesh.height = r * 2.0
	mesh.radial_segments = 22
	mesh.rings = 14
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _ball_material(BB.C_POLLEN if not is_nectar else BB.alliance_colour(alliance))
	add_child(mi)

## One shared material per colour, with a procedurally drawn pickleball hole
## pattern baked into its albedo. Cheaper than real geometry by a mile.
static func _ball_material(c: Color) -> StandardMaterial3D:
	var key := c.to_html(false)
	if _tex_cache.has(key):
		return _tex_cache[key]

	var w := 256
	var h := 128
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	img.fill(c)
	var hole := c.darkened(0.62)
	# Staggered rows of holes, spaced so they stay roughly even once the
	# equirectangular UV is wrapped onto the sphere.
	var rows := 5
	for row in rows:
		var v := (float(row) + 0.5) / float(rows)
		var py := int(v * float(h))
		# fewer holes near the poles, where the UV is compressed
		var count := int(round(10.0 * sin(v * PI)))
		if count < 3:
			count = 3
		var offset := 0.5 if row % 2 == 1 else 0.0
		for i in count:
			var u := (float(i) + offset) / float(count)
			var px := int(u * float(w))
			var rad := int(6.0 * maxf(sin(v * PI), 0.35))
			for dy in range(-rad, rad + 1):
				for dx in range(-rad * 2, rad * 2 + 1):
					if float(dx * dx) / 4.0 + float(dy * dy) > float(rad * rad):
						continue
					img.set_pixel((px + dx + w) % w, clampi(py + dy, 0, h - 1), hole)

	var tex := ImageTexture.create_from_image(img)
	var sm := StandardMaterial3D.new()
	sm.albedo_texture = tex
	sm.albedo_color = Color.WHITE
	sm.roughness = 0.55
	sm.metallic = 0.0
	_tex_cache[key] = sm
	return sm

# ------------------------------------------------------------------- physics

func _physics_process(_d: float) -> void:
	# While a saved situation is being put back, balls are being placed rather
	# than played: no settling, no wall check (which would call a foul and send
	# a human to fetch them), and no impact noise.
	if BB.frozen():
		return
	if held_by != null or freeze:
		return
	_settle()
	_keep_in_bounds()
	_impact_sound()

## Kill the slow ROLL of a ball that is touching something, so the field stops
## creeping between shots.
##
## It brakes the HORIZONTAL velocity only. An earlier version scaled the whole
## velocity vector and quietly fought gravity: a ball dropped down a FLOWER
## reached an equilibrium against the brake and crawled down the tube at a
## constant few in/s instead of falling. Vertical motion is left alone.
## KNOCKS.
##
## Contact monitoring is already on for the physics, so the cheap thing to do
## is watch how hard this ball is being decelerated: a real impact shows up as
## a sudden drop in speed. Below a threshold nothing plays, which keeps a field
## of 56 balls resting on the tiles silent instead of buzzing.
##
## Each element also has its own small cooldown, so a ball rattling down a
## flower tube ticks a few times rather than screaming.
var _last_speed := 0.0
var _hit_cool := 0.0
func _impact_sound() -> void:
	var v := linear_velocity.length()
	_hit_cool = maxf(0.0, _hit_cool - get_physics_process_delta_time())
	var drop := _last_speed - v
	_last_speed = v
	if _hit_cool > 0.0 or drop < BB.m(9.0) or get_contact_count() == 0:
		return
	_hit_cool = 0.07
	# how hard, as 0..1 over a range from a nudge to a launched ball arriving
	var hard: float = clampf(drop / BB.m(70.0), 0.0, 1.0)
	SFX.play_at(
		"nectar" if kind == BB.Kind.NECTAR else "pollen",
		global_position,
		lerpf(-26.0, -8.0, hard),
		randf_range(0.88, 1.14) * (1.0 - hard * 0.18))

func _settle() -> void:
	if get_contact_count() == 0:
		return
	var v := linear_velocity
	var flat := Vector2(v.x, v.z)
	if flat.length() >= BB.m(BB.ELEMENT_REST_SPEED):
		return
	flat *= 0.55
	angular_velocity *= 0.45
	if flat.length() < BB.m(0.6) and absf(v.y) < BB.m(1.5):
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
	else:
		linear_velocity = Vector3(flat.x, v.y, flat.y)

## What happens when an element leaves the FIELD.
##
## It goes back to the nearest LOADING ZONE — the human player area — and is set
## down on the tiles there, the way a human player returns one at an event. It
## does NOT get parked in mid-air at the edge of the field, which is what the
## previous clamp did: it preserved the element's height, so a ball that sailed
## over the wall ended up hanging there.
##
## Falling through the floor is treated separately and silently: that is a
## physics glitch, not something a robot did, so it is recovered without a foul.
func _keep_in_bounds() -> void:
	var p := global_position
	# PAST THE WALL, not near it. The GARDEN strips run right up against the
	# perimeter (y = 70 to 72), so a threshold inside the field treats correctly
	# staged garden POLLEN as having escaped and "returns" them to a loading
	# zone — which is exactly what happened when this was FIELD_HALF - 1.
	var lim := BB.m(BB.FIELD_HALF + 2.5)
	var out_sideways := absf(p.x) > lim or absf(p.z) > lim
	var below := p.y < BB.m(-2.0)
	if not out_sideways and not below:
		return

	if below and not out_sideways:
		# glitch recovery, no foul: put it back on the tiles where it was
		global_position = Vector3(p.x, BB.m(radius_in + 0.5), p.z)
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
		return

	# Left the field. It does NOT reappear in the LOADING ZONE on the same
	# frame: a person has to fetch it. Park it out of play, tell the match
	# manager which side it went out on, and let the human clock put it back.
	var side: int = BB.Alliance.RED if fx() < 0.0 else BB.Alliance.BLUE
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	set_held(self)                  # held_by != null == out of play, unscored
	global_position = BB.fp(0.0, 0.0, -60.0)
	exited_field.emit(side, self)

# -------------------------------------------------------------------- state

func fx() -> float:
	return global_position.x / BB.IN

func fy() -> float:
	return -global_position.z / BB.IN

func fz() -> float:
	return global_position.y / BB.IN

func at_rest() -> bool:
	return linear_velocity.length() < 0.05 and angular_velocity.length() < 0.6

## Park it inside a robot hopper: no physics, no collisions, follows the slot.
func set_held(by: Node) -> void:
	held_by = by
	sleeping = false
	freeze = true
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	set_collision_layer_value(BB.LAYER_ELEMENT, false)
	set_collision_mask_value(BB.LAYER_WORLD, false)
	set_collision_mask_value(BB.LAYER_ELEMENT, false)

func release(at: Transform3D, impulse: Vector3) -> void:
	held_by = null
	set_collision_layer_value(BB.LAYER_ELEMENT, true)
	set_collision_mask_value(BB.LAYER_WORLD, true)
	set_collision_mask_value(BB.LAYER_ELEMENT, true)
	freeze = false
	sleeping = false
	global_transform = at
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	apply_central_impulse(impulse)
