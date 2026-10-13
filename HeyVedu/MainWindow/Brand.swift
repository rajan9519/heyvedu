import AppKit
import SwiftUI

extension Color {
    /// HeyVedu's green, as in the logo and the Activity calendar.
    static let brand = Color(red: 0.11, green: 0.62, blue: 0.46)

    /// The brand green for text and icons on a light brand tint: darker in light mode,
    /// lighter in dark mode, so it stays readable on either.
    static let brandText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.36, green: 0.79, blue: 0.65, alpha: 1)
            : NSColor(srgbRed: 0.06, green: 0.43, blue: 0.34, alpha: 1)
    })
}
