import SwiftUI
import FutureVisuals

/// A ring split into the parts of a whole, from a `groups` field, with each part's name and share
/// beside it: where everyone is in an outbreak, say (docs/DESIGN.md, 9.6).
public struct PartsBackdrop: Backdrop {
    public let kind = BackdropKind.parts

    public init() {}

    /// How strongly each part is filled, in order; they repeat after the last.
    static let shades: [Double] = [0.16, 0.34, 0.6, 0.26, 0.46, 0.2]

    /// Each part's share of the whole, from the field's values. Parts below zero or not finite count as none.
    public static func shares(_ values: [Double]) -> [Double] {
        let clean = values.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        let total = clean.reduce(0, +)
        return total > 0 ? clean.map { $0 / total } : clean.map { _ in 0 }
    }

    /// "12.3%", "0.4%", "<0.1%", "0%".
    public static func percent(_ share: Double) -> String {
        if share <= 0 { return "0%" }
        if share < 0.001 { return "<0.1%" }
        let tenths = (share * 1000).rounded()
        return tenths.truncatingRemainder(dividingBy: 10) == 0 ? "\(Int(tenths / 10))%" : "\(tenths / 10)%"
    }

    public func draw(_ input: BackdropInput, in context: inout GraphicsContext, size: CGSize) {
        guard let field = input.field, !field.keys.isEmpty else { return }
        let shares = Self.shares(field.values)
        let radius = min(size.height * 0.34, size.width * 0.16)
        guard radius > 8 else { return }
        let labelWidth: CGFloat = 170
        let groupWidth = radius * 2 + 20 + labelWidth
        let center = CGPoint(x: (size.width - groupWidth) / 2 + radius, y: size.height / 2)
        let thickness = radius * 0.36

        // The ring, clockwise from the top, with a hairline gap between parts.
        var angle = -Double.pi / 2
        for (index, share) in shares.enumerated() where share > 0 {
            let sweep = share * 2 * .pi
            let gap = shares.filter { $0 > 0 }.count > 1 ? min(0.02, sweep / 4) : 0
            var arc = Path()
            arc.addArc(center: center, radius: radius - thickness / 2, startAngle: .radians(angle + gap / 2),
                       endAngle: .radians(angle + sweep - gap / 2), clockwise: false)
            context.stroke(arc, with: .color(Color(input.color).opacity(Self.shades[index % Self.shades.count])),
                           style: StrokeStyle(lineWidth: thickness, lineCap: .butt))
            angle += sweep
        }

        // Names and shares, left-aligned in a column beside the ring.
        let rowHeight: CGFloat = 18
        let left = center.x + radius + 20
        var y = center.y - CGFloat(field.keys.count) * rowHeight / 2 + rowHeight / 2
        if let label = input.label {
            let title = context.resolve(Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.35)))
            context.draw(title, at: CGPoint(x: left, y: y - rowHeight), anchor: .leading)
        }
        for (index, key) in field.keys.enumerated() {
            let swatch = CGRect(x: left, y: y - 4.5, width: 9, height: 9)
            context.fill(Path(roundedRect: swatch, cornerRadius: 2),
                         with: .color(Color(input.color).opacity(Self.shades[index % Self.shades.count])))
            let name = input.keyLabels[key] ?? key
            let text = context.resolve(Text("\(name)  \(Self.percent(shares[index]))")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.white.opacity(0.42)))
            context.draw(text, at: CGPoint(x: left + 15, y: y), anchor: .leading)
            y += rowHeight
        }
    }
}
