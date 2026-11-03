import Foundation

/// A colour as plain numbers, so code that doesn't draw can carry one: a slot's colour, or the colour a
/// backdrop shades with. Views turn it into a SwiftUI `Color` (FutureUI's `Color(_:)`).
public struct RGBA: Hashable, Sendable {
    /// Each 0...1, in sRGB.
    public var red: Double
    public var green: Double
    public var blue: Double
    public var opacity: Double

    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    /// `RGBA(hex: "#5AA9FF")`, with or without the `#`. What can't be read is white.
    public init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt32(digits, radix: 16) ?? 0xFFFFFF
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    /// The same colour at another opacity.
    public func opacity(_ opacity: Double) -> RGBA {
        RGBA(red: red, green: green, blue: blue, opacity: opacity)
    }
}
