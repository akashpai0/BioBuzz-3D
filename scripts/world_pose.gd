class_name WorldPose
extends RefCounted
##
## POSE THE FIELD FROM RECORDED OR RECEIVED STATE. Presentation only.
##
## Shared by the replay viewer and the online client: both hold rows in the
## ReplayRecorder layout and both must draw them the same way. Poses between
## two rows are interpolated for smooth motion, except across a discontinuity
## — a ball changing owner, or a jump too large to be motion — where the
## earlier row is held. Nothing here writes game state; the bodies it moves
## are frozen and the world around them is halted.
##

const SNAP_ROBOT_M := 0.5
const SNAP_ELEMENT_M := 0.6

## `nodes` = {robots: Array, hives: Array, elements: Array} in row order.
static func apply(nodes: Dictionary, fa: PackedFloat32Array, oa: int,
		fb: PackedFloat32Array, ob: int, alpha: float, have_b: bool,
		n_r: int, n_h: int, n_e: int) -> void:
	var robots: Array = nodes.get("robots", [])
	var hives: Array = nodes.get("hives", [])
	var elements: Array = nodes.get("elements", [])
	var o := ReplayRecorder.HEAD
	for i in n_r:
		var ro := oa + o
		var pa := Vector3(fa[ro], fa[ro + 1], fa[ro + 2])
		var qa := _q(fa, ro + 3)
		var yaw := fa[ro + 7]
		var hood := fa[ro + 8]
		if have_b:
			var rb := ob + o
			var pb := Vector3(fb[rb], fb[rb + 1], fb[rb + 2])
			if pa.distance_to(pb) < SNAP_ROBOT_M:
				pa = pa.lerp(pb, alpha)
				qa = qa.slerp(_q(fb, rb + 3), alpha)
				yaw = lerp_angle(yaw, fb[rb + 7], alpha)
				hood = lerpf(hood, fb[rb + 8], alpha)
		if i < robots.size() and is_instance_valid(robots[i]):
			var rob: Robot = robots[i]
			rob.global_transform = Transform3D(Basis(qa), pa)
			if rob.turret:
				rob.turret.rotation.y = yaw
			if rob.hood:
				rob.hood.rotation.x = deg_to_rad(hood)
		o += ReplayRecorder.PER_ROBOT
	for hi in n_h:
		var ho := oa + o
		var hp := Vector3(fa[ho], fa[ho + 1], fa[ho + 2])
		var hq := _q(fa, ho + 3)
		if have_b:
			var hb := ob + o
			hp = hp.lerp(Vector3(fb[hb], fb[hb + 1], fb[hb + 2]), alpha)
			hq = hq.slerp(_q(fb, hb + 3), alpha)
		if hi < hives.size() and hives[hi] != null and is_instance_valid(hives[hi]):
			(hives[hi] as Hive).swing.global_transform = Transform3D(Basis(hq), hp)
		o += ReplayRecorder.PER_HIVE
	for k in n_e:
		var eo := oa + o
		o += ReplayRecorder.PER_ELEMENT
		if k >= elements.size():
			continue
		var e: Variant = elements[k]
		if e == null or not is_instance_valid(e):
			continue
		var el: GameElement = e
		var holder := int(fa[eo + 7])
		var ep := Vector3(fa[eo], fa[eo + 1], fa[eo + 2])
		if holder <= -2:
			# with a human player, out of play: not on the field to be seen.
			# Still placed at its recorded spot, so the picture depends on the
			# row alone and never on what was drawn before.
			el.visible = false
			el.global_transform = Transform3D(Basis.IDENTITY, ep)
			continue
		el.visible = true
		var eq := _q(fa, eo + 3)
		if have_b:
			var ebo := ob + (eo - oa)
			if int(fb[ebo + 7]) == holder:
				var epb := Vector3(fb[ebo], fb[ebo + 1], fb[ebo + 2])
				if ep.distance_to(epb) < SNAP_ELEMENT_M:
					ep = ep.lerp(epb, alpha)
					eq = eq.slerp(_q(fb, ebo + 3), alpha)
		el.global_transform = Transform3D(Basis(eq), ep)

static func _q(f: PackedFloat32Array, o: int) -> Quaternion:
	var q := Quaternion(f[o], f[o + 1], f[o + 2], f[o + 3])
	if q.length_squared() < 0.0001:
		return Quaternion.IDENTITY
	return q.normalized()

## Nodes of the current world in row order: robots in roster order, hives red
## then blue, elements by the id the restore gave them.
static func index(main: Node) -> Dictionary:
	var robots: Array = []
	for r in main.robots:
		robots.append(r)
	var by_sid := {}
	for n in main.get_tree().get_nodes_in_group("element"):
		if is_instance_valid(n) and not n.is_queued_for_deletion():
			by_sid[String(n.get_meta("sid", ""))] = n
	var ids := by_sid.keys()
	ids.sort()
	var els: Array = []
	for k in ids:
		els.append(by_sid[k])
	return {"robots": robots,
		"hives": [main.field.hives[BB.Alliance.RED], main.field.hives[BB.Alliance.BLUE]],
		"elements": els}
