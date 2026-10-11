import BetterDollarCore
import SwiftUI

/// Bring-your-own Plaid keys. Plaid's free Trial plan covers 10 bank connections with transactions.
struct PlaidSetupView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var clientID = ""
    @State private var secret = ""
    @State private var environment: PlaidEnvironment = .sandbox
    @State private var isChecking = false
    @State private var result: (ok: Bool, text: String)?

    var body: some View {
        Form {
            Section {
                step(1, "Create a free Plaid account at dashboard.plaid.com. New teams in the US and Canada get the Trial plan: 10 bank connections with transactions, including OAuth banks like Chase and Bank of America.")
                step(2, "In the Plaid Dashboard, open Developers, then Keys. Copy your client ID and a secret.")
                step(3, "Paste them below. Start with Sandbox to try fake banks (username user_good, password pass_good), then switch to Production for your real accounts.")
                Link("Open the Plaid Dashboard", destination: URL(string: "https://dashboard.plaid.com/signup")!)
            } header: {
                Text("Get your keys")
            }

            Section {
                TextField("Client ID", text: $clientID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .accessibilityIdentifier("plaid-client-id")
                SecureField("Secret", text: $secret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("plaid-secret")
                Picker("Environment", selection: $environment) {
                    ForEach(PlaidEnvironment.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Your keys")
            } footer: {
                Text("Keys are stored in this iPhone's Keychain only. Each environment has its own secret.")
            }

            Section {
                Button {
                    Task { await check() }
                } label: {
                    HStack {
                        Text("Check and save")
                        if isChecking { Spacer(); ProgressView() }
                    }
                }
                .disabled(clientID.isEmpty || secret.isEmpty || isChecking)
                .accessibilityIdentifier("plaid-save")
                if let result {
                    Label(result.text, systemImage: result.ok ? "checkmark.seal" : "exclamationmark.triangle")
                        .foregroundStyle(result.ok ? Ink.primary : Ink.seal)
                }
                if app.bank.isConfigured {
                    Button("Forget these keys", role: .destructive) {
                        app.bank.save(nil)
                        clientID = ""; secret = ""; result = nil
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .paperBackground()
        .navigationTitle("Plaid")
        .onAppear {
            if let saved = app.bank.credentials {
                clientID = saved.clientID
                secret = saved.secret
                environment = saved.environment
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(Ink.onPrimary)
                .frame(width: 24, height: 24)
                .background(Ink.primary, in: .circle)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    /// Creating a Link token proves the keys work without connecting a bank or using up a connection.
    private func check() async {
        isChecking = true
        defer { isChecking = false }
        let credentials = PlaidCredentials(clientID: clientID, secret: secret, environment: environment)
        do {
            _ = try await PlaidClient(credentials: credentials).createHostedLink(userID: app.bank.vault.userID)
            app.bank.save(credentials)
            result = (true, "Plaid accepted your keys. Connect a bank from Settings.")
        } catch {
            result = (false, error.localizedDescription)
        }
    }
}
