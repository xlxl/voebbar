import Foundation

/// Confirms a renewal per item from the loans list aDIS returns after the submit: only a due date
/// that moved later counts as success — the result page has no success markers to rely on.
/// (Ported from upstream noestreich/voebbar; the grouping additionally uses our barcode.)
enum RenewalVerifier {
    struct Result {
        var confirmed: [RenewabilityRow] = []
        var unconfirmed: [RenewabilityRow] = []
        /// true when the result page could not be read as a loans list at all.
        var unverifiable = false
    }

    /// Groups copies that can't be told apart after the submit. With a barcode that is exactly one
    /// copy; without one, all copies of the same title from the same library (order may change).
    private struct Key: Hashable {
        let id: String
        init(_ loan: Loan) { id = loan.mediaNumber.isEmpty ? "\(loan.title)|\(loan.library)" : loan.mediaNumber }
    }

    /// - submitted: the rows actually submitted for renewal
    /// - before: ALL loans of the same session before the submit (checkbox values match `submitted`)
    /// - after: the loans parsed from the result page
    ///
    /// Per group the multiset of due dates is diffed: a submitted copy counts as renewed only if
    /// its before-date vanished from the group AND a later date appeared. A later date another
    /// copy already had before doesn't confirm an unchanged one.
    static func verify(submitted: [RenewabilityRow], before: [Loan], after: [Loan]) -> Result {
        var result = Result()
        guard !submitted.isEmpty else { return result }
        guard !after.isEmpty else {
            result.unconfirmed = submitted
            result.unverifiable = true
            return result
        }

        let beforeByCheckbox = Dictionary(before.map { ($0.checkboxValue, $0) }, uniquingKeysWith: { a, _ in a })

        // Multiset difference per group: removed = before − after, added = after − before
        var afterDates: [Key: [Date]] = [:]
        for loan in after { afterDates[Key(loan), default: []].append(loan.dueDate) }
        var removed: [Key: [Date]] = [:]
        var added: [Key: [Date]] = [:]
        var beforeKeys = Set<Key>()
        for loan in before {
            let key = Key(loan)
            beforeKeys.insert(key)
            if let idx = afterDates[key]?.firstIndex(of: loan.dueDate) {
                afterDates[key]!.remove(at: idx)
            } else {
                removed[key, default: []].append(loan.dueDate)
            }
        }
        for key in beforeKeys { added[key] = afterDates[key] ?? [] }

        // Assign submitted copies earliest before-date first (stable)
        let matched = submitted.enumerated().compactMap { index, row -> (index: Int, row: RenewabilityRow, loan: Loan)? in
            beforeByCheckbox[row.checkboxValue].map { (index, row, $0) }
        }
        var confirmedIndices = Set<Int>()
        for entry in matched.sorted(by: { ($0.loan.dueDate, $0.index) < ($1.loan.dueDate, $1.index) }) {
            let key = Key(entry.loan)
            guard let removedIdx = removed[key]?.firstIndex(of: entry.loan.dueDate),
                  let addedIdx = added[key]?.indices
                    .filter({ added[key]![$0] > entry.loan.dueDate })
                    .min(by: { added[key]![$0] < added[key]![$1] })
            else { continue }
            removed[key]!.remove(at: removedIdx)
            added[key]!.remove(at: addedIdx)
            confirmedIndices.insert(entry.index)
        }

        for (index, row) in submitted.enumerated() {
            if confirmedIndices.contains(index) {
                result.confirmed.append(row)
            } else {
                result.unconfirmed.append(row)
            }
        }
        return result
    }
}
