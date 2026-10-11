import Foundation
import BetterDollarCore

public enum CoachRole: String, Codable, Sendable {
    case user, assistant
}

public struct CoachTurn: Sendable, Equatable {
    public var role: CoachRole
    public var text: String

    public init(role: CoachRole, text: String) {
        self.role = role
        self.text = text
    }
}

public enum CoachAvailability: Equatable, Sendable {
    case ready
    case needsDownload
    case unavailable(String)
}

/// A model that answers questions about the user's budget without sending data off the device.
@MainActor public protocol CoachEngine: AnyObject {
    /// "apple", or "mlx:<catalog id>".
    var id: String { get }
    var displayName: String { get }
    var availability: CoachAvailability { get }
    /// Streams the cumulative reply text so far; each element replaces the previous one.
    func reply(to conversation: [CoachTurn], data: FinanceData) -> AsyncThrowingStream<String, Error>
    /// Starts loading model resources ahead of the first question.
    func prewarm()
}

public struct CoachError: LocalizedError, Equatable, Sendable {
    public var title: String
    public var message: String

    public init(_ title: String, _ message: String) {
        self.title = title
        self.message = message
    }

    public var errorDescription: String? { message }
    public var failureReason: String? { title }

    static let emptyQuestion = CoachError("Nothing to answer", "Type a question for your coach first.")
    static let busy = CoachError("Coach is busy", "The coach is still answering. Wait for it to finish or stop it first.")
}

/// Text helpers shared by every engine.
public enum CoachText {
    /// Removes reasoning blocks some models emit. An unfinished `<think>` hides everything after it
    /// so partial reasoning never flashes on screen while streaming.
    public static func visibleText(_ raw: String) -> String {
        var text = raw
        while let open = text.range(of: "<think>") {
            if let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                text.removeSubrange(open.lowerBound..<text.endIndex)
            }
        }
        // A stray closing tag means the template opened the block for us.
        if let close = text.range(of: "</think>") { text.removeSubrange(text.startIndex..<close.upperBound) }
        for token in ["<|im_end|>", "<end_of_turn>", "<|eot_id|>", "<turn|>", "<|endoftext|>"] {
            text = text.replacingOccurrences(of: token, with: "")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keeps the latest turns that fit the budget. The result always ends with the newest user
    /// turn and never starts with an assistant turn.
    public static func trimmedHistory(_ turns: [CoachTurn], maxTurns: Int, maxCharacters: Int) -> [CoachTurn] {
        let cleaned = turns.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let lastUser = cleaned.lastIndex(where: { $0.role == .user }) else { return [] }
        var kept: [CoachTurn] = []
        var characters = 0
        for turn in cleaned[...lastUser].reversed() {
            let isNewest = kept.isEmpty
            if !isNewest && (kept.count >= maxTurns || characters + turn.text.count > maxCharacters) { break }
            var turn = turn
            if isNewest && turn.text.count > maxCharacters { turn.text = String(turn.text.prefix(maxCharacters)) }
            kept.insert(turn, at: 0)
            characters += turn.text.count
        }
        while kept.first?.role == .assistant { kept.removeFirst() }
        return kept
    }
}
