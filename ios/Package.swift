// swift-tools-version: 5.9
import PackageDescription

// Exercise the production voice lifecycle without a microphone, signing, or an AI request.
let package = Package(
    name: "NovaVoiceChecks",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "NovaVoiceState", path: "NovaApp",
                exclude: ["ContentView.swift", "Home.swift", "Info.plist", "NovaApp.swift", "NovaModel.swift", "Onboarding.swift", "Theme.swift"],
                sources: ["VoiceCaptureState.swift"]),
        .testTarget(name: "NovaVoiceStateTests", dependencies: ["NovaVoiceState"], path: "VoiceTests")
    ]
)
