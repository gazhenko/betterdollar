import BetterDollarCore
import Foundation
import Observation

enum AppTab: String, Hashable, CaseIterable {
    case budget, transactions, insights, coach, settings
}

/// App-wide UI state that isn't stored in SwiftData.
@Observable final class AppModel {
    var month: MonthKey = .current()
    var tab: AppTab = .budget
    let bank = BankService()

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-BDTab"), index + 1 < arguments.count,
           let tab = AppTab(rawValue: arguments[index + 1]) {
            self.tab = tab
        }
    }

    var isViewingCurrentMonth: Bool { month == .current() }
}
