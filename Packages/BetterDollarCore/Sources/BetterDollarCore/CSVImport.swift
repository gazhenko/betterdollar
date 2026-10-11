import Foundation
import SwiftData

/// Imports a bank's CSV export for people who don't use Plaid. Rows land in the tray, unassigned.
public struct CSVImport: Sendable {
    public struct Row: Equatable, Sendable {
        public var date: Date
        public var merchant: String
        /// Positive for money in, negative for money out.
        public var signedCents: Int
        public var fingerprint: String
    }

    public enum Problem: LocalizedError, Equatable {
        case empty
        case missingColumns
        case noRows

        public var errorDescription: String? {
            switch self {
            case .empty: "The file is empty."
            case .missingColumns: "Couldn't find date, description and amount columns. Export a CSV with a header row."
            case .noRows: "No transactions could be read from this file."
            }
        }
    }

    public var rows: [Row]
    public var skippedLines: Int

    /// - Parameter expensesArePositive: some card exports list purchases as positive numbers.
    public init(text: String, expensesArePositive: Bool = false, calendar: Calendar = .current) throws {
        let records = CSVImport.parseRecords(text).filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
        guard !records.isEmpty else { throw Problem.empty }
        // Some banks put a summary block above the real header, so look for it in the first rows.
        guard let (headerIndex, layout) = records.prefix(20).enumerated().lazy
                .compactMap({ index, record in Layout(header: record).map { (index, $0) } }).first else {
            throw Problem.missingColumns
        }
        let dateColumn = layout.date, nameColumn = layout.name
        let amountColumn = layout.amount, debitColumn = layout.debit, creditColumn = layout.credit

        var rows: [Row] = []
        var skipped = 0
        for record in records.dropFirst(headerIndex + 1) {
            func field(_ index: Int?) -> String {
                guard let index, index < record.count else { return "" }
                return record[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let date = CSVImport.parseDate(field(dateColumn), calendar: calendar) else { skipped += 1; continue }
            var cents: Int?
            if let amountColumn, let value = Money.parse(field(amountColumn)) {
                cents = expensesArePositive ? -value : value
            } else {
                // A zero in one column means the amount is in the other.
                let debit = Money.parse(field(debitColumn)).flatMap { $0 == 0 ? nil : -abs($0) }
                let credit = Money.parse(field(creditColumn)).flatMap { $0 == 0 ? nil : abs($0) }
                cents = debit ?? credit
            }
            guard let cents, cents != 0 else { skipped += 1; continue }
            let merchant = field(nameColumn).isEmpty ? "Imported transaction" : field(nameColumn)
            let day = MonthKey(date: date, calendar: calendar).id + "-" + String(calendar.component(.day, from: date))
            rows.append(Row(date: date, merchant: merchant, signedCents: cents, fingerprint: "\(day)|\(cents)|\(merchant.lowercased())"))
        }
        guard !rows.isEmpty else { throw Problem.noRows }
        self.rows = rows
        self.skippedLines = skipped
    }

    /// Inserts rows that aren't already in the ledger. Returns how many were added.
    @MainActor @discardableResult
    public func insert(into context: ModelContext, account: BankAccount? = nil) -> Int {
        let csv = TransactionSource.csv.rawValue
        let existing = Set(((try? context.fetch(FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.sourceRaw == csv }))) ?? [])
            .compactMap(\.externalID))
        var occurrences: [String: Int] = [:]
        var added = 0
        for row in rows {
            // Two identical purchases on the same day are both kept, and re-importing the same file adds nothing.
            occurrences[row.fingerprint, default: 0] += 1
            let count = occurrences[row.fingerprint] ?? 1
            let fingerprint = count == 1 ? row.fingerprint : "\(row.fingerprint)#\(count)"
            if existing.contains(fingerprint) { continue }
            let transaction = LedgerTransaction(date: row.date, amountCents: abs(row.signedCents), isIncome: row.signedCents > 0,
                                                merchant: row.merchant, source: .csv, externalID: fingerprint)
            transaction.account = account
            context.insert(transaction)
            added += 1
        }
        return added
    }

    /// Which columns hold what, found from a header row.
    struct Layout {
        var date: Int
        var name: Int
        var amount: Int?
        var debit: Int?
        var credit: Int?

        init?(header: [String]) {
            let names = header.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            var used = Set<Int>()
            func column(_ candidates: [String]) -> Int? {
                for candidate in candidates {
                    if let index = names.indices.first(where: { !used.contains($0) && names[$0] == candidate }) { used.insert(index); return index }
                }
                for candidate in candidates {
                    if let index = names.indices.first(where: { !used.contains($0) && names[$0].contains(candidate) }) { used.insert(index); return index }
                }
                return nil
            }
            // Debit and credit first, so "Debit Amount" is never mistaken for a signed amount column.
            debit = column(["debit", "debit amount", "withdrawal", "withdrawals", "money out"])
            credit = column(["credit", "credit amount", "deposit", "deposits", "money in"])
            amount = column(["amount", "amount (usd)", "transaction amount"])
            guard let date = column(["date", "posted date", "posting date", "transaction date", "trans. date"]),
                  let name = column(["description", "payee", "merchant", "name", "memo", "details"]),
                  amount != nil || debit != nil || credit != nil else { return nil }
            self.date = date
            self.name = name
        }
    }

    static func parseDate(_ text: String, calendar: Calendar) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let formats = ["yyyy-MM-dd", "MM/dd/yyyy", "M/d/yyyy", "MM/dd/yy", "M/d/yy", "yyyy/MM/dd", "dd MMM yyyy", "MMM d, yyyy"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                let parts = calendar.dateComponents([.year, .month, .day], from: date)
                guard let year = parts.year, year > 1970 else { continue }
                return calendar.date(from: DateComponents(year: year, month: parts.month, day: parts.day, hour: 12))
            }
        }
        return nil
    }

    /// RFC 4180-style parsing: quoted fields, escaped quotes, commas and newlines inside quotes.
    static func parseRecords(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.replacingOccurrences(of: "\r\n", with: "\n").makeIterator()
        var pending: Character?
        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else { inQuotes = false }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                // A quote only opens a quoted field at its start; elsewhere it's a literal (55" TV).
                case "\"" where field.isEmpty: inQuotes = true
                case ",": record.append(field); field = ""
                case "\n", "\r": record.append(field); records.append(record); record = []; field = ""
                default: field.append(character)
                }
            }
        }
        if !field.isEmpty || !record.isEmpty { record.append(field); records.append(record) }
        return records
    }
}
