import SwiftUI
import UIKit

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

enum Stage { case face, progress, screen, result }

struct ContentView: View {
    @EnvironmentObject private var nova: NovaModel
    @ObservedObject private var listenerState: Listener
    @ObservedObject private var speakerState: Speaker
    @State private var showPanel = false
    @State private var showScreen = false
    @Namespace private var space
    init(nova: NovaModel) { listenerState = nova.listener; speakerState = nova.speaker }

    private var computerTask: Bool { nova.working && nova.chat?.type == "computer.task" }
    private var stage: Stage {
        if listenerState.listening { return .face }
        if showScreen { return .screen }
        if computerTask { return .progress }
        if nova.result != nil { return .result }
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
                    NovaFace(mood: mood)
                        .matchedGeometryEffect(id: "face", in: space)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { Task { await nova.tapFace() } }
                        .onLongPressGesture { showPanel = true }
                        .gesture(DragGesture(minimumDistance: 40).onEnded { if $0.translation.height < -60 && nova.computer?.owner == true { showScreen = true } })
                } else {
                    VStack(spacing: 18) {
                        header
                        Group {
                            switch stage {
                            case .progress: ProgressStage()
                            case .screen: ScreenStage(inControl: computerTask)
                            default: ResultStage()
                            }
                        }
                        .transition(.asymmetric(insertion: .scale(scale: 0.6, anchor: .top).combined(with: .opacity), removal: .opacity))
                        controls
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
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showPanel) { NovaPanel() }
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
            Button { showScreen = false; nova.dismissResult() } label: {
                Image(systemName: "xmark").font(.headline).padding(10).background(.white.opacity(0.08), in: Circle())
            }.accessibilityLabel("Back to Nova's face")
        }
        .padding(.top, 8)
    }
    private var title: String {
        switch stage {
        case .screen: computerTask ? "Nova is in control" : "Your Mac"
        case .progress: "Working on it"
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
            if computerTask {
                Button(role: .destructive) { Task { await nova.stopTask() } } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(.red)
            }
        }
        .controlSize(.large)
        .padding(.bottom, 8)
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
                Text(String(format:"Nova AI allowance: $%.2f used of $%.2f",ai.usedUSD,ai.allowanceUSD))
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
