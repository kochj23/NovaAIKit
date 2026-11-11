//
//  NovaAIStatusIndicator.swift
//  NovaAIKit
//
//  A dot and a short label: the active backend and whether it answers. Click/tap to check again.
//
//  Copyright © 2026 Jordan Koch.
//

#if canImport(SwiftUI)
import SwiftUI

/// Status indicator for toolbars, menu bars and settings headers.
public struct NovaAIStatusIndicator: View {
    @ObservedObject private var ai: NovaAI
    private let showsLabel: Bool
    private let checksOnAppear: Bool

    /// - Parameters:
    ///   - showsLabel: false shows only the dot (the label stays as the accessibility label and help text).
    ///   - checksOnAppear: probe once when first shown if the status is still unknown.
    public init(ai: NovaAI, showsLabel: Bool = true, checksOnAppear: Bool = true) {
        self.ai = ai
        self.showsLabel = showsLabel
        self.checksOnAppear = checksOnAppear
    }

    public var body: some View {
        Button {
            Task { await ai.refreshStatus() }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(Self.color(ai.status.state)).frame(width: 8, height: 8)
                if showsLabel { Text(ai.status.label).font(.caption).lineLimit(1) }
            }
        }
        #if os(tvOS)
        .buttonStyle(PlainButtonStyle())
        #else
        .buttonStyle(BorderlessButtonStyle())
        #endif
        .help(helpText)
        .accessibilityLabel(Text(ai.status.label))
        .onAppear {
            if checksOnAppear, ai.status.state == .unknown { Task { await ai.refreshStatus() } }
        }
    }

    private var helpText: String {
        var s = ai.status.label + ". Click to check again."
        if let e = ai.status.lastError, ai.status.state == .offline { s += " Last error: \(e)" }
        return s
    }

    /// Green online, orange offline, grey off/unknown/checking.
    public nonisolated static func color(_ state: NovaAIStatus.State) -> Color {
        switch state {
        case .online: return .green
        case .offline: return .orange
        case .off, .unknown, .checking: return .gray
        }
    }
}
#endif
