import SwiftUI

enum GroveTheme {
    static let canvas = Color(
        light: NSColor(calibratedRed: 0.961, green: 0.965, blue: 0.969, alpha: 1),
        dark: NSColor(calibratedRed: 0.075, green: 0.078, blue: 0.082, alpha: 1)
    )
    static let surface = Color(
        light: .white,
        dark: NSColor(calibratedRed: 0.102, green: 0.106, blue: 0.110, alpha: 1)
    )
    static let ink = Color(
        light: NSColor(calibratedRed: 0.141, green: 0.157, blue: 0.173, alpha: 1),
        dark: NSColor(calibratedRed: 0.937, green: 0.945, blue: 0.953, alpha: 1)
    )
    static let grove = Color(red: 0.224, green: 0.463, blue: 0.365)
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
