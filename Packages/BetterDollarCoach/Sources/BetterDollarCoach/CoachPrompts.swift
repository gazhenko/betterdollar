import Foundation
import BetterDollarCore

/// The coach's persona and the prompts built from the user's finances.
public enum CoachPrompts {
    public static let persona = """
    You are BetterDollar's coach: a warm, practical guide for zero-based budgeting, where every dollar of income gets a job.
    Rules:
    - Use only the user's real numbers given to you. Never invent amounts, dates, merchants or accounts. If something isn't in the data, say so.
    - Only name budget items, funds, merchants and accounts that appear in the data, and only call something a fund if the data lists it as one. Never say the user mentioned something unless it is in the conversation.
    - Quote amounts exactly as they appear in the data instead of doing your own arithmetic. "Left to budget" is income that has no job yet, not money left to spend.
    - Keep answers short: a sentence or two of insight, then up to three concrete next steps in this app (adjust a planned amount, assign transactions from the tray, add to a fund). Mention at most three budget items; never list the whole budget.
    - Be encouraging and never shame spending. Celebrate progress such as a zero-based plan, a growing fund, or a paid-off debt.
    - You are not a licensed financial, tax, legal or investment advisor. For those questions give general education, say so in one short sentence, and suggest a professional.
    - Never ask for account numbers, passwords or other credentials.
    """

    /// Instructions for Apple's on-device model, which looks details up with tools.
    public static let appleInstructions = persona + """

    Look up details with your tools before answering questions about a budget item, a merchant, funds, accounts or past months. Format money like $1,234.56.
    """

    /// Totals, group lines and problems only, small enough for a 4K-token context window.
    public static func shortOverview(_ data: FinanceData) -> String {
        var lines = ["Today is \(data.today.formatted(date: .abbreviated, time: .omitted)). Budget month: \(data.month.title)."]
        guard data.hasPlan else {
            lines.append("There is no budget plan for \(data.month.title) yet.")
            return lines.joined(separator: "\n")
        }
        let t = data.totals
        lines.append("Income planned \(Money.format(t.plannedIncomeCents)), received \(Money.format(t.receivedCents)). Spending planned \(Money.format(t.plannedExpenseCents)), spent \(Money.format(t.spentCents)).")
        lines.append(BudgetFacts.cashFlow(t))
        if t.leftToBudgetCents == 0 {
            lines.append("Left to budget: $0.00. The plan is zero-based: every planned dollar of income has a job.")
        } else if t.leftToBudgetCents > 0 {
            lines.append("Left to budget: \(Money.format(t.leftToBudgetCents)).")
        } else {
            lines.append("Over-planned by \(Money.format(-t.leftToBudgetCents)).")
        }
        lines.append("Unassigned transactions: \(data.newTransactionCount).")
        let groups = data.groups.filter { !$0.isIncome }.map { "\($0.name) \(Money.format($0.activityCents, showsCents: false)) of \(Money.format($0.plannedCents, showsCents: false))" }
        if !groups.isEmpty { lines.append("Spent by group: " + groups.joined(separator: "; ") + ".") }
        let over = data.items.filter { !$0.isIncome && $0.remainingCents < 0 }
        if !over.isEmpty {
            lines.append("Overspent: " + over.map { "\($0.name) by \(Money.format(-$0.remainingCents))" }.joined(separator: ", ") + ".")
        }
        let itemNames = data.items.filter { !$0.isFund }.map(\.name)
        if !itemNames.isEmpty { lines.append("Budget items: " + itemNames.joined(separator: ", ") + ".") }
        let funds = data.funds.map { fund in
            fund.fundGoalCents > 0
                ? "\(fund.name) (balance \(Money.format(fund.remainingCents, showsCents: false)) of \(Money.format(fund.fundGoalCents, showsCents: false)) goal)"
                : "\(fund.name) (balance \(Money.format(fund.remainingCents, showsCents: false)))"
        }
        lines.append(funds.isEmpty ? "There are no funds." : "Funds, which keep their balance month to month: " + funds.joined(separator: ", ") + ".")
        return lines.joined(separator: "\n")
    }

    /// The system prompt for local MLX models, which get the data inline instead of through tools.
    public static func mlxSystemPrompt(data: FinanceData, question: String) -> String {
        var sections = [persona, "The user's finances:\n" + data.overview()]
        if !data.funds.isEmpty { sections.append(data.fundsText()) }
        if !data.accounts.isEmpty { sections.append(data.accountsText()) }
        let relevant = data.relevantContext(for: question)
        if !relevant.isEmpty { sections.append("Details related to the question:\n" + relevant) }
        sections.append("Answer in plain text with short paragraphs or a brief list. Format money like $1,234.56.")
        return sections.joined(separator: "\n\n")
    }

    /// One prompt for Apple's model: recent conversation as text plus the new question.
    public static func applePrompt(history: [CoachTurn], data: FinanceData, includeOverview: Bool = true) -> String {
        guard let question = history.last(where: { $0.role == .user })?.text else { return "" }
        var parts: [String] = []
        if includeOverview { parts.append("Current snapshot:\n" + shortOverview(data)) }
        let earlier = history.dropLast()
        if !earlier.isEmpty {
            parts.append("Conversation so far:\n" + earlier.map { "\($0.role == .user ? "User" : "Coach"): \($0.text)" }.joined(separator: "\n"))
        }
        parts.append("User: \(question)")
        return parts.joined(separator: "\n\n")
    }

    /// Questions offered on the empty chat screen.
    public static let starters = [
        "How am I doing this month?",
        "Where am I overspending?",
        "How much should I put toward my funds to hit my goals?",
        "What should I do with the money left to budget?"
    ]
}
