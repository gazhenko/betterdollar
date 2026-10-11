import BetterDollarCoach
import BetterDollarCore
import LocalAuthentication
import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appLock") private var appLockEnabled = false
    @State private var isUnlocked = false
    @State private var isAuthenticating = false

    var body: some View {
        @Bindable var app = app
        ZStack {
            TabView(selection: $app.tab) {
                Tab("Budget", systemImage: "list.bullet.rectangle.portrait", value: AppTab.budget) { BudgetScreen() }
                Tab("Transactions", systemImage: "arrow.left.arrow.right", value: AppTab.transactions) { TransactionsScreen() }
                Tab("Insights", systemImage: "chart.bar.xaxis", value: AppTab.insights) { InsightsScreen() }
                Tab("Coach", systemImage: "bubble.left.and.text.bubble.right", value: AppTab.coach) { CoachScreen() }
                Tab("Settings", systemImage: "gearshape", value: AppTab.settings) { SettingsScreen() }
            }
            if scenePhase != .active || (appLockEnabled && !isUnlocked) {
                PrivacyCover(isLocked: appLockEnabled && !isUnlocked, unlock: unlock)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: scenePhase)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                isUnlocked = false
                CoachEngineFactory.unloadAll()
            }
            if phase == .active && appLockEnabled && !isUnlocked { unlock() }
        }
        .task { if appLockEnabled { unlock() } }
    }

    private func unlock() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your budget") { success, _ in
            Task { @MainActor in
                isAuthenticating = false
                if success { isUnlocked = true }
            }
        }
    }
}

/// Covers the budget in the app switcher and while App Lock is engaged.
struct PrivacyCover: View {
    let isLocked: Bool
    let unlock: () -> Void

    var body: some View {
        ZStack {
            Ink.paper.ignoresSafeArea()
            Guilloche(completion: 1, lineWidth: 0.5, layers: 14)
                .ignoresSafeArea()
                .opacity(0.8)
            VStack(spacing: 14) {
                Text("BetterDollar").font(Typeface.title(34)).foregroundStyle(Ink.primary)
                if isLocked {
                    Button("Unlock", systemImage: "faceid", action: unlock)
                        .buttonStyle(InkButtonStyle())
                        .frame(width: 200)
                }
            }
        }
    }
}
