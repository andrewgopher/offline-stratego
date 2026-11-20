import Foundation
import Testing
@testable import BarrageCore

func sq(_ name: String) -> Square { Square(name: name)! }
func mv(_ text: String) -> Move { Move(text)! }

/// A free-form position for rules tests: any pieces, any squares.
func makeGame(_ pieces: [(Side, String, Rank)]) -> Game {
    var ranks: [PieceID: Rank] = [:]
    var ids: [PieceID] = []
    for (side, name, rank) in pieces {
        let id = PieceID(side, sq(name))
        ids.append(id)
        ranks[id] = rank
    }
    return Game(pieces: ids, ranks: ranks)
}

@Suite struct BoardTests {
    @Test func lakesAndNames() {
        let lakes = Square.all.filter(\.isLake).map(\.name).sorted()
        #expect(lakes == ["C5", "C6", "D5", "D6", "G5", "G6", "H5", "H6"])
        #expect(Square(name: "J10") == Square(9, 9))
        #expect(Square(name: "K1") == nil)
        #expect(Square.homeSquares(.red).count == 40)
        #expect(Square.homeSquares(.blue).allSatisfy { (6...9).contains($0.y) })
    }

    @Test func perspectiveIsA180DegreeTurn() {
        // Blue's bottom-left corner is J10 seen from Red.
        #expect(Square(column: 0, rowFromBack: 0, side: .blue) == sq("J10"))
        #expect(Square(column: 0, rowFromBack: 0, side: .red) == sq("A1"))
        for square in Square.all {
            for side in Side.allCases {
                let back = Square(column: square.column(for: side), rowFromBack: square.rowFromBack(for: side), side: side)
                #expect(back == square)
            }
            // Lakes map onto lakes, so a setup works for either color.
            #expect(Square(column: square.x, rowFromBack: square.y, side: .blue).isLake == square.isLake)
        }
    }

    @Test func pieceIDRoundTrip() throws {
        let id = PieceID(.blue, sq("C8"))
        #expect(PieceID(rawValue: id.rawValue) == id)
        let data = try JSONEncoder().encode([id])
        #expect(try JSONDecoder().decode([PieceID].self, from: data) == [id])
    }
}

@Suite struct BattleTests {
    @Test func outcomes() {
        #expect(Rules.battle(attacker: .marshal, defender: .general) == .attackerWins)
        #expect(Rules.battle(attacker: .general, defender: .marshal) == .defenderWins)
        #expect(Rules.battle(attacker: .scout, defender: .scout) == .bothLose)
        #expect(Rules.battle(attacker: .spy, defender: .marshal) == .attackerWins, "the Spy wins only when it strikes first")
        #expect(Rules.battle(attacker: .marshal, defender: .spy) == .attackerWins)
        #expect(Rules.battle(attacker: .spy, defender: .general) == .defenderWins)
        #expect(Rules.battle(attacker: .miner, defender: .bomb) == .attackerWins)
        #expect(Rules.battle(attacker: .marshal, defender: .bomb) == .defenderWins)
        #expect(Rules.battle(attacker: .spy, defender: .flag) == .attackerWins)
        #expect(Rules.battle(attacker: .scout, defender: .miner) == .defenderWins)
    }

    @Test func bombStaysAndMinerMovesIn() {
        var game = makeGame([(.red, "A4", .general), (.red, "B4", .miner), (.blue, "A5", .bomb), (.blue, "J7", .scout)])
        let ok1 = game.apply(mv("A4-A5"))
        #expect(ok1)
        #expect(game.position[sq("A5")]?.side == .blue, "the Bomb stays")
        #expect(game.position.pieces[PieceID(.red, sq("A4"))]?.isAlive == false)
        let ok2 = game.apply(mv("J7-J6"))
        #expect(ok2)
        let ok3 = game.apply(mv("B4-B5"))
        #expect(ok3)
        let ok4 = game.apply(mv("J6-J7"))
        #expect(ok4)
        let ok5 = game.apply(mv("B5-A5"))
        #expect(ok5)
        #expect(game.position[sq("A5")]?.id == PieceID(.red, sq("B4")), "the Miner takes the Bomb's square")
    }

    @Test func flagCaptureEndsTheGame() {
        var game = makeGame([(.red, "A4", .scout), (.blue, "A9", .flag), (.blue, "J7", .scout)])
        let ok6 = game.apply(mv("A4-A9"))
        #expect(ok6, "a Scout may move and strike in the same turn")
        #expect(game.winnerByFlag == .red)
        let ok7 = game.apply(mv("J7-J6"))
        #expect(!ok7)
    }

    @Test func battleWaitsForUnknownRank() {
        // Red's view: Blue's piece on A5 is unknown.
        var game = Game(pieces: [PieceID(.red, sq("A4")), PieceID(.blue, sq("A5"))], ranks: [PieceID(.red, sq("A4")): .marshal])
        let ok8 = game.apply(mv("A4-A5"))
        #expect(ok8)
        #expect(game.isAwaitingBattle)
        #expect(game.position[sq("A4")] != nil, "the attacker hasn't moved yet")
        let ok9 = game.learn([PieceID(.blue, sq("A5")): .general])
        #expect(ok9)
        #expect(!game.isAwaitingBattle)
        #expect(game.position[sq("A5")]?.id == PieceID(.red, sq("A4")))
        #expect(game.records[0].outcome == .attackerWins)
    }
}

@Suite struct MovementTests {
    @Test func normalPiecesStepOneSquare() {
        let game = makeGame([(.red, "B4", .marshal), (.red, "B3", .bomb), (.blue, "C4", .scout)])
        let targets = Set(Rules.legalMoves(in: game, for: .red).map(\.to.name))
        #expect(targets == ["A4", "B5", "C4"])
    }

    @Test func scoutsMoveAlongOpenLinesButNotThroughLakes() {
        let game = makeGame([(.red, "C4", .scout), (.red, "A4", .flag), (.blue, "C2", .miner)])
        let targets = Set(Rules.legalMoves(in: game, for: .red).map(\.to.name))
        // Up is a lake; left stops before the own Flag; down stops at the enemy (attack).
        #expect(targets == ["B4", "D4", "E4", "F4", "G4", "H4", "I4", "J4", "C3", "C2"])
    }

    @Test func bombsAndFlagsNeverMove() {
        let game = makeGame([(.red, "A1", .bomb), (.red, "J1", .flag), (.blue, "J10", .flag)])
        #expect(Rules.legalMoves(in: game, for: .red).isEmpty)
        #expect(!Rules.canMoveAtAll(.red, in: game))
    }

    @Test func longMoveNeedsAKnownScout() {
        // Seen from Blue: Red's piece is unknown, so a long move can't be accepted without its rank.
        let red = PieceID(.red, sq("A4"))
        var game = Game(pieces: [red, PieceID(.blue, sq("J7"))], ranks: [PieceID(.blue, sq("J7")): .marshal])
        #expect(!game.canApply(mv("A4-A6")))
        #expect(game.canApply(mv("A4-A5")))
        game.learn([red: .scout])
        #expect(game.canApply(mv("A4-A6")))
    }
}

@Suite struct RepetitionTests {
    @Test func twoSquaresRuleAllowsFiveShuttlesNotSix() {
        var game = makeGame([(.red, "A4", .miner), (.red, "E4", .general), (.blue, "J7", .general), (.blue, "A10", .flag)])
        let redShuttle = ["A4-A5", "A5-A4", "A4-A5", "A5-A4", "A4-A5"]
        let blueShuttle = ["J7-J6", "J6-J7", "J7-J6", "J6-J7", "J7-J6"]
        for (r, b) in zip(redShuttle, blueShuttle) {
            #expect(Rules.isLegal(mv(r), in: game))
            game.apply(mv(r))
            #expect(Rules.isLegal(mv(b), in: game))
            game.apply(mv(b))
        }
        #expect(Rules.restriction(on: mv("A5-A4"), in: game) == .twoSquares)
        #expect(Rules.isLegal(mv("A5-B5"), in: game), "other squares are fine")
        #expect(Rules.isLegal(mv("E4-E5"), in: game), "other pieces are fine")
        #expect(!Rules.legalMoves(in: game, for: .red).contains(mv("A5-A4")))

        // Moving another piece breaks the sequence.
        game.apply(mv("E4-E5"))
        #expect(Rules.restriction(on: mv("J6-J7"), in: game) == .twoSquares, "Blue is still stuck shuttling")
        game.apply(mv("J6-I6"))
        #expect(Rules.isLegal(mv("A5-A4"), in: game))
    }

    @Test func overlappingScoutMovesCountAsShuttling() {
        var game = makeGame([(.red, "A2", .scout), (.red, "J1", .flag), (.blue, "J10", .general)])
        let scout = ["A2-A5", "A5-A3", "A3-A6", "A6-A2", "A2-A4"]
        let blue = ["J10-I10", "I10-H10", "H10-G10", "G10-F10", "F10-E10"]
        for (r, b) in zip(scout, blue) {
            #expect(Rules.isLegal(mv(r), in: game), "\(r)")
            game.apply(mv(r))
            game.apply(mv(b))
        }
        // All five moves crossed the edge between A3 and A4.
        #expect(Rules.restriction(on: mv("A4-A1"), in: game) == .twoSquares)
        #expect(Rules.isLegal(mv("A4-A7"), in: game), "a move that doesn't overlap is allowed")
        #expect(Rules.isLegal(mv("A4-B4"), in: game))
    }

    @Test func chasingAroundALakeCantRepeatAPosition() {
        // Red's Marshal follows Blue's General around the C5-D6 lake.
        let ring = ["B4", "B5", "B6", "B7", "C7", "D7", "E7", "E6", "E5", "E4", "D4", "C4"]
        var game = makeGame([(.red, ring[0], .marshal), (.blue, ring[2], .general), (.red, "J1", .flag), (.blue, "J10", .flag)])
        var chaser = 0
        var evader = 2
        for round in 0..<12 {
            let chase = Move(sq(ring[chaser]), sq(ring[(chaser + 1) % 12]))
            #expect(Rules.restriction(on: chase, in: game) == nil, "round \(round)")
            game.apply(chase)
            chaser = (chaser + 1) % 12
            let evade = Move(sq(ring[evader]), sq(ring[(evader + 1) % 12]))
            #expect(Rules.isLegal(evade, in: game), "round \(round)")
            game.apply(evade)
            evader = (evader + 1) % 12
        }
        // One full lap later, the next chasing move would recreate the position after Red's first move.
        let repeatChase = Move(sq(ring[chaser]), sq(ring[(chaser + 1) % 12]))
        #expect(Rules.restriction(on: repeatChase, in: game) == .chasing)
        #expect(Rules.isLegal(Move(sq(ring[chaser]), sq("A4")), in: game), "breaking off the chase is fine")
    }

    @Test func chaserMayStepBackWhereItCameFrom() {
        var game = makeGame([(.red, "F4", .marshal), (.blue, "F6", .general), (.red, "J1", .flag), (.blue, "J10", .flag)])
        game.apply(mv("F4-F5"))  // threat
        game.apply(mv("F6-E6"))  // evade
        game.apply(mv("F5-E5"))  // chase
        game.apply(mv("E6-F6"))  // evade, back to a seen square
        // F5 recreates the position after Red's first move, but it's where the Marshal just came from.
        #expect(Rules.restriction(on: mv("E5-F5"), in: game) == nil)
    }
}

@Suite struct SetupTests {
    @Test func placingMovingAndSwapping() {
        var setup = Setup(side: .red)
        let ok10 = setup.place(.marshal, at: sq("A1"))
        #expect(ok10)
        let ok11 = setup.place(.marshal, at: sq("B1"))
        #expect(!ok11, "only one Marshal")
        let ok12 = setup.place(.general, at: sq("A5"))
        #expect(!ok12, "outside the setup rows")
        let ok13 = setup.place(.scout, at: sq("B1"))
        #expect(ok13)
        let ok14 = setup.place(.scout, at: sq("C1"))
        #expect(ok14)
        let ok15 = setup.place(.scout, at: sq("D1"))
        #expect(!ok15, "only two Scouts")
        let ok16 = setup.place(.general, at: sq("C1"))
        #expect(ok16, "replacing a piece sends it back to the tray")
        #expect(setup.unplaced == [.miner, .scout, .spy, .bomb, .flag])
        let ok17 = setup.move(from: sq("A1"), to: sq("B1"))
        #expect(ok17)
        #expect(setup[sq("A1")] == .scout && setup[sq("B1")] == .marshal)
        #expect(!setup.isComplete)
    }

    @Test func randomSetupsAreComplete() {
        for side in Side.allCases {
            let setup = Setup.random(side: side)
            #expect(setup.isComplete)
            #expect(setup.placements.keys.allSatisfy { $0.isHome(of: side) })
        }
    }

    @Test func slotsCarryASetupToTheOtherColor() {
        let red = Setup.random(side: .red)
        let blue = Setup(side: .blue, slots: red.slots)
        #expect(blue.isComplete)
        for (square, rank) in red.placements {
            #expect(blue[Square(column: square.column(for: .red), rowFromBack: square.rowFromBack(for: .red), side: .blue)] == rank)
        }
    }
}

@Suite struct CommitmentTests {
    @Test func digestsBindRankAndNonce() {
        let game = UUID()
        let piece = PieceID(.red, sq("A1"))
        let secret = PieceSecret(rank: .flag, nonce: Commitments.makeNonce())
        let digest = Commitments.digest(gameID: game, piece: piece, secret: secret)
        #expect(digest == Commitments.digest(gameID: game, piece: piece, secret: secret))
        #expect(digest != Commitments.digest(gameID: game, piece: piece, secret: PieceSecret(rank: .bomb, nonce: secret.nonce)))
        #expect(digest != Commitments.digest(gameID: UUID(), piece: piece, secret: secret))
        #expect(Commitments.makeNonce() != Commitments.makeNonce())
        #expect(Commitments.makeNonce().count == 32)
    }
}
