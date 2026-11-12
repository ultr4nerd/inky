import AppKit
import SwiftUI

/// Inky's mark: a serif "i" whose dot is a falling ink drop. Template image, so it takes
/// the menu bar's (or the view's) foreground color.
enum Brand {
    static let glyph: NSImage = {
        if let url = Bundle.main.url(forResource: "InkyGlyph", withExtension: "pdf"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.accessibilityDescription = "Inky"
            return image
        }
        return NSImage(systemSymbolName: "pencil.tip", accessibilityDescription: "Inky")!
    }()

    /// The glyph as a SwiftUI view, `size` points tall, tinted with the foreground style.
    static func mark(_ size: CGFloat) -> some View {
        Image(nsImage: glyph).renderingMode(.template).resizable().scaledToFit().frame(width: size, height: size)
    }
}
