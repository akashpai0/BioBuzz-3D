# Online practice rooms — player-hosted

Private rooms so a team can practise together from different places: driver and
operator on one robot, two robots on one alliance, or a full 2 v 2 with people or
configurable AI on every robot. **One player's game hosts the room** — nobody
rents, runs or pays for a server. No accounts, no public matchmaking, no global
leaderboard, no voice chat, no cloud replays.

## Status — read this first

| | |
|---|---|
| **Implemented** | Hosting from inside the game (the host's world is the room's simulation), invites, admission, lobby, seats and roles, scenario sharing, ready / start / pause / retry, reconnection, host-leaves-ends-the-session, online replays in each player's local library. Internet transport and room lookup through **Epic Online Services** via the EOSG plugin; a same-network (LAN) transport for play at one site and for the tests. |
| **Simulated tests** | Bad connections modelled inside the game (added delay, jitter, loss) on one machine; and the **EOS path's own logic** (anonymous login, publishing the room, looking it up from an invite, refusing closed / locked / different-build rooms, the relay setting) run against *stand-ins with EOSG's API* — not against Epic. |
| **Local tests** | Real separate programs on one machine over the same-network (ENet) path: a full copy of the game **hosts from inside itself** and drives with its keyboard while another program joins with the invite and operates the same robot; the full rule checklist; a full 8-player room; load and responsiveness. All pass (below). |
| **Actual internet tests** | **NOT DONE.** EOS has never run for real: this workspace can't reach Epic's servers, can't download the EOS SDK, and has no Epic credentials. Nothing has crossed two home routers yet. The prototype test in **"Internet test (do this first)"** below is what's outstanding, and it needs the developer-portal setup, which needs your Epic account. |

Until that setup is done, **Over the internet** says plainly that this build
doesn't have Epic Online Services, and **Same network only** and offline play
work as normal.

---

## How it works

```
 HOST'S GAME                                         GUEST'S GAME
 ┌──────────────────────────────┐                   ┌───────────────────────┐
 │ its own world = THE room     │   EOS P2P         │ puppet world, drawn   │
 │  physics · AI · clocks ·     │◀═════════════════▶│ from the host's       │
 │  scoring · objectives ·      │  direct (punched  │ snapshots             │
 │  retries · recording         │  through both     │                       │
 │ NetRoomServer ◀─in-process─▶ │  routers) or via  │ sends only its seat's │
 │ the host's own seat          │  Epic's relay     │ inputs                │
 └──────────────┬───────────────┘                   └───────────┬───────────┘
                │ publishes                    looks up by id   │
                ▼                                               │
        Epic lobby service: a directory entry  ◀────────────────┘
        (build, room name, locked, players — never the secret)
```

- **Authority.** The host's running game is the only simulation: physics,
  mechanisms, ball ownership, AI opponents, clocks, scores, fouls, objectives,
  results and coordinated retries. The host plays through an in-process link to
  their own room, exactly like a guest — same validation, same input path.
  Guests send only what their seat may press, 60 times a second, and draw the
  host's snapshots a little behind the newest. No client prediction: nothing a
  guest sees is a guess.
- **Discovery — how an invite finds the room.** When you host over the
  internet, the game logs in to Epic anonymously (see *Player authentication*),
  creates an **EOS lobby** as a directory entry — build, room name, locked, player
  count — and starts listening on an **EOS P2P socket**. The invite is
  `BBZ1-E.<lobby id>.<host's player id>.<secret>`. A guest's game **searches
  Epic's lobby service for that lobby id** (it never joins the lobby — joining
  it would grant nothing anyway), checks it's open, unlocked and the same build,
  checks the lobby's owner is the host named in the invite, then opens an EOS P2P
  connection to the host. (If the lookup itself errors, the game still tries the
  host named in the invite; the host's secret check is the gate either way.) EOS tries a direct path through both routers first and
  falls back to **Epic's relay** when it can't.
- **Admission — who gets in.** The secret (26 characters, ~128 bits, from the
  OS's secure random source) never goes into the lobby; it only travels in the
  invite. The host's game compares it (constant time) before admitting anyone,
  then checks build, lock and capacity. Wrong secret → refused and disconnected.
  A new room makes a new secret, so an old invite dies with its room.
- **Why not just a code or plain Godot networking?** A plain Godot ENet
  connection can't reach a game behind a home router unless the host forwards a
  port, and a short code needs a service somewhere to turn it into an address.
  EOS provides both the lookup and the router traversal (with relay fallback),
  free, with no server of ours. The invite is long because it carries everything
  needed — it's meant to be copied and pasted, not typed.
- **Same network only** (`BBZ1-L.<address>:<port>.<secret>`) is plain ENet to the
  host's LAN address. It works at one school or house and is what the local tests
  use; it does not cross home routers and is labelled as such in the game.
- **Transport details.** Channels: control (reliable), input (unreliable), state
  (unreliable), bulk (reliable: scenarios, replay chunks). EOS P2P carries at most
  1170 bytes a packet (1164 after EOSG's header); anything larger — scenarios,
  replay chunks, a snapshot of a very full field — is split and reassembled by
  the game, and the same limit is enforced on the LAN path so the tests exercise
  it.
- **Pausing never stops the network.** A shared pause halts the scene tree on
  the host; the room, its links, menus — and EOSG's own runtime, which the game
  sets to keep processing — keep running. The **host's personal menu** (Esc)
  pauses nobody: it makes the host's own seat neutral and tells everyone.

---

## For players

**Play → Online practice.**

- **Host a room** — name the room, choose **Over the internet** or **Same
  network only**, press **Host room**. Your game now runs the practice for
  everyone: keep it open, and it's best on a computer with a decent upload (see
  *Host requirements*). **Copy invite** and paste it to your team (Discord, text…).
- **Join a room** — paste the invite (the **Paste** button reads the clipboard)
  and press **Join**. Clear errors for: not an invite, a typo, a room that has
  ended, a locked room, a full room (8 people), a different game build, a host
  that doesn't answer, and a build without Epic Online Services.
- **Relay (for testing a connection)** — *Automatic* for play; *Always relay*
  proves the relay path; *Never relay* shows whether a direct path exists.

### The lobby

Every robot (alliance, number, AI or human), its seats and who holds them;
everyone in the room with their ping as the host measures it and how their
connection travels (**direct**, **via Epic relay**, same network, hosting); the
scenario summary; who is ready.

- **Seats.** A robot is either **Whole robot** or split into **Driver** +
  **Operator**. Four robots × two seats = 8 human seats. The host's game grants
  seats one request at a time, so two people can never hold the same role.
  Taking a seat clears everyone's Ready.

  | Role | Controls |
  |---|---|
  | Driver | drive stick, turn, precision, *slow* (held), *field-centric* toggle |
  | Operator | intake off, turret left/right, hood up/down, power up/down, fire, *outtake*, *aim assist* toggle, *recalibrate* |
  | Whole robot | both |
  | Nobody (always local) | camera, menus, your controller's device and profile |

  Field-centric belongs to the driver, aim assist to the operator. Your own
  controller profile shapes your input on your computer before it is sent; your
  device IDs never leave it. The host's game ignores (and counts) anything
  outside your role.
- **Robots.** The host switches any robot between people and AI. Standard setups
  start with your alliance as people and opponents as AI.
- **Scenario.** The host picks a standard setup or shares a saved situation
  (objective, robot profiles, opponent configuration included). Everyone sees a
  summary; every computer must confirm the same revision before Ready; any change
  clears Ready. Scenarios are untrusted data: size-limited, structure- and
  range-checked on the host and on every guest, no scripts, resources or paths.
  **Save scenario locally** adds a new situation, never overwriting one of yours.
  Custom CAD models aren't shared: online, robots are drawn with the built-in
  model and the lobby says so; the simulated profile is the shared one.
- **Host controls:** Lock joining, remove a player, **Low upload** (see below),
  **End session**.

### During a run

- **Your menu (Esc) doesn't pause anyone** — host included. Your seat goes
  neutral and everyone sees it.
- **Request pause / request retry** — anyone can ask; the host decides.
- **Pause** freezes physics, mechanisms, AI (including an opponent mid-wait),
  clocks and objective timers for everyone; networking and menus stay live.
- **Retry** finalises the attempt once, restores the starting state exactly
  (opponent waits included), clears everyone's held controls, starts a new run
  number so late packets from the old run are ignored, waits for every seated
  player's game to confirm, then one shared countdown. A key already held when
  the countdown ends is ignored until you let go.
- **Changing seats mid-run** needs a pause, then fresh Ready from those affected.

### Connection problems

| What happens | Rule |
|---|---|
| Your inputs stop arriving | After **250 ms** the host's game sets your seat to neutral. |
| Nothing at all arrives from someone for 8 s | Treated as disconnected, whatever the transport says. |
| A seated guest disconnects | The room pauses, naming the person, robot and role. Nobody is replaced by AI. |
| They're back within **60 s** | Same seat, automatically (a per-player token); fresh state; controls must return to neutral before they count. The host resumes. |
| They don't come back | Their seat is freed; the host can wait, give it to someone else, or end the session. |
| Someone joins mid-run | They watch; they can take a seat in the lobby or during a pause. |
| **The host leaves** | The session ends for everyone with a message; every player keeps their replays. The lobby entry is removed and the invite stops working. No host migration. |
| **The host's game crashes or loses its connection** | Guests keep trying to reconnect for 60 s, then return to the menu with "Lost the connection to the host" and a replay marked incomplete. |

### Replays

Every online run is recorded by the host's game from its own state and streamed
to each player, whose game writes it into their normal local collection
(Progress → Replays → **Online practice**), labelled with the room and roster.
**Practise from here** works offline later, with seats reassigned to your
controller. Late joins, drop-outs and missing chunks are labelled; branching only
uses checkpoints that arrived whole. A full disk stops your copy and tells you;
the session carries on. Nothing is uploaded anywhere.

---

## Set up Epic Online Services (once, needs your Epic account)

Everything below is free. Nothing here is a paid service. **Who does it:** the
person who builds the game for the team. Epic's developer agreement is accepted
when you create an organization — read its eligibility terms; if you're not able
to accept it yourself (for example because of age), your team's mentor or a
parent can own the organization and add you.

### 1. Developer portal

1. Sign in at **dev.epicgames.com/portal** and create an **Organization** (e.g.
   "FTC 506 Pandara").
2. **Create Product** → name it "BioBuzz3D".
3. **Product Settings → Clients → Add new client.**
   - **Client policy:** create a **Custom policy**. Turn on **User required**. In
     *Features*, enable only **Connect**, **Lobbies** and **P2P** (with their
     actions allowed). Leave everything else off — every copy of the game carries
     this client's credentials, so it should be able to do only what it needs.
   - Save; note the **Client ID** and **Client Secret**.
4. **Product Settings → SDK Download & Credentials** (sometimes shown as
   *Product Settings → General*): note the **Product ID**, the **Sandbox ID** and
   **Deployment ID** you'll use. The *Development* sandbox is fine for your
   team's practice.
5. You do **not** need: Epic Account Services, brand review, an Epic Games Store
   listing, identity-provider setup, or any payment details. Players never sign
   in to Epic (see below).

### 2. The plugin (EOSG) — in the Godot editor

1. **AssetLib** → search **EOSG** → *Epic Online Services Godot (EOSG)* by
   3ddelano → Download → Install. (Or download the latest release zip from
   `github.com/3ddelano/epic-online-services-godot/releases` and copy
   `addons/epic-online-services-godot` into this project's `addons/`.) Use
   **2.3.1 or newer**: that release is the one that states support for Godot 4.5
   (built with godot-cpp 4.5).
2. **Project → Project Settings → Plugins** → enable **Epic Online Services Godot**.
   Restart the editor. (This adds the plugin's autoloads to `project.godot`.)
3. Check `addons/epic-online-services-godot/bin/windows/` contains
   **`EOSSDK-Win64-Shipping.dll`**. If it doesn't, download the **EOS C SDK** from
   the portal's *SDK Download* page (the version named in the plugin's README) and
   copy that DLL from its `SDK/Bin/` folder into that `bin/windows/` folder.

### 3. Credentials

Copy `eos_credentials.example.cfg` to **`eos_credentials.cfg`** next to
`project.godot` and fill in the five IDs from step 1. The export presets already
include that file. (To test without re-exporting, the same file can go in the
game's user folder: `%APPDATA%\Godot\app_userdata\BIOBUZZ 3D\`.) The client
secret ends up inside every copy of the game — that's how EOS game clients work,
which is why the client policy above grants so little.

### 4. Export and share

Export **Windows Desktop** as before. With the plugin, the export is the `.exe`
**plus DLLs next to it** (the plugin's library and Epic's SDK) — zip the whole
folder when you share it. Everyone in a room needs the same build.

### Player authentication

None visible. Each game logs in to EOS's **Connect** interface with a **Device
ID** credential: an anonymous ID made on first use and kept on that computer, so
the same computer keeps the same player id. No Epic account, no password, no
sign-in window, no email. What passes through Epic: that anonymous id, the
display name typed in the game, the room's directory entry, and — when a
connection is relayed — the game traffic itself. The game sends nothing else.

---

## Internet test (do this first)

This is the prototype check that has **not** been done. Two computers on
**different internet connections** (e.g. home broadband and a phone hotspot — not
the same Wi-Fi), both with the EOS-enabled build.

1. **Direct.** Both set Relay → *Never relay*. A hosts (**Over the internet**),
   copies the invite, B joins. In the lobby, B's row should read **direct**. A
   takes Driver, B takes Operator on robot 1; start; A drives while B fires. If it
   won't connect at all, that pair of networks can't make a direct path — fine,
   that's what the relay is for.
2. **Relay.** Both set *Always relay*, repeat. The row should read **via Epic
   relay**; driving and firing still work, a bit later.
3. **Automatic** (normal play): note which one it picked.
4. In any of them: host **pauses** (B's game keeps its connection line live);
   host opens their **own menu** (nothing freezes for B); **Retry** together; pull
   B's network for ~10 s and plug it back (B returns to the same seat); host ends
   the session (B gets the message; both have the replay).
5. Then a full room: 2 v 2, split roles, from several homes.

Write down for each: connected? direct or relayed? ping shown? anything odd. If
something fails, the game's log (`%APPDATA%\Godot\app_userdata\BIOBUZZ 3D\logs\`)
has EOS's own messages.

If Windows asks whether to allow BioBuzz3D through the firewall, allow it — the
host needs to accept incoming peer-to-peer packets.

---

## Host requirements

Measured on a 2-vCPU Intel Xeon @ 2.1 GHz container with the host running
**headless** (simulation and networking only — a real host also draws the game on
screen) and 8 players on the same machine. Full room = 2 v 2, all four robots
human, all split driver/operator.

| | |
|---|---|
| Host CPU for the room | **≈ 68 % of one core** (physics ≈ 4.1 ms per 180 Hz tick, room logic ≈ 0.16 ms), plus drawing the game |
| Host memory | ≈ 200 MB for the game (a room adds little) |
| Host **upload** | **≈ 60 KB/s ≈ 0.5 Mbit/s per guest** — a full room of 7 guests ≈ 3.4–3.8 Mbit/s |
| Host download | ≈ 1.3 KB/s per guest |
| Idle (lobby / paused) | ≈ 8 % of one core |

**Upload is the host's real limit.** Home connections often upload far less than
they download. With 1–3 guests almost anything works; for a full room pick the
teammate with the best upload, or turn on **Low upload** in the lobby: 30
snapshots a second instead of 60, about half the traffic, and guests draw the
field a little further behind. Epic's relay adds a hop; Epic doesn't publish
per-relay throughput limits that I could find.

## Measured responsiveness (simulated conditions)

Full 8-player room, 30 s per condition, conditions **simulated inside each
player's game** on one machine (added one-way delay each direction, jitter,
loss each way) — a model, not the internet. "2 cm" = first snapshot in which the
robot has moved 2 cm after the stick is pushed from rest. Offline the same push
takes **166 ms** (that's acceleration, and it's in every figure).

| Condition | Ping | Input → host applied | Input → 2 cm in a snapshot | Guest draw delay | ≈ Input → guest's screen |
|---|---|---|---|---|---|
| Loopback | 8 ms | 22 ms | 180 ms | 43 ms | ≈ 220 ms |
| RTT +30 ms, ±3 ms | 43 ms | 70 ms | 222 ms | 50 ms | ≈ 270 ms |
| RTT +60 ms, ±8 ms, 2 % loss | 76 ms | 97 ms | 242 ms | 61 ms | ≈ 300 ms |
| RTT +100 ms, ±15 ms, 5 % loss | 124 ms | 125 ms | 290 ms | 62 ms | ≈ 350 ms |
| RTT +200 ms, ±30 ms, 10 % loss | 218 ms | 228 ms | 388 ms | 84 ms | ≈ 470 ms |

(Medians of 11 trials.) The **host** has no network delay at all for their own
seat. Snapshots kept arriving at 54–60 a second at up to 10 % loss.
**Reconnecting** at RTT +100 ms with 5 % loss: back in the same seat with fresh
state in 117–156 ms after the network returns (5 of 5, same seat).

---

## Test record

| Test | Kind | What it proves | Result |
|---|---|---|---|
| `tools/debug_net_link.tscn` | local + simulated | the transport: no datagram over 1164 bytes; a 300 KB message arrives whole; reliable order kept; big unreliable messages whole-or-nothing — on the in-process link and real ENet sockets, with and without simulated loss | 18 / 18 |
| `tools/debug_net_2proc.tscn` | **local, separate programs** | **the prototype:** a full game hosts from inside itself and drives with its keyboard; a separate program joins with the invite and operates the same robot; identical state in both; host's own menu doesn't freeze anyone; shared pause halts the world but not the network; retry together; host leaving ends the session and the guest is told; no-EOS build says why instead of breaking | 29 / 29 (28 / 28 five runs in a row, then + the host's end message) |
| `tools/debug_net_smoke.tscn` | local | headless host + two players sharing one robot | 9 / 9 |
| `tools/debug_net_client.tscn` | local | the real guest client: puppet world, keyboard drive, personal menu, pause, retry, replay saved, replay-disk failure, **host's game killed** → menu, replay kept | 28 / 28 |
| `tools/debug_net.tscn -- write` / `-- read` | local | the full checklist (below) with protocol players against a hosted room, then a cold start that plays the online replays offline | 75 + 6 |
| `tools/debug_net_eos_sim.tscn` | **simulated EOS**, two programs | NetEOS + NetClient's internet code against EOSG stand-ins: persistent anonymous login, room published (secret not in it), found from the invite by a second program, forced relay shown as relayed, locked / forged / different-build / ended rooms refused with a sentence | 16 / 16 |
| `tools/perf_net.tscn` | simulated conditions | the numbers above | — |
| offline suite (36 runs) + `debug_replay` write/read | local | offline play unchanged | 36 / 36 exit 0, replay 2 / 2 |
| exported Linux build, `--host-test` | local | the shipped program boots and hosts a room | invite written |

The checklist: wrong build refused; wrong secret refused and dropped; garbled
invites refused; host-only commands refused for players; 8 kinds of malformed
scenario refused; valid scenario reaches everyone; competing seat requests — one
wins; driver's fire does nothing, operator's stick does nothing, both at once
work; pause freezes an AI mid-wait; retry restores the wait exactly, new run,
old-run packets ignored; low upload halves the snapshot rate and is host-only;
frozen input cleared after 250 ms; disconnect pauses naming the seat; reconnect
to the same seat; a stick held from before the drop doesn't drive; grace expiry
frees the seat, not given to AI; reassign; lock; remove; two rooms can't see each
other; everyone gets the same result; every player keeps their replays; host
leaving ends the session and kills the invite; online replays survive a restart
and branch offline.

## Outstanding

1. **Epic setup** (above) — needs your account.
2. **The internet test** — two separate connections, direct and relayed. Until
   it's done, nothing here is proven across real routers.
3. **Windows ↔ Windows** hasn't run at all (everything here was Linux).
4. **Host migration** — deliberately not in this version.
5. **A physical controller** has still never been connected to any build.

Sources used for the EOS design: the EOSG repository (source read directly),
its 2.3.1 release notes, and Epic's Online Services product page (free use).
