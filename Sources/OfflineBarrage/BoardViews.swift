import BarrageCore
import SwiftUI

/// Maps squares to screen positions with the local player's army at the bottom.
struct BoardLayout {
    let localSide: Side
    let squareSize: CGFloat

    var side: CGFloat { squareSize * CGFloat(Square.size) }

    func column(_ square: Square) -> Int { square.column(for: localSide) }
    func row(_ square: Square) -> Int { Square.size - 1 - square.rowFromBack(for: localSide) }

    func origin(_ square: Square) -> CGPoint {
        CGPoint(x: CGFloat(column(square)) * squareSize, y: CGFloat(row(square)) * squareSize)
    }

    func square(at point: CGPoint) -> Square? {
        let column = Int(floor(point.x / squareSize))
        let row = Int(floor(point.y / squareSize))
        guard (0..<Square.size).contains(column), (0..<Square.size).contains(row) else { return nil }
        return Square(column: column, rowFromBack: Square.size - 1 - row, side: localSide)
    }
}

struct SquareMarks: OptionSet, Hashable {
    let rawValue: Int
    static let lastMove = SquareMarks(rawValue: 1 << 0)
    static let selected = SquareMarks(rawValue: 1 << 1)
    static let setupZone = SquareMarks(rawValue: 1 << 2)
    static let battle = SquareMarks(rawValue: 1 << 3)
}

/// The field, the lakes and the coordinates.
struct BoardBackground: View {
    let layout: BoardLayout
    let marks: [Square: SquareMarks]

    static let lakes: [[Square]] = [
        [Square(2, 4), Square(3, 4), Square(2, 5), Square(3, 5)],
        [Square(6, 4), Square(7, 4), Square(6, 5), Square(7, 5)],
    ]

    var body: some View {
        let size = layout.squareSize
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Palette.fieldDark)
            ForEach(Square.all.filter { !$0.isLake }, id: \.self) { square in
                SquareCell(
                    square: square,
                    size: size,
                    marks: marks[square] ?? [],
                    columnLabel: layout.row(square) == Square.size - 1 ? String(Square.columnLetters[square.x]) : nil,
                    rowLabel: layout.column(square) == 0 ? String(square.y + 1) : nil
                )
                .offset(x: layout.origin(square).x, y: layout.origin(square).y)
            }
            ForEach(0..<BoardBackground.lakes.count, id: \.self) { index in
                let origin = lakeOrigin(BoardBackground.lakes[index])
                LakeView(size: size * 2)
                    .offset(x: origin.x, y: origin.y)
            }
        }
        .frame(width: layout.side, height: layout.side, alignment: .topLeading)
    }

    private func lakeOrigin(_ squares: [Square]) -> CGPoint {
        let origins = squares.map(layout.origin)
        return CGPoint(x: origins.map(\.x).min() ?? 0, y: origins.map(\.y).min() ?? 0)
    }
}

private struct SquareCell: View {
    let square: Square
    let size: CGFloat
    let marks: SquareMarks
    let columnLabel: String?
    let rowLabel: String?

    var body: some View {
        ZStack {
            Rectangle().fill((square.x + square.y) % 2 == 0 ? Palette.fieldDark : Palette.fieldLight)
            if marks.contains(.setupZone) { Rectangle().fill(Palette.homeZone) }
            if marks.contains(.lastMove) { Rectangle().fill(Palette.lastMove) }
            if marks.contains(.selected) { Rectangle().fill(Palette.selected) }
            Rectangle().strokeBorder(Palette.gridLine, lineWidth: 0.5)
            if marks.contains(.battle) {
                Rectangle().strokeBorder(Color.orange, lineWidth: max(2, size * 0.07))
            }
            if let rowLabel = rowLabel {
                Text(rowLabel)
                    .font(.system(size: max(8, size * 0.15), weight: .bold))
                    .foregroundColor(.black.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(size * 0.05)
            }
            if let columnLabel = columnLabel {
                Text(columnLabel)
                    .font(.system(size: max(8, size * 0.15), weight: .bold))
                    .foregroundColor(.black.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(size * 0.05)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct LakeView: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.14)
                .fill(LinearGradient(colors: [Palette.lake, Palette.lakeDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "water.waves")
                .font(.system(size: size * 0.3))
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(size * 0.035)
        .frame(width: size, height: size)
    }
}

// MARK: - Playing

struct PlayBoardView: View {
    let position: Position
    let ranks: [PieceID: Rank]
    let localSide: Side
    /// Show every rank (post-game review).
    let revealAll: Bool
    let lastMove: Move?
    let pendingAttack: Move?
    let interactive: Bool
    let legalMoves: [Move]
    /// Moves allowed by movement alone; those not in `legalMoves` are blocked by a repetition rule.
    let candidateMoves: [Move]
    let onMove: (Move) -> Void
    let onBlockedMove: (Move) -> Void
    /// 2v2 plays without memory aids: enemy ranks never stay visible and nothing is marked.
    var memoryAids = true
    /// 2v2: while a reserve piece is picked, clicking one of these squares swaps it in.
    var swapTargets: Set<Square> = []
    var onSwap: (Square) -> Void = { _ in }
    /// 2v2: where our partner just swapped (outlined for a moment).
    var highlight: Square? = nil

    @State private var selected: Square? = nil
    @State private var dragFrom: Square? = nil
    @State private var dragLocation: CGPoint? = nil
    @State private var selectedByThisPress = false
    @State private var pressStarted = false

    var body: some View {
        GeometryReader { geometry in
            let side = floor(min(geometry.size.width, geometry.size.height) / 10) * 10
            let layout = BoardLayout(localSide: localSide, squareSize: side / 10)
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    BoardBackground(layout: layout, marks: marks)
                    pieces(layout)
                    targetMarkers(layout)
                    swapMarkers(layout)
                }
                // Children are placed with .offset, which doesn't affect layout, so size explicitly.
                .frame(width: side, height: side, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(boardGesture(layout))

                if let from = dragFrom, let location = dragLocation, let piece = position[from] {
                    PieceToken(token: token(for: piece), size: layout.squareSize * 0.92)
                        .position(location)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .onChange(of: position) { _ in clearSelection() }
        .onChange(of: interactive) { _ in clearSelection() }
    }

    private func clearSelection() {
        selected = nil
        dragFrom = nil
        dragLocation = nil
    }

    private var marks: [Square: SquareMarks] {
        var result: [Square: SquareMarks] = [:]
        if let move = lastMove {
            result[move.from, default: []].insert(.lastMove)
            result[move.to, default: []].insert(.lastMove)
        }
        if let pending = pendingAttack {
            result[pending.from, default: []].insert(.battle)
            result[pending.to, default: []].insert(.battle)
        }
        if let square = selected ?? dragFrom {
            result[square, default: []].insert(.selected)
        }
        if let square = highlight {
            result[square, default: []].insert(.battle)
        }
        return result
    }

    private func token(for piece: PieceState) -> TokenModel {
        let mine = piece.side == localSide
        guard memoryAids else {
            return TokenModel(side: piece.side, rank: mine || revealAll ? ranks[piece.id] : nil)
        }
        let visible = mine || piece.isRevealed || revealAll
        return TokenModel(side: piece.side, rank: visible ? ranks[piece.id] : nil,
                          showsMoved: piece.hasMoved, showsRevealed: mine && piece.isRevealed)
    }

    private func helpText(for piece: PieceState) -> String {
        let mine = piece.side == localSide
        guard memoryAids else {
            if let rank = token(for: piece).rank { return rank.fullName }
            return "Hidden enemy piece"
        }
        var parts: [String] = []
        if let rank = token(for: piece).rank {
            parts.append("\(mine ? "Your" : "Their") \(rank.fullName)")
        } else {
            parts.append("Unknown enemy piece")
        }
        if piece.hasMoved { parts.append(mine ? "has moved, so they know it isn't a Bomb or the Flag" : "has moved: not a Bomb or the Flag") }
        if mine && piece.isRevealed { parts.append("its rank is known to your opponent") }
        return parts.joined(separator: " · ")
    }

    private func pieces(_ layout: BoardLayout) -> some View {
        let alive = position.pieces.values.filter(\.isAlive).sorted { $0.id < $1.id }
        return ForEach(alive, id: \.id) { piece in
            if let square = piece.square {
                PieceToken(token: token(for: piece), size: layout.squareSize * 0.86)
                    .frame(width: layout.squareSize, height: layout.squareSize)
                    .opacity(square == dragFrom && dragLocation != nil ? 0.3 : 1)
                    .help(helpText(for: piece))
                    .offset(x: layout.origin(square).x, y: layout.origin(square).y)
            }
        }
    }

    private func targetMarkers(_ layout: BoardLayout) -> some View {
        let size = layout.squareSize
        let from = selected ?? dragFrom
        let targets = from.map { start in legalMoves.filter { $0.from == start }.map(\.to) } ?? []
        let blocked = from.map { start in
            candidateMoves.filter { $0.from == start && !legalMoves.contains($0) }.map(\.to)
        } ?? []
        return ZStack(alignment: .topLeading) {
            ForEach(targets, id: \.self) { square in
                Group {
                    if position[square] != nil {
                        RoundedRectangle(cornerRadius: size * 0.17)
                            .strokeBorder(Color.red.opacity(0.85), lineWidth: max(2, size * 0.07))
                            .frame(width: size * 0.94, height: size * 0.94)
                    } else {
                        Circle()
                            .fill(Palette.hint)
                            .frame(width: size * 0.28, height: size * 0.28)
                    }
                }
                .frame(width: size, height: size)
                .offset(x: layout.origin(square).x, y: layout.origin(square).y)
            }
            ForEach(blocked, id: \.self) { square in
                Image(systemName: "nosign")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundColor(.red.opacity(0.65))
                    .frame(width: size, height: size)
                    .offset(x: layout.origin(square).x, y: layout.origin(square).y)
            }
        }
        .allowsHitTesting(false)
    }

    private func swapMarkers(_ layout: BoardLayout) -> some View {
        let size = layout.squareSize
        return ZStack(alignment: .topLeading) {
            ForEach(Array(swapTargets), id: \.self) { square in
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: size * 0.17)
                        .strokeBorder(Color.green, style: StrokeStyle(lineWidth: max(2, size * 0.06), dash: [size * 0.12, size * 0.08]))
                        .frame(width: size * 0.94, height: size * 0.94)
                        .frame(width: size, height: size)
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: size * 0.16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: size * 0.3, height: size * 0.3)
                        .background(Circle().fill(Color.green))
                }
                .frame(width: size, height: size)
                .offset(x: layout.origin(square).x, y: layout.origin(square).y)
            }
        }
        .allowsHitTesting(false)
    }

    private func boardGesture(_ layout: BoardLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard swapTargets.isEmpty else { return }
                beginPress(at: value.startLocation, layout)
                if dragFrom != nil, hypot(value.translation.width, value.translation.height) > 4 {
                    dragLocation = value.location
                }
            }
            .onEnded { value in
                if !swapTargets.isEmpty {
                    pressStarted = false
                    if interactive, let square = layout.square(at: value.location), swapTargets.contains(square) {
                        onSwap(square)
                    }
                    return
                }
                let dragged = dragLocation != nil
                let start = dragFrom
                let target = layout.square(at: value.location)
                let keepSelection = selectedByThisPress
                dragFrom = nil
                dragLocation = nil
                selectedByThisPress = false
                pressStarted = false

                if dragged, let from = start {
                    if let to = target, to != from { attemptMove(from: from, to: to) }
                    return
                }
                guard let to = target else { return }
                if let from = start, from == to {
                    // Click on one of our pieces: select it, or deselect it if it was already selected.
                    if !keepSelection { selected = nil }
                    return
                }
                if let from = selected {
                    attemptMove(from: from, to: to)
                }
            }
    }

    /// Runs once per mouse press: picks up (and selects) one of our pieces that can move.
    private func beginPress(at point: CGPoint, _ layout: BoardLayout) {
        guard !pressStarted else { return }
        pressStarted = true
        guard interactive, let square = layout.square(at: point), let piece = position[square],
              piece.side == localSide, candidateMoves.contains(where: { $0.from == square })
        else { return }
        dragFrom = square
        if selected != square {
            selected = square
            selectedByThisPress = true
        }
    }

    private func attemptMove(from: Square, to: Square) {
        guard interactive else { return }
        let move = Move(from, to)
        if legalMoves.contains(move) {
            selected = nil
            onMove(move)
        } else if candidateMoves.contains(move) {
            selected = from
            onBlockedMove(move)
        } else if let piece = position[to], piece.side == localSide, candidateMoves.contains(where: { $0.from == to }) {
            selected = to
        } else {
            selected = nil
        }
    }
}

// MARK: - Setting up

/// The board during setup, with a tray of unplaced pieces below it. Both share one coordinate
/// space so pieces can be dragged between them.
struct SetupBoardView: View {
    let setup: Setup
    let editable: Bool
    let opponentName: String
    let opponentReady: Bool
    let onPlace: (Rank, Square) -> Void
    let onMove: (Square, Square) -> Void
    let onRemove: (Square) -> Void

    private enum Source: Hashable {
        case tray(Int)
        case board(Square)
    }

    @State private var selection: Source? = nil
    @State private var dragSource: Source? = nil
    @State private var dragLocation: CGPoint? = nil
    @State private var pressStarted = false

    private struct Metrics {
        let squareSize: CGFloat
        var boardSide: CGFloat { squareSize * 10 }
        var trayTop: CGFloat { boardSide + squareSize * 0.3 }
        var trayHeight: CGFloat { squareSize * 1.2 }
        var totalHeight: CGFloat { trayTop + trayHeight }
        var slotSize: CGFloat { squareSize * 0.92 }
        var slotGap: CGFloat { (boardSide - 8 * slotSize) / 9 }

        func slotOrigin(_ index: Int) -> CGPoint {
            CGPoint(x: slotGap + CGFloat(index) * (slotSize + slotGap), y: trayTop + (trayHeight - slotSize) / 2)
        }

        func slotHitRect(_ index: Int) -> CGRect {
            CGRect(origin: slotOrigin(index), size: CGSize(width: slotSize, height: slotSize))
                .insetBy(dx: -slotGap / 2, dy: -squareSize * 0.1)
        }

        var trayRect: CGRect { CGRect(x: 0, y: trayTop, width: boardSide, height: trayHeight) }
    }

    static let aspectRatio: CGFloat = 10 / 11.5

    var body: some View {
        GeometryReader { geometry in
            let squareSize = floor(min(geometry.size.width / 10, geometry.size.height / 11.5))
            let metrics = Metrics(squareSize: squareSize)
            let layout = BoardLayout(localSide: setup.side, squareSize: squareSize)
            ZStack(alignment: .topLeading) {
                BoardBackground(layout: layout, marks: marks)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                opponentZone(metrics)
                placedPieces(layout)
                tray(metrics)
                if let source = dragSource, let location = dragLocation, let rank = rank(of: source) {
                    PieceToken(token: TokenModel(side: setup.side, rank: rank), size: squareSize * 0.92)
                        .position(location)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: metrics.boardSide, height: metrics.totalHeight, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(setupGesture(layout, metrics))
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .aspectRatio(SetupBoardView.aspectRatio, contentMode: .fit)
        .onChange(of: setup) { _ in selection = nil }
        .onChange(of: editable) { _ in
            selection = nil
            dragSource = nil
            dragLocation = nil
        }
    }

    private var marks: [Square: SquareMarks] {
        var result: [Square: SquareMarks] = [:]
        if editable {
            for square in Square.homeSquares(setup.side) { result[square] = .setupZone }
        }
        if case .board(let square)? = selection {
            result[square, default: []].insert(.selected)
        }
        return result
    }

    private func opponentZone(_ metrics: Metrics) -> some View {
        HStack(spacing: 8) {
            if opponentReady {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text("\(opponentName) is ready")
            } else {
                ProgressView().controlSize(.small)
                Text("\(opponentName) is setting up…")
            }
        }
        .font(.headline)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(.regularMaterial))
        .frame(width: metrics.boardSide, height: metrics.squareSize * 4)
        .allowsHitTesting(false)
    }

    private func placedPieces(_ layout: BoardLayout) -> some View {
        ForEach(setup.placements.keys.sorted(), id: \.self) { square in
            if let rank = setup[square] {
                PieceToken(token: TokenModel(side: setup.side, rank: rank), size: layout.squareSize * 0.86)
                    .frame(width: layout.squareSize, height: layout.squareSize)
                    .opacity(dragSource == .board(square) && dragLocation != nil ? 0.3 : 1)
                    .offset(x: layout.origin(square).x, y: layout.origin(square).y)
                    .allowsHitTesting(false)
            }
        }
    }

    private func tray(_ metrics: Metrics) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: metrics.boardSide, height: metrics.trayHeight)
                .offset(y: metrics.trayTop)
            if editable {
                ForEach(0..<Rank.barrageArmy.count, id: \.self) { index in
                    let origin = metrics.slotOrigin(index)
                    ZStack {
                        RoundedRectangle(cornerRadius: metrics.slotSize * 0.17)
                            .strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        if trayHas(index) {
                            PieceToken(token: TokenModel(side: setup.side, rank: Rank.barrageArmy[index]), size: metrics.slotSize)
                                .opacity(dragSource == .tray(index) && dragLocation != nil ? 0.3 : 1)
                        }
                        if selection == .tray(index) {
                            RoundedRectangle(cornerRadius: metrics.slotSize * 0.17)
                                .strokeBorder(Color.green, lineWidth: 3)
                        }
                    }
                    .frame(width: metrics.slotSize, height: metrics.slotSize)
                    .offset(x: origin.x, y: origin.y)
                }
            } else {
                Label("Your setup is locked in", systemImage: "lock.fill")
                    .font(.headline)
                    .foregroundColor(.secondary)
                    .frame(width: metrics.boardSide, height: metrics.trayHeight)
                    .offset(y: metrics.trayTop)
            }
        }
        .allowsHitTesting(false)
    }

    /// Whether tray slot `index` still holds its piece (for the two Scouts, the first slot empties first).
    private func trayHas(_ index: Int) -> Bool {
        let rank = Rank.barrageArmy[index]
        let instance = Rank.barrageArmy[..<index].filter { $0 == rank }.count
        return instance >= setup.placedCount(rank)
    }

    private func rank(of source: Source) -> Rank? {
        switch source {
        case .tray(let index): return Rank.barrageArmy[index]
        case .board(let square): return setup[square]
        }
    }

    private func homeSquare(at point: CGPoint, _ layout: BoardLayout, _ metrics: Metrics) -> Square? {
        guard point.y < metrics.boardSide, let square = layout.square(at: point), square.isHome(of: setup.side) else { return nil }
        return square
    }

    private func source(at point: CGPoint, _ layout: BoardLayout, _ metrics: Metrics) -> Source? {
        if let square = homeSquare(at: point, layout, metrics), setup[square] != nil { return .board(square) }
        for index in 0..<Rank.barrageArmy.count where trayHas(index) && metrics.slotHitRect(index).contains(point) {
            return .tray(index)
        }
        return nil
    }

    private func setupGesture(_ layout: BoardLayout, _ metrics: Metrics) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !pressStarted {
                    pressStarted = true
                    dragSource = editable ? source(at: value.startLocation, layout, metrics) : nil
                }
                if dragSource != nil, hypot(value.translation.width, value.translation.height) > 4 {
                    dragLocation = value.location
                }
            }
            .onEnded { value in
                let dragged = dragLocation != nil
                let source = dragSource
                pressStarted = false
                dragSource = nil
                dragLocation = nil
                guard editable else { return }
                if dragged, let source = source {
                    drop(source, at: value.location, layout, metrics)
                    selection = nil
                } else {
                    click(at: value.location, layout, metrics)
                }
            }
    }

    private func drop(_ source: Source, at point: CGPoint, _ layout: BoardLayout, _ metrics: Metrics) {
        let target = homeSquare(at: point, layout, metrics)
        switch source {
        case .tray(let index):
            if let target = target { onPlace(Rank.barrageArmy[index], target) }
        case .board(let from):
            if let target = target {
                if target != from { onMove(from, target) }
            } else {
                onRemove(from)  // dropped outside the setup rows: back to the tray
            }
        }
    }

    private func click(at point: CGPoint, _ layout: BoardLayout, _ metrics: Metrics) {
        let target = homeSquare(at: point, layout, metrics)
        let hit = source(at: point, layout, metrics)
        switch selection {
        case .tray(let index)?:
            if let target = target {
                onPlace(Rank.barrageArmy[index], target)
                selection = nil
            } else if let hit = hit, hit != selection {
                selection = hit
            } else {
                selection = nil
            }
        case .board(let from)?:
            if let target = target {
                if target != from { onMove(from, target) }
                selection = nil
            } else if metrics.trayRect.contains(point) {
                onRemove(from)
                selection = nil
            } else {
                selection = nil
            }
        case nil:
            selection = hit
        }
    }
}
