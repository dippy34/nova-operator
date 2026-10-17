import SwiftUI

/// Hold-the-face menu: ask, control, schedule, settings.
struct HomeView: View {
    @EnvironmentObject private var nova: NovaModel
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var showStop = false
    @State private var showUnpair = false
    @State private var showSchedule = false
    @State private var scheduleTitle = ""
    @State private var scheduleTask = ""
    @State private var scheduleWhen = "daily"
    @State private var dailyAt = "08:00"
    @State private var everyMinutes = "30"
    @State private var onceAt = ""
    @State private var monitor = false
    @State private var usesComputer = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    StatusStrip()
                    Text("Your requests, your computer, your way.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)

                    SectionLabel(text: "Conversation")
                    lastExchange
                    askField
                    if nova.working && nova.chat?.type == "computer.task" {
                        ExplainButton(title: "Stop this task", does: "End the current computer task.", symbol: "stop.fill", danger: true) {
                            Task { await nova.stopTask() }
                        }
                    }

                    if nova.computer?.owner == true {
                        SectionLabel(text: "Your computer")
                        if nova.computer?.paused == true {
                            Label("Paused. You have the Mac. Hand back to let me continue.", systemImage: "pause.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.mint)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        ExplainButton(
                            title: "Take control",
                            does: nova.setup?.access.level == "chat" ? "Available when computer access is enabled." : "Pause Nova and use your Mac from here.",
                            symbol: "hand.point.up.left.fill",
                            tint: .orange,
                            prominent: true
                        ) {
                            dismiss()
                            nova.takeOver()
                        }
                        .disabled(nova.setup?.access.level == "chat")
                        ExplainLink(title: "Schedules and reports", does: "Scheduled tasks, monitors, and recent results.", symbol: "calendar.badge.clock") {
                            WorkView()
                        }
                        ExplainButton(title: "New schedule", does: "Plan a task or watch for changes.", symbol: "plus.circle.fill", tint: .mint) {
                            showSchedule = true
                        }
                    }

                    SectionLabel(text: "Settings")
                    ExplainLink(title: "Settings", does: "Access, AI provider, and paired devices.", symbol: "slider.horizontal.3") {
                        SettingsView()
                    }
                    Toggle(isOn: $nova.voiceReplies) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Speak replies").font(.headline)
                            Text("Hear Nova’s answers aloud.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .background(NovaInk.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    SectionLabel(text: "Safety")
                    ExplainButton(title: "Emergency stop", does: "Stop all work. Resume from Nova on your Mac.", symbol: "stop.circle.fill", danger: true) {
                        showStop = true
                    }
                    .disabled(nova.busy || nova.stopped)
                    if nova.stopped {
                        Text("Stopped. Only the Mac can resume me.")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    ExplainButton(title: "Unpair this iPhone", does: "Remove this phone’s connection to your Mac.", symbol: "iphone.slash", tint: .orange) {
                        showUnpair = true
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
            .background(NovaBackground())
            .navigationTitle("Nova")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(for: String.self) { JobDetailView(id: $0) }
            .alert("Nova", isPresented: Binding(get: { nova.errorMessage != nil }, set: { if !$0 { nova.errorMessage = nil } })) {
                Button("OK") { nova.errorMessage = nil }
            } message: { Text(nova.errorMessage ?? "") }
            .confirmationDialog("Stop all Nova jobs?", isPresented: $showStop, titleVisibility: .visible) {
                Button("Emergency stop", role: .destructive) { Task { await nova.emergencyStop() } }
            } message: { Text("This stops work on the Mac until you resume it in Nova Operator.") }
            .confirmationDialog("Unpair this iPhone?", isPresented: $showUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) { nova.unpair(); dismiss() }
            } message: { Text("This iPhone will lose access. Pair it again with a new code from the Mac.") }
            .sheet(isPresented: $showSchedule) { scheduleSheet }
            .onChange(of: nova.tutorialSeen) { _, seen in
                if !seen { dismiss() }
            }
        }
        .presentationDragIndicator(.visible)
        .presentationDetents([.large])
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var lastExchange: some View {
        if let chat = nova.chat {
            VStack(alignment: .leading, spacing: 8) {
                if let question = chat.payload["message"] {
                    Text("You asked").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    Text(question.description).foregroundStyle(.cyan).lineLimit(3)
                }
                if let reply = chat.result?["message"] {
                    Text("I said").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    Text(reply.description).textSelection(.enabled)
                } else if let error = chat.error {
                    Text(error).foregroundStyle(.orange)
                } else if nova.working {
                    ProgressView(chat.type == "computer.task" ? "Using the Mac…" : "Thinking. Not touching the Mac.")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NovaInk.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var askField: some View {
        HStack(spacing: 10) {
            TextField("Type a task", text: $message, axis: .vertical)
                .lineLimit(1...4)
                .accessibilityLabel("Task for Nova")
            Button {
                Task { if await nova.send(message) { message = ""; dismiss() } }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title)
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Send task")
            .disabled(nova.busy || nova.working || nova.stopped || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(14)
        .background(NovaInk.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var scheduleSheet: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $scheduleTitle)
                TextField("What should Nova do?", text: $scheduleTask, axis: .vertical).lineLimit(3...8)
                Picker("When", selection: $scheduleWhen) {
                    Text("Every day").tag("daily")
                    Text("Every few minutes").tag("every")
                    Text("Once").tag("once")
                }
                if scheduleWhen == "daily" { TextField("Time (08:00)", text: $dailyAt) }
                if scheduleWhen == "every" { TextField("Minutes", text: $everyMinutes).keyboardType(.numberPad) }
                if scheduleWhen == "once" { TextField("Local time", text: $onceAt) }
                Toggle("Only tell me when something happens", isOn: $monitor)
                Text(monitor ? "Does: watch quietly. Does not: ping you every run." : "Does: run and report. Does not: wait for a change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if nova.setup?.access.level != "chat" {
                    Toggle("Needs the Mac screen", isOn: $usesComputer)
                    Text(usesComputer ? "Does: click and type on the Mac. Does not: run if access is Just chat." : "Does: research in the background. Does not: touch the screen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Schedule")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showSchedule = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            var body: [String: Any] = ["title": scheduleTitle, "task": scheduleTask, "monitor": monitor, "uses_computer": usesComputer]
                            if scheduleWhen == "daily" { body["daily_at"] = dailyAt }
                            if scheduleWhen == "every", let n = Int(everyMinutes) { body["every_minutes"] = n }
                            if scheduleWhen == "once" { body["at"] = onceAt }
                            if await nova.addSchedule(body) { showSchedule = false }
                        }
                    }
                    .disabled(scheduleTitle.isEmpty || scheduleTask.isEmpty)
                }
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var nova: NovaModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                StatusStrip()
                Text("Make Nova feel right for you. You’re always in control.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                SectionLabel(text: "Access")
                if nova.computer?.owner == true {
                    ExplainLink(title: "What I may use", does: "\(rangeLabel). Review Nova’s apps and files.", symbol: "lock.shield.fill", tint: .orange) {
                        RangeSettings()
                    }
                    SectionLabel(text: "AI")
                    ExplainLink(title: "Provider and keys", does: "\(nova.provider?.label ?? "Claude"). Keys are stored securely on your Mac.", symbol: "key.fill", tint: .mint) {
                        AISettings()
                    }
                } else {
                    ExplainRow(title: rangeLabel,
                               does: "To control the Mac, pair this iPhone from Nova on your Mac with ‘This iPhone controls the Mac’ enabled.",
                               symbol: "bubble.left.and.bubble.right", tint: .blue)
                }

                if nova.computer?.owner == true {
                    SectionLabel(text: "Devices")
                    ExplainLink(title: "Paired phones", does: "Review and remove connected devices.", symbol: "iphone") {
                        DevicesSettings()
                    }
                }

                SectionLabel(text: "This Mac")
                VStack(spacing: 0) {
                    settingsFact("Connection", nova.connection)
                    Divider().overlay(.white.opacity(0.08))
                    settingsFact("Computer", nova.setup?.computer.name ?? "Your Mac")
                    if let ai = nova.ai {
                        Divider().overlay(.white.opacity(0.08))
                        settingsFact("Spent", String(format: "$%.2f", ai.usedUSD))
                    }
                }
                .background(NovaInk.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                ExplainButton(title: "Check Mac status", does: "Check the connection without using your AI balance.", symbol: "stethoscope") {
                    Task { await nova.submit("mac.status") }
                }
                .disabled(nova.busy || nova.stopped)

                SectionLabel(text: "How to use")
                howTo("mic", "Talk to Nova", "Tap Talk to start. Tap Send when you’re ready.")
                howTo("slider.horizontal.3", "Your controls", "Open the top-right control to type a request or change settings.")
                howTo("arrow.up", "Swipe up", "Live picture of the Mac.")
                howTo("arrow.left", "Swipe left", "Schedules, agents, and reports.")
                howTo("keyboard", "Control-Option-S", "Emergency stop on the Mac keyboard.")
                ExplainButton(title: "Replay tutorial", does: "See the introduction again. Your connection stays paired.", symbol: "book.fill", tint: .mint) {
                    nova.replayTutorial()
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .background(NovaBackground())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
    private var rangeLabel: String { nova.effectiveAccessLabel }
    private func settingsFact(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.body.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(14)
        .accessibilityElement(children: .combine)
    }
    private func howTo(_ symbol: String, _ title: String, _ does: String) -> some View {
        ExplainRow(title: title, does: does, symbol: symbol, tint: .cyan)
    }
}

struct RangeSettings: View {
    @EnvironmentObject private var nova: NovaModel
    @State private var level = "chat"
    @State private var apps: [NovaAppChoice] = []
    @State private var chosen: Set<NovaAppChoice> = []
    @State private var folders: [NovaFolderChoice] = []
    @State private var chosenFolders: [String] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Three levels. Chat never sees the Mac. Chosen apps only use what you tick. Whole Mac can use anything.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                RangePicker(level: $level)
                if level == "apps" {
                    Text("Apps").font(.headline)
                    ForEach(apps) { app in
                        Toggle(app.name, isOn: Binding(get: { chosen.contains(app) }, set: { on in
                            if on { chosen.insert(app) } else { chosen.remove(app) }
                        }))
                    }
                    Text("Folders").font(.headline)
                    ForEach(folders) { folder in
                        Toggle(folder.name, isOn: Binding(get: { chosenFolders.contains(folder.path) }, set: { on in
                            if on { chosenFolders.append(folder.path) } else { chosenFolders.removeAll { $0 == folder.path } }
                        }))
                    }
                }
                Button {
                    Task { await save() }
                } label: {
                    Text("Save").font(.headline).frame(maxWidth: .infinity).frame(minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(level == "apps" && chosen.isEmpty && chosenFolders.isEmpty)
            }
            .padding()
        }
        .navigationTitle("Access")
        .background(NovaBackground())
        .task {
            level = nova.setup?.access.level ?? "chat"
            apps = await nova.listedApps()
            folders = await nova.listedFolders()
            chosen = Set(nova.setup?.access.apps ?? [])
            chosenFolders = nova.setup?.access.folders ?? []
        }
    }
    private func save() async {
        switch level {
        case "apps": _ = await nova.setAccess(level: "apps", apps: Array(chosen), folders: chosenFolders)
        case "full": _ = await nova.setAccess(level: "full")
        default: _ = await nova.setAccess(level: "chat")
        }
    }
}

struct AISettings: View {
    @EnvironmentObject private var nova: NovaModel
    @State private var provider = "anthropic"
    @State private var key = ""
    @State private var note: String?
    var body: some View {
        Form {
            Section("In use") {
                Text(nova.setup?.ai.selected == "openai" ? "OpenAI" : "Claude")
                DoesDoesNot(
                    does: ["Talks to the model you pick.", "Spends from that provider's API bill."],
                    doesNot: ["Store the key on this phone.", "Use ChatGPT Plus or Claude Pro as the API."]
                )
                .padding(.vertical, 4)
                if nova.setup?.ai.anthropic.configured == true {
                    Button("Use Claude") { Task { await nova.selectProvider("anthropic") } }
                }
                if nova.setup?.ai.openai.configured == true {
                    Button("Use OpenAI") { Task { await nova.selectProvider("openai") } }
                }
            }
            Section("Add a key") {
                Picker("Provider", selection: $provider) {
                    Text("Claude").tag("anthropic")
                    Text("OpenAI").tag("openai")
                }.pickerStyle(.segmented)
                if provider == "openai" {
                    Text("API billing is separate from ChatGPT Plus or Pro.")
                }
                SecureField("API key", text: $key).textContentType(.password)
                Button("Save and test") {
                    Task { note = await nova.saveKey(provider: provider, key: key); key = "" }
                }.disabled(key.isEmpty)
                if let note { Text(note) }
            }
            Section {
                if nova.setup?.ai.openai.configured == true {
                    Button("Remove OpenAI key", role: .destructive) { Task { await nova.removeKey("openai") } }
                }
            }
        }
        .navigationTitle("AI provider")
        .scrollContentBackground(.hidden)
        .background(NovaBackground())
    }
}

struct DevicesSettings: View {
    @EnvironmentObject private var nova: NovaModel
    @State private var devices: [NovaPairedDevice] = []
    var body: some View {
        List {
            ForEach(devices) { device in
                HStack {
                    VStack(alignment: .leading) {
                        Text(device.name).font(.headline)
                        Text(device.owner ? "Controls this Mac" : "Can chat").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if device.current { Text("This iPhone").font(.caption) }
                }
                .swipeActions {
                    if !device.current {
                        Button("Remove", role: .destructive) {
                            Task { await nova.revokeDevice(device.id); devices = await nova.pairedDevices() }
                        }
                    }
                }
            }
        }
        .navigationTitle("Devices")
        .scrollContentBackground(.hidden)
        .background(NovaBackground())
        .task { devices = await nova.pairedDevices() }
    }
}
