//
//  SABnzbdNewsServerBrowserState.swift
//  Trawl
//
//  Shared selection and state for the SABnzbd News Servers split view.
//

import SwiftUI
import Observation

/// The News Servers list's selection and editor state, owned above the split view
/// so both native columns (list and detail) share it.
@MainActor
@Observable
final class SABnzbdNewsServerBrowserState {
    var selectedServerID: String?
    var editorTarget: EditorTarget?
    var serverPendingDeletion: SABnzbdNewsServer?
    var actionError: String?

    /// `server == nil` is the add case. Wrapped in an Identifiable box so one
    /// `.sheet(item:)` covers both add and edit.
    struct EditorTarget: Identifiable {
        let server: SABnzbdNewsServer?
        var id: String { server?.id ?? "new-server" }
    }

    func reconcileSelection(servers: [SABnzbdNewsServer]) {
        if let selected = selectedServerID, servers.contains(where: { $0.id == selected }) {
            return
        }
        selectedServerID = servers.first?.id
    }
}
