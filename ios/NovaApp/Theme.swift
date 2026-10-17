import SwiftUI

/// Content stays quiet; color belongs to Nova's presence and the control layer.
enum NovaInk {
    static let bg = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let line = Color.primary.opacity(0.09)
    static let cyan = Color(red: 0.32, green: 0.80, blue: 0.96)
    static let pop = Color(red: 0.58, green: 0.56, blue: 1)
    static let spectrum: [Color] = [cyan, Color(red: 0.52, green: 0.53, blue: 0.96), Color(red: 0.36, green: 0.83, blue: 0.77), cyan]
}

struct NovaBackground: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                NovaInk.bg
                RadialGradient(colors: [NovaInk.pop.opacity(0.10), .clear], center: .topTrailing, startRadius: 0, endRadius: proxy.size.height * 0.65)
                RadialGradient(colors: [Color.blue.opacity(0.07), .clear], center: .bottomLeading, startRadius: 0, endRadius: proxy.size.height * 0.55)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct NovaSurface: ViewModifier {
    var radius: CGFloat = 24
    func body(content: Content) -> some View {
        content
            .background(NovaInk.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(NovaInk.line, lineWidth: 0.5).allowsHitTesting(false) }
    }
}

/// Native Liquid Glass on iOS 26; system material on Matthew's iOS 18 phone.
struct NovaGlass: ViewModifier {
    var radius: CGFloat = 28
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder func body(content: Content) -> some View {
        if opaque || contrast == .increased {
            content.modifier(NovaSurface(radius: radius))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.13), lineWidth: 0.5).allowsHitTesting(false) }
        }
    }
}

extension View {
    func novaSurface(radius: CGFloat = 24) -> some View { modifier(NovaSurface(radius: radius)) }
    func novaGlass(radius: CGFloat = 28) -> some View { modifier(NovaGlass(radius: radius)) }
}

struct NovaPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct NovaPrimaryStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(Color.accentColor.opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.3), in: Capsule())
            .opacity(enabled ? 1 : 0.65)
    }
}

struct NovaLanding: View {
    var mood: FaceMood = .idle
    var connection = "Mac connected"
    var stopped = false
    var canControl = true
    var voiceBusy = false
    var voicePrompt: String?
    var running = 0
    var scheduled = 0
    var onTalk: () -> Void = {}
    var onMenu: () -> Void = {}
    var onScreen: () -> Void = {}
    var onWork: () -> Void = {}
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        GeometryReader { geometry in
            if typeSize.isAccessibilitySize {
                ScrollView { layout(compact: true) }
            } else {
                ViewThatFits(in: .vertical) {
                    layout(compact: geometry.size.height < 680)
                    ScrollView { layout(compact: true) }
                }
            }
        }
    }
    private func layout(compact: Bool) -> some View {
        VStack(spacing: compact ? 20 : 30) {
            HStack {
                Text("Nova").font(.title2.weight(.semibold)).tracking(-0.6)
                Spacer()
                Button(action: onMenu) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 18, weight: .medium))
                        .frame(width: 46, height: 46).novaGlass(radius: 23)
                }
                .buttonStyle(NovaPressStyle()).accessibilityLabel("Open Nova settings and controls")
            }
            .padding(.top, 8)
            Spacer(minLength: 0)
            VStack(spacing: compact ? 8 : 20) {
                Button(action: onTalk) {
                    NovaFace(mood: mood, size: compact || typeSize.isAccessibilitySize ? 0.70 : 0.92)
                }
                .buttonStyle(NovaPressStyle())
                .disabled(stopped || voiceBusy)
                .accessibilityLabel(mood == .listening ? "Finish listening and send" : "Talk to Nova")
                .accessibilityHint("Start a voice request")
                VStack(spacing: 10) {
                    Text(headline).font(.largeTitle.weight(.semibold)).tracking(-1.1)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(.body).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 20) {
                Label(stopped ? "Emergency stop is on" : connection, systemImage: stopped ? "stop.circle" : "laptopcomputer")
                    .font(.footnote.weight(.medium)).foregroundStyle(stopped ? Color.red : Color.secondary)
                    .accessibilityElement(children: .combine)
                Group {
                    if typeSize.isAccessibilitySize {
                        VStack(spacing: 8) { dockControls }
                    } else {
                        HStack(spacing: 0) { dockControls }
                    }
                }
                .padding(8).novaGlass(radius: 32)

                if running > 0 || scheduled > 0 {
                    Button(action: onWork) {
                        Text(running > 0 ? "\(running) task\(running == 1 ? "" : "s") in progress" : "\(scheduled) scheduled")
                            .font(.footnote).foregroundStyle(.secondary).frame(minHeight: 44)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.bottom, compact ? 8 : 20)
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity)
    }
    @ViewBuilder private var dockControls: some View {
        dockButton(mood == .listening ? "Send" : "Talk", mood == .listening ? "arrow.up" : "mic.fill", action: onTalk).disabled(stopped || voiceBusy)
        if !typeSize.isAccessibilitySize { Divider().frame(height: 24).padding(.horizontal, 4) }
        if canControl { dockButton("Computer", "display", action: onScreen) }
        dockButton("Activity", "clock.arrow.circlepath", action: onWork)
    }
    private func dockButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if typeSize.isAccessibilitySize {
                    HStack(spacing: 16) {
                        Image(systemName: symbol).font(.system(size: 24, weight: .medium)).frame(width: 30)
                        Text(title).font(.body.weight(.medium))
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 20)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: symbol).font(.title3.weight(.medium)).frame(height: 25)
                        Text(title).font(.caption.weight(.medium))
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .foregroundStyle(.primary)
            .contentShape(RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(NovaPressStyle())
    }
    private var headline: String {
        if let voicePrompt { return voicePrompt }
        if stopped { return "Taking a pause." }
        switch mood {
        case .idle: return "What’s on your mind?"
        case .listening: return "I'm listening."
        case .working: return "On it."
        case .speaking: return "Here's what I found."
        case .happy: return "All taken care of."
        case .confused: return "Let's take a look."
        }
    }
    private var detail: String {
        if voicePrompt != nil { return "Just a moment." }
        if stopped { return "Resume Nova on your Mac to continue." }
        switch mood {
        case .idle: return typeSize.isAccessibilitySize ? "Tap Talk to begin." : "Talk, plan, or make something happen."
        case .listening: return "Take your time. Tap Send when you're ready."
        case .working: return "Your request is in progress."
        case .speaking: return "You can interrupt me with a tap."
        case .happy: return "Ready for whatever comes next."
        case .confused: return "Open Activity to review what happened."
        }
    }
}

/// Always-on strip: connection, access, AI, and what Nova is doing this second.
struct StatusStrip: View {
    @EnvironmentObject private var nova: NovaModel
    var listening: Bool = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(nova.stopped ? Color.red : nova.connection == "Mac connected" ? Color.green : Color.orange).frame(width: 6, height: 6)
                Text(nova.stopped ? "Stopped" : nova.connection).font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
                if let spent = nova.ai?.usedUSD { Text(String(format: "$%.2f", spent)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
            Text(doing).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { Label(rangeWord, systemImage: "lock.shield"); Text(nova.provider?.label ?? "Claude") }
                VStack(alignment: .leading, spacing: 6) { Label(rangeWord, systemImage: "lock.shield"); Text(nova.provider?.label ?? "Claude") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .novaSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(nova.connection). \(rangeWord). \(doing)")
    }

    private var rangeWord: String { nova.effectiveAccessLabel }
    private var doing: String {
        if nova.stopped { return "Emergency stop is on. Resume Nova on your Mac." }
        if listening { return "Listening to you. Tap again to send." }
        if nova.computer?.paused == true { return "You’re in control. Hand back when you’re ready." }
        if nova.working, nova.chat?.type == "computer.task" {
            let now = nova.chat?.events.last(where: { $0.kind == "narration" || $0.kind == "action" })?.description
            return "Using the Mac. \(now ?? "Started.")"
        }
        if nova.working { return "Thinking about your request." }
        if !(nova.work?.running.isEmpty ?? true) { return "\(nova.work?.running.count ?? 0) background tasks in progress." }
        return "Ready when you are."
    }
    private var doingColor: Color {
        if nova.stopped { return .red }
        if listening { return Color(red: 0.85, green: 0.5, blue: 1) }
        if nova.working && nova.chat?.type == "computer.task" { return NovaInk.pop }
        if nova.working { return .orange }
        return .mint
    }
    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(color)
            .background(color.opacity(0.10), in: Capsule())
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }
}

/// Title plus one line of “this does that”.
struct ExplainRow: View {
    let title: String
    let does: String
    var symbol: String
    var tint: Color = .cyan
    var prominent = false
    var danger = false
    var chevron = false
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(danger ? Color.red : tint)
                .frame(width: 36, height: 36)
                .background((danger ? Color.red : tint).opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                Text(does).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .novaSurface()
        .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(prominent ? tint.opacity(0.22) : Color.clear, lineWidth: 1).allowsHitTesting(false) }
    }
}

struct ExplainButton: View {
    let title: String
    let does: String
    var symbol: String
    var tint: Color = .cyan
    var prominent = false
    var danger = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            ExplainRow(title: title, does: does, symbol: symbol, tint: tint, prominent: prominent, danger: danger)
        }
        .buttonStyle(NovaPressStyle())
        .frame(minHeight: 56)
        .accessibilityHint(does)
    }
}

struct ExplainLink<Destination: View>: View {
    let title: String
    let does: String
    var symbol: String
    var tint: Color = .cyan
    @ViewBuilder var destination: () -> Destination
    var body: some View {
        NavigationLink {
            destination()
        } label: {
            ExplainRow(title: title, does: does, symbol: symbol, tint: tint, chevron: true)
        }
        .buttonStyle(NovaPressStyle())
        .frame(minHeight: 56)
        .accessibilityHint(does)
    }
}

struct HintChip: View {
    let symbol: String
    let text: String
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(NovaInk.card, in: Capsule())
    }
}

struct DoesDoesNot: View {
    let does: [String]
    let doesNot: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(does, id: \.self) { line in
                Label(line, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.primary)
                    .font(.subheadline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            ForEach(doesNot, id: \.self) { line in
                Label(line, systemImage: "minus.circle")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
struct NovaDesignReview: View {
    @StateObject private var nova = NovaModel()
    @State private var showMenu = false
    @State private var showWork = false
    @State private var showSettings = false
    @State private var range = "chat"
    private var mode: String {
        ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("-nova-design=") })?.split(separator: "=").last.map(String.init) ?? "home"
    }
    var body: some View {
        ZStack {
            NovaBackground()
            if mode == "access" {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("Choose what Nova can access. You can change this whenever you like.").foregroundStyle(.secondary)
                            RangePicker(level: $range)
                        }.padding(24)
                    }.background(NovaBackground()).navigationTitle("Access")
                }
            } else if mode == "settings" {
                NavigationStack { SettingsView() }
            } else if mode == "menu" {
                HomeView()
            } else if mode == "welcome" {
                OnboardingView()
            } else {
                NovaLanding(mood: mode == "listening" ? .listening : .idle,
                            onTalk: {}, onMenu: { showMenu = true }, onScreen: { showSettings = true }, onWork: { showWork = true })
                if mode == "listening" { EdgeGlow(level: 0.35) }
            }
        }
        .environmentObject(nova)
        .sheet(isPresented: $showMenu) { HomeView().environmentObject(nova) }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView().environmentObject(nova) } }
        .sheet(isPresented: $showWork) { NavigationStack { WorkView().environmentObject(nova) } }
    }
}
#endif
