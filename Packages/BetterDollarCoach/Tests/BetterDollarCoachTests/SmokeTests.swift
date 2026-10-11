import Foundation
import Testing
@testable import BetterDollarCoach

/// Downloads a real model and answers one question. Off by default; run with
/// TEST_RUNNER_BD_MLX_SMOKE=1 (optionally TEST_RUNNER_BD_MLX_SMOKE_DIR / TEST_RUNNER_BD_MLX_SMOKE_MODEL).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BD_MLX_SMOKE"] == "1"))
@MainActor struct SmokeTests {
    @Test(.timeLimit(.minutes(60))) func downloadAndAnswer() async throws {
        let environment = ProcessInfo.processInfo.environment
        let root = environment["BD_MLX_SMOKE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("bd-smoke-models")
        for id in (environment["BD_MLX_SMOKE_MODEL"] ?? "lfm2.5-1.2b").split(separator: ",").map(String.init) {
            let spec = try #require(MLXModelCatalog.spec(id: id))
            try await run(spec, root: root, cleanUp: environment["BD_MLX_SMOKE_CLEANUP"] == "1")
        }
    }

    private func run(_ spec: MLXModelSpec, root: URL, cleanUp: Bool) async throws {
        let store = MLXModelStore(rootDirectory: root)
        let downloadStart = Date()
        store.download(spec)
        while case .downloading = store.state(for: spec) { try await Task.sleep(for: .milliseconds(500)) }
        #expect(store.state(for: spec) == .ready, "state: \(store.state(for: spec))")
        let downloadSeconds = Date().timeIntervalSince(downloadStart)

        let engine = MLXCoachEngine(spec: spec, store: store)
        var reply = ""
        let question = "How am I doing this month, and what should I fix first?"
        for try await text in engine.reply(to: [CoachTurn(role: .user, text: question)], data: Sample.data) { reply = text }
        let stats = try #require(engine.lastStats)
        let report = """
        model: \(spec.repo)@\(spec.revision)
        download: \(Int(downloadSeconds)) s, on disk \(store.diskUsageBytes(for: spec)) bytes
        load: \(stats.loadSeconds.map { String(format: "%.1f s", $0) } ?? "cached")
        prompt tokens: \(stats.promptTokens), generated: \(stats.generatedTokens), \(String(format: "%.1f", stats.tokensPerSecond)) tok/s
        question: \(question)
        reply:
        \(reply)
        """
        print(report)
        try report.write(to: root.appendingPathComponent("smoke-\(spec.id).txt"), atomically: true, encoding: .utf8)
        #expect(!reply.isEmpty)
        #expect(!reply.contains("<think>"))
        engine.unload()
        if cleanUp { store.delete(spec) }
    }
}
