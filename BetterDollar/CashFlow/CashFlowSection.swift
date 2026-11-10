import BetterDollarCore
import SwiftData
import SwiftUI

/// The cash flow tabs: the headline and what to do about it, then the forecast as a line or a calendar.
enum CashFlowTab: String, CaseIterable, Identifiable {
    case summary, runway, calendar

    var id: String { rawValue }
    var title: String {
        switch self {
        case .summary: "Summary"
        case .runway: "Runway"
        case .calendar: "Calendar"
        }
    }
}

/// Checking walked forward through paydays, bills and everyday spending, so a dip shows up before it happens.
struct CashFlowSection: View {
    @Environment(\.modelContext) private var context
    // Read so the forecast refreshes whenever any of them change.
    @Query private var transactions: [LedgerTransaction]
    @Query private var accounts: [BankAccount]
    @Query private var flows: [RecurringFlow]
    @Query private var months: [BudgetMonth]
    @Query private var allocations: [Allocation]
    @AppStorage("cashFlowTab") private var tab: CashFlowTab = .summary
    @AppStorage("cashFlowCushion") private var cushionCents = 0
    @AppStorage("cashFlowManualBalance") private var manualBalanceCents = 0
    @State private var reviewing: CashFlowReviewView.Focus?

    var body: some View {
        let _ = (transactions.count, accounts.count, flows.count, months.count, allocations.count)
        let snapshot = CashFlowPlanner.snapshot(in: context, cushionCents: cushionCents, manualBalanceCents: manualBalanceCents)
        VStack(alignment: .leading, spacing: 20) {
            header(snapshot)
            Picker("View", selection: $tab) {
                ForEach(CashFlowTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("cash-flow-tab")

            switch tab {
            case .summary:
                CashFlowPlate(snapshot: snapshot)
                prompts(snapshot)
                if !snapshot.forecast.suggestions.isEmpty {
                    SuggestionList(suggestions: snapshot.forecast.suggestions)
                }
                HowCashFlowWorks()
            case .runway:
                RunwayView(forecast: snapshot.forecast)
            case .calendar:
                CashFlowCalendar(forecast: snapshot.forecast)
            }
        }
        .sheet(item: $reviewing) { focus in
            CashFlowReviewView(focus: focus, patterns: snapshot.patterns, cardInfo: snapshot.cards)
        }
    }

    private func header(_ snapshot: CashFlowPlanner.Snapshot) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Cash flow")
                    .font(Typeface.title(34))
                    .foregroundStyle(Ink.text)
                Text("Next \(snapshot.forecast.days.count) days")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Ink.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer()
            Button { reviewing = .all } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 40, height: 40)
            }
            .font(.title3.weight(.semibold))
            .accessibilityLabel("Paychecks and bills")
            .accessibilityIdentifier("cash-flow-review")
        }
    }

    @ViewBuilder private func prompts(_ snapshot: CashFlowPlanner.Snapshot) -> some View {
        if snapshot.usesManualBalance {
            PromptCard(systemImage: "building.columns", text: "No checking account is connected. Enter today's checking balance to start from.") {
                MoneyField(title: "Checking today", cents: $manualBalanceCents)
            }
        }
        ForEach(snapshot.cardsWithoutDueDay) { card in
            PromptCard(systemImage: "creditcard",
                       text: "\(card.name) has a \(Money.format(card.balanceCents)) balance that isn't in this forecast yet.") {
                Button("Set its payment date") { reviewing = .cards }
                    .font(.subheadline.weight(.semibold))
            }
        }
        ForEach(snapshot.cardsOnUsualDay) { card in
            PromptCard(systemImage: "creditcard", text: usualDayText(card)) {
                HStack(spacing: 20) {
                    Button("Looks right") { confirmUsualDay(card) }
                        .accessibilityIdentifier("card-looks-right")
                    Button("Change it") { reviewing = .cards }
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        if !snapshot.missingIncome.isEmpty {
            PromptCard(systemImage: "banknote", text: missingIncomeText(snapshot.missingIncome)) {
                Button("Add a paycheck") { reviewing = .addPaycheck }
                    .font(.subheadline.weight(.semibold))
            }
        }
        if snapshot.unreviewedCount > 0 {
            PromptCard(systemImage: "sparkle.magnifyingglass", text: foundText(snapshot)) {
                Button("Review them") { reviewing = .all }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("review-found")
            }
        } else if !snapshot.hasPaydays {
            PromptCard(systemImage: "banknote", text: "No regular paycheck found in checking, so this forecast has no money coming in.") {
                Button("Add a paycheck") { reviewing = .addPaycheck }
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    private func missingIncomeText(_ income: [CashFlowPlanner.MissingIncome]) -> String {
        let total = Money.format(income.reduce(0) { $0 + $1.cents })
        let names = income.map(\.name).formatted(.list(type: .and))
        return "Your budget plans \(total) of income this forecast doesn't count: \(names). Add \(income.count == 1 ? "it" : "them") with the day \(income.count == 1 ? "it arrives" : "they arrive") so the forecast includes \(income.count == 1 ? "it" : "them")."
    }

    private func usualDayText(_ card: CashFlowPlanner.Card) -> String {
        guard let next = card.payments.first else {
            return "\(card.name) is paid around the \(ordinal(card.habit?.day ?? 1)) in this forecast, when checking usually pays it."
        }
        return "\(card.name) is paid \(Money.format(-next.amountCents)) on \(CashFlowFormat.short(next.date)) in this forecast, around when checking usually pays it."
    }

    /// Keeps the usual day as the card's due day.
    private func confirmUsualDay(_ card: CashFlowPlanner.Card) {
        guard let day = card.habit?.day, let account = accounts.first(where: { $0.uuid == card.id }) else { return }
        withAnimation(.snappy) { account.paymentDueDay = day }
    }

    private func foundText(_ snapshot: CashFlowPlanner.Snapshot) -> String {
        let pay = snapshot.patterns.filter(\.isIncome).count
        let bills = snapshot.patterns.count - pay
        let parts = [pay > 0 ? (pay == 1 ? "1 paycheck" : "\(pay) paychecks") : nil,
                     bills > 0 ? (bills == 1 ? "1 bill" : "\(bills) bills") : nil].compactMap { $0 }
        return "Found \(parts.formatted(.list(type: .and))) that repeat in your checking history. They're in the forecast; check they look right."
    }
}

/// The headline: the lowest checking balance ahead, and whether it crosses the line.
struct CashFlowPlate: View {
    let snapshot: CashFlowPlanner.Snapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let forecast = snapshot.forecast
        let isShort = forecast.dip != nil
        let lowest = forecast.lowest
        VStack(alignment: .leading, spacing: 6) {
            AmountText(cents: lowest?.endCents ?? forecast.startingCents, font: Typeface.figure(40), color: isShort ? Ink.seal : Ink.primary)
            Text(lowest.map { "lowest balance, \(CashFlowFormat.weekday($0.date))" } ?? "checking today")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Ink.secondary)
            Text(statusLine(forecast))
                .font(.callout)
                .foregroundStyle(isShort ? Ink.seal : Ink.text)
                .padding(.top, 6)
                .fixedSize(horizontal: false, vertical: true)
            Text(sourceLine)
                .font(.caption)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .engravedPlate(completion: clearShare(forecast), color: isShort ? Ink.seal : Ink.primary,
                       borderOpacity: 0.35, animates: !reduceMotion)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("cash-flow-plate")
    }

    /// How much of the forecast is clear before the first dip; the engraving fills that far.
    private func clearShare(_ forecast: CashFlowForecast) -> Double {
        guard let dip = forecast.dip, let index = forecast.days.firstIndex(where: { $0.date == dip.start }) else { return 1 }
        return max(0.04, Double(index) / Double(max(1, forecast.days.count)))
    }

    private func statusLine(_ forecast: CashFlowForecast) -> String {
        let line = forecast.cushionCents > 0 ? Money.format(forecast.cushionCents, showsCents: false) : "$0"
        let dips = forecast.dips
        guard let first = dips.first else {
            return "Checking stays above \(line) through \(CashFlowFormat.short(forecast.end))."
        }
        var text = "Checking drops below \(line) on \(CashFlowFormat.short(first.start))"
        text += first.recovery.map { " and is back up on \(CashFlowFormat.short($0))." } ?? " and stays there through \(CashFlowFormat.short(forecast.end))."
        if let deepest = forecast.deepestDip, deepest.start != first.start {
            text += " It drops again on \(CashFlowFormat.short(deepest.start)), down to \(Money.format(deepest.lowest.endCents)) on \(CashFlowFormat.short(deepest.lowest.date))."
        } else if dips.count > 1 {
            text += dips.count == 2 ? " It happens once more after that." : " It happens \(dips.count - 1) more times after that."
        }
        return text
    }

    private var sourceLine: String {
        let start = Money.format(snapshot.forecast.startingCents)
        if snapshot.usesManualBalance { return "Starts from the \(start) you entered." }
        var text = "Starts from \(start) in \(snapshot.checkingNames.formatted(.list(type: .and)))"
        if let asOf = snapshot.balanceAsOf {
            text += Calendar.current.isDateInToday(asOf)
                ? ", updated at \(asOf.formatted(date: .omitted, time: .shortened))"
                : ", updated \(CashFlowFormat.short(asOf))"
        }
        return text + "."
    }
}

/// A setup nudge with one action.
struct PromptCard<Action: View>: View {
    let systemImage: String
    let text: String
    @ViewBuilder let action: Action

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(Ink.primary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Ink.text)
                    .fixedSize(horizontal: false, vertical: true)
                action
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.sheet, in: .rect(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(Ink.rule, lineWidth: 1) }
    }
}

/// Concrete ways to avoid the dip, each tested against the forecast.
struct SuggestionList: View {
    let suggestions: [CashFlowSuggestion]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Get ahead of it")
                .font(Typeface.groupTitle)
                .foregroundStyle(Ink.text)
                .accessibilityAddTraits(.isHeader)
            ForEach(suggestions) { suggestion in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon(suggestion.kind))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Ink.primary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(suggestion.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Ink.text)
                        Text(suggestion.detail)
                            .font(.subheadline)
                            .foregroundStyle(Ink.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.sheet, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cash-flow-suggestions")
    }

    private func icon(_ kind: CashFlowSuggestion.Kind) -> String {
        switch kind {
        case .moveSavings: "arrow.left.arrow.right"
        case .moveBill: "calendar.badge.clock"
        case .splitPayment: "square.split.2x1"
        case .spendLess: "cart"
        case .needMore: "exclamationmark.triangle"
        }
    }
}

struct HowCashFlowWorks: View {
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text("It starts from your checking balance and walks forward one day at a time.")
                Text("Paychecks and bills come from your checking history: anything that repeats every week, every two weeks, twice a month or monthly. Turn any of them off, change an amount, or add your own under Paychecks and bills.")
                Text("Budget items with a due day are paid on that day. The rest of each budget item is spread evenly over the month as everyday spending. Funds stay in checking until you spend them, so they aren't subtracted.")
                Text("A credit card is paid on the due day you set, or the day checking usually pays it. It pays what you owe as the statement balance, the full balance, the minimum, a set amount or what you usually pay. Spending in the budget groups you pay with a card builds up on the card and leaves checking with its payment; other card spending counts as everyday spending.")
                Text("Payments a few days late still count, on today.")
            }
            .font(.subheadline)
            .foregroundStyle(Ink.secondary)
            .padding(.top, 8)
        } label: {
            Text("How this forecast works")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Ink.text)
        }
        .tint(Ink.primary)
    }
}

enum CashFlowFormat {
    /// "Nov 8"
    static func short(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated).day()) }
    /// "Sun, Nov 8"
    static func weekday(_ date: Date) -> String { date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
    /// "+$2,000.00" or "-$85.00"
    static func signed(_ cents: Int) -> String { cents > 0 ? "+" + Money.format(cents) : Money.format(cents) }
}

/// One line of a little statement: a label, an optional note, and an amount.
struct LedgerLine: View {
    let label: String
    var note: String?
    let cents: Int
    var signed = true
    var emphasized = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(emphasized ? .subheadline.weight(.semibold) : .subheadline)
                .foregroundStyle(Ink.text)
                .lineLimit(1)
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(signed ? CashFlowFormat.signed(cents) : Money.format(cents))
                .font(emphasized ? Typeface.amount.weight(.semibold) : Typeface.amountSmall)
                .foregroundStyle(cents < 0 && !signed ? Ink.seal : (cents > 0 && signed ? Ink.income : Ink.text))
        }
        .accessibilityElement(children: .combine)
    }
}
