extends Node
func _ready() -> void:
	var bad := 0
	for d in ["res://scripts/net/", "res://scripts/", "res://tools/"]:
		for f in DirAccess.get_files_at(d):
			if not f.ends_with(".gd") or f.begins_with("_chk"):
				continue
			var s: GDScript = load(d + f)
			if s == null or not s.can_instantiate():
				print("BAD ", d + f)
				bad += 1
	print("checked, bad=", bad)
	get_tree().quit()
