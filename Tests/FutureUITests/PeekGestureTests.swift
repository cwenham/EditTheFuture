import Foundation
import Testing
@testable import FutureKit
@testable import FutureUI

@Suite("Peek gesture")
struct PeekGestureTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("Holding peeks, releasing hides")
    func hold() {
        var gesture = PeekGesture()
        #expect(gesture.press(at: t0, panelVisible: false) == .beginPeek)
        #expect(gesture.release(at: t0.addingTimeInterval(0.8)) == .hide)
    }

    @Test("A quick tap opens the panel, another closes it")
    func tap() {
        var gesture = PeekGesture()
        #expect(gesture.press(at: t0, panelVisible: false) == .beginPeek)
        #expect(gesture.release(at: t0.addingTimeInterval(0.1)) == .showFully)
        #expect(gesture.press(at: t0.addingTimeInterval(1), panelVisible: true) == .nothing)
        #expect(gesture.release(at: t0.addingTimeInterval(1.1)) == .hide)
    }

    @Test("Key repeat and stray releases are ignored")
    func repeats() {
        var gesture = PeekGesture()
        #expect(gesture.release(at: t0) == .nothing)
        #expect(gesture.press(at: t0, panelVisible: false) == .beginPeek)
        #expect(gesture.press(at: t0.addingTimeInterval(0.05), panelVisible: true) == .nothing)
        #expect(gesture.release(at: t0.addingTimeInterval(0.5)) == .hide)
    }
}
