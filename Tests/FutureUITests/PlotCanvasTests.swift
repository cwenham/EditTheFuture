import Foundation
import SwiftUI
import Testing
import FutureEngine
@testable import FutureUI

@Suite("Plot drawing")
struct PlotCanvasTests {
    @Test("A dense line is thinned to a few points per pixel column but keeps its extremes")
    func decimation() {
        let start = utc(2000, 1, 1)
        // 40 years of daily samples, with one spike.
        var samples: [Sample] = (0..<(40 * 365)).map { day in
            Sample(time: start.addingTimeInterval(Double(day) * 86_400), value: sin(Double(day) / 30))
        }
        samples[7_000] = Sample(time: samples[7_000].time, value: 50)
        let frame = TimeFrame(start: start, end: samples.last!.time)
        let size = CGSize(width: 400, height: 100)
        var highest = CGFloat.infinity
        var points = 0
        let path = PlotCanvas.path(for: samples, frame: frame, size: size,
                                   x: { frame.x($0, width: size.width) },
                                   y: { CGFloat(100 - $0) })
        path.forEach { element in
            switch element {
            case .move(let point), .line(let point):
                points += 1
                highest = min(highest, point.y)
            default: break
            }
        }
        #expect(points <= 4 * 402)
        #expect(highest == 50)  // y = 100 - 50: the spike survived thinning
    }

    @Test("A sparse line keeps every point, plus one either side of the frame")
    func sparse() {
        let start = utc(2000, 1, 1)
        let samples = (0..<120).map { Sample(time: start.addingTimeInterval(Double($0) * 30 * 86_400), value: Double($0)) }
        // Starts just after a sample and ends between two, so the line needs one sample on each side.
        let frame = TimeFrame(start: samples[10].time.addingTimeInterval(86_400), end: samples[20].time.addingTimeInterval(10 * 86_400))
        let size = CGSize(width: 800, height: 100)
        var points = 0
        PlotCanvas.path(for: samples, frame: frame, size: size, x: { frame.x($0, width: size.width) }, y: { CGFloat($0) })
            .forEach { if case .line = $0 { points += 1 } else if case .move = $0 { points += 1 } }
        #expect(points == 12)  // samples 11...20 are visible, plus 10 and 21
    }
}
