extends Node
## Leaderboard behaviour: best-run-per-variant, two separate tables, and the
## share code round-tripping between two players.
var fails := 0

func _ok(label: String, got, want) -> void:
	var good: bool = got == want
	if not good:
		fails += 1
	print("  %s %-52s got %s   want %s" % ["PASS" if good else "FAIL", label, str(got), str(want)])

func _ready() -> void:
	print("\n--- LEADERBOARD ---")
	# start from nothing
	Leaderboard.save_all([])
	Leaderboard.set_player_name("Julian")
	_ok("signed in", Leaderboard.signed_in(), true)
	_ok("name stored", Leaderboard.player_name(), "Julian")

	Leaderboard.submit("Julian", 120, 1, "FULL MATCH")
	Leaderboard.submit("Julian", 95, 1, "FULL MATCH")      # worse: must not replace
	Leaderboard.submit("Julian", 160, 2, "TELEOP")         # other variant: its own row
	var one := Leaderboard.table(1)
	var two := Leaderboard.table(2)
	_ok("one row per variant for a player", one.size() + two.size(), 2)
	_ok("keeps the BEST one-intake run", int(one[0]["points"]), 120)
	_ok("two-intake run is on its own table", int(two[0]["points"]), 160)

	Leaderboard.submit("Julian", 210, 1, "FULL MATCH")     # better: must replace
	_ok("a better run replaces the old one", int(Leaderboard.table(1)[0]["points"]), 210)

	# --- another player's board, shared across as a code
	var mine := Leaderboard.to_code()
	Leaderboard.save_all([])
	Leaderboard.set_player_name("Teammate")
	Leaderboard.submit("Teammate", 175, 1, "FULL MATCH")
	var merged := Leaderboard.merge_code(mine)
	_ok("merging a share code added the other player", merged >= 2, true)
	var board := Leaderboard.table(1)
	_ok("both players are on the one-intake table", board.size(), 2)
	_ok("sorted best first", int(board[0]["points"]), 210)
	_ok("and the runner-up below", int(board[1]["points"]), 175)
	_ok("rubbish is rejected, not crashed on", Leaderboard.merge_code("not-a-code"), -1)

	# leave a believable board behind for the screenshot
	Leaderboard.save_all([])
	Leaderboard.set_player_name("Julian")
	for row in [["Julian", 212, 1], ["Pandara 506", 188, 1], ["Ava", 151, 1],
			["Julian", 243, 2], ["Marcus", 205, 2], ["Pandara 506", 166, 2]]:
		Leaderboard.submit(row[0], row[1], row[2], "FULL MATCH")

	print("\n  %s  (%d failures)" % ["LEADERBOARD OK" if fails == 0 else "PROBLEMS", fails])
	get_tree().quit(1 if fails > 0 else 0)
