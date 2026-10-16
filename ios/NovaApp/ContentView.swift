import SwiftUI
import UIKit

struct NovaFace: View {
    var listening = false
    var working = false
    var speaking = false
    @State private var pulse = false
    private var color: Color { listening ? .pink : working ? .orange : .cyan }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 32).fill(Color(red:0.075,green:0.105,blue:0.16))
            VStack(spacing: 14) {
                HStack(spacing: 38) {
                    Capsule().fill(color).frame(width: 24,height: listening ? 48 : 42)
                    Capsule().fill(color).frame(width: 24,height: listening ? 48 : 42)
                }
                Image(systemName: speaking ? "waveform" : "mouth").font(.largeTitle).foregroundStyle(color)
                    .symbolEffect(.variableColor.iterative, isActive: speaking)
            }
            .scaleEffect(pulse && (working || listening) ? 1.04 : 1)
        }
        .frame(height: 182)
        .animation(.easeInOut(duration: 0.25), value: color)
        .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { pulse = true } }
        .accessibilityLabel(listening ? "Nova is listening" : working ? "Nova is working" : speaking ? "Nova is speaking" : "Nova")
    }
}

struct ContentView: View {
    @EnvironmentObject private var nova: NovaModel
    @State private var message = ""
    @State private var showStopConfirmation = false
    @ObservedObject private var listenerState: Listener
    @ObservedObject private var speakerState: Speaker
    init(nova: NovaModel) { listenerState = nova.listener; speakerState = nova.speaker }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading, spacing:20) {
                    NovaFace(listening: listenerState.listening, working: nova.working, speaking: speakerState.speaking)
                    HStack(spacing:8) {
                        Circle().fill(nova.connection == "Mac connected" ? .green : .orange).frame(width:9,height:9)
                        Text(nova.paired ? nova.connection : "Pair your iPhone")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if !nova.paired { pairing }
                    else { connected }
                }.padding()
            }
            .background(Color(red:0.035,green:0.055,blue:0.09))
            .navigationTitle("Nova")
            .toolbar { if nova.paired { Button("Unpair") {nova.unpair()} } }
            .navigationDestination(for: String.self) { JobDetailView(id:$0) }
            .alert("Nova", isPresented:Binding(get:{nova.errorMessage != nil}, set:{ if !$0 {nova.errorMessage = nil} })) {
                Button("OK") {nova.errorMessage = nil}
            } message: {Text(nova.errorMessage ?? "")}
            .confirmationDialog("Stop all Nova jobs?",isPresented:$showStopConfirmation,titleVisibility:.visible) {
                Button("Emergency Stop",role:.destructive) {Task {await nova.emergencyStop()} }
            } message: {Text("This stops work on the Mac until you run npm run resume locally.")}
        }
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
            if listenerState.listening {
                Text(listenerState.transcript.isEmpty ? "Listening…" : listenerState.transcript).foregroundStyle(.pink)
            }
            HStack {
                TextField("Message Nova",text:$message,axis:.vertical).lineLimit(1...5).textFieldStyle(.roundedBorder)
                Button { Task { await nova.toggleListening() } } label: {
                    Image(systemName: listenerState.listening ? "stop.circle.fill" : "mic.circle.fill").font(.title).foregroundStyle(listenerState.listening ? .pink : .cyan)
                }.accessibilityLabel(listenerState.listening ? "Stop listening and send" : "Talk to Nova")
                    .disabled(nova.stopped || nova.ai?.configured != true || (nova.working && !listenerState.listening))
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
