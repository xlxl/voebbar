import AppKit

/// Traffic-light colour for due dates (thresholds in `Urgency`), used by the menu's dots and the
/// overview table. Replaces the old 📕📙📗 emojis: easier to tell apart at menu size, adapts to
/// dark mode, and doesn't claim a Tonie or DVD is a book.
enum UrgencyStyle {
    static func color(daysUntilDue days: Int) -> NSColor {
        if days < Urgency.urgentDays { return .systemRed }   // overdue days are negative
        if days <= Urgency.soonDays { return .systemOrange }
        return .systemGreen
    }

    /// "●  text" with a coloured dot and a normal-coloured label. Set as `attributedTitle`; an
    /// enabled item keeps the label colour, a disabled one is dimmed by macOS like any other.
    static func dotTitle(_ text: String, color: NSColor, indent: String = "  ") -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let result = NSMutableAttributedString(string: "\(indent)●  ", attributes: [.font: font, .foregroundColor: color])
        result.append(NSAttributedString(string: text, attributes: [.font: font]))
        return result
    }
}

extension Loan {
    var urgencyColor: NSColor { UrgencyStyle.color(daysUntilDue: daysUntilDue) }
}

extension AccountData {
    /// Colour of the most urgent loan (overdue included); green without loans.
    var urgencyColor: NSColor {
        guard let days = loans.map(\.daysUntilDue).min() else { return .systemGreen }
        return UrgencyStyle.color(daysUntilDue: days)
    }
}
