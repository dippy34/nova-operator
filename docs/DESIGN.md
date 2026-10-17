# Nova interface

Nova uses quiet content surfaces and Nova’s expressive minimal smiley face. Color signals activity, rather than filling every card.

## Native surfaces

- Nova keeps its own identity: two rounded eyes, a small smile, and cyan/indigo/mint light. No Siri orb or full-spectrum rainbow is used. Expressions distinguish listening, thinking, speaking, success, and errors.

The home screen exposes Talk, Computer (owner devices), Activity, and the controls button. Existing gestures remain optional shortcuts.
- Nova illuminates the screen edges only while the microphone is listening. Voice volume controls opacity of a fixed cyan/indigo/mint glow. Tasks and spoken replies keep the glow off; the character and status text describe those states. This is an in-app effect, not a system overlay or a replacement for the iPhone side-button Siri gesture.
- Navigation and action controls use native Liquid Glass on iOS 26, with regular system material on iOS 18. Content uses grouped system backgrounds. Mac setup follows the system appearance.
- Setup, permissions, credentials, devices, schedules, reports, visual answers, progress, and remote-control screens retain their existing actions.

## Accessibility

Reduce Motion stops the face timeline and replaces meter updates with a static listening glow and disables animated app transactions. Reduce Transparency or increased contrast replaces glass controls with solid surfaces. Accessibility text sizes use a scrollable home layout and vertical action controls. Visible text accompanies the presence, so activity does not depend on color alone.

## Review without a model request

Debug iOS builds accept `-nova-design=home`, `listening`, `welcome`, `menu`, `settings`, or `access`. These render the same presentation components with an isolated model. The home preview says “Mac connected” as sample copy; it does not establish a connection. The review does not pair, read a provider key, submit an AI request, or run computer input. Controls that would need a backend are inert or show unconfigured settings. Do not use review mode for end-to-end functionality claims.

The Mac executable supports `preview-setup <png-path> --design-preview --code` to render sample setup without starting the executor or fetching Core status. The displayed invitation is a nonfunctional placeholder. Omit `--design-preview` only when intentionally reviewing actual local setup status.

## Platform references

- [Apple: materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Apple: applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)

The interface is inspired by Apple platform conventions and Matthew’s references. Nova is an independent app; it does not use private Siri UI or APIs.

## Voice lifecycle checks

Run `swift test --package-path ios` for the production capture-state and meter checks. They cover permission-prompt cancellation, rapid double taps, immediate end of listening during finalization, stale results and audio buffers, recognition/start failures, background cancellation, and concurrent metering. These checks do not capture sound, contact a provider, or measure real-device frame rate.

The microphone meter is a thread-safe mailbox sampled only by the listening overlay. Microphone buffers and recognition partials no longer publish changes to the entire app view. Starting and finalizing are explicit exclusive states. Final transcription may take up to 600 ms after the microphone is stopped; the screen stops showing listening immediately. Backgrounding, interruptions, navigation, and a new task cancel capture. Recognition finishing unexpectedly resets the microphone and shows a retry message rather than silently submitting a task.
