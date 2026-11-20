# Offline Barrage

A native app for **Mac, iPhone and iPad** for the classic hidden-rank battle game in its 8-piece
**Barrage** form, played between devices sitting next to each other with **no internet and no
Wi-Fi network**, for example on a plane: **1v1** on two devices, or a bughouse-style **2v2** on
four (see [2v2](#2v2-four-players-two-boards)). Macs, iPhones and iPads all play with each other
(see [iPhone and iPad](#iphone-and-ipad)).

The devices talk directly over **peer-to-peer Wi-Fi**, the same radio link AirDrop uses
(Apple's MultipeerConnectivity / AWDL), plus Bluetooth on iPhone and iPad. The Wi-Fi radio has to
be **on**, but it doesn't need to join any network. Airplane mode lets you switch Wi-Fi back on.

## Features

- Automatic discovery of nearby Macs, iPhones and iPads running the app: no pairing codes or IP addresses
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
- **2v2 on four devices**: two boards, partners on opposite colors, captured pieces go to your
  partner, who can swap them in instead of moving. No memory aids in this mode.
- **iPhone and iPad** versions with layouts made for them; any mix of devices can play together.

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

## 2v2: four players, two boards

Inspired by chess bughouse, but different. The 1v1 game above is unchanged.

**Seats.** Team 1 is Red on board 1 and Blue on board 2; team 2 is the other two seats. Partners
play opposite colors on different boards, so a captured piece always has the color of the player
who receives it. Everyone sets up as in 1v1, and both boards start when all four are ready.

**Captures.** When a piece loses a battle, it goes to the reserve of the winner's partner on the
other board: if your Marshal takes a General, the General goes to your teammate. In a tie both
pieces go (each to the other side's partner). A piece that hits a Bomb goes to the Bomb owner's
partner, and a Bomb defused by a Miner goes to the Miner owner's partner.

**Swaps.** On your turn you either move, or **swap**: put a piece from your reserve in place of one
of your pieces on the board (any piece but the Flag, Bombs included). The replaced piece goes into
your own reserve. Your opponents only learn the two ranks, never which piece changed: your board
opponent sees *"An opponent's General in your game was replaced by a Scout"*, the other opponent
*"…in the other game…"*. Your partner sees exactly what happened. Everyone sees every reserve,
with ranks.

**What you see.** Both boards. Your own and your partner's pieces are face up; the opponents' are
face down. There are **no memory aids** in 2v2: a rank revealed in battle shows only on the battle
card, nothing marks moved pieces, and the move list appears only after the game. The last move on
each board stays highlighted.

**Clocks and waiting.** Every player has their own clock (2v2 always has one), and clocks run from
the start. If none of your pieces can move and you can't swap, you **wait** with your clock
running, and the app says *"You can't move: wait for your teammate"*. With an empty reserve you
wait for your partner to capture something for you. With only your Flag left, nothing can come in
at all (a swap replaces a piece on the board, and the Flag can't be swapped out), so you hold on
while your partner tries to win the match on their board before your clock runs out.

**Rules that carry over.** Movement, battles, the two-squares rule and the chasing rule apply on
each board as in 1v1. A swap counts as a turn that moves no piece, so it breaks a back-and-forth
sequence.

**The end.** The first board to finish decides the match: capturing a Flag wins for your team;
resigning or running out of time loses for it. A draw needs all four players to agree. Then all
four armies are revealed and every turn on both boards, swaps included, is checked.

### Starting a 2v2 game

1. All four open Offline Barrage with Wi-Fi on (as for 1v1). Any mix of Macs, iPhones and iPads works.
2. One player clicks **New 2v2 Game…** (it needs three other players nearby), picks who sits where
   (or **Shuffle Seats**) and a clock, and clicks **Send Invitations**.
3. The other three accept. Once all four devices are linked to each other, set up and press **Ready**.
4. To swap, click (or tap) a piece in your reserve (next to your name), then the piece of yours it
   replaces.

If anyone drops out, all clocks pause until all four are linked again. An unfinished 2v2 game can
be resumed from the lobby; the other players get a request to rejoin.

## iPhone and iPad

The same app runs on iPhone and iPad (iOS / iPadOS 16 or later), and every device plays with every
other: an iPhone can challenge a Mac, and a 2v2 table can mix Macs, iPhones and iPads. All of them
need to be built from the same version of the code (they check a protocol version).

- **iPhone** (portrait): the board sits between the two player bars, with tabs underneath for the
  game controls, the move list and the chat. In 2v2 your board is on top and your partner's board
  is a thumbnail underneath, next to both players' clocks and reserves; tap it for a full-size
  view. Swap notices and battles from the other board appear at the top of the screen.
- **iPad**: the Mac layout in landscape, the iPhone layout in portrait.
- Drag pieces or tap a piece and then a square, as on the Mac. Sounds become haptics plus a few
  quiet system sounds (one switch for both).
- The screen stays awake during a game. If you switch to another app or lock the phone, iOS
  suspends Offline Barrage, so it drops its links right away: everyone's clocks pause, as for any
  lost connection, and the game reconnects by itself when you come back. A 2v2 invitation that
  hasn't been accepted by everyone yet is called off instead.
- On a plane: in airplane mode, switch **Wi-Fi and Bluetooth** back on (Control Center).

### Installing on an iPhone or iPad

You need a Mac with **Xcode 16 or later** (free on the Mac App Store) and an Apple ID.

1. Open `iOS/OfflineBarrage.xcodeproj` in Xcode.
2. Select the **OfflineBarrage** target → **Signing & Capabilities** and pick your **Team** (add your
   Apple ID under Xcode → Settings → Accounts first if needed).
3. The bundle identifier is `local.offlinebarrage.ios`. Each Apple ID needs its own, so if Xcode
   says it isn't available (say, a friend already used it), add something of yours to it.
4. Connect the iPhone or iPad, choose it as the run destination and press **Run**. The first time,
   the device asks you to turn on **Developer Mode** (Settings → Privacy & Security) and to trust
   your developer certificate (Settings → General → VPN & Device Management).
5. On first launch, allow **Offline Barrage** to find devices on your local network (you can
   change it later in Settings → Privacy & Security → Local Network).

With a free Apple ID, an app installed this way stops opening after 7 days; run it from Xcode again
to renew it. A paid developer account makes it last a year and can hand it out over TestFlight.

The iOS app target compiles the same app sources as the Mac app (`Sources/OfflineBarrage`) and links
`BarrageCore` and `PeerKit` from the Swift package. The only platform-specific code is in
`Platform.swift`, the app entry point and a few `#if os(iOS)` blocks (going to the background,
keeping the screen awake).

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

### Hidden swaps in 2v2

The same commitments, with one addition: each swap starts a new **commitment epoch**. The swapper
announces the two ranks and sends fresh commitments (with new nonces) for *all* their pieces on
the board, so nobody can tell which commitment hides the new rank. Battles and Scout moves are
proven against the epoch in force at the time. When the game ends, each player reveals every
epoch, and all four Macs check that the army started as a standard Barrage army, that each swap
changed exactly one piece from the announced rank to the announced rank (never the Flag), that
the swapped-in piece was really in the reserve, and that every move was legal for the piece that
made it (a swapped-in Bomb can't move).

Partners send each other their current ranks directly, so team pieces are face up. Each Mac keeps
a direct, encrypted link to each of the other three, so those messages reach only the partner.

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
- In 2v2 each board's log is shared by all four Macs and only ever grows, so the same merge works:
  each turn is authored by the player to move on that board, and a swap names how much of the other
  board it relied on, so every Mac judges the reserve identically even when messages arrive out of
  order. If two boards end at almost the same moment, the earlier event counts. 2v2 games are saved
  in `~/Library/Application Support/OfflineBarrage/TeamGames/`.

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
  Team.swift                2v2: seats, teams, invitations, swaps, messages, snapshots
  TeamBoard.swift           2v2: one board's shared log replayed into positions
  TeamMatch.swift           2v2: the per-Mac state machine for four players and two boards
Sources/PeerKit/          PeerService: MultipeerConnectivity discovery + encrypted links (one per peer)
  TableLinks.swift          2v2: keeps a link to each of the other three players
Sources/OfflineBarrage/   the app (SwiftUI), for macOS and iOS
  AppModel.swift            app state; glues UI ⇄ Match ⇄ PeerService; persistence
  Platform.swift            what differs between Mac and iPhone/iPad (sounds, names, layout switch)
  CompactViews.swift        pieces of the stacked iPhone layouts (top bar, tabbed panel)
  AppModel+Team.swift       2v2 invitations, resuming and closing tables
  TeamTable.swift           one 2v2 table: TeamMatch ⇄ TableLinks ⇄ UI
  LobbyView / ChallengeViews / GameView / BoardViews / PieceViews
  TeamGameView / TeamLobbyViews  the 2v2 screen, the seating sheet, saved 2v2 games
  DemoSnapshots.swift       debug-only: renders the UI in demo states to PNG files
Sources/PeerSmokeTest/    headless tool: two (or four) copies find each other and play a short game
Tests/BarrageCoreTests/   rules, repetition rules, commitments, two- and four-Mac protocol simulations
Support/Info.plist        Mac bundle metadata, Local Network usage text and Bonjour service types
iOS/                      the iPhone/iPad app: Xcode project, Info.plist, app icon
scripts/                  build-app.sh (packages the Mac app), test.sh (runs the tests),
                          check-ios.sh (checks the iOS app without Xcode), make-app-icon.swift
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

The 2v2 version needs four copies (the host, `team-a`, last):

```sh
for r in team-b team-c team-d; do .build/release/PeerSmokeTest $r & done
.build/release/PeerSmokeTest team-a
```

### Two copies on one Mac

`OFFLINE_BARRAGE_PROFILE` gives a copy its own identity, settings and saved games, so you can
play against yourself on one Mac:

```sh
swift build
OFFLINE_BARRAGE_PROFILE=one .build/debug/OfflineBarrage &
OFFLINE_BARRAGE_PROFILE=two .build/debug/OfflineBarrage &
```

Four profiles (say `one` to `four`) give you a whole 2v2 table on one Mac.

### 2v2 autoplay

Debug builds can also play a whole 2v2 game through the real app with no mouse: four copies invite
each other, set up at random, and play random legal moves and swaps until the game ends, then check
all four armies. Each copy prints `PASS` or `FAIL`. Setting `OFFLINE_BARRAGE_AUTOPLAY_CRASH_AFTER=40`
on a guest makes it quit abruptly mid-game; relaunching it tests rejoining a game in progress.

```sh
swift build
for p in auto2 auto3 auto4; do OFFLINE_BARRAGE_PROFILE=$p OFFLINE_BARRAGE_AUTOPLAY=guest .build/debug/OfflineBarrage & done
OFFLINE_BARRAGE_PROFILE=auto1 OFFLINE_BARRAGE_AUTOPLAY=host .build/debug/OfflineBarrage
```

### Checking the iOS app without Xcode

The iOS SDK comes with Xcode, but the macOS SDK in the Command Line Tools includes the iOS
frameworks that Mac Catalyst apps use. `scripts/check-ios.sh` builds the app for Mac Catalyst, which
compiles every `#if os(iOS)` path against the iOS API surface:

```sh
./scripts/check-ios.sh                              # compile only
./scripts/check-ios.sh snapshots /tmp/ios-snaps     # also render the iOS UI at iPhone size
./scripts/check-ios.sh snapshots /tmp/ipad 820x1180 # ...or another size
./scripts/check-ios.sh app                          # .build/catalyst/OfflineBarrage.app
```

That app runs on the Mac with the iOS interface and the iOS code paths, so it can join an
autoplay table next to Mac copies. `OFFLINE_BARRAGE_AUTOPLAY_BACKGROUND_AT=30` makes such a copy
act as if it went to the background for 10 seconds, 30 seconds in:

```sh
ios=.build/catalyst/OfflineBarrage.app/Contents/MacOS/OfflineBarrage
OFFLINE_BARRAGE_PROFILE=auto2 OFFLINE_BARRAGE_AUTOPLAY=guest OFFLINE_BARRAGE_AUTOPLAY_BACKGROUND_AT=30 $ios &
OFFLINE_BARRAGE_PROFILE=auto3 OFFLINE_BARRAGE_AUTOPLAY=guest $ios &
OFFLINE_BARRAGE_PROFILE=auto4 OFFLINE_BARRAGE_AUTOPLAY=guest .build/debug/OfflineBarrage &
OFFLINE_BARRAGE_PROFILE=auto1 OFFLINE_BARRAGE_AUTOPLAY=host .build/debug/OfflineBarrage
```

CI builds the real iOS app for the simulator with `xcodebuild`.

### UI snapshots

Debug builds can render the real UI in a series of demo states (lobby, setup, mid-game, battle,
Blue's view, game over, history, the 2v2 screens, plus dark mode) without going online:

```sh
swift build
OFFLINE_BARRAGE_PROFILE=snapshots OFFLINE_BARRAGE_SNAPSHOTS=/tmp/barrage-snaps .build/debug/OfflineBarrage
```
