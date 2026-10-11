import BetterDollarCoach
import BetterDollarCore
import SwiftData
import SwiftUI

/// A chat with an on-device model that can see this month's budget. Nothing leaves the iPhone.
struct CoachScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \CoachMessage.createdAt) private var messages: [CoachMessage]
    @AppStorage("coachEngine") private var engineID = ""
    @State private var store = MLXModelStore.shared
    @State private var draft = ""
    @State private var streaming: String?
    @State private var task: Task<Void, Never>?
    @State private var error: String?
    @State private var showingModels = false
    @FocusState private var composerFocused: Bool

    private var engine: (any CoachEngine)? { CoachEngineFactory.engine(id: resolvedEngineID, store: store) }
    private var resolvedEngineID: String { engineID.isEmpty ? CoachEngineFactory.defaultEngineID(store: store) : engineID }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        header
                        if let engine, engine.availability != .ready {
                            unavailable(engine)
                        }
                        if messages.isEmpty && streaming == nil {
                            starters
                        }
                        ForEach(messages) { message in
                            MessageView(text: message.text, isUser: message.isUser, footnote: message.isUser ? nil : message.engine)
                                .id(message.persistentModelID)
                        }
                        if let streaming {
                            MessageView(text: streaming.isEmpty ? "Thinking…" : streaming, isUser: false, footnote: nil, isPending: streaming.isEmpty)
                                .id("streaming")
                        }
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(Ink.seal)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: streaming) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: messages.count) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .statusBarShield()
            .paperBackground()
            .safeAreaInset(edge: .bottom) { composer }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingModels) {
                NavigationStack { CoachModelsView(showsDone: true) }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Coach").font(Typeface.title(34)).foregroundStyle(Ink.text)
                Menu {
                    Picker("Model", selection: $engineID) {
                        ForEach(CoachEngineFactory.availableEngineIDs(store: store), id: \.self) { id in
                            Text(name(for: id)).tag(id)
                        }
                    }
                    Button("Download models", systemImage: "arrow.down.circle") { showingModels = true }
                } label: {
                    HStack(spacing: 4) {
                        Text(name(for: resolvedEngineID))
                        Image(systemName: "chevron.down").font(.caption.weight(.bold))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Ink.primary)
                }
                .accessibilityLabel("Model: \(name(for: resolvedEngineID))")
                .accessibilityIdentifier("coach-model")
            }
            Spacer()
            if !messages.isEmpty {
                Button("New chat", systemImage: "square.and.pencil") { clear() }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(Ink.primary)
                    .disabled(streaming != nil)
            }
        }
        .padding(.top, 8)
    }

    private var starters: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ask about your budget, your funds or where the money went. Answers are written on this iPhone from your own numbers; nothing is sent to a cloud AI.")
                .font(.callout)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(CoachPrompts.starters, id: \.self) { starter in
                Button {
                    send(starter)
                } label: {
                    HStack {
                        Text(starter).multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "arrow.up.circle").foregroundStyle(Ink.primary)
                    }
                    .font(.body)
                    .foregroundStyle(Ink.text)
                    .padding(14)
                    .background(Ink.sheet, in: .rect(cornerRadius: 14))
                    .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.rule) }
                }
                .buttonStyle(.plain)
                .disabled(engine?.availability != .ready)
            }
        }
    }

    private func unavailable(_ engine: any CoachEngine) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch engine.availability {
            case .unavailable(let reason):
                Text(reason).foregroundStyle(Ink.text)
                Text("You can download a model that runs entirely on this iPhone instead.").foregroundStyle(Ink.secondary)
            case .needsDownload:
                Text("\(engine.displayName) isn't downloaded yet.").foregroundStyle(Ink.text)
            case .ready:
                EmptyView()
            }
            Button("Choose a model to download") { showingModels = true }
                .buttonStyle(InkButtonStyle())
        }
        .font(.callout)
        .padding(16)
        .background(Ink.sheet, in: .rect(cornerRadius: 16))
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask your coach", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($composerFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Ink.sheet, in: .rect(cornerRadius: 20))
                .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(Ink.rule) }
                .submitLabel(.send)
                .onSubmit { send(draft) }
                .accessibilityIdentifier("coach-input")
            if streaming != nil {
                Button("Stop", systemImage: "stop.circle.fill") { task?.cancel() }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 32))
                    .foregroundStyle(Ink.primary)
            } else {
                Button("Send", systemImage: "arrow.up.circle.fill") { send(draft) }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 32))
                    .foregroundStyle(Ink.primary)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || engine?.availability != .ready)
                    .accessibilityIdentifier("coach-send")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Ink.paper.opacity(0.96))
    }

    private func name(for id: String) -> String {
        if id == AppleCoachEngine.engineID { return "Apple Intelligence" }
        return MLXModelCatalog.spec(id: String(id.dropFirst(4)))?.displayName ?? id
    }

    private func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, streaming == nil, let engine, engine.availability == .ready else { return }
        draft = ""
        error = nil
        let history = messages.suffix(12).map { CoachTurn(role: $0.isUser ? .user : .assistant, text: $0.text) }
            + [CoachTurn(role: .user, text: question)]
        context.insert(CoachMessage(role: "user", text: question))
        let data = FinanceData.build(month: app.month, context: context)
        let engineName = engine.displayName
        streaming = ""
        task = Task {
            var reply = ""
            do {
                for try await partial in engine.reply(to: history, data: data) {
                    reply = partial
                    streaming = partial
                }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            if !reply.isEmpty {
                context.insert(CoachMessage(role: "assistant", text: reply, engine: engineName))
            }
            try? context.save()
            streaming = nil
        }
    }

    private func clear() {
        for message in messages { context.delete(message) }
        error = nil
    }
}

struct MessageView: View {
    let text: String
    let isUser: Bool
    let footnote: String?
    var isPending = false

    var body: some View {
        if isUser {
            HStack {
                Spacer(minLength: 48)
                Text(text)
                    .foregroundStyle(Ink.onPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Ink.primary, in: .rect(cornerRadius: 18))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(rendered)
                    .foregroundStyle(isPending ? Ink.secondary : Ink.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let footnote, !footnote.isEmpty {
                    Text("Written on this iPhone by \(footnote)")
                        .font(.caption2)
                        .foregroundStyle(Ink.secondary)
                }
            }
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                Rectangle().fill(Ink.primary.opacity(0.35)).frame(width: 2)
            }
        }
    }

    /// Small models write Markdown: headings become bold lines, list markers become bullets, the rest stays inline.
    private var rendered: AttributedString {
        var result = AttributedString()
        let lines = text.components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            var line = raw
            var isHeading = false
            if let range = line.range(of: #"^\s*#{1,6}\s+"#, options: .regularExpression) {
                line.removeSubrange(range)
                isHeading = true
            } else if let range = line.range(of: #"^\s*[*-]\s+"#, options: .regularExpression) {
                line.replaceSubrange(range, with: "•  ")
            }
            var piece = (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(line)
            if isHeading { piece.font = .body.weight(.semibold) }
            result += piece
            if index < lines.count - 1 { result += AttributedString("\n") }
        }
        return result
    }
}
