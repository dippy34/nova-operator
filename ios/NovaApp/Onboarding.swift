import SwiftUI
import AVFoundation
import LocalAuthentication
import UIKit

/// Swipeable first-run. Pairing and range stay button-driven so you cannot swipe past them.
struct OnboardingView: View {
    @EnvironmentObject private var nova: NovaModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lesson = 0
    @State private var step: SetupStep?
    @State private var pairMode = 0
    @State private var rangePick = "chat"
    @State private var apps: [NovaAppChoice] = []
    @State private var chosenApps: Set<NovaAppChoice> = []
    @State private var folders: [NovaFolderChoice] = []
    @State private var chosenFolders: [String] = []
    @State private var folderRoot = "~"
    @State private var provider = "anthropic"
    @State private var key = ""
    @State private var keyNote: String?

    enum SetupStep: Int {
        case pair, confirm, range, apps, permissions, ai, ready
    }

    var body: some View {
        VStack(spacing: 0) {
            if let step {
                setupChrome(step)
                setupPage(step)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 22)
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            } else {
                tutorial
            }
        }
        .background(NovaBackground())
        .preferredColorScheme(.dark)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: step)
        .task {
            if nova.tutorialSeen { await land() }
        }
        .onChange(of: nova.pendingPair) { _, invite in
            if invite != nil { go(.confirm) }
        }
        .onChange(of: nova.paired) { _, paired in
            if paired { Task { await land() } }
        }
        .alert("Couldn't pair", isPresented: Binding(get: { nova.errorMessage != nil && !nova.paired && (step == .pair || step == .confirm) }, set: { if !$0 { nova.errorMessage = nil } })) {
            Button("Try another code") { go(.pair); pairMode = 1; nova.errorMessage = nil }
            Button("Scan again") { go(.pair); pairMode = 0; nova.errorMessage = nil }
            Button("OK", role: .cancel) { nova.errorMessage = nil }
        } message: {
            Text(recovery(nova.errorMessage ?? ""))
        }
    }

    private var tutorial: some View {
        VStack(spacing: 0) {
            TabView(selection: $lesson) {
                lessonPage(0, "Meet Nova.", "A thoughtful assistant for your Mac. Start a conversation, get things done, and stay in control from your iPhone.", .idle)
                lessonPage(1, "A little help, at a tap.", "Talk naturally or type a request. Your activity and controls are always within reach.", .idle, chips: [
                    ("mic", "Talk to Nova"),
                    ("slider.horizontal.3", "Your controls, always available")
                ])
                lessonPage(2, "Your Mac. Wherever you are.", "See your screen, check on a task, or take over. Computer controls are available to your paired owner device.", .working, chips: [
                    ("arrow.up", "Swipe up = see the Mac"),
                    ("arrow.left", "Swipe left = jobs")
                ])
                accessLesson
                lessonPage(4, "Private by design.", "Tailscale connects your devices privately. Nova runs from your Mac’s menu bar. Pair wirelessly with a code; a cable alone does not pair devices.", .speaking, chips: [
                    ("keyboard", "Control-Option-S = emergency stop"),
                    ("laptopcomputer", "Resume lives on the Mac")
                ])
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .padding(.bottom, 8)
            Button(action: nextLesson) {
                Text(lesson < 4 ? "Next" : "Pair this iPhone")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 52)
            }
            .buttonStyle(NovaPrimaryStyle())
            .padding(.horizontal, 22)
            .padding(.bottom, 24)
            .accessibilityHint(lesson < 4 ? "Go to the next slide" : "Start pairing")
        }
    }

    private var accessLesson: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)
            Text("What I may use")
                .font(.title.bold())
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.center)
            Text("Choose what Nova can access. Change it whenever you like.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 12) {
                tutorialRange("Just chat", ["Talk, search, research."], ["See the Mac.", "Click or type."])
                tutorialRange("Chosen apps", ["Use only the apps you tick."], ["See other windows."])
                tutorialRange("Whole Mac", ["See the screen. Use any app."], ["Unlock the Mac.", "Bypass Emergency stop."])
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 22)
        .tag(3)
    }

    private func tutorialRange(_ name: String, _ does: [String], _ doesNot: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name).font(.headline)
            DoesDoesNot(does: does, doesNot: doesNot)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NovaInk.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func lessonPage(_ tag: Int, _ heading: String, _ body: String, _ mood: FaceMood, chips: [(String, String)] = []) -> some View {
        VStack(spacing: 22) {
            Spacer()
            NovaFace(mood: mood, size: 0.7)
            Text(heading)
                .font(.title.bold())
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
                .multilineTextAlignment(.center)
            Text(body)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 8)
            if !chips.isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                        HintChip(symbol: chip.0, text: chip.1)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .tag(tag)
    }

    private func nextLesson() {
        if lesson < 4 {
            if reduceMotion { lesson += 1 }
            else { withAnimation(.easeInOut(duration: 0.28)) { lesson += 1 } }
        } else {
            nova.tutorialSeen = true
            if nova.paired { Task { await land() } }
            else { go(.pair) }
        }
    }

    private func setupChrome(_ step: SetupStep) -> some View {
        VStack(spacing: 16) {
            HStack {
                if step != .ready {
                    Button { back(from: step) } label: {
                        Image(systemName: "chevron.left").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                    }.accessibilityLabel("Back")
                } else { Color.clear.frame(width: 44, height: 44) }
                Spacer()
                Text(setupTitle(step)).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(step.rawValue + 1) of 7").font(.caption).foregroundStyle(.secondary).frame(minWidth: 44)
            }
            HStack(spacing: 5) {
                ForEach(0..<7) { index in
                    Capsule().fill(index <= step.rawValue ? Color.accentColor : NovaInk.line).frame(height: 3)
                }
            }.padding(.horizontal, 8).accessibilityHidden(true)
        }
        .padding(.horizontal, 16).padding(.bottom, 24)
    }

    @ViewBuilder private func setupPage(_ step: SetupStep) -> some View {
        switch step {
        case .pair: pairPage
        case .confirm: confirmPage
        case .range: rangePage
        case .apps: appsPage
        case .permissions: permissionsPage
        case .ai: aiPage
        case .ready: ReadyScreen { nova.readySeen = true }
        }
    }

    private var pairPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pair with your Mac")
                .font(.title.bold())
                .lineLimit(2)
                .minimumScaleFactor(0.75)
            Picker("How", selection: $pairMode) {
                Text("Scan").tag(0)
                Text("Type").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(minHeight: 44)
            if pairMode == 0 {
                QRScanner { raw in
                    if nova.applyPairingLink(raw) { go(.confirm) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .accessibilityLabel("Camera, looking for the pairing QR code")
            } else {
                Text("Eight characters under the QR, or paste the long code. One use, 10 minutes.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                field("ABCD-1234", text: $nova.pairingCode)
                    .textInputAutocapitalization(.characters)
                    .font(.title3.monospaced())
                    .accessibilityLabel("Pairing code")
                field("https://your-mac.ts.net", text: $nova.address)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("Mac address")
                Spacer()
                primary("Continue") {
                    nova.pendingPair = PairingInvite(url: nova.address, code: nova.pairingCode, computer: "this Mac")
                    go(.confirm)
                }
                .disabled(nova.pairingCode.trimmingCharacters(in: .whitespaces).isEmpty || nova.address.isEmpty)
            }
        }
    }

    private var confirmPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("This Mac?")
                .font(.title.bold())
            if let invite = nova.pendingPair {
                info("Computer", invite.computer)
                info("Address", invite.url)
            }
            Text("This iPhone gets its own sign-in. You can remove it in Settings.")
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer()
            primary(nova.busy ? "Pairing…" : "Pair") {
                Task {
                    await nova.pair()
                    if nova.paired { await land() }
                }
            }
            .disabled(nova.busy)
        }
    }

    private var rangePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your assistant. Your boundaries.")
                .font(.title.bold())
                .lineLimit(2)
                .minimumScaleFactor(0.75)
            Text("Choose the access that feels right. You can change this later.")
                .font(.body)
                .foregroundStyle(.secondary)
            ScrollView { RangePicker(level: $rangePick).padding(.bottom, 8) }
            Spacer(minLength: 0)
            primary("Continue") {
                Task { await applyRange() }
            }
        }
    }

    private var appsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apps and folders")
                .font(.title.bold())
                .lineLimit(2)
                .minimumScaleFactor(0.75)
            Text("I may only use what you tick. Hidden folders and Library stay closed.")
                .font(.body)
                .foregroundStyle(.secondary)
            List {
                Section("Apps") {
                    ForEach(apps) { app in
                        Toggle(app.name, isOn: bindApp(app))
                    }
                }
                Section("Folders") {
                    ForEach(folders) { folder in
                        HStack {
                            Toggle(folder.name, isOn: bindFolder(folder.path))
                            Button("Open") {
                                folderRoot = folder.path
                                Task { folders = await nova.listedFolders(in: folder.path) }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    if folderRoot != "~" {
                        Button("Back to home folders") {
                            folderRoot = "~"
                            Task { folders = await nova.listedFolders() }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            primary("Continue") {
                Task {
                    if await nova.setAccess(level: "apps", apps: Array(chosenApps), folders: chosenFolders) { go(.permissions) }
                }
            }
            .disabled(chosenApps.isEmpty && chosenFolders.isEmpty)
        }
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Allow me on the Mac")
                .font(.title.bold())
                .lineLimit(2)
                .minimumScaleFactor(0.75)
            perm("Screen Recording", nova.setup?.permissions?.screenRecording == true, "I can see the apps I'm allowed to use.")
            perm("Accessibility", nova.setup?.permissions?.accessibility == true, "I can click and type in those apps.")
            Text("macOS asks on the Mac. You decide in System Settings.")
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer()
            primary("Ask on my Mac") { Task { await nova.askMacPermissions() } }
            Button("I've allowed them") { Task { await nova.loadSetup(); go(.ai) } }
                .frame(minHeight: 44)
                .frame(maxWidth: .infinity)
        }
    }

    private var aiPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect an AI")
                .font(.title.bold())
            Picker("Provider", selection: $provider) {
                Text("Claude").tag("anthropic")
                Text("OpenAI").tag("openai")
            }
            .pickerStyle(.segmented)
            .frame(minHeight: 44)
            if provider == "openai" {
                Text("API billing is separate. ChatGPT Plus or Pro does not include it.")
                    .font(.body)
            }
            SecureField(provider == "openai" ? "OpenAI API key" : "Claude API key", text: $key)
                .textContentType(.password)
                .padding(14)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityLabel("API key")
            if let keyNote { Text(keyNote).foregroundStyle(.secondary) }
            Text("Saved in the Mac Keychain, not on this phone. The test lists models and costs nothing.")
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer()
            if nova.setup?.ai.anthropic.configured == true || nova.setup?.ai.openai.configured == true {
                Button("Skip — a key is already connected") { go(.ready) }
                    .frame(minHeight: 44)
            }
            primary(nova.busy ? "Testing…" : "Save and test") {
                Task {
                    keyNote = await nova.saveKey(provider: provider, key: key)
                    key = ""
                    if nova.setup?.ai.anthropic.configured == true || nova.setup?.ai.openai.configured == true { go(.ready) }
                }
            }
            .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || nova.busy)
        }
    }

    private func applyRange() async {
        switch rangePick {
        case "apps":
            apps = await nova.listedApps()
            folders = await nova.listedFolders()
            go(.apps)
        case "full":
            guard await confirmIdentity() else { return }
            if await nova.setAccess(level: "full") { go(.permissions) }
        default:
            if await nova.setAccess(level: "chat") { go(.ai) }
        }
    }

    private func land() async {
        if nova.paired { await nova.loadSetup() }
        guard nova.paired else { return }
        if let steps = nova.setup?.steps {
            if !steps.range { go(.range); return }
            if !steps.permissions { go(.permissions); return }
            if !steps.ai { go(.ai); return }
        }
        go(.ready)
    }

    private func go(_ next: SetupStep) {
        if reduceMotion { step = next }
        else { withAnimation(.easeInOut(duration: 0.28)) { step = next } }
    }

    private func back(from step: SetupStep) {
        switch step {
        case .pair: self.step = nil
        case .confirm: go(.pair)
        case .range: go(.confirm)
        case .apps: go(.range)
        case .permissions: go(.range)
        case .ai: go(.range)
        case .ready: break
        }
    }

    private func setupTitle(_ step: SetupStep) -> String {
        switch step {
        case .pair: return "Pair"
        case .confirm: return "Confirm"
        case .range: return "Access"
        case .apps: return "Apps"
        case .permissions: return "Permissions"
        case .ai: return "AI"
        case .ready: return "Ready"
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.headline).frame(maxWidth: .infinity).frame(minHeight: 52)
        }
        .buttonStyle(NovaPrimaryStyle())
        .controlSize(.large)
    }

    private func field(_ hint: String, text: Binding<String>) -> some View {
        TextField(hint, text: text)
            .autocorrectionDisabled()
            .padding(14)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func info(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.body.weight(.semibold)).textSelection(.enabled).lineLimit(3).minimumScaleFactor(0.8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func perm(_ name: String, _ ok: Bool, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? Color.mint : Color.secondary)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(ok ? "Allowed" : "Not allowed yet")
    }

    private func bindApp(_ app: NovaAppChoice) -> Binding<Bool> {
        Binding(get: { chosenApps.contains(app) }, set: { on in
            if on { chosenApps.insert(app) } else { chosenApps.remove(app) }
        })
    }
    private func bindFolder(_ path: String) -> Binding<Bool> {
        Binding(get: { chosenFolders.contains(path) }, set: { on in
            if on { chosenFolders.append(path) } else { chosenFolders.removeAll { $0 == path } }
        })
    }

    private func recovery(_ message: String) -> String {
        if message.localizedCaseInsensitiveContains("locked") || message.localizedCaseInsensitiveContains("wait 10") {
            return "Too many wrong codes. Wait 10 minutes, then make a new code on the Mac."
        }
        if message.localizedCaseInsensitiveContains("reach") || message.localizedCaseInsensitiveContains("offline") {
            return "Couldn't reach the Mac. Open Tailscale on both devices, same account."
        }
        return message + " Make a new code on the Mac if this one is old or already used."
    }

    private func confirmIdentity() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        return await withCheckedContinuation { done in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Confirm that Nova may use the whole Mac") { ok, _ in
                done.resume(returning: ok)
            }
        }
    }
}

/// Three access levels: chat, chosen apps/folders, or the whole Mac.
struct RangePicker: View {
    @Binding var level: String
    var body: some View {
        VStack(spacing: 10) {
            rangeCard("chat", "Just chat", ["Talk, search, and research."], ["See the Mac.", "Click, type, or take control."])
            rangeCard("apps", "Chosen apps and folders", ["Use only the apps and folders you tick."], ["See other windows.", "Open hidden folders or Library."])
            rangeCard("full", "Whole Mac", ["See the whole screen.", "Use any app."], ["Unlock the Mac.", "Bypass Emergency stop."])
        }
    }
    private func rangeCard(_ id: String, _ name: String, _ does: [String], _ doesNot: [String]) -> some View {
        Button { level = id } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: level == id ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(level == id ? Color.accentColor : Color.secondary)
                    Text(name).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                DoesDoesNot(does: does, doesNot: doesNot)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .novaSurface()
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(level == id ? Color.accentColor : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(NovaPressStyle())
        .accessibilityAddTraits(level == id ? .isSelected : [])
    }
}

struct QRScanner: UIViewRepresentable {
    var onCode: (String) -> Void
    func makeUIView(context: Context) -> QRScannerView {
        let view = QRScannerView()
        view.onCode = onCode
        return view
    }
    func updateUIView(_ view: QRScannerView, context: Context) { view.onCode = onCode }
}

final class QRScannerView: UIView, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var handled = false
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, preview == nil else { return }
        Task { await start() }
    }
    private func start() async {
        let status = await AVCaptureDevice.requestAccess(for: .video)
        await MainActor.run {
            guard status, let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device) else { return }
            session.beginConfiguration()
            if session.canAddInput(input) { session.addInput(input) }
            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
            }
            session.commitConfiguration()
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = bounds
            self.layer.addSublayer(layer)
            preview = layer
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        preview?.frame = bounds
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !handled, let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject, let value = object.stringValue else { return }
        handled = true
        onCode?(value)
    }
}

struct ReadyScreen: View {
    @EnvironmentObject private var nova: NovaModel
    var onContinue: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            NovaFace(mood: .happy, size: 0.50)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            Text("You’re all set.")
                .font(.largeTitle.weight(.semibold))
                .tracking(-1)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                readyRow("Computer", nova.setup?.computer.name ?? "Your Mac")
                Divider().overlay(.white.opacity(0.08))
                readyRow("Connection", nova.stopped ? "Emergency stopped" : nova.connection)
                Divider().overlay(.white.opacity(0.08))
                readyRow("Access", rangeLabel)
                Divider().overlay(.white.opacity(0.08))
                readyRow("AI", nova.provider?.label ?? nova.setup?.ai.anthropic.label ?? "Claude")
            }
            .padding(6)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text("Tap Talk to begin. Your computer and activity are one tap away.")
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                nova.readySeen = true
                onContinue()
            } label: {
                Text("Let’s begin").font(.headline).frame(maxWidth: .infinity).frame(minHeight: 52)
            }
            .buttonStyle(NovaPrimaryStyle())
            .controlSize(.large)
        }
        .padding(.top, 8)
        .task { await nova.loadSetup() }
    }
    private var rangeLabel: String { nova.effectiveAccessLabel }
    private func readyRow(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.body.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75).multilineTextAlignment(.trailing)
        }
        .padding(12)
        .accessibilityElement(children: .combine)
    }
}
