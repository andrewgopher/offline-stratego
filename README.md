# Offline Barrage

A native macOS app for the classic hidden-rank battle game in its 8-piece **Barrage** form, played
between two Macs sitting next to each other with **no internet and no Wi-Fi network**, for example
on a plane.

The Macs talk directly over **peer-to-peer Wi-Fi**, the same radio link AirDrop uses
(Apple's MultipeerConnectivity / AWDL). The Wi-Fi radio has to be **on**, but it doesn't need to
join any network. Airplane mode lets you switch Wi-Fi back on.

## Features

- Automatic discovery of nearby Macs running the app: no pairing codes or IP addresses
- Challenge a player; the challenger picks **Red / Blue / Random** and a clock. The other player
  gets an Accept/Decline prompt. Red moves first.
- **Setup** by dragging pieces from a tray onto your four back rows (or click a piece, then a
  square). **Random** and **Clear** buttons, and a library of **saved setups** that work for either
  color. The last setup you used comes back automatically.
- **Hidden ranks, no referee**: neither Mac ever receives the other's unrevealed ranks (see below).
- Full rules, including the ISF **two-squares rule** and **chasing (more-squares) rule**. Blocked
  moves are marked on the board and explained when you try them.
- **Memory aids**: ranks revealed in battle (or by a Scout's long move) stay visible; every piece
  that has moved is marked (so it's not a Bomb or the Flag); your own pieces whose rank the
  opponent knows are marked; each player's army roster shows which pieces have been captured.
- A battle card shows both ranks and the outcome after every attack.
- **Chess-style clock** (time bank plus increment per move, presets or custom, or no clock).
  Setup isn't timed; clocks start after Red's first move and pause if the connection drops.
- **Draw offers**, **resign**, **rematch** (sides swapped), and **chat**
- When the game ends, both armies are revealed and the whole game is **checked** against them.
  Step through the game with every rank shown (**post-game replay**), also later from the lobby.
- Games **auto-save**. If the connection drops, the app reconnects on its own; unfinished games
  can be resumed later, even after quitting the app.
- Sounds, with a toggle

## Rules (Barrage)

- 10×10 board with two 2×2 lakes (C5–D6 and G5–H6). Each side has 8 pieces: Marshal (10),
  General (9), Miner (3), two Scouts (2), Spy (S), Bomb (B), Flag (F). They may stand on any square
  of the owner's four back rows.
- Pieces move one square up, down, left or right; never diagonally, never into a lake. Scouts move
  any distance in a straight line over empty squares and may attack at the end of the move.
  Bombs and the Flag never move.
- Attacking reveals both pieces. The higher rank wins and the loser is removed; equal ranks are
  both removed. The Spy beats the Marshal only when the Spy attacks. Any piece attacking the Bomb
  is removed and the Bomb stays, except a Miner, which defuses it. Attacking the Flag wins.
- **Two-squares rule (ISF)**: a piece may not move back and forth between the same two squares
  more than 5 times in a row, whatever the opponent does. For Scouts, every square passed over
  counts, so consecutive overlapping moves along one line count as shuttling.
- **Chasing rule (ISF more-squares rule)**: if your piece moves next to an enemy piece and the
  opponent moves that piece away, your next move that threatens it again may not recreate a
  position that has already occurred. Stepping the chasing piece straight back to the square it
  just came from is always allowed (the two-squares rule still applies).
- A player with no legal move on their turn (including moves blocked by those rules) loses. If
  neither side has any piece that can move, the game is a draw.

## Build

Requirements: macOS 13 Ventura or later, and Xcode 15+ **or** just the Command Line Tools
(`xcode-select --install`).

```sh
./scripts/build-app.sh
open dist/OfflineBarrage.app
```

This produces a universal (Apple silicon + Intel) `dist/OfflineBarrage.app` and
`dist/OfflineBarrage.zip`, ad-hoc signed. You can also open `Package.swift` in Xcode and run the
`OfflineBarrage` scheme.

### Getting it onto the second Mac

Do this **before the flight**, or on the plane over AirDrop (AirDrop works offline too).

- **Easiest:** clone the repo and run `./scripts/build-app.sh` on each Mac.
- **Or copy** `OfflineBarrage.zip` to the other Mac. The app isn't notarized, so macOS blocks it the
  first time. Either run `xattr -dr com.apple.quarantine /path/to/OfflineBarrage.app`, or try to
  open it, then go to **System Settings → Privacy & Security** and click **Open Anyway**.

### First launch

Launch the app once on each Mac before you need it. macOS will ask:

- **"Allow Offline Barrage to find devices on local networks?"** Click **Allow**. Without it, the
  Macs can't see each other. You can change it later in System Settings → Privacy & Security → Local Network.
- If the firewall asks whether to accept incoming connections, click **Allow**.

## Playing on a plane

1. Turn Wi-Fi **on** on both Macs (Control Center → Wi-Fi). Don't join the in-flight network.
2. Open Offline Barrage on both. Each Mac shows up under **Nearby players** on the other.
3. Click **Challenge…**, pick your side and clock, and send it. The other player accepts.
4. Arrange your army and press **Ready**. The game starts once both players are ready.
5. Click one of your pieces to see where it can go, then click the destination (or drag it).

If the connection drops mid-game (lid closed, out of range…), both clocks pause and the app keeps
trying to reconnect. If one player goes back to the lobby, the game stays saved under
**Unfinished games**; click **Resume** when you're both ready.

## How hidden ranks work without a referee

Each Mac only ever holds its own ranks plus the ranks that have legitimately been revealed, so
looking at the other Mac's messages or at your own saved game files doesn't give anything away.

- When you press **Ready**, your Mac picks a random secret (nonce) for every piece and computes a
  hash commitment `SHA-256(game, piece, rank, nonce)` per piece. It sends only a single hash of all
  of them, which hides even which squares you used.
- Once both players are ready, each Mac sends its per-piece commitments (checked against that
  hash). Now both know where the pieces stand, but not what they are.
- An attack carries the attacker's rank and nonce; the defender's Mac answers with the defender's
  rank and nonce. Both are checked against the commitments, so nobody can change a rank after the
  setup. A Scout moving more than one square reveals itself the same way.
- A player with no legal move declares it, since only their Mac knows its ranks.
- When the game ends, both Macs reveal their whole army. Each replays the full game with every rank
  known and checks that every move was legal, that the army is a standard Barrage army, and that
  any "no legal move" claim was true. The result is shown under the game's outcome.

### How the two Macs stay in sync

- Both Macs run the same `Match` state machine. Each player is authoritative for **their own
  moves, ranks and clock**: a move message carries the mover's remaining time, and only the owner
  of a clock can declare that it ran out.
- Every received move is validated (movement, the repetition rules, and any rank proof) and
  tagged with its move number; stale messages are ignored.
- On every (re)connect the Macs exchange a snapshot that contains only public information and run
  the same deterministic merge: the longer move history wins when one extends the other, each side
  keeps its own clock, results like resignations carry over, chat is unioned, and anything the
  other side is missing (a lock-in, commitments, a rank owed for a battle) is sent again. This
  recovers a move or a battle that was in flight when the connection dropped.
- Saved games live in `~/Library/Application Support/OfflineBarrage/Games/` as JSON, and saved
  setups in `~/Library/Application Support/OfflineBarrage/Setups.json`.

## Project layout

```
Package.swift
Sources/BarrageCore/      Pure Swift (Foundation + CryptoKit), unit-tested
  Board.swift               sides, squares, lakes, ranks, piece IDs
  Game.swift                moves, positions, battles, replay with partial rank knowledge
  Rules.swift               movement, battle outcomes, two-squares and chasing rules
  Setup.swift               arranging an army, saved setups
  Commitments.swift         hash commitments that keep setups secret
  Clock.swift               time controls and a deterministic two-sided clock
  Protocol.swift            wire messages, invitations, snapshots, results
  Match.swift               the per-Mac game state machine (setup exchange, moves, reveals, sync/merge)
Sources/PeerKit/          PeerService: MultipeerConnectivity discovery + one encrypted 1:1 link
Sources/OfflineBarrage/   macOS app (SwiftUI)
  AppModel.swift            app state; glues UI ⇄ Match ⇄ PeerService; persistence
  LobbyView / ChallengeViews / GameView / BoardViews / PieceViews
  DemoSnapshots.swift       debug-only: renders the UI in demo states to PNG files
Sources/PeerSmokeTest/    headless tool: two copies find each other and play a short game
Tests/BarrageCoreTests/   rules, repetition rules, commitments, two-Mac protocol simulations
Support/Info.plist        bundle metadata, Local Network usage text and Bonjour service types
scripts/                  build-app.sh (packages the .app), test.sh (runs the tests)
```

## Tests

```sh
./scripts/test.sh
```

The tests use Swift Testing. With a full Xcode install `swift test` works too; with only the
Command Line Tools, `scripts/test.sh` adds the framework paths SwiftPM needs.

To check the peer-to-peer link without the UI, run two copies of the smoke-test tool on one Mac,
or one copy on each of two Macs:

```sh
swift build -c release --product PeerSmokeTest
.build/release/PeerSmokeTest guest &
.build/release/PeerSmokeTest host     # prints PASS when the scripted game completes
```

### Two copies on one Mac

`OFFLINE_BARRAGE_PROFILE` gives a copy its own identity, settings and saved games, so you can
play against yourself on one Mac:

```sh
swift build
OFFLINE_BARRAGE_PROFILE=one .build/debug/OfflineBarrage &
OFFLINE_BARRAGE_PROFILE=two .build/debug/OfflineBarrage &
```

### UI snapshots

Debug builds can render the real UI in a series of demo states (lobby, setup, mid-game, battle,
Blue's view, game over, history, plus dark mode) without going online:

```sh
swift build
OFFLINE_BARRAGE_PROFILE=snapshots OFFLINE_BARRAGE_SNAPSHOTS=/tmp/barrage-snaps .build/debug/OfflineBarrage
```
