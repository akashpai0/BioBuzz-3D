extends Node
##
## IS THE SOUND ACTUALLY THERE?
##
## Nothing here can listen, so this checks the things that go wrong silently
## with generated audio: a buffer that came out all zeros, a looping sample
## whose ends do not meet (an audible tick every cycle), clipping, and DC
## offset (which sounds like nothing and eats headroom).
##
var fails := 0

## Sounds that must loop seamlessly.
const LOOPING := ["crowd", "intake", "flywheel", "drive"]
## Sounds that are one-shots.
const ONESHOT := ["shot", "pollen", "nectar", "wall", "intake_grab", "tip",
	"buzzer", "start", "foul", "click", "select"]

func _ready() -> void:
	await get_tree().process_frame
	print("\n--- GENERATED AUDIO ---")
	for name in LOOPING + ONESHOT:
		_check(name, LOOPING.has(name))

	# the mixer has to exist before the settings screen can drive it
	_ok("SFX bus exists", AudioServer.get_bus_index(SFX.BUS_SFX) >= 0, true)
	_ok("AMBIENCE bus exists", AudioServer.get_bus_index(SFX.BUS_AMB) >= 0, true)
	SFX.set_volume(SFX.BUS_SFX, 0.5)
	_ok("volume round-trips", absf(SFX.get_volume(SFX.BUS_SFX) - 0.5) < 0.02, true)
	SFX.set_volume(SFX.BUS_SFX, 0.0)
	_ok("zero mutes rather than sending -inf",
		AudioServer.is_bus_mute(AudioServer.get_bus_index(SFX.BUS_SFX)), true)
	SFX.set_volume(SFX.BUS_SFX, 0.9)

	print("  %s  (%d failures)" % [
		"AUDIO OK" if fails == 0 else "AUDIO PROBLEMS", fails])
	get_tree().quit(1 if fails > 0 else 0)

func _check(name: String, looping: bool) -> void:
	var st: AudioStreamWAV = SFX._streams.get(name)
	if st == null:
		_ok("%s exists" % name, false, true)
		return
	var n := st.data.size() / 2
	var peak := 0.0
	var sum := 0.0
	var energy := 0.0
	for i in n:
		var v := float(st.data.decode_s16(i * 2)) / 32768.0
		peak = maxf(peak, absf(v))
		sum += v
		energy += v * v
	var dc := sum / float(n)
	var rms := sqrt(energy / float(n))

	var label := name.rpad(12)
	var good := true
	if peak < 0.02:
		good = false
		print("    %s SILENT" % label)
	if peak > 0.999:
		good = false
		print("    %s CLIPPING" % label)
	if absf(dc) > 0.05:
		good = false
		print("    %s DC OFFSET %.3f" % [label, dc])
	if looping:
		if st.loop_mode != AudioStreamWAV.LOOP_FORWARD:
			good = false
			print("    %s NOT MARKED LOOPING" % label)
		# a loop whose first and last samples are far apart ticks once a cycle
		var first := float(st.data.decode_s16(0)) / 32768.0
		var last := float(st.data.decode_s16((n - 1) * 2)) / 32768.0
		if absf(first - last) > 0.35:
			good = false
			print("    %s SEAM %.3f -> %.3f" % [label, first, last])
	_ok("%s  %.2fs  peak %.2f  rms %.3f" % [label, float(n) / float(SFX.RATE), peak, rms],
		good, true)

func _ok(label: String, got, want) -> void:
	var good: bool = got == want
	if not good:
		fails += 1
	print("  %s %s" % ["PASS" if good else "FAIL", label])
