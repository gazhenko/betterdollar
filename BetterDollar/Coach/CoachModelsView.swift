import BetterDollarCoach
import SwiftUI

/// Choose and download open models that run on this iPhone through MLX.
struct CoachModelsView: View {
    /// True when shown as a sheet from the Coach tab.
    var showsDone = false
    @State private var store = MLXModelStore.shared
    @AppStorage("coachEngine") private var engineID = ""
    @Environment(\.dismiss) private var dismiss
    @State private var apple = AppleCoachEngine()

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Apple Intelligence").font(.body.weight(.medium))
                        Text(appleStatus).font(.caption).foregroundStyle(Ink.secondary)
                    }
                    Spacer()
                    if engineID == AppleCoachEngine.engineID || (engineID.isEmpty && apple.availability == .ready) {
                        Image(systemName: "checkmark").foregroundStyle(Ink.primary).accessibilityLabel("In use")
                    }
                }
                .contentShape(.rect)
                .onTapGesture { engineID = AppleCoachEngine.engineID }
            } header: {
                Text("Built in")
            } footer: {
                Text("Apple's on-device model needs an iPhone with Apple Intelligence turned on. It looks up details in your budget as it answers.")
            }

            Section {
                ForEach(MLXModelCatalog.all) { spec in
                    ModelRow(spec: spec, store: store, isSelected: engineID == MLXCoachEngine.engineID(for: spec)) {
                        engineID = MLXCoachEngine.engineID(for: spec)
                    }
                }
            } header: {
                Text("Download a model")
            } footer: {
                Text("Models download once from Hugging Face at a fixed version, then run fully offline. Keep BetterDollar open while a model downloads; if it stops, tap Download again to resume.")
            }
        }
        .scrollContentBackground(.hidden)
        .paperBackground()
        .navigationTitle("On-device AI")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDone { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var appleStatus: String {
        switch apple.availability {
        case .ready: "Ready on this iPhone"
        case .needsDownload: "Apple Intelligence is still downloading"
        case .unavailable(let reason): reason
        }
    }
}

private struct ModelRow: View {
    let spec: MLXModelSpec
    let store: MLXModelStore
    let isSelected: Bool
    let select: () -> Void
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(spec.displayName).font(.body.weight(.medium))
                if spec.isRecommended {
                    Text("Recommended")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .foregroundStyle(Ink.onPrimary)
                        .background(Ink.primary, in: .capsule)
                }
                Spacer()
                Text(spec.sizeText).font(.caption.monospacedDigit()).foregroundStyle(Ink.secondary)
            }
            Text(spec.summary).font(.callout).foregroundStyle(Ink.secondary)
            Text("\(spec.license). Needs about \(spec.minimumRAMGB) GB of memory.")
                .font(.caption).foregroundStyle(Ink.secondary)
            controls
        }
        .padding(.vertical, 4)
        .confirmationDialog("Delete \(spec.displayName)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete \(spec.sizeText)", role: .destructive) { store.delete(spec) }
        }
    }

    @ViewBuilder private var controls: some View {
        switch store.state(for: spec) {
        case .notDownloaded:
            Button("Download", systemImage: "arrow.down.circle") { store.download(spec) }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("download-\(spec.id)")
        case .downloading(let fraction):
            HStack {
                ProgressView(value: fraction)
                Text(fraction.formatted(.percent.precision(.fractionLength(0)))).font(.caption.monospacedDigit())
                Button("Cancel") { store.cancel(spec) }.font(.caption)
            }
        case .ready:
            HStack {
                Button(isSelected ? "In use" : "Use this model", systemImage: isSelected ? "checkmark" : "bubble.left") { select() }
                    .buttonStyle(.bordered)
                    .disabled(isSelected)
                Spacer()
                Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message).font(.caption).foregroundStyle(Ink.seal)
                Button("Try again", systemImage: "arrow.clockwise") { store.download(spec) }.buttonStyle(.bordered)
            }
        }
    }
}
