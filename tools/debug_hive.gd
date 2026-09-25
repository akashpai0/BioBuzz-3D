extends Node3D
## One-shot diagnostic: does the load actually land in the CELL, and is the
## swing free to move at all? Detent torque is zeroed, so it MUST move.
var field: Field
var hive: Hive
var t := 0.0

func _ready() -> void:
	field = Field.new(); add_child(field); field.build()
	hive = field.hives[BB.Alliance.RED]
	hive.set_tilt(-1)
	await get_tree().physics_frame
	var cell := hive.up_cell()
	print("cell origin y_in = %.1f" % (cell.global_position.y / BB.IN))
	for i in 8:
		var e := GameElement.make(BB.Kind.POLLEN)
		add_child(e)
		e.global_position = cell.global_transform * (Vector3(
			(float(i % 4) - 1.5) * 4.2,
			-BB.CELL_HEIGHT * 0.5 + 1.8 + float(i / 4) * 3.2,
			(float(i % 2) - 0.5) * 4.2) * BB.IN)
	print("spawned 8 pollen")

func _physics_process(d: float) -> void:
	t += d
	if fmod(t, 0.5) < d:
		var probe: GameElement = null
		for e in get_tree().get_nodes_in_group("element"):
			probe = e
			break
		if probe:
			print("   ball: contacts=%d sleeping=%s y=%.2f in  v=%.3f  layer=%d mask=%d" % [
				probe.get_contact_count(), str(probe.sleeping), probe.fz(),
				probe.linear_velocity.length(), probe.collision_layer, probe.collision_mask])
		print("t=%.1f angle=%6.2f omega=%.3f in_cell=%d mass=%.4f/%.4f hold=%.2f tips=%d" % [
			t, rad_to_deg(hive.angle()), hive.swing.angular_velocity.x,
			hive.up_cell_elements().size(), hive.cell_mass(hive.up_cell()), BB.TIP_MASS,
			hive.hold_torque, hive.tip_count])
	# probe: is the hinge free at all, and which way does the load push?
	if t > 5.0 and t < 7.0:
		hive.swing.apply_torque(Vector3(0.5, 0, 0))
		if fmod(t, 0.5) < d:
			print("  +0.5 Nm -> omega %.4f  angle %.2f" % [
				hive.swing.angular_velocity.x, rad_to_deg(hive.angle())])
	if t > 7.0 and t < 9.0:
		hive.swing.apply_torque(Vector3(-0.5, 0, 0))
		if fmod(t, 0.5) < d:
			print("  -0.5 Nm -> omega %.4f  angle %.2f" % [
				hive.swing.angular_velocity.x, rad_to_deg(hive.angle())])
	if t > 9.0:
		print("swing: mass=%.2f freeze=%s sleeping=%s can_sleep=%s" % [
			hive.swing.mass, str(hive.swing.freeze), str(hive.swing.sleeping),
			str(hive.swing.can_sleep)])
		get_tree().quit()
