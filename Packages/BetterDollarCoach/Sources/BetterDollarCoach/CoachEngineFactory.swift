import Foundation

/// Hands out one engine per id so a loaded local model is reused between questions,
/// and keeps only one local model in memory at a time.
@MainActor public enum CoachEngineFactory {
    private static var engines: [String: any CoachEngine] = [:]

    public static func engine(id: String, store: MLXModelStore = .shared) -> (any CoachEngine)? {
        let engine: any CoachEngine
        if let cached = engines[id] {
            engine = cached
        } else if id == AppleCoachEngine.engineID {
            engine = AppleCoachEngine()
        } else if id.hasPrefix("mlx:"), let spec = MLXModelCatalog.spec(id: String(id.dropFirst(4))) {
            engine = MLXCoachEngine(spec: spec, store: store)
        } else {
            return nil
        }
        engines[id] = engine
        for (otherID, other) in engines where otherID != id {
            (other as? MLXCoachEngine)?.unload()
        }
        return engine
    }

    /// Apple Intelligence first, then every downloaded local model.
    public static func availableEngineIDs(store: MLXModelStore = .shared) -> [String] {
        [AppleCoachEngine.engineID] + store.downloadedModels.map(MLXCoachEngine.engineID(for:))
    }

    /// The engine to use when the user hasn't picked one: Apple Intelligence if it works here,
    /// otherwise the first downloaded model.
    public static func defaultEngineID(store: MLXModelStore = .shared) -> String {
        if AppleCoachEngine().availability == .ready { return AppleCoachEngine.engineID }
        return store.downloadedModels.first.map(MLXCoachEngine.engineID(for:)) ?? AppleCoachEngine.engineID
    }

    /// Unloads every local model, for example when the app goes to the background.
    public static func unloadAll() {
        for engine in engines.values { (engine as? MLXCoachEngine)?.unload() }
    }
}
