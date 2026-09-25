class_name NetBot
extends RefCounted
##
## A protocol-only player for the tests: a NetSession plus the automatic
## courtesies a real client performs (acknowledge the scenario, confirm a
## restored run once its first snapshot arrives). It has no game world; what
## it knows about the field is what the room sent it.
##

var s := NetSession.new()
var name := ""
var auto_restore_ack := true
var input := NetProto.neutral_input()
var presses := {}
var send_inputs := false
var acked_run := -1

func _init(n: String) -> void:
	name = n

## Join with a same-network invite (the tests' host listens on 127.0.0.1).
func join(invite: String, display := "") -> void:
	var inv := NetInvite.parse(invite)
	if not bool(inv.get("ok", false)):
		s.phase = "failed"
		s.error_reason = "invalid"
		s.error_text = String(inv.get("error", ""))
		return
	var addr := String(inv["address"])
	var port := int(inv["port"])
	s.connect_timeout_ms = 8000
	s.join(func() -> NetLink: return NetLink.enet_client(addr, port), String(inv["secret"]),
		display if display != "" else name)

## Join with a hand-made secret (tests of admission).
func join_with_secret(address: String, port: int, secret: String) -> void:
	s.connect_timeout_ms = 8000
	s.join(func() -> NetLink: return NetLink.enet_client(address, port), secret, name)

func poll() -> void:
	s.poll()
	if s.phase != "in_room":
		return
	var run := int(s.state.get("run", 0))
	if auto_restore_ack and String(s.state.get("state", "")) == "loading" \
			and acked_run != run and not s.snaps.is_empty():
		acked_run = run
		s.send(NetProto.RESTORE_ACK, {"run": run})
	if send_inputs:
		var v := input.duplicate(true)
		v["presses"] = presses.duplicate()
		s.send_input(v)

func press(action: String) -> void:
	presses[action] = (int(presses.get(action, 0)) + 1) & 0xFF

func hold(action: String, on: bool) -> void:
	(input["held"] as Dictionary)[action] = on

func latest() -> Dictionary:
	return s.snaps[-1] if not s.snaps.is_empty() else {}

## Robot r's position (m) and hopper count in the latest snapshot.
func robot_pos(r: int) -> Vector3:
	var sn := latest()
	if sn.is_empty():
		return Vector3.INF
	var row: PackedFloat32Array = sn["row"]
	var o := ReplayRecorder.HEAD + r * ReplayRecorder.PER_ROBOT
	return Vector3(row[o], row[o + 1], row[o + 2])

func robot_hopper(r: int) -> int:
	var sn := latest()
	if sn.is_empty():
		return -1
	var row: PackedFloat32Array = sn["row"]
	return int(row[ReplayRecorder.HEAD + r * ReplayRecorder.PER_ROBOT + 9])

func room_state() -> String:
	return String(s.state.get("state", ""))
