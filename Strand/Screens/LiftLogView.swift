import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// The Lift Log: build a program once, then run it in the gym by tapping through it.
//
// This screen is the front door — it lists the saved programs and (from a later phase) the sessions
// run from them. It lives in the Effort colour world, like Workouts, because a finished session
// lands in the `workout` table beside every other workout.
//
// EFFORT IS NEVER MODIFIED HERE (load-bearing). NOOP's Effort is computed from heart rate alone
// (Karvonen %HRR → Edwards TRIMP, `StrainScorer`), and there is no validated public path from typed
// sets/reps/weight to a cardiovascular-strain equivalent — WHOOP's own muscular load runs
// velocity-based algorithms over strap accelerometer/gyroscope data under an unpublished model.
// So the lifting figures are shown BESIDE Effort and never folded into it, matching the choice the
// imported-lifting path already made (`strain: nil, // never a fabricated cardiovascular strain`).

struct LiftLogView: View {
    @EnvironmentObject var repo: Repository

    /// Saved programs, most-recently-touched first. Loaded off the store on appear/refresh.
    @State private var programs: [LiftProgramRow] = []
    /// How many exercise lines each program has, by program id.
    @State private var itemCounts: [String: Int] = [:]
    @State private var loaded = false

    /// The program being created or edited (nil = the editor is closed).
    @State private var editing: ProgramEditTarget?
    /// The routine whose detail sheet is open, and what to do once that sheet has closed.
    @State private var viewingProgram: ProgramEditTarget?
    @State private var afterDetail: (() -> Void)?
    @State private var importing = false
    /// The live session, owned at the app root so it survives this screen going away.
    @EnvironmentObject private var session: LiftSessionController
    /// Recent finished sessions, newest first.
    @State private var history: [LiftSessionRow] = []
    /// Finished sessions since the start of this calendar week, for the week strip.
    @State private var weekSessions: [LiftSessionRow] = []
    /// This week's fractional sets per muscle.
    @State private var weekCounts: [LiftMuscle: Double] = [:]
    /// The session whose detail sheet is open.
    @State private var viewing: SessionDetailTarget?
    /// The exercise library sheet (iOS, where the catalogue ships).
    @State private var browsingLibrary = false
    /// The gyms sheet, and the gym a new session is done at (a preference: see `LiftGymsSheet`).
    @State private var showingGyms = false
    /// The muscle map: volume, recovery and neglect per muscle.
    @State private var showingMuscleMap = false
    /// Strength balance: lifts against each other and against body weight.
    @State private var showingBalance = false
    /// The rotation sheet, and what is up next in it (nil when no program is in a rotation).
    @State private var showingRotation = false
    @State private var rotationNext: LiftRotationNext?
    @AppStorage(LiftGymsSheet.activeKey) private var activeGymId = ""

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    var body: some View {
        ScreenScaffold(
            title: "Lift Log",
            subtitle: "Build a program once, then tap through it at the gym. Kept on \(Platform.deviceNounPhrase).",
            onRefresh: { await load() }
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                todayCard
                weekStrip
                programsSection
                toolsSection
                weekSection
                historySection
                effortNote
            }
        }
        .environment(\.noopBackdropTint, StrandPalette.gymAccent)
        // Also on a saved session: the session sheet lives above this screen and cannot tell it
        // directly, and a save does not always bump `refreshSeq`.
        .task(id: "\(repo.refreshSeq)-\(session.savedSessions)") { await load() }
        .sheet(item: $viewingProgram, onDismiss: {
            let action = afterDetail
            afterDetail = nil
            action?()
        }) { target in
            if let program = target.program {
                LiftProgramDetailSheet(
                    program: program,
                    onEdit: { afterDetail = { editing = ProgramEditTarget(id: program.id, program: program) } },
                    onStart: { afterDetail = { Task { await start(program) } } })
            }
        }
        .sheet(item: $editing) { target in
            LiftProgramEditorSheet(program: target.program) {
                await load()
            }
        }
        .sheet(isPresented: $importing) {
            LiftProgramImportSheet { await load() }
        }
        .sheet(item: $viewing) { target in
            LiftSessionDetailSheet(session: target.session) { await load() }
        }
        .sheet(isPresented: $browsingLibrary) {
            ExerciseLibraryView()
        }
        .sheet(isPresented: $showingGyms) {
            LiftGymsSheet()
        }
        .sheet(isPresented: $showingMuscleMap) {
            LiftMuscleMapSheet()
        }
        .sheet(isPresented: $showingBalance) {
            LiftBalanceSheet()
        }
        .sheet(isPresented: $showingRotation) {
            LiftRotationSheet { await load() }
        }
    }

    // MARK: - This week, day by day

    /// The seven days of this week, openGym style: a short weekday, the date, a dot under a day with a session.
    /// The count and the time are read from the same sessions, so the strip and its numbers cannot disagree.
    private var weekStrip: some View {
        let calendar = Calendar.current
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? calendar.startOfDay(for: Date())
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
        let minutes = weekSessions.reduce(0) { $0 + max(0, (($1.endTs ?? $1.startTs) - $1.startTs) / 60) }

        return VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
            GymSectionTitle(title: "This week")
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                HStack(spacing: 4) {
                    ForEach(days, id: \.self) { day in
                        let trained = weekSessions.contains {
                            calendar.isDate(Date(timeIntervalSince1970: TimeInterval($0.startTs)), inSameDayAs: day)
                        }
                        dayCell(day, trained: trained, today: calendar.isDateInToday(day))
                            .frame(maxWidth: .infinity)
                    }
                }
                Text(String(localized: "\(weekSessions.count) sessions · \(minutes) min"))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .padding(NoopMetrics.gap)
            .frame(maxWidth: .infinity, alignment: .leading)
            .gymCard()
        }
    }

    private func dayCell(_ day: Date, trained: Bool, today: Bool) -> some View {
        VStack(spacing: 4) {
            Text(day.formatted(.dateTime.weekday(.abbreviated)))
                .font(StrandFont.caption.weight(.medium))
                .foregroundStyle(StrandPalette.textSecondary)
            Text(day.formatted(.dateTime.day()))
                .font(StrandFont.body.weight(today ? .bold : .regular))
                .foregroundStyle(today ? StrandPalette.onGymAccent : StrandPalette.textPrimary)
                .frame(width: 34, height: 34)
                .background(today ? StrandPalette.gymAccent : Color.clear, in: Circle())
            Circle()
                .fill(trained ? StrandPalette.gymAccent : Color.clear)
                .frame(width: 5, height: 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(trained
                            ? String(localized: "\(day.formatted(.dateTime.weekday(.wide))): trained")
                            : day.formatted(.dateTime.weekday(.wide)))
    }

    // MARK: - Today: what to do now

    private struct TodayInfo {
        let label: LocalizedStringKey
        let title: String
        let subtitle: String?
        let tag: LocalizedStringKey
        let systemImage: String
        let perform: () -> Void
    }

    /// The one program to start now: the running session first, then what the rotation has up next, then the
    /// program touched most recently.
    private var todayInfo: TodayInfo? {
        if session.isActive {
            return TodayInfo(label: "Workout in progress", title: session.programName ?? String(localized: "Session"),
                             subtitle: nil, tag: "Resume", systemImage: "waveform") { session.isPresented = true }
        } else if let next = rotationNext, let program = programs.first(where: { $0.id == next.step.programId }) {
            return TodayInfo(label: next.isDue ? "Up next" : "Rest day", title: program.name,
                             subtitle: [exerciseCount(program), rotationCaption(next)].compactMap { $0 }.joined(separator: " · "),
                             tag: next.isDue ? "Start" : "Start anyway", systemImage: "dumbbell.fill") {
                Task { await start(program) }
            }
        } else if let program = programs.first {
            return TodayInfo(label: "Start a workout", title: program.name, subtitle: exerciseCount(program),
                             tag: "Start", systemImage: "dumbbell.fill") { Task { await start(program) } }
        } else if loaded {
            return TodayInfo(label: "Start a workout", title: String(localized: "No programs yet"),
                             subtitle: String(localized: "A program is a name and an ordered list of exercises with your targets — working sets, reps, weight, rest and your own technique note."),
                             tag: "New program", systemImage: "plus") {
                editing = ProgramEditTarget(id: "new", program: nil)
            }
        }
        return nil
    }

    @ViewBuilder private var todayCard: some View {
        if let info = todayInfo {
            Button(action: info.perform) {
                HStack(spacing: NoopMetrics.gap) {
                    Image(systemName: info.systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(StrandPalette.onGymAccent)
                        .frame(width: 44, height: 44)
                        .background(StrandPalette.gymAccent, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.label)
                            .font(StrandFont.caption.weight(.semibold))
                            .foregroundStyle(StrandPalette.gymAccent)
                            .textCase(.uppercase)
                        Text(info.title)
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(2)
                        if let sub = info.subtitle, !sub.isEmpty {
                            Text(sub)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                    GymTag(title: info.tag)
                }
                .padding(NoopMetrics.gap)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .gymCard()
        }
    }

    private func exerciseCount(_ program: LiftProgramRow) -> String? {
        guard let count = itemCounts[program.id], count > 0 else { return nil }
        return String(localized: "\(count) exercises")
    }

    // MARK: - Tools

    private struct Tool: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        let tint: Color
        let open: () -> Void
    }

    private var tools: [Tool] {
        var list: [Tool] = []
        if ExerciseLibrary.shared != nil {
            list.append(Tool(id: "library", title: String(localized: "Exercise library"), systemImage: "books.vertical.fill",
                             tint: StrandPalette.gymAccent) { browsingLibrary = true })
        }
        list.append(Tool(id: "rotation", title: String(localized: "Rotation"), systemImage: "arrow.triangle.2.circlepath",
                         tint: StrandPalette.metricPurple) { showingRotation = true })
        list.append(Tool(id: "map", title: String(localized: "Muscle map"), systemImage: "figure.arms.open",
                         tint: StrandPalette.metricRose) { showingMuscleMap = true })
        list.append(Tool(id: "balance", title: String(localized: "Strength balance"), systemImage: "scale.3d",
                         tint: StrandPalette.metricAmber) { showingBalance = true })
        list.append(Tool(id: "gyms", title: String(localized: "Gyms and plates"), systemImage: "scalemass.fill",
                         tint: StrandPalette.metricCyan) { showingGyms = true })
        list.append(Tool(id: "import", title: String(localized: "Import"), systemImage: "tablecells",
                         tint: StrandPalette.accent) { importing = true })
        return list
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
            GymSectionTitle(title: "Tools")
            GymList {
                ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                    Button(action: tool.open) {
                        GymListRow(systemImage: tool.systemImage, tint: tool.tint, title: tool.title,
                                   divider: index < tools.count - 1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Programs

    private var programsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
            GymSectionTitle(title: "Programs")
            if !loaded {
                ComingSoon(what: "Reading your programs…", symbol: "dumbbell")
            } else {
                GymList {
                    ForEach(programs, id: \.id) { program in
                        Button {
                            viewingProgram = ProgramEditTarget(id: program.id, program: program)
                        } label: {
                            GymListRow(systemImage: "dumbbell.fill", title: program.name,
                                       subtitle: [exerciseCount(program), program.note].compactMap { $0 }
                                           .filter { !$0.isEmpty }.joined(separator: " · "))
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        editing = ProgramEditTarget(id: "new", program: nil)
                    } label: {
                        HStack(spacing: NoopMetrics.gap) {
                            Image(systemName: "plus")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(StrandPalette.gymAccent)
                                .frame(width: 30, height: 30)
                                .background(StrandPalette.gymAccent.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Text("New program")
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.gymAccent)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, NoopMetrics.gap)
                        .frame(minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Start a session

    /// Flatten a program into the plan the session runs. The plan is SNAPSHOT at start: editing or
    /// deleting the program mid-session cannot change what is being tapped through.
    private func start(_ program: LiftProgramRow) async {
        guard let store = await repo.storeHandle() else { return }
        let items = (try? await store.liftProgramItems(programId: program.id)) ?? []
        guard !items.isEmpty else { return }
        let vocabulary = (try? await store.liftExercises(deviceId: repo.deviceId)) ?? []
        // What a line's rule needs: the history of its exercise, and when each session happened.
        let hasRule = items.contains { LiftProgressionStore.policy(of: $0) != nil }
        let history = hasRule
            ? ((try? await store.liftSetsBefore(deviceId: repo.deviceId, startTs: Int(Date().timeIntervalSince1970) + 1)) ?? [])
            : []
        let starts = hasRule
            ? Dictionary(((try? await store.liftSessions(deviceId: repo.deviceId, fromTs: 0, toTs: Int.max)) ?? [])
                .map { ($0.id, $0.startTs) }, uniquingKeysWith: { first, _ in first })
            : [:]

        let plan = items.map { item -> LiftPlanItem in
            // The classification comes from the exercise vocabulary, which is the one place that owns
            // it — the program line deliberately stores no muscle of its own to drift from.
            let known = vocabulary.first { $0.name == item.exercise }
            let line = LiftPlanItem(exercise: item.exercise,
                                primaryMuscle: known?.primaryMuscle,
                                secondaryMuscles: known?.secondaryMuscles ?? [],
                                targetSets: item.targetSets,
                                restSec: item.restSec,
                                targetRepsLow: item.targetRepsLow,
                                targetRepsHigh: item.targetRepsHigh,
                                targetRpe: item.targetRpe,
                                targetWeightKg: item.targetWeightKg,
                                note: item.note,
                                // Carried so a set added or dropped mid-session can be written back
                                // onto the line it came from, and be there next time.
                                programItemId: item.id,
                                // Decides whether a gym's plates apply to this line.
                                equipment: known?.equipment,
                                supersetGroup: item.supersetGroup,
                                backups: item.backups)
            // A line with a progression rule runs on the rule's target for today, derived from what this
            // exercise did before (by name, or by the library exercise the name is linked to).
            let sets = history.filter { $0.exercise == item.exercise || (item.catalogueId != nil && $0.catalogueId == item.catalogueId) }
            guard let prescription = LiftProgressionStore.prescription(for: item, lineSets: sets, sessionStarts: starts) else {
                return line
            }
            return line.applying(prescription, stamp: LiftProgressionStore.stamp(for: item))
        }
        // Refuse to start a second session over a running one: two live sessions would both claim
        // the strap gesture and both write the in-flight snapshot.
        guard !session.isActive else {
            session.isPresented = true
            return
        }
        // The gym this session is done at: the one in use if it still exists, else the one used most recently.
        // It is marked used now, so it is offered first next time.
        let gyms = (try? await store.liftGyms(deviceId: repo.deviceId)) ?? []
        let gym = gyms.first { $0.id == activeGymId } ?? gyms.first
        if var used = gym {
            used.lastUsedTs = Int(Date().timeIntervalSince1970)
            _ = try? await store.upsertLiftGyms([used])
        }
        session.start(plan: plan, programId: program.id, programName: program.name, gymId: gym?.id)
    }

    // MARK: - This week, per muscle

    private var weekSection: some View {
        let ordered = LiftMuscle.ordered.filter { (weekCounts[$0] ?? 0) > 0 }
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            GymSectionTitle(title: "Sets per muscle")
            VStack(alignment: .leading) {
                if ordered.isEmpty {
                    Text("Once you've logged a session, this shows how many sets each muscle got this week, against what the research associates with growth.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                        ForEach(ordered, id: \.self) { muscle in
                            muscleBar(muscle, sets: weekCounts[muscle] ?? 0)
                        }
                        // The band is named and sourced, never phrased as a target NOOP sets for
                        // anyone: this is not a medical device and does not prescribe.
                        Text("Counted from the muscles you assigned each exercise: direct sets count once, indirect ones half. The tick is about 4 sets a week — below that, studies across GROUPS of people stop reliably detecting growth. It is a research reference, not a target for you, and above it gains continue with strongly diminishing returns and no clear ceiling, so the bar has no \"full\".")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(NoopMetrics.gap)
            .frame(maxWidth: .infinity, alignment: .leading)
            .gymCard()
        }
    }

    /// The span the weekly bar is drawn across.
    ///
    /// A DRAWING choice, not a dose. The evidence puts a floor at about 4 sets a week and identifies
    /// NO ceiling for hypertrophy — gains continue above it with strongly diminishing returns — so
    /// any bar maximum is arbitrary and must never be read as a target. 20 is chosen only because it
    /// comfortably contains the range people actually train in, which puts the floor tick early on
    /// the bar and makes a normal week read as progress rather than as "finished".
    ///
    /// The NUMBER beside the bar is the truth. The bar is context for it, and a count past 20 fills
    /// the bar while the number keeps counting.
    private static let weeklySetsBarSpan = 20.0

    /// One muscle's week: the count, and where it sits relative to the evidence.
    ///
    /// This used to scale the bar 0...4 and turn it FULL and GREEN at four sets — so the screen said
    /// "done" at the exact point the research says growth merely becomes *detectable*. It was telling
    /// the user to stop at the starting line, and it contradicted the caption printed directly below
    /// it. Now four sets is a TICK a fifth of the way along, and nothing on the bar ever reads as
    /// complete, because nothing about the dose is.
    private func muscleBar(_ muscle: LiftMuscle, sets: Double) -> some View {
        let floor = LiftMetrics.ReferenceDose.hypertrophyMinimumSetsPerWeek
        let atOrAboveFloor = sets >= floor
        let fill = min(1.0, sets / Self.weeklySetsBarSpan)
        let tick = min(1.0, floor / Self.weeklySetsBarSpan)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(muscle.displayName)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 0)
                // Deliberately NOT a success colour. There is no success point to signal, and a
                // green number is exactly what made four sets read as an achievement.
                Text(LiftFormat.trim(sets))
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(StrandPalette.surfaceRaised)
                    Capsule()
                        // Muted below the floor — below it growth is not reliably detectable, which
                        // is worth showing — and the ordinary accent above it. Never a "done" colour.
                        .fill(StrandPalette.gymAccent.opacity(atOrAboveFloor ? 1.0 : 0.45))
                        .frame(width: max(2, geo.size.width * fill))
                    // The floor, marked where it actually falls.
                    Capsule()
                        .fill(StrandPalette.textPrimary.opacity(0.45))
                        .frame(width: 2)
                        .offset(x: max(0, geo.size.width * tick - 1))
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(atOrAboveFloor
                                ? String(localized: "\(muscle.displayName): \(LiftFormat.trim(sets)) sets, at or above the weekly floor of \(LiftFormat.trim(floor))")
                                : String(localized: "\(muscle.displayName): \(LiftFormat.trim(sets)) sets, below the weekly floor of \(LiftFormat.trim(floor))"))
        }
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
            GymSectionTitle(title: "Sessions")
            if history.isEmpty {
                Text("Finished sessions land here, with every set you logged.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(NoopMetrics.gap)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .gymCard()
            } else {
                GymList {
                    ForEach(Array(history.enumerated()), id: \.element.id) { index, session in
                        Button {
                            viewing = SessionDetailTarget(id: session.id, session: session)
                        } label: {
                            historyRow(session, divider: index < history.count - 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func historyRow(_ session: LiftSessionRow, divider: Bool) -> some View {
        let date = Date(timeIntervalSince1970: TimeInterval(session.startTs))
        let minutes = max(0, ((session.endTs ?? session.startTs) - session.startTs) / 60)
        let leaf = VStack(spacing: 0) {
            Text(date.formatted(.dateTime.month(.abbreviated)).uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(StrandPalette.gymAccent)
            Text(date.formatted(.dateTime.day()))
                .font(StrandFont.rounded(17, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
        return GymListRow(leading: AnyView(leaf),
                          title: session.programName ?? String(localized: "Session"),
                          subtitle: String(localized: "\(date.formatted(date: .abbreviated, time: .shortened)) · \(minutes) min"),
                          divider: divider)
    }

    // MARK: - Effort

    private var effortNote: some View {
        Text("Lifting adds volume and set counts. It never changes your Effort, which stays measured from heart rate.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Load

    private func load() async {
        guard let store = await repo.storeHandle() else { return }
        programs = (try? await store.liftPrograms(deviceId: repo.deviceId)) ?? []
        var counts: [String: Int] = [:]
        for program in programs {
            counts[program.id] = ((try? await store.liftProgramItems(programId: program.id)) ?? []).count
        }
        itemCounts = counts

        let now = Int(Date().timeIntervalSince1970)
        history = ((try? await store.liftSessions(deviceId: repo.deviceId,
                                                  fromTs: now - 180 * 86_400,
                                                  toTs: now)) ?? [])
            .filter { $0.endTs != nil }                 // an abandoned session is not history
            .sorted { $0.startTs > $1.startTs }
        let weekStart = Int((Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start
                             ?? Calendar.current.startOfDay(for: Date())).timeIntervalSince1970)
        weekSessions = history.filter { $0.startTs >= weekStart }
        weekCounts = (try? await store.liftSetCounts(deviceId: repo.deviceId,
                                                      fromTs: now - 7 * 86_400,
                                                      toTs: now).fractional) ?? [:]
        // What is up next in the rotation follows the last session of any of its programs, however old.
        let all = (try? await store.liftSessions(deviceId: repo.deviceId, fromTs: 0, toTs: now + 86_400)) ?? []
        rotationNext = LiftRotation.next(steps: LiftRotation.steps(programs), sessions: all,
                                         today: LiftRotation.localDay(now))
        loaded = true
    }

    // MARK: - The rotation

    private func rotationCaption(_ next: LiftRotationNext) -> String {
        switch next.state {
        case .notStarted:
            return String(localized: "The first program of your rotation")
        case .due(let overdue):
            let after = next.after?.name ?? ""
            return overdue == 0
                ? String(localized: "Due today, after \(after)")
                : String(localized: "Overdue by \(overdue) days, after \(after)")
        case .rest(_, let left):
            return left == 1
                ? String(localized: "Due tomorrow")
                : String(localized: "Due in \(left) days")
        }
    }
}

/// The session whose detail is being read back. A wrapper rather than a retroactive `Identifiable`
/// on `LiftSessionRow`, keeping the store's row types free of app-layer conformances.
private struct SessionDetailTarget: Identifiable {
    let id: String
    let session: LiftSessionRow
}


/// Identifies what the editor sheet is editing. A wrapper rather than a retroactive `Identifiable`
/// on `LiftProgramRow`, so the store's row types stay free of app-layer conformances — and so
/// "new program" has an identity of its own to present on.
private struct ProgramEditTarget: Identifiable {
    let id: String
    let program: LiftProgramRow?
}
