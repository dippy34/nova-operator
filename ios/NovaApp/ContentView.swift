import SwiftUI
import UIKit
import Charts

enum FaceMood { case idle, listening, working, speaking, happy, confused }

struct NovaFace: View {
    var mood: FaceMood
    var size: CGFloat = 1
    @State private var blink = false
    private var color: Color {
        switch mood {
        case .idle: .cyan
        case .listening: Color(red:0.85,green:0.5,blue:1)
        case .working: .orange
        case .speaking, .happy: .mint
        case .confused: Color(red:1,green:0.45,blue:0.45)
        }
    }
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let glance = mood == .working ? sin(t*2.2)*22 : 0
            VStack(spacing: 46) {
                HStack(spacing: 70) {
                    eye(left: true).offset(x: glance)
                    eye(left: false).offset(x: glance)
                }
                mouth(t: t).frame(height: 40)
            }
            .offset(y: sin(t*1.6)*6)
            .scaleEffect(size)
            .frame(width: 260*size, height: 260*size)
            .shadow(color: color.opacity(0.8), radius: 24*size)
        }
        .animation(.spring(duration: 0.4), value: mood)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 2.5...5)))
                withAnimation(.easeInOut(duration: 0.08)) { blink = true }
                try? await Task.sleep(for: .milliseconds(110))
                withAnimation(.easeInOut(duration: 0.1)) { blink = false }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(mood == .listening ? "Nova is listening. Tap to send." : mood == .working ? "Nova is working" : mood == .speaking ? "Nova is speaking" : "Nova. Tap to talk, press and hold for more.")
    }
    @ViewBuilder private func eye(left: Bool) -> some View {
        if mood == .happy && !blink {
            HappyEye().stroke(color, style: StrokeStyle(lineWidth: 18, lineCap: .round)).frame(width: 62, height: 40).frame(height: 108)
        } else {
            let height: CGFloat = blink ? 8 : mood == .listening ? 128 : mood == .confused ? (left ? 70 : 108) : 108
            Capsule().fill(color).frame(width: 58, height: height)
                .rotationEffect(.degrees(mood == .confused ? (left ? -12 : 8) : 0))
                .frame(height: 128)
        }
    }
    @ViewBuilder private func mouth(t: Double) -> some View {
        switch mood {
        case .speaking, .listening:
            HStack(spacing: 7) {
                ForEach(0..<7, id: \.self) { i in
                    Capsule().fill(color)
                        .frame(width: 9, height: mood == .speaking ? 10+abs(sin(t*9+Double(i)*0.9))*30 : 10+abs(sin(t*3+Double(i)*0.6))*10)
                }
            }
        case .happy:
            HappyEye().stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round)).frame(width: 90, height: 26).rotationEffect(.degrees(180))
        case .confused:
            Capsule().fill(color).frame(width: 60, height: 10).rotationEffect(.degrees(-8))
        default:
            Capsule().fill(color.opacity(mood == .working ? 0.7 : 1)).frame(width: mood == .working ? 36 : 90, height: 10)
        }
    }
}

/// An upward arc: a smiling eye, or (rotated) a smile.
struct HappyEye: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY - rect.height*0.6))
        return path
    }
}

/// An animated glow around the screen's rounded edges, shown while Nova listens.
struct EdgeGlow: View {
    var level: CGFloat
    private let shape = RoundedRectangle(cornerRadius: 47, style: .continuous)
    var body: some View {
        TimelineView(.animation) { context in
            let angle = Angle.degrees(context.date.timeIntervalSinceReferenceDate * 80)
            let gradient = AngularGradient(colors: [.cyan, .blue, .purple, .pink, .orange, .yellow, .cyan], center: .center, angle: angle)
            ZStack {
                shape.stroke(gradient, lineWidth: 5 + level*6)
                shape.stroke(gradient, lineWidth: 14 + level*22).blur(radius: 12)
                shape.stroke(gradient, lineWidth: 34 + level*44).blur(radius: 36).opacity(0.75)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

enum Stage { case face, progress, screen, control, visual, result }

struct ContentView: View {
    @EnvironmentObject private var nova: NovaModel
    @ObservedObject private var listenerState: Listener
    @ObservedObject private var speakerState: Speaker
    @State private var showPanel = false
    @State private var showScreen = false
    @State private var showWork = false
    @Namespace private var space
    init(nova: NovaModel) { listenerState = nova.listener; speakerState = nova.speaker }

    private var computerTask: Bool { nova.working && nova.chat?.type == "computer.task" }
    private var usedComputer: Bool { nova.chat?.events.contains { $0.kind == "action" } == true }
    /// Nova stays a face unless it is using the Mac or drawing something.
    private var stage: Stage {
        if listenerState.listening { return nova.visuals.isEmpty ? .face : .visual }
        if nova.controlling { return .control }
        if showScreen { return .screen }
        if computerTask && usedComputer { return .progress }
        if !nova.visuals.isEmpty { return .visual }
        if nova.result != nil && usedComputer { return .result }
        return .face
    }
    private var mood: FaceMood {
        if listenerState.listening { return .listening }
        if nova.working { return .working }
        if speakerState.speaking { return .speaking }
        if let result = nova.result { return result.ok ? .happy : .confused }
        return .idle
    }

    var body: some View {
        ZStack {
            Color(red:0.02,green:0.03,blue:0.06).ignoresSafeArea()
            if nova.paired {
                if stage == .face {
                    ZStack {
                        WorkOrbit(count: nova.work?.running.count ?? 0)
                        NovaFace(mood: mood)
                            .matchedGeometryEffect(id: "face", in: space)
                    }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { Task { await nova.tapFace() } }
                        .onLongPressGesture { showPanel = true }
                        .gesture(DragGesture(minimumDistance: 40).onEnded { drag in
                            guard nova.computer?.owner == true else { return }
                            if drag.translation.height < -60 { showScreen = true }
                            else if drag.translation.width < -60 { showWork = true }
                        })
                    faceExtras
                } else if stage == .control {
                    ControlStage(mood: mood)
                } else {
                    VStack(spacing: 18) {
                        header
                        Group {
                            switch stage {
                            case .progress: ProgressStage()
                            case .screen: ScreenStage(inControl: computerTask)
                            case .control: ControlStage()
                            case .visual: VisualStage()
                            default: ResultStage()
                            }
                        }
                        .transition(.asymmetric(insertion: .scale(scale: 0.6, anchor: .top).combined(with: .opacity), removal: .opacity))
                        if ![.visual, .control].contains(stage) { controls }
                    }
                    .padding(.horizontal)
                }
                if listenerState.listening {
                    EdgeGlow(level: listenerState.level).transition(.opacity)
                }
            } else {
                ScrollView { pairing.padding() }
            }
        }
        .animation(.spring(duration: 0.55, bounce: 0.2), value: stage)
        .animation(.easeInOut(duration: 0.3), value: listenerState.listening)
        .onChange(of: nova.controlling) { _, on in AppDelegate.landscape(on) }
        .onChange(of: nova.requestedView) { _, view in
            if view == "screen" { showScreen = true } else if view == "work" { showWork = true }
            nova.requestedView = nil
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showPanel) { NovaPanel() }
        .sheet(isPresented: $showWork) {
            NavigationStack {
                WorkView(onShow: { showWork = false })
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showWork = false } } }
            }
            .presentationDragIndicator(.visible)
        }
        .alert("Nova", isPresented:Binding(get:{nova.errorMessage != nil && !showPanel}, set:{ if !$0 {nova.errorMessage = nil} })) {
            Button("OK") {nova.errorMessage = nil}
        } message: {Text(nova.errorMessage ?? "")}
        .task {
            while !Task.isCancelled {
                if nova.paired {await nova.refresh()}
                try? await Task.sleep(for: .seconds(nova.working ? 1 : 4))
            }
        }
    }

    /// The face shrinks into this corner when Nova has something to show; tapping it still talks.
    private var header: some View {
        HStack(spacing: 14) {
            NovaFace(mood: mood, size: 0.28)
                .matchedGeometryEffect(id: "face", in: space)
                .contentShape(Rectangle())
                .onTapGesture { Task { await nova.tapFace() } }
                .onLongPressGesture { showPanel = true }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(subtitle(now: context.date)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer()
            Button {
                if stage == .visual { nova.speaker.stop(); nova.clearVisuals() }
                else if stage == .control { Task { await nova.handBack() } }
                else { showScreen = false; nova.dismissResult() }
            } label: {
                Image(systemName: "xmark").font(.headline).padding(10).background(.white.opacity(0.08), in: Circle())
            }.accessibilityLabel("Back to Nova's face")
        }
        .padding(.top, 8)
    }
    private var title: String {
        switch stage {
        case .screen: computerTask ? "Nova is in control" : "Your Mac"
        case .progress: "Working on it"
        case .control: "You're driving"
        case .visual: nova.visuals.indices.contains(nova.page) ? nova.visuals[nova.page].title ?? "Nova" : "Nova"
        default: nova.result?.ok == false ? "Something went wrong" : "Done"
        }
    }
    private func subtitle(now: Date) -> String {
        let steps = nova.chat?.events.filter { $0.kind == "action" }.count ?? 0
        if nova.working, let start = nova.workStarted {
            let seconds = Int(now.timeIntervalSince(start))
            return "\(steps) step\(steps == 1 ? "" : "s") · \(seconds / 60):\(String(format: "%02d", seconds % 60))"
        }
        if stage == .screen { return "Live view" }
        if stage == .control { return "Tap to click · hold to right-click" }
        if stage == .visual { return nova.visuals.count > 1 ? "\(nova.page + 1) of \(nova.visuals.count)" : "" }
        if let cost = nova.result?.cost { return String(format: "\(steps) steps · $%.3f", cost) }
        return ""
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if nova.computer?.owner == true {
                Button { showScreen.toggle() } label: {
                    Label(showScreen ? (computerTask ? "Progress" : "Close screen") : "Show screen", systemImage: showScreen ? "list.bullet" : "display")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(.cyan)
            }
            if stage == .screen {
                Button { showScreen = false; nova.takeOver() } label: {
                    Label("Take over", systemImage: "hand.point.up.left.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(.cyan)
            }
            if computerTask {
                Button(role: .destructive) { Task { await nova.stopTask() } } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(.red)
            }
        }
        .controlSize(.large)
        .padding(.bottom, 8)
    }
    /// A banner for the newest report, and a pill summarizing background work. Both open the Work view.
    @ViewBuilder private var faceExtras: some View {
        VStack {
            if let report = nova.banner {
                Button { showWork = true } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: report.ok ? "tray.full.fill" : "exclamationmark.triangle.fill")
                            .font(.title3).foregroundStyle(report.ok ? .cyan : .orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(report.title).font(.subheadline.bold())
                            Text(report.message).font(.caption).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
            if let work = nova.work, !(work.running.isEmpty && work.schedules.isEmpty) {
                Button { showWork = true } label: {
                    Label(workSummary(work), systemImage: work.running.isEmpty ? "calendar.badge.clock" : "sparkles")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.white.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .animation(.spring(duration: 0.5), value: nova.banner)
    }
    private func workSummary(_ work: NovaWork) -> String {
        var parts: [String] = []
        if !work.running.isEmpty { parts.append("\(work.running.count) working") }
        if !work.schedules.isEmpty { parts.append("\(work.schedules.count) scheduled") }
        return parts.joined(separator: " · ")
    }
    private var pairing: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Connect to your Mac").font(.title2.bold())
            Text("Run Nova Core and Tailscale Serve on the Mac, then enter its HTTPS address and one-time pairing code.")
                .foregroundStyle(.secondary).font(.subheadline)
            TextField("https://mac.example.ts.net",text:$nova.address)
                .textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(.URL).textFieldStyle(.roundedBorder)
            TextField("One-time pairing code",text:$nova.pairingCode)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            Button {Task {await nova.pair()}} label: {
                Label(nova.busy ? "Pairing..." : "Pair Nova",systemImage:"link").frame(maxWidth:.infinity)
            }.buttonStyle(.borderedProminent).disabled(nova.busy || nova.pairingCode.isEmpty)
        }.padding().background(.white.opacity(0.06),in:RoundedRectangle(cornerRadius:16))
    }

}

/// Nova's narration as a big caption, above a timeline of its actions.
struct ProgressStage: View {
    @EnvironmentObject private var nova: NovaModel
    var body: some View {
        let events = nova.chat?.events.filter { ["narration","action"].contains($0.kind) } ?? []
        VStack(alignment: .leading, spacing: 16) {
            if let question = nova.chat?.payload["message"] {
                Text("“\(question.description)”").font(.subheadline).foregroundStyle(.cyan).lineLimit(2)
            }
            Text(events.last(where: { $0.kind == "narration" })?.description ?? "Getting started…")
                .font(.title2.weight(.semibold))
                .contentTransition(.opacity)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeInOut, value: events.count)
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                            StepRow(event: event, current: index == events.count - 1)
                                .id(event.id)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                }
                .onChange(of: events.count) { withAnimation { scroller.scrollTo(events.last?.id, anchor: .bottom) } }
            }
            if let data = nova.computerScreen, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12)))
                    .frame(maxHeight: 150)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct StepRow: View {
    let event: NovaEvent
    let current: Bool
    @State private var pulse = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(current ? Color.orange : Color.mint.opacity(0.8)).frame(width: 12, height: 12)
                    if current { Circle().stroke(Color.orange, lineWidth: 2).frame(width: 22, height: 22).scaleEffect(pulse ? 1.3 : 0.8).opacity(pulse ? 0 : 1) }
                }.frame(width: 22, height: 22)
                Rectangle().fill(.white.opacity(0.12)).frame(width: 2).frame(maxHeight: .infinity)
            }
            Label(event.description, systemImage: event.kind == "narration" ? "text.bubble" : icon)
                .font(event.kind == "narration" ? .subheadline : .caption)
                .foregroundStyle(event.kind == "narration" ? .primary : .secondary)
                .padding(.vertical, 3)
                .padding(.bottom, 10)
            Spacer(minLength: 0)
        }
        .onAppear { withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulse = true } }
    }
    private var icon: String {
        let text = event.description.lowercased()
        if text.hasPrefix("typed") { return "keyboard" }
        if text.hasPrefix("pressed") { return "command" }
        if text.hasPrefix("scrolled") { return "scroll" }
        if text.hasPrefix("dragged") { return "hand.draw" }
        return "cursorarrow.click"
    }
}

/// A live view of the Mac, with a ring where Nova last acted.
struct ScreenStage: View {
    @EnvironmentObject private var nova: NovaModel
    var inControl: Bool
    @State private var zoom: CGFloat = 1
    @State private var pulse = false
    var body: some View {
        VStack(spacing: 14) {
            if let data = nova.liveScreen ?? nova.computerScreen, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
                    .overlay {
                        GeometryReader { geometry in
                            if inControl, let target = nova.target {
                                Circle().stroke(Color.cyan, lineWidth: 3).frame(width: 34, height: 34)
                                    .scaleEffect(pulse ? 1.4 : 0.8).opacity(pulse ? 0.2 : 1)
                                    .position(x: target.x * geometry.size.width, y: target.y * geometry.size.height)
                                    .animation(.spring, value: target)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(inControl ? Color.orange : Color.white.opacity(0.15), lineWidth: inControl ? 2 : 1))
                    .shadow(color: (inControl ? Color.orange : Color.cyan).opacity(0.35), radius: 18)
                    .scaleEffect(zoom)
                    .gesture(MagnifyGesture().onChanged { zoom = min(3, max(1, $0.magnification)) }.onEnded { _ in withAnimation(.spring) { zoom = 1 } })
                    .onAppear { withAnimation(.easeOut(duration: 1).repeatForever(autoreverses: false)) { pulse = true } }
            } else {
                ProgressView("Connecting to your Mac…").frame(maxWidth: .infinity, minHeight: 220)
            }
            if inControl, let line = nova.chat?.events.last(where: { $0.kind == "narration" })?.description {
                Text(line).font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).contentTransition(.opacity)
            } else if !inControl {
                Text("Tap Nova's face and ask it to do anything here.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: .infinity)
        .task { await nova.watchScreen() }
    }
}

/// Nova's answer after a task, until dismissed or 20 seconds pass.
struct ResultStage: View {
    @EnvironmentObject private var nova: NovaModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let question = nova.chat?.payload["message"] {
                Text("“\(question.description)”").font(.subheadline).foregroundStyle(.cyan).lineLimit(2)
            }
            Text(nova.result?.text ?? "")
                .font(.title3.weight(.medium))
                .textSelection(.enabled)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
            if let data = nova.computerScreen, nova.chat?.type == "computer.task", let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12)).frame(maxHeight: 200)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Nova's face formed into whatever it is explaining. Several visuals page horizontally.
struct VisualStage: View {
    @EnvironmentObject private var nova: NovaModel
    var body: some View {
        TabView(selection: $nova.page) {
            ForEach(Array(nova.visuals.enumerated()), id: \.offset) { index, visual in
                VisualView(visual: visual, revealed: nova.revealed[index] ?? visual.steps?.count ?? 0)
                    .padding(.bottom, nova.visuals.count > 1 ? 34 : 8)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: nova.visuals.count > 1 ? .always : .never))
    }
}

struct VisualView: View {
    let visual: NovaVisual
    let revealed: Int
    var body: some View {
        switch visual.type {
        case "graph": GraphView(visual: visual)
        case "chart": ChartView(visual: visual)
        case "board": BoardView(visual: visual, revealed: revealed)
        case "cards": CardsView(items: visual.items ?? [])
        case "table": TableView(columns: visual.columns ?? [], rows: visual.rows ?? [])
        default: Text(visual.title ?? "").font(.title2)
        }
    }
}

private let plotColors: [Color] = [.cyan, .pink, .yellow, .mint, .orange, .purple]

/// Evaluates math in x, such as "x^2 - 5x + 6", "2sin(x)" or "sqrt(|x|)".
struct MathExpression {
    indirect enum Node { case number(Double), x, call(String, Node), op(Character, Node, Node), negate(Node) }
    private let root: Node
    init?(_ text: String) {
        var source = text.lowercased()
        for (from, to) in ["−":"-", "×":"*", "·":"*", "÷":"/", "²":"^2", "³":"^3", "π":"pi", "√":"sqrt", " ":""] { source = source.replacingOccurrences(of: from, with: to) }
        for prefix in ["y=", "f(x)="] where source.hasPrefix(prefix) { source.removeFirst(prefix.count) }
        var parser = Parser(chars: Array(source))
        guard let node = parser.sum(), parser.index == parser.chars.count else { return nil }
        root = node
    }
    func callAsFunction(_ x: Double) -> Double { Self.evaluate(root, x) }
    private static func evaluate(_ node: Node, _ x: Double) -> Double {
        switch node {
        case .number(let value): return value
        case .x: return x
        case .negate(let inner): return -evaluate(inner, x)
        case .op(let op, let a, let b):
            let l = evaluate(a, x), r = evaluate(b, x)
            switch op { case "+": return l + r; case "-": return l - r; case "*": return l * r; case "/": return l / r; default: return pow(l, r) }
        case .call(let name, let inner):
            let v = evaluate(inner, x)
            switch name {
            case "sin": return sin(v); case "cos": return cos(v); case "tan": return tan(v)
            case "asin": return asin(v); case "acos": return acos(v); case "atan": return atan(v)
            case "sqrt": return sqrt(v); case "abs": return abs(v); case "ln": return log(v); case "log": return log10(v)
            case "exp": return exp(v); case "floor": return floor(v); default: return ceil(v)
            }
        }
    }
    struct Parser {
        let chars: [Character]
        var index = 0
        private static let names = ["asin","acos","atan","sqrt","floor","ceil","sin","cos","tan","abs","exp","ln","log","pi","x","e"]
        private var next: Character? { index < chars.count ? chars[index] : nil }
        private mutating func eat(_ c: Character) -> Bool { if next == c { index += 1; return true }; return false }
        mutating func sum() -> Node? {
            guard var node = product() else { return nil }
            while let c = next, c == "+" || c == "-" {
                index += 1
                guard let rhs = product() else { return nil }
                node = .op(c, node, rhs)
            }
            return node
        }
        mutating func product() -> Node? {
            guard var node = signed() else { return nil }
            while let c = next {
                if c == "*" || c == "/" {
                    index += 1
                    guard let rhs = signed() else { return nil }
                    node = .op(c, node, rhs)
                } else if c.isLetter || c.isNumber || c == "." || c == "(" {
                    guard let rhs = power() else { return nil }
                    node = .op("*", node, rhs)
                } else { break }
            }
            return node
        }
        mutating func signed() -> Node? {
            if eat("-") { return signed().map { .negate($0) } }
            if eat("+") { return signed() }
            return power()
        }
        mutating func power() -> Node? {
            guard let base = atom() else { return nil }
            if eat("^") { return signed().map { .op("^", base, $0) } }
            return base
        }
        mutating func atom() -> Node? {
            guard let c = next else { return nil }
            if c.isNumber || c == "." {
                let start = index
                while let d = next, d.isNumber || d == "." { index += 1 }
                return Double(String(chars[start..<index])).map { .number($0) }
            }
            if eat("(") { let inner = sum(); return eat(")") ? inner : nil }
            if eat("|") { let inner = sum(); return eat("|") ? inner.map { .call("abs", $0) } : nil }
            let rest = String(chars[index...])
            guard let name = Self.names.first(where: { rest.hasPrefix($0) }) else { return nil }
            index += name.count
            switch name {
            case "x": return .x
            case "pi": return .number(.pi)
            case "e": return .number(M_E)
            default: return power().map { .call(name, $0) }
            }
        }
    }
}

/// A function plot that draws itself left to right, with labeled points.
struct GraphView: View {
    let visual: NovaVisual
    @State private var drawn: CGFloat = 0
    private struct Sample: Identifiable { let id: Int; let x: Double; let y: Double; let segment: String; let label: String }

    var body: some View {
        let functions = (visual.functions ?? []).compactMap { f in MathExpression(f.expression).map { (label: f.label ?? f.expression, fn: $0) } }
        let points = visual.points ?? []
        let xs = range(visual.x_range) ?? fallbackX(points)
        let raw = functions.map { f in (0...240).map { i -> (Double, Double) in let x = xs.lowerBound + (xs.upperBound - xs.lowerBound) * Double(i) / 240; return (x, f.fn(x)) } }
        let ys = range(visual.y_range) ?? fallbackY(raw.flatMap { $0.map(\.1) } + points.map(\.y))
        let span = ys.upperBound - ys.lowerBound
        var samples: [Sample] = []
        for (f, values) in raw.enumerated() {
            var segment = 0, last: Double?
            for (i, (x, y)) in values.enumerated() {
                guard y.isFinite, y > ys.lowerBound - span * 2, y < ys.upperBound + span * 2 else { segment += 1; last = nil; continue }
                if let last, abs(y - last) > span { segment += 1 }
                samples.append(Sample(id: f * 1000 + i, x: x, y: y, segment: "\(f)-\(segment)", label: functions[f].label))
                last = y
            }
        }
        let labels = functions.map(\.label)
        return VStack(alignment: .leading, spacing: 12) {
            Chart {
                if ys.contains(0) { RuleMark(y: .value("x axis", 0)).foregroundStyle(.white.opacity(0.35)) }
                if xs.contains(0) { RuleMark(x: .value("y axis", 0)).foregroundStyle(.white.opacity(0.35)) }
                ForEach(samples) { s in
                    LineMark(x: .value("x", s.x), y: .value("y", s.y), series: .value("Segment", s.segment))
                        .foregroundStyle(by: .value("Function", s.label))
                        .lineStyle(StrokeStyle(lineWidth: 3.5, lineCap: .round))
                }
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    PointMark(x: .value("x", point.x), y: .value("y", point.y))
                        .foregroundStyle(.white).symbolSize(90)
                        .annotation(position: labelPosition(index, points, span: xs.upperBound - xs.lowerBound), spacing: 6) {
                            if let label = point.label {
                                Text(label).font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 3).background(.black.opacity(0.7), in: Capsule())
                            }
                        }
                }
            }
            .chartForegroundStyleScale(domain: labels, range: Array(plotColors.prefix(max(1, labels.count))))
            .chartXScale(domain: xs)
            .chartYScale(domain: ys)
            .chartLegend(.hidden)
            .chartPlotStyle { $0.clipped() }
            .mask(alignment: .leading) { GeometryReader { g in Rectangle().frame(width: g.size.width * drawn) } }
            .frame(maxHeight: 420)
            ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                Label(label, systemImage: "function").font(.headline).foregroundStyle(plotColors[i % plotColors.count])
            }
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 22))
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { withAnimation(.easeInOut(duration: 1.6)) { drawn = 1 } }
    }
    /// Spreads labels of nearby points apart: the lowest goes below, the rest to either side above.
    private func labelPosition(_ index: Int, _ points: [NovaVisual.Point], span: Double) -> AnnotationPosition {
        let point = points[index]
        let cluster = points.filter { abs($0.x - point.x) < span * 0.12 }
        guard cluster.count > 1 else { return .top }
        if point.y == cluster.map(\.y).min() && cluster.filter({ $0.y == point.y }).count == 1 { return .bottom }
        return point.x <= cluster.map(\.x).reduce(0, +) / Double(cluster.count) ? .topLeading : .topTrailing
    }
    private func range(_ values: [Double]?) -> ClosedRange<Double>? {
        guard let values, values.count == 2, values[0].isFinite, values[1].isFinite, values[0] < values[1] else { return nil }
        return values[0]...values[1]
    }
    private func fallbackX(_ points: [NovaVisual.Point]) -> ClosedRange<Double> {
        guard let lo = points.map(\.x).min(), let hi = points.map(\.x).max(), lo < hi else { return -10...10 }
        let pad = (hi - lo) * 0.3
        return (lo - pad)...(hi + pad)
    }
    private func fallbackY(_ values: [Double]) -> ClosedRange<Double> {
        let sorted = values.filter(\.isFinite).sorted()
        guard sorted.count > 1 else { return -10...10 }
        var lo = sorted[sorted.count / 20], hi = sorted[sorted.count - 1 - sorted.count / 20]
        if lo == hi { lo -= 1; hi += 1 }
        let pad = (hi - lo) * 0.12
        return (lo - pad)...(hi + pad)
    }
}

/// Bar, line or pie charts that grow into place.
struct ChartView: View {
    let visual: NovaVisual
    @State private var grown = false
    private struct Datum: Identifiable { let id: Int; let label: String; let series: String; let value: Double }
    var body: some View {
        let labels = visual.labels ?? []
        let series = visual.series ?? []
        let data = series.enumerated().flatMap { si, s in
            labels.enumerated().compactMap { li, label in li < s.values.count && s.values[li].isFinite ? Datum(id: si * 1000 + li, label: label, series: s.name ?? "Value", value: s.values[li]) : nil }
        }
        let kind = visual.kind ?? "bar"
        return VStack(spacing: 12) {
            Group {
                if kind == "pie" {
                    Chart(data.filter { $0.id < 1000 }) { d in
                        SectorMark(angle: .value("Value", grown ? d.value : 0.0001), innerRadius: .ratio(0.5), angularInset: 2)
                            .foregroundStyle(by: .value("Label", d.label))
                            .cornerRadius(6)
                    }
                    .chartForegroundStyleScale(range: plotColors)
                } else if kind == "line" {
                    Chart(data) { d in
                        LineMark(x: .value("Label", d.label), y: .value("Value", grown ? d.value : 0), series: .value("Series", d.series))
                            .foregroundStyle(by: .value("Series", d.series))
                            .lineStyle(StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        PointMark(x: .value("Label", d.label), y: .value("Value", grown ? d.value : 0))
                            .foregroundStyle(by: .value("Series", d.series))
                    }
                    .chartForegroundStyleScale(range: plotColors)
                } else {
                    Chart(data) { d in
                        BarMark(x: .value("Label", d.label), y: .value("Value", grown ? d.value : 0))
                            .foregroundStyle(by: .value("Series", d.series))
                            .position(by: .value("Series", d.series))
                            .cornerRadius(6)
                    }
                    .chartForegroundStyleScale(range: plotColors)
                }
            }
            .chartLegend(kind == "pie" || series.count > 1 ? .visible : .hidden)
            .frame(maxHeight: 420)
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 22))
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { withAnimation(.spring(duration: 1.1, bounce: 0.25)) { grown = true } }
    }
}

private func chalk(_ name: String?) -> Color {
    switch name?.lowercased() {
    case "yellow": Color(red: 1, green: 0.92, blue: 0.5)
    case "pink", "red": Color(red: 1, green: 0.55, blue: 0.65)
    case "blue", "cyan": Color(red: 0.55, green: 0.85, blue: 1)
    case "green", "mint": Color(red: 0.6, green: 1, blue: 0.7)
    case "orange": Color(red: 1, green: 0.72, blue: 0.4)
    default: Color.white.opacity(0.92)
    }
}

/// A chalkboard that Nova writes on one step at a time while it talks.
struct BoardView: View {
    let visual: NovaVisual
    let revealed: Int
    var body: some View {
        let steps = Array((visual.steps ?? []).prefix(revealed))
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        BoardLine(step: step, current: index == steps.count - 1).id(index)
                            .transition(.opacity)
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: revealed) { withAnimation { scroller.scrollTo(revealed - 1, anchor: .bottom) } }
        }
        .background(
            LinearGradient(colors: [Color(red: 0.1, green: 0.24, blue: 0.19), Color(red: 0.06, green: 0.16, blue: 0.13)], startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 20)
        )
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(red: 0.45, green: 0.3, blue: 0.18), lineWidth: 7))
        .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
    }
}

struct BoardLine: View {
    let step: NovaVisual.Step
    let current: Bool
    @State private var written: CGFloat = 0
    @State private var boxed: CGFloat = 0
    var body: some View {
        let highlight = step.highlight == true
        VStack(alignment: .leading, spacing: 10) {
            Text(step.write)
                .font(.custom("Chalkboard SE", size: 25))
                .foregroundStyle(highlight ? chalk("yellow") : chalk(nil))
                .mask(alignment: .leading) { GeometryReader { g in Rectangle().frame(width: g.size.width * written) } }
                .padding(.horizontal, highlight ? 10 : 0).padding(.vertical, highlight ? 6 : 0)
                .overlay {
                    if highlight { RoundedRectangle(cornerRadius: 10).trim(from: 0, to: boxed).stroke(chalk("yellow"), lineWidth: 2.5) }
                }
            if let sketch = step.sketch, !sketch.isEmpty { SketchView(marks: sketch).frame(maxWidth: 360) }
        }
        .opacity(current ? 1 : 0.7)
        .animation(.easeInOut, value: current)
        .onAppear {
            let duration = min(2.2, 0.4 + Double(step.write.count) * 0.04)
            withAnimation(.linear(duration: duration)) { written = 1 }
            if highlight { withAnimation(.easeInOut(duration: 0.7).delay(duration)) { boxed = 1 } }
        }
    }
}

/// Chalk drawings in a 100 by 60 box, traced in as they appear.
struct SketchView: View {
    let marks: [NovaVisual.Mark]
    @State private var traced: CGFloat = 0
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                    if mark.shape == "text", let p = mark.points.first, p.count == 2 {
                        Text(mark.text ?? "").font(.custom("Chalkboard SE", size: 17)).foregroundStyle(chalk(mark.color))
                            .position(x: p[0] / 100 * g.size.width, y: p[1] / 60 * g.size.height)
                            .opacity(Double(traced))
                    } else {
                        SketchShape(mark: mark).trim(from: 0, to: traced)
                            .stroke(chalk(mark.color), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    }
                }
            }
        }
        .aspectRatio(100 / 60, contentMode: .fit)
        .onAppear { withAnimation(.easeInOut(duration: 1.4).delay(0.3)) { traced = 1 } }
    }
}

struct SketchShape: Shape {
    let mark: NovaVisual.Mark
    func path(in rect: CGRect) -> Path {
        let points = mark.points.filter { $0.count == 2 }.map { CGPoint(x: $0[0] / 100 * rect.width, y: $0[1] / 60 * rect.height) }
        var path = Path()
        guard let first = points.first else { return path }
        switch mark.shape {
        case "circle":
            let r = CGFloat(mark.size ?? 6) / 100 * rect.width
            path.addEllipse(in: CGRect(x: first.x - r, y: first.y - r, width: r * 2, height: r * 2))
        case "rect" where points.count > 1:
            path.addRect(CGRect(x: min(first.x, points[1].x), y: min(first.y, points[1].y), width: abs(points[1].x - first.x), height: abs(points[1].y - first.y)))
        case "curve" where points.count > 2:
            path.move(to: first)
            for i in 1..<points.count - 1 {
                let mid = CGPoint(x: (points[i].x + points[i+1].x) / 2, y: (points[i].y + points[i+1].y) / 2)
                path.addQuadCurve(to: i == points.count - 2 ? points[i+1] : mid, control: points[i])
            }
        default:
            path.addLines(points)
            if mark.shape == "arrow", points.count > 1 {
                let tip = points[points.count - 1], tail = points[points.count - 2]
                let angle = atan2(tip.y - tail.y, tip.x - tail.x), head: CGFloat = 12
                for side in [-0.45, 0.45] {
                    path.move(to: tip)
                    path.addLine(to: CGPoint(x: tip.x - head * cos(angle + side), y: tip.y - head * sin(angle + side)))
                }
            }
        }
        return path
    }
}

struct CardsView: View {
    let items: [NovaVisual.Item]
    @State private var shown = false
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: UIImage(systemName: item.symbol ?? "") == nil ? "sparkle" : item.symbol!)
                            .font(.title2).foregroundStyle(plotColors[index % plotColors.count])
                            .frame(width: 46, height: 46)
                            .background(plotColors[index % plotColors.count].opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.headline)
                            if let detail = item.detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 30)
                    .animation(.spring(duration: 0.5).delay(Double(index) * 0.12), value: shown)
                }
            }
        }
        .onAppear { shown = true }
    }
}

struct TableView: View {
    let columns: [String]
    let rows: [[String]]
    @State private var shown = false
    var body: some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                GridRow { ForEach(Array(columns.enumerated()), id: \.offset) { _, c in Text(c).font(.headline).foregroundStyle(.cyan) } }
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    Divider().overlay(.white.opacity(0.1))
                    GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, cell in Text(cell) } }
                        .opacity(shown ? 1 : 0)
                        .offset(x: shown ? 0 : 20)
                        .animation(.spring(duration: 0.45).delay(Double(index) * 0.08), value: shown)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 22))
        }
        .onAppear { shown = true }
    }
}

/// Matthew drives the Mac from the iPhone: tap to click, double-tap to double-click,
/// press and hold to right-click, pinch to zoom, the side pad scrolls, and the keyboard types.
struct ControlStage: View {
    @EnvironmentObject private var nova: NovaModel
    var mood: FaceMood = .idle
    @State private var typing = ""
    @State private var last: CGPoint?
    @FocusState private var keyboard: Bool
    private let keys: [(String, String)] = [("return","⏎"), ("backspace","⌫"), ("tab","⇥"), ("escape","esc"), ("left","←"), ("up","↑"), ("down","↓"), ("right","→"),
                                            ("cmd+space","⌘ Space"), ("cmd+tab","⌘ Tab"), ("cmd+c","⌘C"), ("cmd+v","⌘V"), ("cmd+z","⌘Z"), ("cmd+w","⌘W")]
    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width > geometry.size.height {
                HStack(spacing: 10) {
                    screen
                    VStack(spacing: 10) {
                        header
                        ScrollView {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) { keyButtons }
                        }
                        typingRow
                    }
                    .frame(width: 236)
                }
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 10) {
                    header
                    screen
                    Label("Turn your iPhone sideways for a bigger screen", systemImage: "rotate.right").font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { keyButtons } }
                    typingRow
                }
                .padding(.bottom, 8)
            }
        }
        .padding(.horizontal)
        .task { await nova.watchScreen() }
    }
    private var header: some View {
        HStack(spacing: 10) {
            NovaFace(mood: mood, size: 0.2).frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text("You're driving").font(.headline)
                Text("Tap to click · hold to right-click").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { Task { await nova.handBack() } } label: {
                Text("Hand back").font(.subheadline.bold())
            }.buttonStyle(.borderedProminent).tint(.mint)
        }
    }
    @ViewBuilder private var screen: some View {
        if let data = nova.liveScreen, let image = UIImage(data: data) {
            HStack(spacing: 8) {
                RemoteScreen(image: image,
                             onTap: { p in last = p; send(["action": "left_click", "coordinate": [p.x, p.y]]) },
                             onDoubleTap: { p in last = p; send(["action": "double_click", "coordinate": [p.x, p.y]]) },
                             onLongPress: { p in last = p; send(["action": "right_click", "coordinate": [p.x, p.y]]) })
                    .aspectRatio(image.size.width / image.size.height, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cyan.opacity(0.6), lineWidth: 1.5))
                ScrollPad { direction in
                    let p = last ?? CGPoint(x: image.size.width / 2, y: image.size.height / 2)
                    send(["action": "scroll", "coordinate": [p.x, p.y], "scroll_direction": direction, "scroll_amount": 2], haptic: false)
                }
                .frame(width: 30)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView("Connecting to your Mac…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    @ViewBuilder private var keyButtons: some View {
        ForEach(keys, id: \.0) { key, label in
            Button { send(["action": "key", "text": key]) } label: {
                Text(label).font(.callout.weight(.medium)).frame(minWidth: 44).padding(.horizontal, 8).padding(.vertical, 8)
                    .background(.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }
    private var typingRow: some View {
        HStack {
            TextField("Type on your Mac", text: $typing)
                .textFieldStyle(.roundedBorder).focused($keyboard).submitLabel(.send)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .onSubmit(sendText)
            Button(action: sendText) { Image(systemName: "arrow.up.circle.fill").font(.title) }
                .disabled(typing.isEmpty).accessibilityLabel("Type on the Mac")
        }
    }
    private func sendText() {
        guard !typing.isEmpty else { return }
        send(["action": "type", "text": typing]); typing = ""
    }
    private func send(_ body: [String: Any], haptic: Bool = true) {
        if haptic { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        Task { await nova.input(body) }
    }
}

/// A vertical pad: drag up or down on it to scroll the Mac where you last tapped.
struct ScrollPad: View {
    var onScroll: (String) -> Void
    @State private var travelled: CGFloat = 0
    var body: some View {
        Capsule().fill(.white.opacity(0.07))
            .overlay(VStack { Image(systemName: "chevron.up"); Spacer(); Image(systemName: "arrow.up.and.down").font(.caption); Spacer(); Image(systemName: "chevron.down") }
                .font(.footnote).foregroundStyle(.secondary).padding(.vertical, 14))
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { drag in
                    let step: CGFloat = 22
                    while drag.translation.height - travelled <= -step { travelled -= step; onScroll("down") }
                    while drag.translation.height - travelled >= step { travelled += step; onScroll("up") }
                }
                .onEnded { _ in travelled = 0 })
            .accessibilityLabel("Scroll pad")
    }
}

/// The live Mac screen in a zoomable scroll view. Reports points in screenshot pixels.
struct RemoteScreen: UIViewRepresentable {
    let image: UIImage
    var onTap: (CGPoint) -> Void
    var onDoubleTap: (CGPoint) -> Void
    var onLongPress: (CGPoint) -> Void
    func makeUIView(context: Context) -> RemoteScrollView { RemoteScrollView() }
    func updateUIView(_ view: RemoteScrollView, context: Context) {
        view.onTap = onTap; view.onDoubleTap = onDoubleTap; view.onLongPress = onLongPress
        view.show(image)
    }
}

final class RemoteScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var onTap: ((CGPoint) -> Void)?
    var onDoubleTap: ((CGPoint) -> Void)?
    var onLongPress: ((CGPoint) -> Void)?
    private var imageSize: CGSize = .zero
    init() {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1; maximumZoomScale = 4
        showsVerticalScrollIndicator = false; showsHorizontalScrollIndicator = false
        backgroundColor = .black
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:))); double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: self, action: #selector(tapped(_:))); single.require(toFail: double)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:))); hold.minimumPressDuration = 0.45
        [double, single, hold].forEach(imageView.addGestureRecognizer)
    }
    required init?(coder: NSCoder) { nil }
    func show(_ image: UIImage) {
        imageView.image = image
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        if size != imageSize { imageSize = size; setNeedsLayout() }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard imageSize.width > 0, bounds.width > 0 else { return }
        let fit = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let base = CGSize(width: imageSize.width * fit, height: imageSize.height * fit)
        if imageView.bounds.size != base {
            zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: base)
            contentSize = base
        }
        center()
    }
    private func center() {
        let dx = max(0, (bounds.width - contentSize.width) / 2), dy = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }
    private func pixel(_ gesture: UIGestureRecognizer) -> CGPoint {
        let p = gesture.location(in: imageView)
        ripple(at: p)
        return CGPoint(x: (p.x / imageView.bounds.width * imageSize.width).rounded(), y: (p.y / imageView.bounds.height * imageSize.height).rounded())
    }
    private func ripple(at p: CGPoint) {
        let ring = CAShapeLayer()
        ring.path = UIBezierPath(ovalIn: CGRect(x: -14, y: -14, width: 28, height: 28)).cgPath
        ring.position = p; ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor.systemCyan.cgColor; ring.lineWidth = 2.5 / zoomScale
        imageView.layer.addSublayer(ring)
        let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 0.3 / zoomScale; grow.toValue = 1.4 / zoomScale
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
        let group = CAAnimationGroup(); group.animations = [grow, fade]; group.duration = 0.45
        group.fillMode = .forwards; group.isRemovedOnCompletion = false
        ring.add(group, forKey: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ring.removeFromSuperlayer() }
    }
    @objc private func tapped(_ g: UITapGestureRecognizer) { onTap?(pixel(g)) }
    @objc private func doubleTapped(_ g: UITapGestureRecognizer) { onDoubleTap?(pixel(g)) }
    @objc private func held(_ g: UILongPressGestureRecognizer) { if g.state == .began { onLongPress?(pixel(g)) } }
}

/// Little lights circling Nova's face, one per background agent at work.
struct WorkOrbit: View {
    let count: Int
    var body: some View {
        TimelineView(.animation(paused: count == 0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate, n = min(count, 4)
            ZStack {
                ForEach(0..<n, id: \.self) { i in
                    let angle = t * 1.1 + Double(i) * 2 * .pi / Double(n)
                    Circle().fill(Color.orange).frame(width: 11, height: 11)
                        .shadow(color: .orange, radius: 8)
                        .offset(x: cos(angle) * 175, y: sin(angle) * 175 * 0.32)
                        .opacity(sin(angle) < 0 ? 0.45 : 1)
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeInOut, value: count)
    }
}

private let isoFormatter: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
private func relative(_ iso: String) -> String {
    guard let date = isoFormatter.date(from: iso) else { return "" }
    return date.formatted(.relative(presentation: .named))
}

/// Background agents at work, schedules and monitors, and everything they reported.
struct WorkView: View {
    @EnvironmentObject private var nova: NovaModel
    var onShow: (() -> Void)?
    var body: some View {
        List {
            if let work = nova.work {
                Section("Working now") {
                    if work.running.isEmpty { Text("Nothing running. Ask Nova to research something in the background.").foregroundStyle(.secondary) }
                    ForEach(work.running) { run in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: run.usesComputer ? "desktopcomputer" : run.kind == "agent" ? "sparkle.magnifyingglass" : run.kind == "monitor" ? "eye" : "clock")
                                    .foregroundStyle(.orange)
                                Text(run.title).font(.headline)
                                Spacer()
                                ProgressView()
                            }
                            Text("Started \(relative(run.started))").font(.caption2).foregroundStyle(.secondary)
                            if let latest = run.latest { Text(latest).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                        }
                        .swipeActions { Button("Stop", role: .destructive) { Task { await nova.cancelWork(run.id) } } }
                    }
                }
                Section("Scheduled") {
                    if work.schedules.isEmpty { Text("Nothing scheduled. Try “every weekday at 8, brief me on the news” or “watch this page and tell me when it changes”.").foregroundStyle(.secondary) }
                    ForEach(work.schedules) { schedule in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: schedule.monitor ? "eye" : "calendar.badge.clock").foregroundStyle(.cyan).frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(schedule.title).font(.headline)
                                Text("\(schedule.repeat)\(schedule.usesComputer ? " · uses the Mac" : "") · next \(relative(schedule.next))").font(.caption).foregroundStyle(.secondary)
                                if let last = schedule.lastResult { Text("Last: \(last)").font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                            }
                        }
                        .swipeActions { Button("Delete", role: .destructive) { Task { await nova.cancelWork(schedule.id) } } }
                    }
                }
                Section("Reports") {
                    if work.reports.isEmpty { Text("Reports from agents and schedules appear here.").foregroundStyle(.secondary) }
                    ForEach(work.reports) { report in ReportRow(report: report, onShow: onShow) }
                }
                if work.awake {
                    Section { Label("Keeping your Mac awake while Nova has work to do", systemImage: "cup.and.saucer.fill").font(.footnote).foregroundStyle(.secondary) }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Nova's work")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await nova.refresh() }
    }
}

struct ReportRow: View {
    @EnvironmentObject private var nova: NovaModel
    let report: NovaWork.Report
    var onShow: (() -> Void)?
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: report.ok ? (report.source == "agent" ? "sparkle.magnifyingglass" : report.source == "monitor" ? "eye" : "clock") : "exclamationmark.triangle.fill")
                    .foregroundStyle(report.ok ? .cyan : .orange)
                Text(report.title).font(.headline)
                Spacer()
                Text(relative(report.created_at)).font(.caption2).foregroundStyle(.secondary)
            }
            Text(report.message).font(.subheadline).lineLimit(expanded ? nil : 3).textSelection(.enabled)
            if !report.visuals.isEmpty {
                Button { nova.showReport(report); onShow?() } label: { Label("Show on Nova's face", systemImage: "chart.xyaxis.line") }
                    .font(.caption.bold()).buttonStyle(.bordered).tint(.cyan)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { expanded.toggle() } }
    }
}

/// Everything besides the face: conversation, typing, settings, jobs and stop controls.
/// Opened by pressing and holding the face.
struct NovaPanel: View {
    @EnvironmentObject private var nova: NovaModel
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var showStopConfirmation = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    HStack(spacing:8) {
                        Circle().fill(nova.connection == "Mac connected" ? .green : .orange).frame(width:9,height:9)
                        Text(nova.connection).font(.subheadline).foregroundStyle(.secondary)
                    }
                    connected
                }.padding()
            }
            .navigationTitle("Nova")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Unpair") { nova.unpair(); dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(for: String.self) { JobDetailView(id:$0) }
            .alert("Nova", isPresented:Binding(get:{nova.errorMessage != nil}, set:{ if !$0 {nova.errorMessage = nil} })) {
                Button("OK") {nova.errorMessage = nil}
            } message: {Text(nova.errorMessage ?? "")}
            .confirmationDialog("Stop all Nova jobs?",isPresented:$showStopConfirmation,titleVisibility:.visible) {
                Button("Emergency Stop",role:.destructive) {Task {await nova.emergencyStop()} }
            } message: {Text("This stops work on the Mac until you run npm run resume locally.")}
        }
        .presentationDragIndicator(.visible)
    }

    private var connected: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Talk to Nova").font(.title2.bold())
            Text(nova.computer?.owner == true ? "Nova can see your Mac's screen and use its mouse and keyboard without asking. Your words and screenshots go to Anthropic. Press Control-Option-S on the Mac to stop it instantly." : "Chat with Claude. This iPhone isn't the computer owner, so Nova can't use the Mac from here.")
                .font(.caption).foregroundStyle(.secondary)
            if let ai = nova.ai {
                Text(String(format:"Claude spending so far: $%.2f. No limit; Nova stops when your credits run out.",ai.usedUSD))
                    .font(.caption).foregroundStyle(.secondary)
                if !ai.configured { Text("Add your Claude API key on the Mac to enable Nova.").foregroundStyle(.orange) }
            }
            if let chat = nova.chat {
                if let question = chat.payload["message"] { Text(question.description).font(.subheadline).foregroundStyle(.cyan) }
                ForEach(chat.events.filter { ["narration","action"].contains($0.kind) }.suffix(8)) { event in
                    Label(event.description, systemImage: event.kind == "narration" ? "text.bubble" : "cursorarrow.click")
                        .font(event.kind == "narration" ? .subheadline : .caption).foregroundStyle(event.kind == "narration" ? .primary : .secondary)
                }
                if let reply = chat.result?["message"] {
                    Text(reply.description).font(.body.weight(.medium)).textSelection(.enabled)
                    if let cost = chat.result?["estimatedUSD"], case .number(let usd) = cost {
                        Text(String(format:"Cost: $%.3f",usd)).font(.caption2).foregroundStyle(.secondary)
                    }
                } else if let error = chat.error { Text(error).foregroundStyle(.orange) }
                else if nova.working { ProgressView(chat.type == "computer.task" ? "Nova is working…" : "Nova is thinking…") }
                else { Text("Message \(chat.status)").foregroundStyle(.secondary) }
                if chat.type == "computer.task", let data = nova.computerScreen, let image = UIImage(data:data) {
                    Image(uiImage:image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius:8))
                }
                if nova.working && chat.type == "computer.task" {
                    Button(role:.destructive) {Task {await nova.stopTask()}} label:{Label("Stop this task",systemImage:"stop.fill")}.buttonStyle(.bordered)
                }
            }
            HStack {
                TextField("Message Nova",text:$message,axis:.vertical).lineLimit(1...5).textFieldStyle(.roundedBorder)
                Button { Task { if await nova.send(message) { message = "" } } } label: {
                    Image(systemName:"arrow.up.circle.fill").font(.title)
                }.accessibilityLabel("Send message")
                    .disabled(nova.busy || nova.working || nova.stopped || nova.ai?.configured != true || message.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || message.count > 2000)
            }
            Toggle("Speak replies", isOn: $nova.voiceReplies).font(.subheadline)
            if nova.computer?.owner == true {
                NavigationLink { WorkView() } label: { Label("Agents, schedules and reports", systemImage: "sparkles") }
            }
            Divider()
            Text("Safe tasks").font(.title2.bold())
            Text("These checks do not use AI or change your Mac.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Mac status") {Task {await nova.submit("mac.status")}}
                Button("Repo status") {Task {await nova.submit("repo.status")}}
            }.buttonStyle(.bordered).disabled(nova.busy || nova.stopped)
            Divider()
            Text("Recent jobs").font(.headline)
            if nova.jobs.isEmpty {Text("No jobs yet").foregroundStyle(.secondary)}
            ForEach(nova.jobs) { job in
                NavigationLink(value:job.id) {
                    HStack {
                        Image(systemName:job.status == "succeeded" ? "checkmark.circle.fill" : "circle.dotted")
                            .foregroundStyle(job.status == "succeeded" ? .green : .orange)
                        VStack(alignment:.leading) {
                            Text(job.type).foregroundStyle(.primary)
                            Text(job.status).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName:"chevron.right").foregroundStyle(.secondary)
                    }.padding(12).background(.white.opacity(0.07),in:RoundedRectangle(cornerRadius:12))
                }
            }
            Button(role:.destructive) {showStopConfirmation = true} label:{Label("Emergency stop",systemImage:"stop.circle")}
                .buttonStyle(.bordered).disabled(nova.busy || nova.stopped)
            if nova.stopped {Text("Stopped. Only the Mac can resume Nova.").foregroundStyle(.orange)}
        }
    }
}

struct JobDetailView: View {
    @EnvironmentObject private var nova:NovaModel
    let id:String
    @State private var job:NovaDetail?
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                if let job {
                    Text(job.type).font(.title2.bold())
                    LabeledContent("Status",value:job.status)
                    if let result=job.result {
                        Text("Result").font(.headline)
                        Text(result.map{"\($0.key): \($0.value)"}.sorted().joined(separator:"\n"))
                            .font(.system(.body,design:.monospaced)).textSelection(.enabled)
                    }
                    if let error=job.error {Text(error).foregroundStyle(.orange)}
                    Text("Activity").font(.headline)
                    ForEach(job.events) { event in
                        VStack(alignment:.leading,spacing:4) {
                            Text(event.description)
                            Text(event.created_at).font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth:.infinity,alignment:.leading).padding(10)
                            .background(.white.opacity(0.07),in:RoundedRectangle(cornerRadius:12))
                    }
                } else {ProgressView()}
            }.padding()
        }.navigationTitle("Job details")
         .task {
            while !Task.isCancelled {
                job = await nova.detail(id)
                if let job, ["succeeded","failed","cancelled","interrupted"].contains(job.status) {break}
                try? await Task.sleep(for:.seconds(2))
            }
         }
    }
}
