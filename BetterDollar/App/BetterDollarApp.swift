import BetterDollarCore
import SwiftData
import SwiftUI

@main
struct BetterDollarApp: App {
    @State private var app = AppModel()
    private let container: ModelContainer

    init() {
        container = Self.makeContainer()
        Typeface.styleSystemControls()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .tint(Ink.primary)
        }
        .modelContainer(container)
    }

    /// The store lives in Application Support on this iPhone only (no CloudKit), protected while the device is locked.
    private static func makeContainer() -> ModelContainer {
        let arguments = ProcessInfo.processInfo.arguments
        do {
            if arguments.contains("-BDDemo") || arguments.contains("-BDEmpty") || arguments.contains("-BDFirstMonth") {
                let container = try BetterDollarSchema.container(inMemory: true)
                if arguments.contains("-BDDemo") { DemoData.seed(into: container.mainContext) }
                // The sample household with only this month behind it.
                if arguments.contains("-BDFirstMonth") { DemoData.seed(into: container.mainContext, historyMonths: 1) }
                return container
            }
            let directory = URL.applicationSupportDirectory.appending(path: "BetterDollar", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: directory.path)
            let container = try BetterDollarSchema.container(url: directory.appending(path: "BetterDollar.store"))
            if arguments.contains("-BDRemoveSampleData") { DemoData.remove(from: container.mainContext) }
            return container
        } catch {
            fatalError("BetterDollar couldn't open its data store: \(error)")
        }
    }
}
