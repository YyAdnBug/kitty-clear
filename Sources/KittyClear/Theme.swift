import SwiftUI

/// The app icon's palette (scripts/brand-icon.swift). The window is the icon's sky-blue plate and
/// all content sits on its cream card, so these are the only colours the UI uses.
enum Theme {
    static let skyTop = Color(hex: 0x86C5FF)
    static let sky = Color(hex: 0x3C96F7)
    static let skyDeep = Color(hex: 0x2478DC)
    static let cream = Color(hex: 0xFFF5F0)
    static let ink = Color(hex: 0x3A2530)
    static let inkSoft = Color(hex: 0x3A2530).opacity(0.62)
    static let blush = Color(hex: 0xFF7FA0)
    static let beans = Color(hex: 0xFF9FB8)
    static let shine = Color(hex: 0x2F86E8)
    static let blueLine = Color(hex: 0xB5D8FF)
    static let pinkLine = Color(hex: 0xFFCFDC)
    /// For a reading that has gone high, and for one that has gone too high.
    static let amber = Color(hex: 0xF28C28)
    static let alarm = Color(hex: 0xE5484D)

    /// Rounded, like the kitten: big numbers and headlines.
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    static func text(_ size: CGFloat = 13, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// The icon's plate: sky gradient with a soft glow top-left.
struct Sky: View {
    var body: some View {
        ZStack {
            LinearGradient(
                stops: [.init(color: Theme.skyTop, location: 0), .init(color: Theme.sky, location: 0.55),
                        .init(color: Theme.skyDeep, location: 1)],
                startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [.white.opacity(0.22), .clear], center: UnitPoint(x: 0.3, y: 0.2),
                           startRadius: 0, endRadius: 560)
        }
    }
}

/// The icon's kitten, same geometry as scripts/brand-icon.swift (1024-unit design space), split into
/// the part behind the card edge it leans on and the paws in front of it. It is drawn every frame from
/// a `Pose`, so it can look around, drum its paws, wipe the card and blink.
struct Kitten: View {
    enum Layer { case head, paws }
    /// What the kitten is doing. `.searching` and `.wiping` move continuously; the others only blink.
    enum Mood { case calm, searching, wiping, happy }

    let layer: Layer
    var mood = Mood.calm
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blinkStart: Date?

    // The slice of design space the canvas shows. The card edge is at y = 614.
    private static let origin = CGPoint(x: 240, y: 170)
    private static let extent = CGSize(width: 544, height: 570)
    static let aspect = extent.width / extent.height
    /// Share of the kitten's height that shows above the card edge.
    static let aboveEdge = (614 - origin.y) / extent.height
    /// How fast the eyes sweep the card while searching (radians per second); `ScanBeam` follows it.
    static let sweepRate = 2.4
    private static let blinkLength = 0.3

    var body: some View {
        let moving = (mood == .searching || mood == .wiping) && !reduceMotion
        TimelineView(.animation(paused: !moving && blinkStart == nil)) { timeline in
            Canvas { context, size in
                var g = context
                let scale = size.width / Self.extent.width
                g.scaleBy(x: scale, y: scale)
                g.translateBy(x: -Self.origin.x, y: -Self.origin.y)
                var pose = Pose(mood: moving || mood == .happy ? mood : .calm,
                                time: timeline.date.timeIntervalSinceReferenceDate)
                if let blinkStart {
                    let progress = min(max(timeline.date.timeIntervalSince(blinkStart) / Self.blinkLength, 0), 1)
                    pose.blink = sin(progress * .pi)
                }
                switch layer {
                case .head: Self.head(&g, pose)
                case .paws: Self.paws(&g, pose)
                }
            }
        }
        .aspectRatio(Self.aspect, contentMode: .fit)
        .accessibilityHidden(true)
        .task(id: reduceMotion) {
            // A blink every few seconds keeps the kitten alive even when nothing is running.
            guard layer == .head, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(.random(in: 2.5...5.5)))
                blinkStart = .now
                try? await Task.sleep(for: .seconds(Self.blinkLength))
                blinkStart = nil
            }
        }
    }

    /// Everything about the kitten that moves, in design units.
    private struct Pose {
        var gaze = CGPoint(x: 6, y: 24) // pupil offset from the eye centre; the icon looks down at the card
        var blink: CGFloat = 0 // 0 open, 1 closed
        var happy = false // eyes squeezed into smiling arcs
        var earFlick: CGFloat = 0 // left ear, radians
        var bob: CGFloat = 0 // head, y offset
        var lift: (left: CGFloat, right: CGFloat) = (0, 0) // paws raised off the card
        var wipe: CGFloat = 0 // right paw, x offset

        init(mood: Mood, time t: Double) {
            switch mood {
            case .calm:
                break
            case .searching:
                // Eyes sweep the card from side to side, paws drum on its edge, an ear flicks now and then.
                let angle = 0.9 * sin(t * Kitten.sweepRate)
                gaze = CGPoint(x: 20 * sin(angle), y: 24 * cos(angle))
                bob = 3 * sin(t * Kitten.sweepRate + 1)
                lift = (10 * max(0, sin(t * 7)), 10 * max(0, sin(t * 7 + .pi)))
                let flick = t.truncatingRemainder(dividingBy: 3.4) / 0.24
                earFlick = flick < 1 ? 0.16 * sin(flick * .pi) : 0
            case .wiping:
                // One paw wipes the card edge and the eyes follow it.
                let sweep = sin(t * 6)
                wipe = 46 * sweep
                lift.right = 4
                gaze = CGPoint(x: 6 + 13 * sweep, y: 22)
            case .happy:
                happy = true
            }
        }
    }

    private static func ellipse(
        _ g: inout GraphicsContext, _ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ color: Color
    ) {
        g.fill(Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)), with: .color(color))
    }

    /// Filled triangle with a same-colour round stroke (ears, nose)
    private static func triangle(_ g: inout GraphicsContext, _ points: [CGPoint], _ color: Color, round: CGFloat) {
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        g.fill(path, with: .color(color))
        g.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: round, lineJoin: .round))
    }

    private static func mirrored(_ points: [CGPoint]) -> [CGPoint] { points.map { CGPoint(x: 1024 - $0.x, y: $0.y) } }

    private static func head(_ g: inout GraphicsContext, _ pose: Pose) {
        g.translateBy(x: 0, y: pose.bob)
        let ear = [CGPoint(x: 352, y: 392), CGPoint(x: 296, y: 204), CGPoint(x: 478, y: 330)]
        let inner = [CGPoint(x: 366, y: 354), CGPoint(x: 338, y: 260), CGPoint(x: 426, y: 320)]
        // The left ear flicks about the middle of its base.
        g.drawLayer { left in
            left.translateBy(x: 415, y: 361)
            left.rotate(by: .radians(-pose.earFlick))
            left.translateBy(x: -415, y: -361)
            triangle(&left, ear, Theme.ink, round: 32)
            triangle(&left, inner, Theme.blush, round: 12)
        }
        triangle(&g, mirrored(ear), Theme.ink, round: 32)
        triangle(&g, mirrored(inner), Theme.blush, round: 12)
        // Head and blush
        ellipse(&g, 512, 522, 256, 208, Theme.ink)
        ellipse(&g, 352, 568, 30, 16, Theme.blush.opacity(0.8))
        ellipse(&g, 672, 568, 30, 16, Theme.blush.opacity(0.8))
        for cx: CGFloat in [424, 600] {
            if pose.happy {
                var arc = Path()
                arc.move(to: CGPoint(x: cx - 44, y: 516))
                arc.addQuadCurve(to: CGPoint(x: cx + 44, y: 516), control: CGPoint(x: cx, y: 452))
                g.stroke(arc, with: .color(Theme.cream), style: StrokeStyle(lineWidth: 16, lineCap: .round))
            } else {
                // The eyelids close over the eye; the pupil is clipped to what is left of the white.
                let open = max(0.06, 1 - pose.blink)
                let white = Path(ellipseIn: CGRect(x: cx - 56, y: 500 - 60 * open, width: 112, height: 120 * open))
                g.fill(white, with: .color(Theme.cream))
                g.drawLayer { eye in
                    eye.clip(to: white)
                    let (px, py) = (cx + pose.gaze.x, 500 + pose.gaze.y)
                    ellipse(&eye, px, py, 34, 35, Theme.ink)
                    ellipse(&eye, px + 15, py - 17, 11.5, 11.5, .white)
                    ellipse(&eye, px - 14, py + 17, 5.5, 5.5, .white.opacity(0.9))
                }
            }
        }
        // Nose and mouth
        triangle(&g, [CGPoint(x: 496, y: 566), CGPoint(x: 528, y: 566), CGPoint(x: 512, y: 585)], Theme.blush, round: 10)
        var mouth = Path()
        mouth.move(to: CGPoint(x: 490, y: 594))
        mouth.addQuadCurve(to: CGPoint(x: 512, y: 596), control: CGPoint(x: 500, y: 612))
        mouth.addQuadCurve(to: CGPoint(x: 534, y: 594), control: CGPoint(x: 524, y: 612))
        g.stroke(mouth, with: .color(Theme.beans), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
    }

    private static func paws(_ g: inout GraphicsContext, _ pose: Pose) {
        for (cx, lift) in [(386, pose.lift.left), (638 + pose.wipe, pose.lift.right)] as [(CGFloat, CGFloat)] {
            // A raised paw casts a smaller, fainter shadow on the card.
            let grounded = 1 - min(lift / 24, 1) * 0.5
            ellipse(&g, cx, 652, 70 * grounded, 13 * grounded, Color(hex: 0xE9C6D0).opacity(0.8 * grounded))
            ellipse(&g, cx, 616 - lift, 76, 46, Theme.ink)
            for (dx, dy) in [(-26.0, 14.0), (0.0, 21.0), (26.0, 14.0)] as [(CGFloat, CGFloat)] {
                ellipse(&g, cx + dx, 616 - lift + dy, 10, 9, Theme.beans)
            }
        }
    }
}

/// The icon's composition as a layout: the kitten leans over the top edge of a cream card that rises
/// from the bottom of the window. `.hero` is one message and one action; `.full` gives the card the room
/// and moves the page title onto the sky.
struct Stage<Content: View>: View {
    enum Size { case hero, full }
    let size: Size
    var title = ""
    var subtitle = ""
    var mood = Kitten.Mood.calm
    @ViewBuilder let content: Content

    var body: some View {
        let hero = size == .hero
        let kitten: CGFloat = hero ? 250 : 124
        let above = kitten / Kitten.aspect * Kitten.aboveEdge
        let side: Alignment = hero ? .top : .topTrailing
        let card = UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30, style: .continuous)

        content
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: hero ? 540 : .infinity, maxHeight: hero ? 300 : .infinity)
            .clipShape(card)
            .background { card.fill(Theme.cream).shadow(color: Theme.skyDeep.opacity(0.45), radius: 26, y: 10) }
            .padding(.top, above)
            .background(alignment: side) {
                Kitten(layer: .head, mood: mood).frame(width: kitten).padding(.trailing, hero ? 0 : 56)
            }
            .overlay(alignment: side) {
                Kitten(layer: .paws, mood: mood).frame(width: kitten).padding(.trailing, hero ? 0 : 56)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                if !hero {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(Theme.display(26))
                        Text(subtitle.replacing("\n", with: "")).font(Theme.text(13)).opacity(0.9)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .foregroundStyle(.white)
                    .padding(.leading, 6)
                    .padding(.trailing, 220)
                    .frame(height: above - 14, alignment: .bottomLeading)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .animation(.snappy(duration: 0.45), value: size)
    }
}

/// One message and its actions, centred on a hero card.
struct Hero<Actions: View>: View {
    enum Activity {
        case resting
        /// Looking for something: sparkles twinkle and a light sweeps the card with the kitten's eyes.
        case searching
        /// Doing the work: sparkles twinkle.
        case working
        /// It went well: extra sparkles pop out once.
        case celebrating
    }

    let title: String
    var text = ""
    var activity = Activity.resting
    @ViewBuilder let actions: Actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 12) {
            // A number that grows rolls its digits instead of jumping.
            Text(title).font(Theme.display(44)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.35), value: title)
            if !text.isEmpty {
                Text(text).font(Theme.text(13)).foregroundStyle(Theme.inkSoft)
                    .multilineTextAlignment(.center).lineLimit(3)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.25), value: text)
            }
            HStack(spacing: 10) { actions }.padding(.top, 6)
        }
        .padding(.horizontal, 72) // keeps the words clear of the sparkles in the corners
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Sparkles(twinkling: activity == .searching || activity == .working, celebrating: activity == .celebrating)
        }
        .background {
            if activity == .searching && !reduceMotion { ScanBeam() }
        }
    }
}

/// A soft light that crosses the card in step with the kitten's eyes while it searches.
private struct ScanBeam: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            GeometryReader { geo in
                let sweep = sin(timeline.date.timeIntervalSinceReferenceDate * Kitten.sweepRate)
                LinearGradient(colors: [.clear, Theme.blueLine.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.36)
                    .offset(x: geo.size.width * 0.32 * (1 + sweep))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A four-point sparkle, the shine on the icon's card.
struct Sparkle: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY), r = min(rect.width, rect.height) / 2
        let tips = [CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x + r, y: c.y), CGPoint(x: c.x, y: c.y + r), CGPoint(x: c.x - r, y: c.y)]
        var path = Path()
        path.move(to: tips[3])
        for tip in tips { path.addQuadCurve(to: tip, control: c) }
        path.closeSubpath()
        return path
    }
}

/// The card's sparkles, out in the corners, clear of the words.
private struct Sparkles: View {
    let twinkling: Bool
    let celebrating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var popped = false

    private struct Mark: Identifiable {
        let id: Int
        let x, y, size: CGFloat
        let color: Color
    }

    private static let marks = [
        Mark(id: 0, x: 0.09, y: 0.20, size: 30, color: Theme.blueLine),
        Mark(id: 1, x: 0.90, y: 0.17, size: 36, color: Theme.pinkLine),
        Mark(id: 2, x: 0.88, y: 0.80, size: 20, color: Theme.blueLine),
        Mark(id: 3, x: 0.11, y: 0.83, size: 16, color: Theme.pinkLine),
    ]

    /// The extra shine after a clean, like the big sparkle on the icon's card.
    private static let confetti = [
        Mark(id: 4, x: 0.20, y: 0.12, size: 22, color: Theme.shine),
        Mark(id: 5, x: 0.79, y: 0.10, size: 16, color: Theme.shine),
        Mark(id: 6, x: 0.05, y: 0.52, size: 18, color: Theme.pinkLine),
        Mark(id: 7, x: 0.95, y: 0.50, size: 24, color: Theme.shine),
        Mark(id: 8, x: 0.26, y: 0.90, size: 14, color: Theme.blueLine),
        Mark(id: 9, x: 0.72, y: 0.90, size: 20, color: Theme.pinkLine),
    ]

    var body: some View {
        GeometryReader { geo in
            ForEach(Self.marks + (celebrating ? Self.confetti : [])) { mark in
                let sparkle = Sparkle()
                    .fill(mark.color)
                    .stroke(mark.color, style: StrokeStyle(lineWidth: mark.size * 0.08, lineJoin: .round))
                    .frame(width: mark.size, height: mark.size)
                Group {
                    if twinkling && !reduceMotion {
                        // Each sparkle breathes at its own pace, so they never pulse in step.
                        sparkle.phaseAnimator([false, true]) { view, lit in
                            view.scaleEffect(lit ? 1.25 : 0.9).opacity(lit ? 1 : 0.4)
                        } animation: { _ in
                            .easeInOut(duration: 0.7 + Double(mark.id) * 0.15)
                        }
                    } else if celebrating && !reduceMotion {
                        // One after another, each pops out with a little overshoot.
                        sparkle
                            .scaleEffect(popped ? 1 : 0.01)
                            .opacity(popped ? 1 : 0)
                            .animation(.spring(response: 0.45, dampingFraction: 0.45).delay(Double(mark.id) * 0.06), value: popped)
                    } else {
                        sparkle
                    }
                }
                .position(x: geo.size.width * mark.x, y: geo.size.height * mark.y)
            }
        }
        .onAppear { popped = true }
        .accessibilityHidden(true)
    }
}

extension View {
    /// Lets the window be dragged by this view. The window has no title bar, so the sky does that job.
    @ViewBuilder func dragsWindow() -> some View {
        if #available(macOS 15, *) { gesture(WindowDragGesture()) } else { self }
    }
}

/// One reading on a tinted tile: a name, the number, a small gauge and a line of detail. The menu bar
/// panel uses the small size, the status page the roomy one.
/// How much a reading is to be worried about. It colours the number and its gauge: as usual while all
/// is well, orange when it has gone high, red when it has gone too high.
enum Level: Int, Comparable {
    case fine, high, critical

    /// A share (0...1) of something that is spent when full: a processor, memory, a disk. Orange past
    /// 80%, red past 90%.
    init(used share: Double) { self = share > 0.9 ? .critical : share > 0.8 ? .high : .fine }
    /// A battery's charge in percent, where little is the worry: orange from 20% down, red from 10%.
    init(charge percent: Double) { self = percent <= 10 ? .critical : percent <= 20 ? .high : .fine }
    /// Mole's health score, which it calls fair under 65 and poor under 45.
    init(health score: Int) { self = score < 45 ? .critical : score < 65 ? .high : .fine }
    /// The chip's temperature in °C.
    init(heat degrees: Double) { self = degrees >= 95 ? .critical : degrees >= 80 ? .high : .fine }

    static func < (one: Level, other: Level) -> Bool { one.rawValue < other.rawValue }

    /// For a gauge: the icon's blue while all is well.
    var tint: Color { [Theme.shine, Theme.amber, Theme.alarm][rawValue] }
    /// For a number: ink while all is well.
    var ink: Color { self == .fine ? Theme.ink : tint }
}

struct Tile<Gauge: View>: View {
    let title: String
    var badge = ""
    let value: String
    let note: String
    var roomy = false
    var level = Level.fine
    @ViewBuilder let gauge: Gauge

    var body: some View {
        VStack(alignment: .leading, spacing: roomy ? 5 : 4) {
            HStack {
                Text(title).font(Theme.text(roomy ? 12.5 : 11.5, .medium)).foregroundStyle(Theme.inkSoft)
                Spacer()
                Text(badge).font(Theme.text(roomy ? 11.5 : 10.5, .medium)).foregroundStyle(Theme.inkSoft).lineLimit(1)
            }
            Text(value).font(Theme.display(roomy ? 25 : 19)).foregroundStyle(level.ink).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            gauge.frame(height: roomy ? 26 : 18)
            Text(note).font(Theme.text(roomy ? 11.5 : 10.5)).foregroundStyle(Theme.inkSoft).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(roomy ? 12 : 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.blueLine.opacity(0.24), in: RoundedRectangle(cornerRadius: roomy ? 14 : 12, style: .continuous))
    }
}

/// Lays its views out in a row and starts a new row when the next one does not fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = place(subviews, in: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.maxX).max() ?? 0, height: rows.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, place(subviews, in: bounds.width)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
        }
    }

    private func place(_ subviews: Subviews, in width: CGFloat) -> [CGRect] {
        var corner = CGPoint.zero
        var rowHeight: CGFloat = 0
        return subviews.map { view in
            let size = view.sizeThatFits(.unspecified)
            if corner.x > 0, corner.x + size.width > width {
                corner = CGPoint(x: 0, y: corner.y + rowHeight + spacing)
                rowHeight = 0
            }
            defer { corner.x += size.width + spacing }
            rowHeight = max(rowHeight, size.height)
            return CGRect(origin: corner, size: size)
        }
    }
}

/// Hairline between a card's header and its list.
struct Rule: View {
    var body: some View { Rectangle().fill(Theme.pinkLine).frame(height: 1) }
}

/// Thin usage bar. Pink, the icon's warm accent, means nearly full.
struct Bar: View {
    let fraction: Double
    /// What colours the bar. Left out, a fuller bar is a worse one: orange past 80%, red past 90%.
    var level: Level?

    var body: some View {
        GeometryReader { geo in
            let clamped = min(max(fraction, 0), 1)
            Capsule().fill(Theme.blueLine.opacity(0.55))
                .overlay(alignment: .leading) {
                    Capsule().fill((level ?? Level(used: clamped)).tint)
                        .frame(width: clamped == 0 ? 0 : max(geo.size.height, geo.size.width * clamped))
                }
        }
        .frame(height: 6)
    }
}

/// A charge drawn round an icon: the Mac itself, a mouse, a pair of earphones.
struct ChargeRing: View {
    let symbol: String
    let percent: Int

    var body: some View {
        ZStack {
            Circle().stroke(Theme.blueLine.opacity(0.55), lineWidth: 3)
            Circle().trim(from: 0, to: Double(min(max(percent, 0), 100)) / 100)
                .stroke(Level(charge: Double(percent)).tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink.opacity(0.78))
        }
        .frame(width: 32, height: 32)
        .accessibilityElement()
    }
}

struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, quiet }
    let kind: Kind
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.text(large ? 15 : 13, .semibold))
            .foregroundStyle(kind == .primary ? .white : Theme.shine)
            .padding(.horizontal, large ? 28 : 16)
            .padding(.vertical, large ? 11 : 7)
            .background(kind == .primary ? AnyShapeStyle(Theme.shine.gradient) : AnyShapeStyle(Theme.blueLine.opacity(0.45)),
                        in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var primary: PillButtonStyle { PillButtonStyle(kind: .primary) }
    static var quiet: PillButtonStyle { PillButtonStyle(kind: .quiet) }
    static var heroPrimary: PillButtonStyle { PillButtonStyle(kind: .primary, large: true) }
    static var heroQuiet: PillButtonStyle { PillButtonStyle(kind: .quiet, large: true) }
}

/// Round icon button for a card's header.
struct IconButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.shine)
                .frame(width: 28, height: 28)
                .background(Theme.blueLine.opacity(0.45), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Checkbox in the icon's blue. The whole row is the hit target; a partly checked group shows a dash.
struct CheckToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let filled = configuration.isOn || configuration.isMixed
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(filled ? Theme.shine : .clear)
                    .strokeBorder(filled ? Theme.shine : Theme.ink.opacity(0.28), lineWidth: 1.5)
                    .frame(width: 17, height: 17)
                    .overlay {
                        Image(systemName: configuration.isMixed ? "minus" : "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .opacity(filled ? 1 : 0)
                    }
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// On/off switch in the icon's blue, for settings. Checkboxes are for picking rows out of a list.
/// It draws the switch alone: the setting's name stands beside it, and is its accessibility label.
struct SwitchToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Capsule()
                .fill(configuration.isOn ? AnyShapeStyle(Theme.shine.gradient) : AnyShapeStyle(Theme.ink.opacity(0.16)))
                .frame(width: 42, height: 25)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).shadow(color: Theme.ink.opacity(0.22), radius: 1.5, y: 1).padding(2.5)
                }
                .animation(.snappy(duration: 0.18), value: configuration.isOn)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityValue(configuration.isOn ? "开" : "关")
    }
}

/// A few choices of which exactly one is on, for moving between the parts of a page.
struct Segments<Choice: Hashable>: View {
    let choices: [(value: Choice, title: String)]
    @Binding var selection: Choice

    var body: some View {
        HStack(spacing: 2) {
            ForEach(choices, id: \.value) { choice in
                let on = choice.value == selection
                Button {
                    selection = choice.value
                } label: {
                    Text(choice.title).font(Theme.text(13, .semibold))
                        .foregroundStyle(on ? .white : Theme.shine)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 6)
                        .background(on ? AnyShapeStyle(Theme.shine.gradient) : AnyShapeStyle(.clear), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.blueLine.opacity(0.45), in: Capsule())
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.inkSoft)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(Theme.text(13))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.blueLine.opacity(0.35), in: Capsule())
        .frame(maxWidth: 240)
    }
}

/// Centred spinner for a card that is still loading.
struct Waiting: View {
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(text).font(Theme.text(13)).foregroundStyle(Theme.inkSoft)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
