import XCTest
@testable import NovaVoiceState

final class VoiceCaptureStateTests: XCTestCase {
    func testRepeatedTapsDuringPermissionPromptCannotStartAnotherCapture() throws {
        var state = VoiceCaptureState()
        let id = try XCTUnwrap(state.beginStart())
        XCTAssertEqual(state.phase, .starting)
        XCTAssertNil(state.beginStart())
        XCTAssertNil(state.beginFinishing())
        XCTAssertTrue(state.didStart(id))
        XCTAssertTrue(state.listening)
    }
    func testCancelWhileRequestingPermissionRejectsLateGrant() throws {
        var state = VoiceCaptureState()
        let id = try XCTUnwrap(state.beginStart())
        state.cancel()
        XCTAssertFalse(state.didStart(id))
        XCTAssertFalse(state.accepts(id))
        XCTAssertEqual(state.phase, .idle)
    }
    func testStopClearsListeningBeforeWaitingForRecognition() throws {
        var state = VoiceCaptureState()
        let id = try XCTUnwrap(state.beginStart())
        XCTAssertTrue(state.didStart(id))
        XCTAssertEqual(state.beginFinishing(), id)
        XCTAssertFalse(state.listening)
        XCTAssertTrue(state.transitioning)
        XCTAssertNil(state.beginStart())
    }
    func testRapidDoubleSendClaimsTheTranscriptOnce() throws {
        var state = VoiceCaptureState()
        let id = try XCTUnwrap(state.beginStart())
        XCTAssertTrue(state.didStart(id))
        XCTAssertEqual(state.beginFinishing(), id)
        XCTAssertNil(state.beginFinishing())
        XCTAssertTrue(state.finish(id))
        XCTAssertFalse(state.finish(id))
    }
    func testOldFinalCallbackCannotEndAReplacementCapture() throws {
        var state = VoiceCaptureState()
        let old = try XCTUnwrap(state.beginStart())
        XCTAssertTrue(state.didStart(old))
        XCTAssertEqual(state.beginFinishing(), old)
        state.cancel()
        let current = try XCTUnwrap(state.beginStart())
        XCTAssertTrue(state.didStart(current))
        XCTAssertFalse(state.finish(old))
        XCTAssertTrue(state.listening)
        XCTAssertTrue(state.accepts(current))
    }
    func testRecognitionFailureEndsListeningAndAllowsRetry() throws {
        var state = VoiceCaptureState()
        let id = try XCTUnwrap(state.beginStart())
        XCTAssertTrue(state.didStart(id))
        XCTAssertTrue(state.finish(id))
        XCTAssertFalse(state.listening)
        XCTAssertFalse(state.accepts(id))
        XCTAssertNotNil(state.beginStart())
    }
    func testAudioEngineStartFailureCanCleanUpStartingState() throws {
        var state = VoiceCaptureState()
        let id = try XCTUnwrap(state.beginStart())
        XCTAssertTrue(state.finish(id))
        XCTAssertFalse(state.transitioning)
        XCTAssertNotNil(state.beginStart())
    }
    func testBackgroundCancellationInvalidatesFinalization() throws {
        var state = VoiceCaptureState()
        let id = try XCTUnwrap(state.beginStart())
        XCTAssertTrue(state.didStart(id))
        XCTAssertEqual(state.beginFinishing(), id)
        state.cancel()
        XCTAssertFalse(state.accepts(id))
        XCTAssertFalse(state.finish(id))
        XCTAssertEqual(state.phase, .idle)
    }
    func testCancelledAudioBuffersCannotRelightTheMeter() {
        let meter = VoiceMeter()
        meter.begin(1); meter.update(1, for: 1)
        XCTAssertGreaterThan(meter.level, 0)
        meter.reset(); meter.update(1, for: 1)
        XCTAssertEqual(meter.level, 0)
        meter.begin(2); meter.update(1, for: 1)
        XCTAssertEqual(meter.level, 0)
        meter.update(1, for: 2)
        XCTAssertGreaterThan(meter.level, 0)
    }
    func testMeterClampsSmoothsAndRejectsNonFiniteSamples() {
        let meter = VoiceMeter(); meter.begin(1)
        meter.update(.infinity, for: 1); meter.update(.nan, for: 1)
        XCTAssertEqual(meter.level, 0)
        meter.update(10, for: 1)
        XCTAssertEqual(meter.level, 0.24, accuracy: 0.00001)
        meter.update(-10, for: 1)
        XCTAssertGreaterThan(meter.level, 0)
        XCTAssertLessThan(meter.level, 0.24)
    }
    func testMeterCanBeReadWhileAudioCallbacksUpdateAndReset() {
        let meter = VoiceMeter(); meter.begin(7)
        DispatchQueue.concurrentPerform(iterations: 1000) { i in
            meter.update(CGFloat(i % 100) / 100, for: 7)
            let value = meter.level
            XCTAssertTrue(value.isFinite && value >= 0 && value <= 1)
            if i % 100 == 0 { meter.reset(); meter.begin(7) }
        }
        meter.reset()
        XCTAssertEqual(meter.level, 0)
    }
}
