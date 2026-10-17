import Testing
@testable import Orra

/// The timing log line for the start of a hold: numbers, yes or no, the path and the
/// transport code, never a device name or text.
struct CaptureTimingsTests {
    @Test func aKeyThatWaitedIsTimedFromItsKeyDown() {
        let keyDown = ContinuousClock.now
        var timings = CaptureTimings(keyDown: keyDown, waited: true)
        timings.counted = keyDown + .milliseconds(301)
        timings.startReturned = keyDown + .milliseconds(335)
        timings.onset = CaptureOnset(
            path: .unit,
            transport: 0x7573_6220,
            firstBuffer: keyDown + .milliseconds(348),
            firstSound: keyDown + .milliseconds(352)
        )
        #expect(timings.summary == "key waited yes 301 ms, path unit, transport usb, from key down: start returned 335 ms, first buffer 348 ms, first sound 352 ms")
    }

    @Test func timesThatNeverCameReadNone() {
        let keyDown = ContinuousClock.now
        var timings = CaptureTimings(keyDown: keyDown, waited: false)
        timings.startReturned = keyDown + .milliseconds(12)
        timings.onset = CaptureOnset(path: .engine, transport: 0x626C_746E, firstBuffer: keyDown + .milliseconds(118))
        #expect(timings.summary == "key waited no, path engine, transport bltn, from key down: start returned 12 ms, first buffer 118 ms, first sound none")
        #expect(CaptureTimings(keyDown: keyDown, waited: true).summary == "key waited yes none, path none, transport none, from key down: start returned none, first buffer none, first sound none")
    }
}
