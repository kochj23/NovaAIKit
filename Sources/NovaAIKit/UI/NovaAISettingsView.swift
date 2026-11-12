//
//  NovaAISettingsView.swift
//  NovaAIKit
//
//  Drop-in AI settings: on/off, the "Allow Nova" switch, backend picker, per-backend URL + model (listed from the backend), API keys
//  (SecureField → Keychain; a stored key is never shown), timeout, status and Test connection.
//  Builds on macOS 12+, iOS 15+, tvOS 15+.
//
//  Copyright © 2026 Jordan Koch.
//

#if canImport(SwiftUI)
import SwiftUI

public struct NovaAISettingsView: View {
    @ObservedObject private var ai: NovaAI
    @State private var keyDrafts: [NovaAIBackend: String] = [:]
    @State private var models: [NovaAIBackend: [String]] = [:]
    @State private var loadingModels: Set<NovaAIBackend> = []
    @State private var testResult: NovaAIProbe?
    @State private var testing = false

    private let footer: String?

    /// - Parameter footer: optional app-specific note (e.g. "When AI is off, the game uses its scripted narrator.").
    public init(ai: NovaAI, footer: String? = nil) {
        self.ai = ai
        self.footer = footer
    }

    static let timeouts: [TimeInterval] = [10, 20, 30, 60, 120, 300]

    public var body: some View {
        Form {
            Section(header: Text("AI"), footer: footerText) {
                Toggle("Use AI", isOn: $ai.settings.enabled)
                Toggle("Allow Nova (gateway / fleet)", isOn: $ai.settings.allowNova)
                NovaAIStatusIndicator(ai: ai)
            }
            if ai.settings.enabled {
                Section(header: Text("Backend")) {
                    Picker("Backend", selection: $ai.settings.backend) {
                        ForEach([.auto] + ai.availableBackends) { b in Text(b.displayName).tag(b) }
                        if !ai.settings.allowNova && ai.settings.backend == .novaGateway {
                            Text("\(NovaAIBackend.novaGateway.displayName) (off)").tag(NovaAIBackend.novaGateway)
                        }
                    }
                    Text(ai.settings.backend.summary).font(.caption).foregroundColor(.secondary)
                    Picker("Timeout", selection: $ai.settings.timeout) {
                        ForEach(Self.timeouts, id: \.self) { t in Text("\(Int(t)) s").tag(t) }
                        if !Self.timeouts.contains(ai.settings.timeout) {
                            Text("\(Int(ai.settings.timeout)) s").tag(ai.settings.timeout)
                        }
                    }
                }
                ForEach(shownBackends) { b in
                    Section(header: Text(b.displayName)) { backendRows(b) }
                }
                Section(header: Text("Connection")) {
                    Button(testing ? "Testing…" : "Test connection") { test() }.disabled(testing)
                    if let r = testResult {
                        Text(r.reachable ? "✓ \(r.backend.displayName) reachable · \(r.detail)" : "✗ \(r.backend.displayName): \(r.detail)")
                            .font(.caption)
                            .foregroundColor(r.reachable ? .green : .orange)
                    }
                }
            }
        }
    }

    private var footerText: Text? { footer.map { Text($0) } }

    /// Auto shows every backend in failover order; otherwise just the chosen one.
    private var shownBackends: [NovaAIBackend] {
        ai.settings.backend == .auto ? ai.availableBackends : [ai.settings.backend]
    }

    @ViewBuilder
    private func backendRows(_ b: NovaAIBackend) -> some View {
        if let ok = ai.status.reachability[b] {
            Text(ok ? "Reachable" : "Not reachable").font(.caption).foregroundColor(ok ? .green : .orange)
        }
        TextField("URL", text: urlBinding(b))
        TextField("Model", text: modelBinding(b))
        if let list = models[b], !list.isEmpty {
            Picker("Available models", selection: modelBinding(b)) {
                ForEach(list, id: \.self) { Text($0).tag($0) }
                if !list.contains(ai.settings.model(for: b)) {
                    Text(ai.settings.model(for: b)).tag(ai.settings.model(for: b))
                }
            }
        }
        Button(loadingModels.contains(b) ? "Loading models…" : "List models") { loadModels(b) }
            .disabled(loadingModels.contains(b))
        if b.acceptsKey { keyRows(b) }
    }

    @ViewBuilder
    private func keyRows(_ b: NovaAIBackend) -> some View {
        let _ = ai.keysVersion          // refresh when a key changes
        let stored = ai.hasAPIKey(for: b)
        SecureField(stored ? "API key stored in Keychain (enter to replace)" : (b.requiresKey ? "API key (required)" : "API key (optional)"),
                    text: keyBinding(b))
        HStack {
            Button("Save key") {
                ai.setAPIKey(keyDrafts[b], for: b)
                keyDrafts[b] = ""
            }
            .disabled((keyDrafts[b] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if stored {
                Button("Remove key") { ai.setAPIKey(nil, for: b) }
            }
        }
        Text(b.requiresKey ? "Sent only over https. Stored only in the Keychain."
                           : "Sent only over https (or to this Mac's localhost). Stored only in the Keychain.")
            .font(.caption).foregroundColor(.secondary)
    }

    private func urlBinding(_ b: NovaAIBackend) -> Binding<String> {
        Binding(get: { ai.settings.url(for: b) }, set: { ai.settings.setURL($0, for: b) })
    }

    private func modelBinding(_ b: NovaAIBackend) -> Binding<String> {
        Binding(get: { ai.settings.model(for: b) }, set: { ai.settings.setModel($0, for: b) })
    }

    private func keyBinding(_ b: NovaAIBackend) -> Binding<String> {
        Binding(get: { keyDrafts[b] ?? "" }, set: { keyDrafts[b] = $0 })
    }

    private func loadModels(_ b: NovaAIBackend) {
        loadingModels.insert(b)
        Task {
            let list = await ai.listModels(for: b)
            models[b] = list
            loadingModels.remove(b)
        }
    }

    private func test() {
        testing = true
        Task {
            testResult = await ai.testConnection()
            testing = false
        }
    }
}
#endif
