import SwiftUI

enum GroveTheme {
    static let canvas = Color(
        light: NSColor(calibratedRed: 0.953, green: 0.969, blue: 0.957, alpha: 1),
        dark: NSColor(calibratedRed: 0.067, green: 0.082, blue: 0.071, alpha: 1)
    )
    static let surface = Color(
        light: .white,
        dark: NSColor(calibratedRed: 0.102, green: 0.118, blue: 0.106, alpha: 1)
    )
    static let ink = Color(
        light: NSColor(calibratedRed: 0.086, green: 0.129, blue: 0.102, alpha: 1),
        dark: NSColor(calibratedRed: 0.937, green: 0.965, blue: 0.945, alpha: 1)
    )
    static let grove = Color(red: 0.18, green: 0.49, blue: 0.36)
    static let evidence = Color(red: 0.76, green: 0.48, blue: 0.16)
    static let revision = Color(red: 0.28, green: 0.46, blue: 0.71)
    static let divider = Color.primary.opacity(0.10)
}

private extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}
