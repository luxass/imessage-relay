import AppKit
import Foundation

/// Copies text with the concealed/transient pasteboard flags and clears it
/// after a minute when the clipboard is untouched.
enum SecurePasteboard {
    @discardableResult
    static func copy(_ string: String, autoClearAfter seconds: Int = 60) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let changeCount = pasteboard.changeCount
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if pasteboard.changeCount == changeCount {
                pasteboard.clearContents()
            }
        }
        return changeCount
    }
}
