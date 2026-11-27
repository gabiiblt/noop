import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// The muscle map: front and back of a body, each muscle shaded by how much it got this week, how fatigued it is, or
// how long it has been left alone, and under it what is still recovering, what has been left alone, and what has
// never been trained.
//
// Every figure is an ESTIMATE from the sets that were logged, never a measurement of anyone's body. The recovery
// maths is ported from openGym (Duarte Santos, MIT authorization to Gabriel Bolatoglu) and checked against openGym's
// own code; the body outlines come from MuscleMap by Melih Colpan (MIT). Both are credited in ATTRIBUTION.md.

// MARK: - Geometry

/// The body outlines, loaded once from `BodyGeometry.json` (see `Tools/body_geometry/convert.py`).
struct BodyGeometry: Decodable {
    struct Side: Decodable {
        var viewBox: [Double]
        var regions: [String: [String]]
        var silhouette: [String]
        var blend: [String: [String]]
    }

    var bodies: [String: [String: Side]]

    init(from decoder: Decoder) throws {
        bodies = try decoder.singleValueContainer().decode([String: [String: Side]].self)
    }

    /// Nil when the resource is missing or unreadable: the screen then shows the lists without a figure.
    static let shared: BodyGeometry? = {
        guard let url = Bundle.main.url(forResource: "BodyGeometry", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BodyGeometry.self, from: data)
    }()
}

extension Path {
    /// A path from the segments `SVGPathData` read.
    init(_ segments: [SVGPathSegment]) {
        self.init()
        for s in segments {
            switch s {
            case .move(let x, let y): move(to: CGPoint(x: x, y: y))
            case .line(let x, let y): addLine(to: CGPoint(x: x, y: y))
            case .cubic(let a, let b, let c, let d, let x, let y):
                addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: a, y: b), control2: CGPoint(x: c, y: d))
            case .quad(let a, let b, let x, let y):
                addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: a, y: b))
            case .close: closeSubpath()
            }
        }
    }
}

/// One view of a body (front or back) with its paths built once.
struct BodyFigure {
    let viewBox: CGRect
    let silhouette: [Path]
    let regions: [(muscle: LiftMuscle, path: Path)]
    /// A muscle that takes another's level too: where a view draws no side delts of its own, the front and rear heads
    /// are shaded with them (a lateral raise lights the shoulder from both sides).
    let blend: [LiftMuscle: [LiftMuscle]]

    init?(_ side: BodyGeometry.Side) {
        guard side.viewBox.count == 4 else { return nil }
        viewBox = CGRect(x: side.viewBox[0], y: side.viewBox[1], width: side.viewBox[2], height: side.viewBox[3])
        silhouette = side.silhouette.map { Path(SVGPathData.parse($0)) }
        regions = side.regions.flatMap { name, paths -> [(LiftMuscle, Path)] in
            guard let muscle = LiftMuscle(rawValue: name) else { return [] }
            return paths.map { (muscle, Path(SVGPathData.parse($0))) }
        }
        var b: [LiftMuscle: [LiftMuscle]] = [:]
        for (name, others) in side.blend {
            if let m = LiftMuscle(rawValue: name) { b[m] = others.compactMap(LiftMuscle.init(rawValue:)) }
        }
        blend = b
    }

    /// The scale and offset that fit the view box in `size`, centred.
    func transform(in size: CGSize) -> CGAffineTransform {
        let scale = min(size.width / viewBox.width, size.height / viewBox.height)
        let dx = (size.width - viewBox.width * scale) / 2
        let dy = (size.height - viewBox.height * scale) / 2
        return CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale).translatedBy(x: -viewBox.minX, y: -viewBox.minY)
    }

    /// The muscle under a point given in the drawing's own coordinates, if any.
    func muscle(at point: CGPoint, in size: CGSize) -> LiftMuscle? {
        let inverse = transform(in: size).inverted()
        let p = point.applying(inverse)
        return regions.first { $0.path.contains(p) }?.muscle
    }
}

// MARK: - The figure

struct BodyMapFigureView: View {
    let figure: BodyFigure
    let level: (LiftMuscle) -> Int
    let color: Color
    let selected: LiftMuscle?
    let onTap: (LiftMuscle?) -> Void

    /// Shade steps for a trained muscle. Five levels, so "more colour = more" means one thing everywhere; the lowest
    /// is strong enough to read as colour, not as a stain on the grey.
    private static let opacities: [Double] = [0, 0.42, 0.62, 0.82, 1.0]

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let t = figure.transform(in: size)
                // The parts that are not muscles (head, hands, knees, feet): a quiet neutral, so the body reads whole.
                for p in figure.silhouette {
                    ctx.fill(p.applying(t), with: .color(StrandPalette.textTertiary.opacity(0.22)))
                }
                for (muscle, path) in figure.regions {
                    let shaded = path.applying(t)
                    var lvl = level(muscle)
                    for other in figure.blend[muscle] ?? [] { lvl = max(lvl, level(other)) }
                    // An untouched muscle is a visible grey, never the card's own colour: drawn in the card colour it
                    // vanished, and the body looked cut into pieces.
                    ctx.fill(shaded, with: .color(lvl > 0 ? color.opacity(Self.opacities[min(lvl, 4)])
                                                          : StrandPalette.textTertiary.opacity(0.38)))
                    // The seams between muscles, so each one reads as its own shape.
                    ctx.stroke(shaded, with: .color(StrandPalette.surfaceBase.opacity(0.9)), lineWidth: 1.2)
                    if muscle == selected {
                        ctx.stroke(shaded, with: .color(StrandPalette.textPrimary), lineWidth: 2)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                onTap(figure.muscle(at: value.location, in: geo.size))
            })
        }
        .aspectRatio(figure.viewBox.width / figure.viewBox.height, contentMode: .fit)
    }
}

// MARK: - The screen

struct LiftMuscleMapSheet: View {
    @EnvironmentObject var repo: Repository
    /// Which body outline to draw. A drawing choice, not a statement about anyone.
    @AppStorage("noop.lift.bodyModel") private var bodyModel = "male"

    @State private var map: [LiftMuscleMapEntry] = []
    @State private var loaded = false
    @State private var mode: LiftMuscleMapMode = .recovery
    @State private var selected: LiftMuscle?

    private var sides: (front: BodyFigure, back: BodyFigure)? {
        guard let body = BodyGeometry.shared?.bodies[bodyModel] ?? BodyGeometry.shared?.bodies["male"],
              let f = body["front"].flatMap(BodyFigure.init), let b = body["back"].flatMap(BodyFigure.init) else { return nil }
        return (f, b)
    }

    var body: some View {
        ScreenScaffold(title: "Muscle map",
                       subtitle: "Estimated from the sets you logged, not a measurement of your body.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                modeCard
                figureCard
                if let entry = selectedEntry { detailCard(entry) }
                if loaded && map.allSatisfy(\.isUntrained) { emptyCard } else { listsSection }
            }
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 560, height: 800)
        #endif
        .noopBackdrop(StrandPalette.gymAccent)
        .task { await load() }
    }

    // MARK: - Pieces

    private var modeCard: some View {
        GymCard {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                Picker("Show", selection: $mode) {
                    Text("Recovery").tag(LiftMuscleMapMode.recovery)
                    Text("Sets this week").tag(LiftMuscleMapMode.volume)
                    Text("Left alone").tag(LiftMuscleMapMode.neglect)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(modeCaption)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modeCaption: LocalizedStringKey {
        switch mode {
        case .recovery: return "How fatigued each muscle is now. It fades with rest: arms and shoulders about a day, torso a day and a quarter, legs and lower back two."
        case .volume: return "Sets in the last 7 days: a direct set counts once, an indirect one half. A reading aid, not a target."
        case .neglect: return "Muscles that went longest without a working set. A muscle keeps its full strength for two weeks, then it fades."
        }
    }

    private var tint: Color {
        switch mode {
        case .recovery: return StrandPalette.statusWarning
        case .volume: return StrandPalette.gymAccent
        case .neglect: return StrandPalette.metricAmber
        }
    }

    @ViewBuilder private var figureCard: some View {
        GymCard {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                if let sides {
                    HStack(spacing: 8) {
                        BodyMapFigureView(figure: sides.front, level: levelOf, color: tint, selected: selected) { selected = $0 }
                        BodyMapFigureView(figure: sides.back, level: levelOf, color: tint, selected: selected) { selected = $0 }
                    }
                    .frame(maxHeight: 520)
                    legend
                    Text("Tap a muscle for its numbers.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                } else {
                    Text("The body drawing is not available here. The lists below still show everything.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Picker("Body", selection: $bodyModel) {
                    Text("Male outline").tag("male")
                    Text("Female outline").tag("female")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    /// The five shades the figure uses, from none to most, so the colour can be read without tapping.
    private var legend: some View {
        HStack(spacing: NoopMetrics.space2) {
            Text("Less").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(StrandPalette.textTertiary.opacity(0.38))
                .frame(width: 18, height: 10)
            ForEach([0.42, 0.62, 0.82, 1.0], id: \.self) { step in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(tint.opacity(step))
                    .frame(width: 18, height: 10)
            }
            Text("More").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private func levelOf(_ muscle: LiftMuscle) -> Int {
        map.first { $0.muscle == muscle }.map { LiftMuscleMap.level($0, mode: mode) } ?? 0
    }

    private var selectedEntry: LiftMuscleMapEntry? { selected.flatMap { m in map.first { $0.muscle == m } } }

    private func detailCard(_ e: LiftMuscleMapEntry) -> some View {
        GymCard(tint: tint) {
            VStack(alignment: .leading, spacing: 4) {
                Text(e.muscle.displayName)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Sets this week: \(LiftFormat.trim(e.weeklySets))")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(stateLine(e))
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(lastLine(e))
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    private func stateLine(_ e: LiftMuscleMapEntry) -> String {
        switch e.state {
        case .ready: return String(localized: "Ready")
        case .recovering: return String(localized: "Recovering")
        case .fatigued: return String(localized: "Fatigued")
        }
    }

    private func lastLine(_ e: LiftMuscleMapEntry) -> String {
        guard let days = e.daysSinceTrained else { return String(localized: "Never trained") }
        return days == 0 ? String(localized: "Trained today") : String(localized: "Last trained \(days) days ago")
    }

    private var emptyCard: some View {
        GymCard {
            Text("Log a session and the map fills in: what you worked, what is still recovering, what you have left alone.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var listsSection: some View {
        let recovering = LiftMuscleMap.recovering(map)
        let neglected = LiftMuscleMap.neglected(map)
        let never = LiftMuscleMap.untrained(map)
        if !recovering.isEmpty {
            listCard(title: "Still recovering", lines: recovering.map { "\($0.muscle.displayName) · \(stateLine($0))" })
        }
        if !neglected.isEmpty {
            listCard(title: "Not trained in over two weeks",
                     lines: neglected.map { "\($0.muscle.displayName) · \(lastLine($0))" })
        }
        if !never.isEmpty {
            listCard(title: "Never trained", lines: never.map(\.displayName))
        }
    }

    private func listCard(title: LocalizedStringKey, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            GymSectionTitle(title: title)
            GymCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    ForEach(lines, id: \.self) { line in
                        HStack(spacing: NoopMetrics.space3) {
                            Circle().fill(tint).frame(width: 8, height: 8).accessibilityHidden(true)
                            Text(line)
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Data

    private func load() async {
        guard let store = await repo.storeHandle() else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let sets = (try? await store.liftSetsBefore(deviceId: repo.deviceId, startTs: stamp + 1)) ?? []
        let sessions = (try? await store.liftSessions(deviceId: repo.deviceId, fromTs: 0, toTs: Int.max)) ?? []
        let starts = Dictionary(sessions.map { ($0.id, $0.startTs) }, uniquingKeysWith: { first, _ in first })
        map = LiftMuscleMap.build(sets: sets, sessionStarts: starts, now: stamp)
        loaded = true
    }
}
