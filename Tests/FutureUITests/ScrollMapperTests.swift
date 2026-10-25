import Testing
@testable import FutureUI

@Suite("Scroll mapping")
struct ScrollMapperTests {
    @Test("With one wheel, the wheel scrolls through time and Shift + wheel zooms")
    func oneWheel() {
        var mapper = ScrollMapper()
        #expect(mapper.map(.init(dx: 0, dy: -1, precise: false)).action == .pan(0.04))
        // macOS delivers Shift + vertical wheel as a horizontal delta.
        let zoomIn = mapper.map(.init(dx: 1, dy: 0, precise: false, shift: true))
        #expect(zoomIn.action == .zoom(0.88))
        #expect(!zoomIn.foundHorizontalWheel)
        #expect(!mapper.hasHorizontalWheel)
    }

    @Test("A horizontal wheel is found the first time it turns, then the vertical wheel zooms")
    func twoWheels() {
        var mapper = ScrollMapper()
        let first = mapper.map(.init(dx: -2, dy: 0, precise: false))
        #expect(first.action == .pan(0.08))
        #expect(first.foundHorizontalWheel)
        #expect(!mapper.map(.init(dx: -1, dy: 0, precise: false)).foundHorizontalWheel)
        #expect(mapper.map(.init(dx: 0, dy: 1, precise: false)).action == .zoom(0.88))
        #expect(mapper.map(.init(dx: 0, dy: -1, precise: false)).action == .zoom(1 / 0.88))
    }

    @Test("Wheel up zooms in whatever the natural-scrolling setting")
    func naturalScrolling() {
        var mapper = ScrollMapper(hasHorizontalWheel: true)
        #expect(mapper.map(.init(dx: 0, dy: -1, precise: false, inverted: true)).action == .zoom(0.88))
    }

    @Test("Trackpad swipes scroll; Shift or Command swipes zoom")
    func trackpad() {
        var mapper = ScrollMapper()
        #expect(mapper.map(.init(dx: -20, dy: 2, precise: true)).action == .pan(0.03))
        if case .zoom(let factor) = mapper.map(.init(dx: 0, dy: 10, precise: true, command: true)).action {
            #expect(factor < 1)
        } else {
            Issue.record("Expected a zoom")
        }
        #expect(!mapper.map(.init(dx: 30, dy: 0, precise: true)).foundHorizontalWheel)
        #expect(!mapper.hasHorizontalWheel)
    }
}
