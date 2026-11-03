import Foundation
import Testing
import FutureTestSupport
import FutureEngine
@testable import FutureKit
@testable import FutureUI

@Suite("Start label")
struct StartLabelTests {
    @Test("The start's label goes left of its line when there's room and it misses the Now label")
    func startLabelPlacement() {
        #expect(StartLabel.trailingEdge(startX: 300, labelWidth: 90, nowLabel: (400, 490)) == 294)
        // Too close to the left edge.
        #expect(StartLabel.trailingEdge(startX: 60, labelWidth: 90, nowLabel: nil) == nil)
        // A scenario that starts after now, with the Now label in the way.
        #expect(StartLabel.trailingEdge(startX: 300, labelWidth: 90, nowLabel: (180, 270)) == nil)
        #expect(StartLabel.trailingEdge(startX: 300, labelWidth: 90, nowLabel: (60, 150)) == 294)
    }
}
