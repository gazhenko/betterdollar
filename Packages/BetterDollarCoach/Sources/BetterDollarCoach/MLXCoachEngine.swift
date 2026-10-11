import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import BetterDollarCore
#if canImport(UIKit)
import UIKit
#endif

/// A downloaded open-weight model running on the device with MLX.
/// The budget is included in the system prompt, since small models call tools unreliably.
@MainActor public final class MLXCoachEngine: CoachEngine {
    public let spec: MLXModelSpec
    public var maxTokens = 700
    public var temperature: Float = 0.3
    public private(set) var lastStats: MLXGenerationStats?

    private let store: MLXModelStore
    private var container: ModelContainer?
    private var loadTask: Task<ModelContainer, Error>?
    private var replyTask: Task<Void, Never>?
    private var isGenerating = false
    private var memoryObserver: NSObjectProtocol?

    public init(spec: MLXModelSpec, store: MLXModelStore = .shared) {
        self.spec = spec
        self.store = store
        #if canImport(UIKit)
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isGenerating else { return }
                self.unload()
            }
        }
        #endif
    }

    isolated deinit {
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
    }

    nonisolated public static func engineID(for spec: MLXModelSpec) -> String { "mlx:\(spec.id)" }
    public var id: String { Self.engineID(for: spec) }
    public var displayName: String { spec.displayName }
    public var isLoaded: Bool { container != nil }

    public var availability: CoachAvailability {
        guard store.state(for: spec) == .ready else { return .needsDownload }
        let ram = CoachMemory.deviceRAMGB
        if ram + 1 < spec.minimumRAMGB {
            return .unavailable("\(spec.displayName) needs about \(spec.minimumRAMGB) GB of memory and this device has \(ram) GB. Try a smaller model.")
        }
        return .ready
    }

    public func prewarm() {
        guard availability == .ready, container == nil, loadTask == nil else { return }
        Task { _ = try? await loadContainer() }
    }

    /// Frees the model's memory. It loads again on the next question.
    public func unload() {
        replyTask?.cancel()
        loadTask?.cancel()
        loadTask = nil
        container = nil
        MLX.Memory.clearCache()
    }

    func loadContainer() async throws -> ModelContainer {
        if let container { return container }
        if let loadTask { return try await loadTask.value }
        let directory = store.directory(for: spec), spec = spec
        let task = Task { () throws -> ModelContainer in
            let required = UInt64(spec.approxBytes) + 768 * 1024 * 1024
            guard CoachMemory.available() >= required else {
                throw CoachError("Not enough memory",
                                 "\(spec.displayName) needs more free memory than this iPhone has right now. Close other apps, try a smaller model, or use Apple Intelligence.")
            }
            MLX.Memory.cacheLimit = 64 * 1024 * 1024
            return try await LLMModelFactory.shared.loadContainer(from: directory, using: LocalTokenizerLoader())
        }
        loadTask = task
        do {
            let loaded = try await task.value
            if loadTask == task { container = loaded; loadTask = nil }
            return loaded
        } catch {
            if loadTask == task { loadTask = nil }
            throw error
        }
    }

    public func reply(to conversation: [CoachTurn], data: FinanceData) -> AsyncThrowingStream<String, Error> {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let history = CoachText.trimmedHistory(conversation, maxTurns: 8, maxCharacters: 6_000)
        guard let question = history.last?.text else {
            continuation.finish(throwing: CoachError.emptyQuestion)
            return stream
        }
        switch availability {
        case .ready: break
        case .needsDownload:
            continuation.finish(throwing: CoachError("Model not downloaded", "Download \(spec.displayName) in Settings → Coach models first."))
            return stream
        case let .unavailable(reason):
            continuation.finish(throwing: CoachError("Model unavailable", reason))
            return stream
        }
        let system = CoachPrompts.mlxSystemPrompt(data: data, question: question)
        let parameters = GenerateParameters(maxTokens: maxTokens, temperature: temperature, topP: 0.9, repetitionPenalty: 1.05)
        replyTask?.cancel()
        isGenerating = true
        let work = Task { [weak self] in
            defer { self?.isGenerating = false }
            do {
                guard let self else { continuation.finish(); return }
                let started = Date(), wasLoaded = self.container != nil
                let container = try await self.loadContainer()
                let loadSeconds = wasLoaded ? nil : Date().timeIntervalSince(started)
                var stats = try await Self.generate(container: container, system: system, turns: history, parameters: parameters) {
                    continuation.yield($0)
                }
                stats.loadSeconds = loadSeconds
                self.lastStats = stats
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch let error as CoachError {
                continuation.finish(throwing: error)
            } catch {
                continuation.finish(throwing: CoachError("The local model hit a problem", error.localizedDescription))
            }
        }
        replyTask = work
        continuation.onTermination = { _ in work.cancel() }
        return stream
    }

    /// Runs one generation off the main actor and streams the visible text so far.
    @concurrent nonisolated static func generate(container: ModelContainer, system: String, turns: [CoachTurn],
                                                 parameters: GenerateParameters,
                                                 onText: @escaping @Sendable (String) -> Void) async throws -> MLXGenerationStats {
        var chat: [Chat.Message] = [.system(system)]
        for turn in turns { chat.append(turn.role == .user ? .user(turn.text) : .assistant(turn.text)) }
        // Qwen 3.5 reads enable_thinking; other templates ignore it.
        let input = UserInput(chat: chat, additionalContext: ["enable_thinking": false])
        let prepared = try await container.prepare(input: input)
        let promptTokens = prepared.text.tokens.size
        let stream = try await container.generate(input: prepared, parameters: parameters)
        var raw = ""
        var stats = MLXGenerationStats(promptTokens: promptTokens, generatedTokens: 0, tokensPerSecond: 0, loadSeconds: nil)
        for await generation in stream {
            try Task.checkCancellation()
            switch generation {
            case let .chunk(text):
                raw += text
                let visible = CoachText.visibleText(raw)
                if !visible.isEmpty { onText(visible) }
            case let .info(info):
                stats.generatedTokens = info.generationTokenCount
                stats.tokensPerSecond = info.tokensPerSecond
            case .toolCall, .rejectedToolCall:
                break
            }
        }
        try Task.checkCancellation()
        if CoachText.visibleText(raw).isEmpty {
            throw CoachError("No answer", "The model didn't produce an answer. Try asking again in different words.")
        }
        return stats
    }
}
