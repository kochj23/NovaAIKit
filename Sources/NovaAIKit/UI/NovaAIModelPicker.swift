//
//  NovaAIModelPicker.swift
//  NovaAIKit
//
//  Backend + model picker for one side of a model-vs-model game (or any per-request override). Bind it to the side's
//  backend and model, then send that side's requests with `NovaAIRequest(…, backend:, model:)`. The URL and key
//  still come from settings. Models come from `listModels(for:)` (the backend's own list, else `fallbackModels`).
//
//  Copyright © 2026 Jordan Koch.
//

#if canImport(SwiftUI)
import SwiftUI

public struct NovaAIModelPicker: View {
    @ObservedObject private var ai: NovaAI
    @Binding private var backend: NovaAIBackend
    @Binding private var model: String
    @State private var models: [String] = []
    private let title: String

    /// - Parameters:
    ///   - title: label, e.g. "White" / "Black".
    ///   - backend: the side's backend; `.auto` means "use the settings" (the request then needs no override).
    ///   - model: the side's model; empty means the backend's model from settings.
    public init(ai: NovaAI, title: String = "AI", backend: Binding<NovaAIBackend>, model: Binding<String>) {
        self.ai = ai
        self.title = title
        self._backend = backend
        self._model = model
    }

    public var body: some View {
        Group {
            Picker(title, selection: backendBinding) {
                Text("Settings (\(ai.settings.backend.displayName))").tag(NovaAIBackend.auto)
                ForEach(ai.availableBackends) { b in Text(b.displayName).tag(b) }
            }
            if backend != .auto {
                Picker("\(title) model", selection: $model) {
                    ForEach(shownModels, id: \.self) { Text($0).tag($0) }
                }
            }
        }
        .onAppear(perform: load)
    }

    /// The listed models plus the current one (so the selection always has a row).
    var shownModels: [String] {
        let list = models.isEmpty ? backend.fallbackModels : models
        return model.isEmpty || list.contains(model) ? list : [model] + list
    }

    private var backendBinding: Binding<NovaAIBackend> {
        Binding(get: { backend }, set: { b in
            backend = b
            model = b == .auto ? "" : ai.settings.model(for: b)
            models = []
            load()
        })
    }

    private func load() {
        let b = backend
        guard b != .auto else { return }
        if model.isEmpty { model = ai.settings.model(for: b) }
        Task {
            let list = await ai.listModels(for: b)
            if backend == b { models = list }
        }
    }
}
#endif
