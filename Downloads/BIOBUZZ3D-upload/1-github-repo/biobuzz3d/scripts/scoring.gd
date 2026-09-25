class_name Scoring
extends RefCounted
##
## Table 10-2 (p91), implemented literally, and reported the way a real match
## report does: every line carries both the COUNT and the POINTS, because "6"
## next to CELL contents is meaningless unless you can also see it came from 3
## elements at 2 each.
##
## Nothing here mutates the world. It reads the field and returns a breakdown,
## so it can be called live for the HUD and again after the settle for the final
## result without the two disagreeing.
##

## Counters the MATCH fills in as things happen. Everything else is read off the
## field at the moment breakdown() is called.
var tips := {BB.Alliance.RED: 0, BB.Alliance.BLUE: 0}
var leave := {BB.Alliance.RED: 0, BB.Alliance.BLUE: 0}
var park_auto := {BB.Alliance.RED: 0, BB.Alliance.BLUE: 0}
var park_teleop := {BB.Alliance.RED: 0, BB.Alliance.BLUE: 0}
var fouls_against := {BB.Alliance.RED: 0, BB.Alliance.BLUE: 0}   # points awarded to the OTHER alliance

## The line items, in the order a match report prints them. Each is
##   [key, label, "count unit" or "" for a points-only row]
## and the results screen walks this rather than hard-coding its own list, so a
## new scoring element only has to be added once.
const REPORT := [
	["_h", "AUTONOMOUS", ""],
	["leave", "LEAVE", "robots"],
	["park_auto", "PARK", "robots"],
	["_h", "END OF MATCH", ""],
	["park_teleop", "PARK", "robots"],
	["_h", "HIVE", ""],
	["tips", "TIPS", "count"],
	["cell", "Up CELL contents", "elements"],
	["_h", "FLOWER", ""],
	["flower", "OWNED FLOWER", "elements"],
	["bottom", "Bottom NECTAR bonus", "FLOWERS"],
	["_h", "GARDEN", ""],
	["garden", "GARDEN", "elements"],
	["_h", "PENALTIES", ""],
	["foul", "Fouls awarded", ""],
]

## Which rows are only worth anything once the MATCH has ended and the field has
## stopped moving. S10.5.C says CELL contents are assessed "after all SCORING
## ELEMENTS and ROBOTS have come to rest at the conclusion of the MATCH", and
## the same is true of what is sitting in a FLOWER: a ball rattling down a tube
## at the buzzer has not scored yet. During play these read "--" rather than a
## number that is about to change.
const END_ONLY := ["cell", "flower", "bottom", "park_teleop"]

## `final` is true only once the MATCH is over and the field has settled.
func breakdown(field: Field, final := false) -> Dictionary:
	var out := {}
	for a in [BB.Alliance.RED, BB.Alliance.BLUE]:
		out[a] = {
			"leave_n": leave[a],              "leave": leave[a] * BB.PTS_LEAVE,
			"park_auto_n": park_auto[a],      "park_auto": park_auto[a] * BB.PTS_PARK,
			"park_teleop_n": 0,               "park_teleop": 0,
			"tips_n": tips[a],                "tips": tips[a] * BB.PTS_TIP,
			"cell_n": 0,                      "cell": 0,
			"flower_n": 0,                    "flower": 0,
			"bottom_n": 0,                    "bottom": 0,
			"garden_n": 0,                    "garden": 0,
			"foul_n": 0,                      "foul": fouls_against[_other(a)],
			"park": park_auto[a] * BB.PTS_PARK,     # HUD's combined PARK line
			"total": 0,
		}

	if final:
		for a in [BB.Alliance.RED, BB.Alliance.BLUE]:
			out[a]["park_teleop_n"] = park_teleop[a]
			out[a]["park_teleop"] = park_teleop[a] * BB.PTS_PARK
			out[a]["park"] = (park_auto[a] + park_teleop[a]) * BB.PTS_PARK

		# POLLEN / NECTAR left in an upward-facing CELL, 2 each
		for a in field.hives:
			var h: Hive = field.hives[a]
			var n := h.up_cell_elements().size()
			out[a]["cell_n"] = n
			out[a]["cell"] = n * BB.PTS_IN_CELL

		# FLOWERS: 2 per element to the OWNER, plus a 5 point bonus per FLOWER
		# whose bottom ring holds that alliance's NECTAR
		for f: Flower in field.flowers:
			var own := f.owner_alliance()
			if own >= 0:
				var n := f.scoring_elements().size()
				out[own]["flower_n"] += n
				out[own]["flower"] += n * BB.PTS_IN_OWNED_FLOWER
			var bot := f.bottom_nectar_alliance()
			if bot >= 0:
				out[bot]["bottom_n"] += 1
				out[bot]["bottom"] += BB.PTS_BOTTOM_NECTAR

	# GARDENS: 1 per element, to the GARDEN's colour whoever put it there.
	# Live all match, because a GARDEN is just a region of tile and nothing
	# about it is in flight at the buzzer.
	for e in field.get_tree().get_nodes_in_group("element"):
		var el: GameElement = e
		if el.held_by != null or el.fz() > 6.0:
			continue
		for a in [BB.Alliance.RED, BB.Alliance.BLUE]:
			if BB.rect_touches(BB.garden(a), el.fx(), el.fy(), el.radius_in):
				out[a]["garden_n"] += 1
				out[a]["garden"] += BB.PTS_GARDEN
				break

	for a in out:
		var t := 0
		for k in ["leave", "park_auto", "park_teleop", "tips", "cell",
				"flower", "bottom", "garden", "foul"]:
			t += int(out[a][k])
		out[a]["total"] = t
	return out

## Ranking points (Table 10-2/10-3, "all other events" thresholds), each with
## the number it was judged on so the report can show how close a miss was.
func ranking_points(a: int, b: Dictionary) -> Array:
	var rp: Array = []
	if int(b[a]["leave"]) + int(b[a]["park"]) >= 16:
		rp.append("SWARM")
	if tips[a] >= 7:
		rp.append("POLLINATOR 2")
	elif tips[a] >= 4:
		rp.append("POLLINATOR 1")
	return rp

## [name, earned, progress text] for every ranking point, earned or not — a
## report that only lists what you got does not tell you what to chase.
func rp_rows(a: int, b: Dictionary) -> Array:
	var swarm := int(b[a]["leave"]) + int(b[a]["park"])
	return [
		["SWARM", swarm >= 16, "%d / 16 LEAVE + PARK points" % swarm],
		["POLLINATOR 1", tips[a] >= 4, "%d / 4 TIPS" % tips[a]],
		["POLLINATOR 2", tips[a] >= 7, "%d / 7 TIPS" % tips[a]],
	]

func _other(a: int) -> int:
	return BB.Alliance.BLUE if a == BB.Alliance.RED else BB.Alliance.RED

# ============================================================== snapshots ====
#
# The scoreboard as plain data, for saved practice situations. Alliance-keyed
# dictionaries are packed as [red, blue] pairs: JSON turns integer keys into
# strings, and a pair survives the round trip without any of that.

static func _pair(d: Dictionary) -> Array:
	return [int(d[BB.Alliance.RED]), int(d[BB.Alliance.BLUE])]

static func _unpair(a: Variant) -> Dictionary:
	var arr: Array = a if a is Array and (a as Array).size() == 2 else [0, 0]
	return {BB.Alliance.RED: int(arr[0]), BB.Alliance.BLUE: int(arr[1])}

func save_state() -> Dictionary:
	return {
		"tips": _pair(tips), "leave": _pair(leave),
		"park_auto": _pair(park_auto), "park_teleop": _pair(park_teleop),
		"fouls_against": _pair(fouls_against),
	}

func apply_state(d: Dictionary) -> void:
	tips = _unpair(d.get("tips", [0, 0]))
	leave = _unpair(d.get("leave", [0, 0]))
	park_auto = _unpair(d.get("park_auto", [0, 0]))
	park_teleop = _unpair(d.get("park_teleop", [0, 0]))
	fouls_against = _unpair(d.get("fouls_against", [0, 0]))
