import Foundation
import FoundationModels
import BetterDollarCore

/// Apple Intelligence's on-device model through the Foundation Models framework.
/// It reads the budget through tools so the 4K-token context stays small.
@MainActor public final class AppleCoachEngine: CoachEngine {
    public static let engineID = "apple"
    public let id = AppleCoachEngine.engineID
    public let displayName = "Apple Intelligence"
    private var task: Task<Void, Never>?

    public init() {}

    public var availability: CoachAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(.deviceNotEligible):
            return .unavailable("This iPhone doesn't support Apple Intelligence. Download a local model instead.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("Turn on Apple Intelligence in Settings to use it here, or download a local model.")
        case .unavailable(.modelNotReady):
            return .unavailable("Apple Intelligence is still getting ready on this iPhone. Try again in a little while.")
        case .unavailable:
            return .unavailable("Apple Intelligence isn't available right now.")
        }
    }

    public func prewarm() {
        guard availability == .ready else { return }
        LanguageModelSession(instructions: CoachPrompts.appleInstructions).prewarm()
    }

    public func reply(to conversation: [CoachTurn], data: FinanceData) -> AsyncThrowingStream<String, Error> {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        guard availability == .ready else {
            if case let .unavailable(reason) = availability {
                continuation.finish(throwing: CoachError("Apple Intelligence unavailable", reason))
            } else {
                continuation.finish(throwing: CoachError("Apple Intelligence unavailable", "Apple Intelligence isn't available right now."))
            }
            return stream
        }
        let history = CoachText.trimmedHistory(conversation, maxTurns: 6, maxCharacters: 2_400)
        guard !history.isEmpty else {
            continuation.finish(throwing: CoachError.emptyQuestion)
            return stream
        }
        task?.cancel()
        let work = Task {
            // Retry with less context when the 4K window overflows.
            let attempts: [(turns: [CoachTurn], overview: Bool)] = [
                (history, true),
                (Array(history.suffix(1)), true),
                (Array(history.suffix(1)), false)
            ]
            for (index, attempt) in attempts.enumerated() {
                do {
                    let session = Self.session(data: data)
                    let prompt = CoachPrompts.applePrompt(history: attempt.turns, data: data, includeOverview: attempt.overview)
                    for try await snapshot in session.streamResponse(to: prompt, options: GenerationOptions(temperature: 0.3)) {
                        try Task.checkCancellation()
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                    return
                } catch let error as LanguageModelSession.GenerationError {
                    if case .exceededContextWindowSize = error, index < attempts.count - 1 { continue }
                    continuation.finish(throwing: Self.friendly(error))
                    return
                } catch is CancellationError {
                    continuation.finish()
                    return
                } catch {
                    continuation.finish(throwing: CoachError("The coach hit a problem", error.localizedDescription))
                    return
                }
            }
        }
        task = work
        continuation.onTermination = { _ in work.cancel() }
        return stream
    }

    static func session(data: FinanceData) -> LanguageModelSession {
        LanguageModelSession(tools: [BudgetItemTool(data: data), TransactionSearchTool(data: data), FinanceSectionTool(data: data)],
                             instructions: CoachPrompts.appleInstructions)
    }

    static func friendly(_ error: LanguageModelSession.GenerationError) -> CoachError {
        switch error {
        case .exceededContextWindowSize:
            return CoachError("Conversation too long", "This conversation is too long for Apple Intelligence. Start a new chat and ask again.")
        case .guardrailViolation, .refusal:
            return CoachError("Can't answer that", "Apple Intelligence declined that question. Try rephrasing it around your budget.")
        case .unsupportedLanguageOrLocale:
            return CoachError("Language not supported", "Apple Intelligence doesn't support this language yet. Try asking in English.")
        case .assetsUnavailable:
            return CoachError("Model not ready", "Apple Intelligence is still downloading or updating. Try again shortly.")
        case .rateLimited, .concurrentRequests:
            return CoachError("Coach is busy", "Apple Intelligence is busy. Wait a moment and try again.")
        default:
            return CoachError("The coach hit a problem", error.localizedDescription)
        }
    }
}

// MARK: - Tools

struct BudgetItemTool: Tool {
    let data: FinanceData
    let name = "getBudgetItem"
    let description = "Get planned, spent and remaining amounts plus recent transactions for one budget item, such as Groceries."

    @Generable struct Arguments {
        @Guide(description: "The budget item's name, for example Groceries or Emergency Fund")
        var name: String

        init(name: String) { self.name = name }
    }

    func call(arguments: Arguments) async throws -> String {
        data.itemDetail(named: arguments.name)
            ?? "There is no budget item called \"\(arguments.name)\". Items: \(data.items.map(\.name).joined(separator: ", "))."
    }
}

struct TransactionSearchTool: Tool {
    let data: FinanceData
    let name = "searchTransactions"
    let description = "Find this month's and last month's transactions by merchant or budget item name. An empty query lists the latest."

    @Generable struct Arguments {
        @Guide(description: "A merchant or budget item to search for, for example Starbucks or Restaurants")
        var query: String

        init(query: String) { self.query = query }
    }

    func call(arguments: Arguments) async throws -> String {
        data.searchTransactions(arguments.query, limit: 12)
    }
}

struct FinanceSectionTool: Tool {
    let data: FinanceData
    let name = "getFinanceSection"
    let description = "Get one section of the user's finances: the full budget, funds and savings goals, bank account balances, or earlier months."

    @Generable enum Section {
        case budget, funds, accounts, history
    }

    @Generable struct Arguments {
        @Guide(description: "Which section to read")
        var section: Section

        init(section: Section) { self.section = section }
    }

    func call(arguments: Arguments) async throws -> String {
        switch arguments.section {
        case .budget: data.overview()
        case .funds: data.fundsText()
        case .accounts: data.accountsText()
        case .history: data.historyText()
        }
    }
}
