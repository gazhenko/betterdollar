import Foundation
import Testing
import BetterDollarCore
@testable import BetterDollarCoach

enum Sample {
    static let today = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 12))!

    static let june2027 = Calendar.current.date(from: DateComponents(year: 2027, month: 6, day: 1))!

    /// FinanceData's nested types have internal memberwise inits, so the sample is decoded from JSON.
    static var data: FinanceData {
        func item(_ name: String, _ group: String, income: Bool = false, fund: Bool = false, planned: Int, activity: Int,
                  remaining: Int, goal: Int = 0, target: Date? = nil, monthly: Int? = nil) -> [String: Any] {
            var value: [String: Any] = ["name": name, "group": group, "isIncome": income, "isFund": fund, "plannedCents": planned,
                                        "activityCents": activity, "remainingCents": remaining, "fundGoalCents": goal, "dueDay": 0]
            if let target { value["fundTargetDate"] = target.timeIntervalSinceReferenceDate }
            if let monthly { value["monthlyToGoalCents"] = monthly }
            return value
        }
        func transaction(_ merchant: String, _ cents: Int, status: String, items: [String], account: String, pending: Bool) -> [String: Any] {
            ["date": today.timeIntervalSinceReferenceDate, "merchant": merchant, "amountCents": cents, "isIncome": false,
             "status": status, "items": items, "account": account, "isPending": pending]
        }
        let groceries = item("Groceries", "Food", planned: 60_000, activity: 64_210, remaining: -4_210)
        let restaurants = item("Restaurants", "Food", planned: 15_000, activity: 9_640, remaining: 5_360)
        let emergency = item("Emergency Fund", "Savings", fund: true, planned: 30_000, activity: 0, remaining: 215_000,
                             goal: 1_000_000, target: june2027, monthly: 87_500)
        let paycheck = item("Paycheck 1", "Income", income: true, planned: 260_000, activity: 260_000, remaining: 0)
        let json: [String: Any] = [
            "month": ["year": 2026, "month": 10],
            "today": today.timeIntervalSinceReferenceDate,
            "hasPlan": true,
            "totals": ["plannedIncomeCents": 520_000, "plannedExpenseCents": 500_000, "receivedCents": 260_000, "spentCents": 183_450],
            "groups": [
                ["name": "Income", "isIncome": true, "plannedCents": 260_000, "activityCents": 260_000, "items": [paycheck]],
                ["name": "Savings", "isIncome": false, "plannedCents": 30_000, "activityCents": 0, "items": [emergency]],
                ["name": "Food", "isIncome": false, "plannedCents": 75_000, "activityCents": 73_850, "items": [groceries, restaurants]]
            ],
            "newTransactionCount": 3,
            "transactions": [
                transaction("Whole Foods", 8_412, status: "tracked", items: ["Groceries"], account: "Checking ••1234", pending: false),
                transaction("Blue Bottle Coffee", 650, status: "new", items: [], account: "Visa ••9876", pending: true)
            ],
            "accounts": [["name": "Checking ••1234", "institution": "Chase", "type": "checking",
                          "currentBalanceCents": 412_377, "availableBalanceCents": 400_000]],
            "history": []
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(FinanceData.self, from: data)
    }
}

@Suite struct CatalogTests {
    @Test func catalogIsWellFormed() {
        let all = MLXModelCatalog.all
        #expect(!all.isEmpty)
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(all.filter(\.isRecommended).count == 1)
        for spec in all {
            #expect(spec.repo.hasPrefix("mlx-community/"), "\(spec.id) should come from mlx-community")
            #expect(spec.revision.count == 40 && spec.revision.allSatisfy(\.isHexDigit), "\(spec.id) must pin a commit")
            #expect(spec.approxBytes > 100_000_000 && spec.approxBytes < 4_000_000_000, "\(spec.id) should fit on a phone")
            #expect(!spec.license.isEmpty && !spec.summary.isEmpty)
            #expect(MLXModelCatalog.spec(id: spec.id) == spec)
        }
        #expect(MLXModelCatalog.recommended.id == "qwen3.5-4b")
    }

    @Test func engineIDsRoundTrip() throws {
        let spec = try #require(MLXModelCatalog.spec(id: "qwen3.5-2b"))
        #expect(MLXCoachEngine.engineID(for: spec) == "mlx:qwen3.5-2b")
    }
}

@Suite struct PromptTests {
    @Test func mlxPromptCarriesRealNumbers() {
        let prompt = CoachPrompts.mlxSystemPrompt(data: Sample.data, question: "Why are my groceries over budget?")
        #expect(prompt.contains("BetterDollar's coach"))
        #expect(prompt.contains("Never invent amounts"))
        #expect(prompt.contains("$5,200.00"), "planned income")
        #expect(prompt.contains("Left to budget: $200.00"))
        #expect(prompt.contains("Groceries"))
        #expect(prompt.contains("OVERSPENT"))
        #expect(prompt.contains("Details related to the question"))
        #expect(prompt.contains("Whole Foods"), "item detail lists assigned transactions")
        #expect(prompt.contains("Funds and goals"))
        #expect(prompt.contains("Chase"))
    }

    @Test func shortOverviewStaysSmall() {
        let overview = CoachPrompts.shortOverview(Sample.data)
        #expect(overview.contains("Left to budget: $200.00"))
        #expect(overview.contains("Overspent: Groceries by $42.10"))
        #expect(overview.contains("Unassigned transactions: 3"))
        #expect(overview.count < 1_200)
    }

    @Test func applePromptIncludesConversation() {
        let turns = [CoachTurn(role: .user, text: "How am I doing?"),
                     CoachTurn(role: .assistant, text: "Pretty well."),
                     CoachTurn(role: .user, text: "And groceries?")]
        let prompt = CoachPrompts.applePrompt(history: turns, data: Sample.data)
        #expect(prompt.hasPrefix("Current snapshot:"))
        #expect(prompt.contains("User: How am I doing?\nCoach: Pretty well."))
        #expect(prompt.hasSuffix("User: And groceries?"))
        let bare = CoachPrompts.applePrompt(history: Array(turns.suffix(1)), data: Sample.data, includeOverview: false)
        #expect(bare == "User: And groceries?")
    }

    @Test func noPlanIsStatedPlainly() {
        let data = FinanceData(month: MonthKey(year: 2026, month: 11), today: Sample.today)
        #expect(CoachPrompts.shortOverview(data).contains("no budget plan for November 2026"))
    }

    @Test func toolsAnswerFromData() async throws {
        let item = try await BudgetItemTool(data: Sample.data).call(arguments: .init(name: "groceries"))
        #expect(item.contains("planned $600.00"))
        let missing = try await BudgetItemTool(data: Sample.data).call(arguments: .init(name: "Yachts"))
        #expect(missing.contains("no budget item called"))
        let search = try await TransactionSearchTool(data: Sample.data).call(arguments: .init(query: "coffee"))
        #expect(search.contains("Blue Bottle"))
        let funds = try await FinanceSectionTool(data: Sample.data).call(arguments: .init(section: .funds))
        #expect(funds.contains("Emergency Fund"))
    }
}

@Suite struct TextTests {
    @Test func stripsThinkingBlocks() {
        #expect(CoachText.visibleText("<think>add it up</think>\n\nYou have $200 left.") == "You have $200 left.")
        #expect(CoachText.visibleText("Answer <think>still going") == "Answer")
        #expect(CoachText.visibleText("<think>only reasoning so far") == "")
        #expect(CoachText.visibleText("reasoning</think>Final answer") == "Final answer")
        #expect(CoachText.visibleText("Done.<|im_end|>") == "Done.")
        #expect(CoachText.visibleText("  plain  ") == "plain")
    }

    @Test func trimsHistoryToBudget() {
        var turns: [CoachTurn] = []
        for i in 0..<10 {
            turns.append(CoachTurn(role: .user, text: "question \(i)"))
            turns.append(CoachTurn(role: .assistant, text: "answer \(i)"))
        }
        turns.append(CoachTurn(role: .user, text: "latest"))
        let trimmed = CoachText.trimmedHistory(turns, maxTurns: 4, maxCharacters: 10_000)
        #expect(trimmed.count == 3)
        #expect(trimmed.first?.role == .user)
        #expect(trimmed.last == CoachTurn(role: .user, text: "latest"))

        let tight = CoachText.trimmedHistory(turns, maxTurns: 20, maxCharacters: 25)
        #expect(tight.last?.text == "latest")
        #expect(tight.reduce(0) { $0 + $1.text.count } <= 25)
        #expect(tight.first?.role == .user)
    }

    @Test func dropsTrailingAssistantAndBlankTurns() {
        let turns = [CoachTurn(role: .user, text: "hi"), CoachTurn(role: .assistant, text: "hello"),
                     CoachTurn(role: .user, text: "   "), CoachTurn(role: .assistant, text: "partial")]
        let trimmed = CoachText.trimmedHistory(turns, maxTurns: 10, maxCharacters: 1_000)
        #expect(trimmed == [CoachTurn(role: .user, text: "hi")])
        #expect(CoachText.trimmedHistory([CoachTurn(role: .assistant, text: "x")], maxTurns: 5, maxCharacters: 100).isEmpty)
    }

    @Test func truncatesAnOversizedQuestion() {
        let long = String(repeating: "a", count: 500)
        let trimmed = CoachText.trimmedHistory([CoachTurn(role: .user, text: long)], maxTurns: 4, maxCharacters: 100)
        #expect(trimmed.count == 1 && trimmed[0].text.count == 100)
    }
}

@Suite @MainActor struct StoreTests {
    @Test func statesFollowTheMarkerFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bd-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MLXModelStore(rootDirectory: root)
        let spec = try #require(MLXModelCatalog.spec(id: "qwen3.5-2b"))
        #expect(store.state(for: spec) == .notDownloaded)
        #expect(store.directory(for: spec).lastPathComponent == "qwen3.5-2b-674aaa7240b9")
        try FileManager.default.createDirectory(at: store.directory(for: spec), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: store.directory(for: spec).appendingPathComponent(".betterdollar-complete"))
        #expect(store.state(for: spec) == .ready)
        #expect(store.downloadedModels == [spec])
        #expect(CoachEngineFactory.availableEngineIDs(store: store) == ["apple", "mlx:qwen3.5-2b"])
        store.delete(spec)
        #expect(store.state(for: spec) == .notDownloaded)
        #expect(!FileManager.default.fileExists(atPath: store.directory(for: spec).path))
    }

    @Test func remoteFileFilterKeepsOnlyModelFiles() throws {
        let json = """
        [{"type":"file","path":"model.safetensors","size":135,"lfs":{"oid":"\(String(repeating: "a", count: 64))","size":662000000}},
         {"type":"file","path":"config.json","size":1200},
         {"type":"file","path":"chat_template.jinja","size":900},
         {"type":"file","path":"README.md","size":4000},
         {"type":"file","path":".gitattributes","size":1500},
         {"type":"directory","path":"images","size":0}]
        """
        let files = try JSONDecoder().decode([RemoteModelFile].self, from: Data(json.utf8)).filter(\.isNeeded)
        #expect(files.map(\.path) == ["model.safetensors", "config.json", "chat_template.jinja"])
        #expect(files[0].byteCount == 662_000_000)
    }

    @Test func engineReportsMissingDownload() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bd-store-\(UUID().uuidString)")
        let engine = MLXCoachEngine(spec: MLXModelCatalog.recommended, store: MLXModelStore(rootDirectory: root))
        #expect(engine.availability == .needsDownload)
    }
}
