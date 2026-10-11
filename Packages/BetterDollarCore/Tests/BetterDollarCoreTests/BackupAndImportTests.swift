import Foundation
import SwiftData
import Testing
@testable import BetterDollarCore

@MainActor struct BackupAndImportTests {
    @Test func encryptedBackupRoundTrips() throws {
        let source = try BetterDollarSchema.container(inMemory: true)
        let today = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 9))!
        DemoData.seed(into: source.mainContext, today: today)
        let archive = try BackupArchive.make(from: source.mainContext, vault: nil, includeBankConnections: false)
        let sealed = try BackupCrypto.seal(archive, passphrase: "correct horse battery", iterations: 1_000)

        // The file must not contain readable financial data.
        #expect(sealed.range(of: Data("Trader Joe".utf8)) == nil)
        #expect(throws: BackupError.wrongPassphrase) { try BackupCrypto.open(sealed, passphrase: "wrong passphrase") }
        #expect(throws: BackupError.notABackup) { try BackupCrypto.open(Data("hello".utf8), passphrase: "anything") }
        #expect(throws: BackupError.weakPassphrase) { try BackupCrypto.seal(archive, passphrase: "short") }

        let opened = try BackupCrypto.open(sealed, passphrase: "correct horse battery")
        let destination = try BetterDollarSchema.container(inMemory: true)
        Ledger.addManual(date: today, amountCents: 1, isIncome: false, merchant: "will be replaced", in: destination.mainContext)
        try opened.restore(into: destination.mainContext, vault: nil)

        let context = destination.mainContext
        let before = BudgetMath.totals(for: try #require(BudgetPlanner.month(MonthKey(year: 2026, month: 10), in: source.mainContext)))
        let after = BudgetMath.totals(for: try #require(BudgetPlanner.month(MonthKey(year: 2026, month: 10), in: context)))
        #expect(before == after)
        let transactions = try context.fetch(FetchDescriptor<LedgerTransaction>())
        #expect(transactions.count == archive.transactionCount)
        #expect(!transactions.contains { $0.merchant == "will be replaced" })
        let funds = FundLedger(months: BudgetPlanner.allMonths(in: context))
        let emergency = try #require(BudgetPlanner.month(MonthKey(year: 2026, month: 10), in: context)?.allItems.first { $0.name == "Emergency Fund" })
        #expect(funds.balance(for: emergency) == 6_200_00 + 3 * 700_00)
    }

    @Test func csvImportHandlesCommonBankFormats() throws {
        let csv = """
        Transaction Date,Post Date,Description,Category,Type,Amount,Memo
        10/09/2026,10/10/2026,"WHOLE FOODS, #10",Groceries,Sale,-84.12,
        10/09/2026,10/10/2026,"WHOLE FOODS, #10",Groceries,Sale,-84.12,
        10/01/2026,10/01/2026,ACME PAYROLL,,Payment,"2,500.00",
        not a date,,junk,,,1,
        """
        let parsed = try CSVImport(text: csv)
        #expect(parsed.rows.count == 3)
        #expect(parsed.skippedLines == 1)
        #expect(parsed.rows[0].merchant == "WHOLE FOODS, #10")
        #expect(parsed.rows[0].signedCents == -84_12)
        #expect(parsed.rows[2].signedCents == 2_500_00)

        let container = try BetterDollarSchema.container(inMemory: true)
        #expect(parsed.insert(into: container.mainContext) == 3)
        // Importing the same file again adds nothing, but the two identical purchases were both kept.
        #expect(parsed.insert(into: container.mainContext) == 0)
        let all = try container.mainContext.fetch(FetchDescriptor<LedgerTransaction>())
        #expect(all.count == 3 && all.allSatisfy { $0.status == .new })
    }

    @Test func csvWithDebitAndCreditColumns() throws {
        let csv = "Date,Payee,Debit,Credit\n2026-10-03,Shell,45.10,\n2026-10-04,Refund,,12.00\n"
        let parsed = try CSVImport(text: csv)
        #expect(parsed.rows.map(\.signedCents) == [-45_10, 12_00])
        #expect(throws: CSVImport.Problem.missingColumns) { try CSVImport(text: "Foo,Bar\n1,2\n") }
    }

    @Test func csvDebitAmountColumnsKeepTheirSigns() throws {
        let csv = "Transaction Date,Transaction Description,Debit Amount,Credit Amount,Balance\n2026-10-03,Shell,45.10,0.00,900\n2026-10-04,Refund,0.00,12.00,912\n"
        let parsed = try CSVImport(text: csv)
        #expect(parsed.rows.map(\.signedCents) == [-45_10, 12_00])
    }

    @Test func csvStrayQuoteAndSummaryBlock() throws {
        let csv = """
        Description,,Summary Amt.
        Beginning balance as of 10/01/2026,,"1,000.00"

        Date,Description,Amount,Running Bal.
        10/03/2026,TV 55" STAND,-45.10,954.90
        10/04/2026,"Coffee, beans",-12.00,942.90
        """
        let parsed = try CSVImport(text: csv)
        #expect(parsed.rows.map(\.merchant) == ["TV 55\" STAND", "Coffee, beans"])
        #expect(parsed.rows.map(\.signedCents) == [-45_10, -12_00])
    }
}
