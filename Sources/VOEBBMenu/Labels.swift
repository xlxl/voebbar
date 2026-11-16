import AppKit

extension NSTextField {
    static func label(_ text: String, font: NSFont) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        return field
    }
}
