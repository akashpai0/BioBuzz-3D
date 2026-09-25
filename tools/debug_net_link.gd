extends Node
## THE TRANSPORT UNDER EVERY ROOM, ON ITS OWN.
##
## EOS peer-to-peer packets are at most 1170 bytes (1164 after EOSG's header),
## so NetLink splits anything larger and joins it back together. This checks,
## on the in-process link and on real ENet sockets on 127.0.0.1, with and
## without a simulated lossy connection:
##   - no datagram handed to a transport is ever larger than 1164 bytes
##   - a 300 KB reliable message (a big scenario) arrives whole and in order
##   - reliable messages keep their order even with jitter
##   - a large UNRELIABLE message (a snapshot of a very full field) is either
##     delivered whole or not at all, never corrupted or half-assembled
##     (real ENet also drops some of a 180-datagram burst on its own: that is
##     what "unreliable" means, and why snapshots are sent 60 times a second)
## Simulated conditions only; not the internet.
var fails := 0
var checks := 0

func _ok(what: String, got: Variant, want: Variant = true) -> void:
	checks += 1
	var good: bool = got == want
	if not good:
		fails += 1
	print("  [%s] %s%s" % ["ok" if good else "FAIL", what, "" if good else "  (got %s, want %s)" % [got, want]])

func _ready() -> void:
	for mode in ["loop", "enet"]:
		for sim in ["", "40,15,0.05"]:
			print("\n--- %s%s ---" % [mode, (" with simulated 40 ms ±15, 5 % loss each way" if sim != "" else "")])
			var pair := await _pair(mode)
			var srv: NetLink = pair[0]
			var cli: NetLink = pair[1]
			if sim != "":
				srv.set_sim(sim)
				cli.set_sim(sim)
			var peer_at_server: int = pair[2]
			var rng := RandomNumberGenerator.new()
			rng.seed = 7
			var big := PackedByteArray()
			big.resize(300 * 1024)
			for i in big.size():
				big[i] = rng.randi() & 0xFF
			var seqs: Array = []
			for k in 20:
				var m := PackedByteArray([k])
				m.resize(1 + (k * 523) % 4000)
				m[0] = k
				seqs.append(m)
			cli.send(1, NetLink.CH_BULK, big)
			for m2 in seqs:
				cli.send(1, NetLink.CH_CONTROL, m2)
			var unrel_sent := 0
			for u in 60:
				var um := PackedByteArray()
				um.resize(2500)
				um.encode_u32(0, u)
				for j in range(4, um.size()):
					um[j] = (u * 7 + j) & 0xFF
				srv.send(peer_at_server, NetLink.CH_STATE, um)
				unrel_sent += 1
			var got_big := PackedByteArray()
			var got_order: Array = []
			var got_unrel: Array = []
			var corrupt := 0
			var t0 := Time.get_ticks_msec()
			while Time.get_ticks_msec() - t0 < 6000 and (got_big.is_empty() or got_order.size() < 20):
				for e in srv.poll():
					if String(e["type"]) == "packet":
						var d: PackedByteArray = e["data"]
						if int(e["channel"]) == NetLink.CH_BULK:
							got_big = d
						elif int(e["channel"]) == NetLink.CH_CONTROL:
							got_order.append(int(d[0]))
				for e2 in cli.poll():
					if String(e2["type"]) == "packet" and int(e2["channel"]) == NetLink.CH_STATE:
						var ud: PackedByteArray = e2["data"]
						var id := ud.decode_u32(0)
						for j in range(4, ud.size()):
							if ud[j] != (id * 7 + j) & 0xFF:
								corrupt += 1
								break
						got_unrel.append(id)
				await get_tree().process_frame
			var ordered := []
			for k2 in 20:
				ordered.append(k2)
			_ok("no datagram over 1164 bytes (largest %d / %d)" % [cli.max_datagram_seen, srv.max_datagram_seen],
				cli.max_datagram_seen <= NetLink.MAX_DATAGRAM and srv.max_datagram_seen <= NetLink.MAX_DATAGRAM, true)
			_ok("a 300 KB reliable message arrived whole (%d fragments)" % cli.fragments_out, got_big == big, true)
			_ok("20 reliable messages of mixed sizes kept their order", got_order, ordered)
			_ok("large unreliable messages: %d of %d arrived, none corrupted" % [got_unrel.size(), unrel_sent],
				corrupt == 0 and got_unrel.size() > 0 and got_unrel.size() <= unrel_sent
				and (sim != "" or mode != "loop" or got_unrel.size() == unrel_sent), true)
			if sim != "":
				_ok("  and with loss some were dropped whole, as a lost snapshot would be", got_unrel.size() < unrel_sent, true)
			srv.close()
			cli.close()
	print("  LINK %s (%d checks, %d failures)" % ["OK" if fails == 0 else "BROKEN", checks, fails])
	get_tree().quit(1 if fails > 0 else 0)

## [server end, client end, the client's peer id at the server]
func _pair(mode: String) -> Array:
	if mode == "loop":
		var lp := NetLink.loop_pair()
		(lp[0] as NetLink).poll()
		(lp[1] as NetLink).poll()
		return [lp[0], lp[1], 2]
	var port := 17800 + randi() % 100
	var s := NetLink.enet_server(port, 4)
	var c := NetLink.enet_client("127.0.0.1", port)
	var pid := -1
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 3000 and (pid < 0 or not c.connected()):
		for e in s.poll():
			if String(e["type"]) == "connect":
				pid = int(e["peer"])
		c.poll()
		await get_tree().process_frame
	return [s, c, pid]
