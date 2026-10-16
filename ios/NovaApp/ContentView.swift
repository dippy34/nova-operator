import SwiftUI
import UIKit

enum FaceMood { case idle, listening, working, speaking }

struct NovaFace: View {
    var mood: FaceMood
    @State private var blink = false
    private var color: Color {
        switch mood { case .idle: .cyan; case .listening: Color(red:0.85,green:0.5,blue:1); case .working: .orange; case .speaking: .mint }
    }
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let glance = mood == .working ? sin(t*2.2)*22 : 0
            let bob = sin(t*1.6)*6
            VStack(spacing: 46) {
                HStack(spacing: 70) {
                    eye(t: t).offset(x: glance)
                    eye(t: t).offset(x: glance)
                }
                mouth(t: t).frame(height: 40)
            }
            .offset(y: bob)
            .shadow(color: color.opacity(0.8), radius: 24)
        }
        .animation(.spring(duration: 0.35), value: mood)
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
    private func eye(t: Double) -> some View {
        let height: CGFloat = blink ? 8 : mood == .listening ? 128 : 108
        return Capsule().fill(color).frame(width: 58, height: height)
    }
    @ViewBuilder private func mouth(t: Double) -> some View {
        if mood == .speaking || mood == .listening {
            HStack(spacing: 7) {
                ForEach(0..<7, id: \.self) { i in
                    Capsule().fill(color)
                        .frame(width: 9, height: mood == .speaking ? 10+abs(sin(t*9+Double(i)*0.9))*30 : 10+abs(sin(t*3+Double(i)*0.6))*10)
                }
            }
        } else {
            Capsule().fill(color.opacity(mood == .working ? 0.7 : 1)).frame(width: mood == .working ? 36 : 90, height: 10)
        }
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

struct ContentView: View {
    @EnvironmentObject private var nova: NovaModel
    @ObservedObject private var listenerState: Listener
    @ObservedObject private var speakerState: Speaker
    @State private var showPanel = false
    init(nova: NovaModel) { listenerState = nova.listener; speakerState = nova.speaker }

    private var mood: FaceMood {
        listenerState.listening ? .listening : nova.working ? .working : speakerState.speaking ? .speaking : .idle
    }

    var body: some View {
        ZStack {
            Color(red:0.02,green:0.03,blue:0.06).ignoresSafeArea()
            if nova.paired {
                NovaFace(mood: mood)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await nova.tapFace() } }
                    .onLongPressGesture { showPanel = true }
                if listenerState.listening {
                    EdgeGlow(level: listenerState.level).transition(.opacity)
                }
            } else {
                ScrollView { pairing.padding() }
            }
        }
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
