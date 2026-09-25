class_name ReplayBranch
extends RefCounted
##
## "PRACTISE FROM HERE": A RECORDED CHECKPOINT BECOMES A SAVED SITUATION.
##
## The checkpoint is already a complete Snapshot.capture() of the world, taken
## on a recorded tick — robot poses and velocities, mechanisms, hoppers,
## batteries, the clock and scoreboard, the hives mid-swing, every AI's config
## AND its runtime state (route position, current target, time left on a
## wait), the human players' queue and autonomous playback. Nothing is
## simulated forward and nothing is reset: what was recorded is what is saved.
##
## THREE DELIBERATE CHANGES, and only these:
##   1. The new situation is FREE PRACTICE. The historical scoreboard and the
##      recorded clock reading stay as the starting state, but nothing counts
##      down and nothing ends.
##   2. It has NO OBJECTIVE. The run it was cut from may have been one point
##      from its goal; inheriting that would hand out a free success. Add an
##      objective in the editor if you want one — it measures from zero, like
##      every objective, because attempts take their baseline when they start.
##   3. It remembers where it came from (`origin`), for the library's note.
##      The replay itself is never written to.
##

## "" when this checkpoint can become a situation, otherwise why not.
static func refusal(cp: Dictionary) -> String:
	if cp.is_empty():
		return "That checkpoint is damaged and cannot be restored."
	if Snapshot.validate(cp) != "":
		return Snapshot.validate(cp)
	var phase := int(cp.get("match", {}).get("phase", BB.Phase.PRE))
	if phase == BB.Phase.SETTLE or phase == BB.Phase.DONE:
		return ("This moment is after the buzzer, while the field settles. "
			+ "Pick a moment before the end of the match.")
	if phase == BB.Phase.PRE:
		return "This moment is before the match started."
	return ""

static func make_situation(cp: Dictionary, replay_id: String, replay_title: String) -> Dictionary:
	var snap := cp.duplicate(true)
	var t := float(snap.get("replay_t", 0.0))
	snap.erase("replay_t")
	snap.erase("objective")
	snap.erase("meta")
	var setup: Dictionary = snap.get("setup", {})
	var m: Dictionary = snap.get("match", {})
	var original_mode := int(m.get("mode", setup.get("mode", BB.Mode.FULL_MATCH)))
	setup["mode"] = BB.Mode.FREE_PRACTICE
	m["mode"] = BB.Mode.FREE_PRACTICE
	snap["setup"] = setup
	snap["match"] = m
	snap["origin"] = {
		"kind": "replay",
		"replay_id": replay_id,
		"replay_title": replay_title,
		"replay_t": t,
		"phase": int(m.get("phase", BB.Phase.TELEOP)),
		"match_clock": float(m.get("time_left", 0.0)),
		"original_mode": original_mode,
	}
	return snap

## Short, factual lines describing a checkpoint, for the save card.
static func summary(cp: Dictionary) -> Array:
	var out: Array = []
	var m: Dictionary = cp.get("match", {})
	var setup: Dictionary = cp.get("setup", {})
	var phase := int(m.get("phase", BB.Phase.TELEOP))
	var names := ["Pre-match", "Autonomous", "Transition", "Teleop", "Settling", "Finished"]
	var mode := int(m.get("mode", setup.get("mode", BB.Mode.FULL_MATCH)))
	if mode == BB.Mode.FREE_PRACTICE:
		out.append("%s · free practice (no clock)" % names[clampi(phase, 0, 5)])
	else:
		out.append("%s · %s left on the recorded match clock" % [
			names[clampi(phase, 0, 5)], BB.clock_text(float(m.get("time_left", 0.0)))])
	for r in cp.get("robots", []):
		var lin := Snapshot.unpack_v3(r.get("lin", []))
		var line := "%s (%s) — %d in the hopper, battery %.1f V, moving %.0f in/s" % [
			String(r.get("label", "robot")),
			BB.alliance_name(int(r.get("alliance", 0))),
			(r.get("hopper", []) as Array).size(),
			float(r.get("battery_v", BB.BATTERY_NOMINAL)),
			Vector2(lin.x, lin.z).length() / BB.IN]
		var br: Variant = r.get("brain")
		if br is Dictionary:
			var cfg := OpponentConfig.from_brain(br)
			var st := String((br as Dictionary).get("status", ""))
			line += " · %s%s" % [OpponentConfig.describe(cfg),
				(", " + st) if st != "" else ""]
		out.append(line)
	var flying := Objective.count_in_flight(cp)
	if flying > 0:
		out.append(("%d ball%s in the air at this moment and will keep flying. "
			% [flying, "" if flying == 1 else "s are"])
			+ "If you add an objective: " + Objective.FLIGHT_RULE_SHOTS + " "
			+ Objective.FLIGHT_RULE_POINTS)
	var auto: Dictionary = cp.get("auto", {})
	if bool(auto.get("playing", false)):
		out.append("Autonomous routine \"%s\" was %.1f s in and carries on from there." % [
			String(auto.get("routine", "")), float(auto.get("t", 0.0))])
	out.append("Saved as Free practice with no objective. Add one in the editor if you want a goal.")
	return out
