//
//  SABnzbdNewsServerBrowserStateTests.swift
//  TrawlTests
//
//  The News Servers list and detail columns are two instances of one screen that
//  share SABnzbdNewsServerBrowserState, so what it selects is what both columns agree
//  the user is looking at.
//

import Foundation
import Testing
@testable import Trawl

@Suite("SABnzbd News Server browser state")
@MainActor
struct SABnzbdNewsServerBrowserStateTests {

    private static func makeServer(name: String, host: String = "news.example.com", port: Int = 563) -> SABnzbdNewsServer {
        SABnzbdNewsServer(
            name: name,
            displayName: name.capitalized,
            host: host,
            port: port,
            username: "user",
            password: "password",
            connections: 8,
            ssl: true
        )
    }

    @Test("Initial state has no selection and no editor target")
    func initialState() {
        let state = SABnzbdNewsServerBrowserState()
        #expect(state.selectedServerID == nil)
        #expect(state.editorTarget == nil)
        #expect(state.serverPendingDeletion == nil)
        #expect(state.actionError == nil)
    }

    @Test("Reconcile selection picks the first server when selection is nil")
    func reconcilePicksFirstWhenNil() {
        let state = SABnzbdNewsServerBrowserState()
        let servers = [
            Self.makeServer(name: "server-1"),
            Self.makeServer(name: "server-2")
        ]

        state.reconcileSelection(servers: servers)
        #expect(state.selectedServerID == "server-1")
    }

    @Test("Reconcile selection preserves existing selection when it is still in the list")
    func reconcilePreservesExistingSelection() {
        let state = SABnzbdNewsServerBrowserState()
        let servers = [
            Self.makeServer(name: "server-1"),
            Self.makeServer(name: "server-2")
        ]

        state.selectedServerID = "server-2"
        state.reconcileSelection(servers: servers)
        #expect(state.selectedServerID == "server-2")
    }

    @Test("Reconcile selection falls back to the first server when the selected server was deleted")
    func reconcileFallsBackWhenDeleted() {
        let state = SABnzbdNewsServerBrowserState()
        state.selectedServerID = "server-deleted"

        let servers = [
            Self.makeServer(name: "server-1"),
            Self.makeServer(name: "server-2")
        ]

        state.reconcileSelection(servers: servers)
        #expect(state.selectedServerID == "server-1")
    }

    @Test("Reconcile selection clears selection when servers list becomes empty")
    func reconcileClearsWhenEmpty() {
        let state = SABnzbdNewsServerBrowserState()
        state.selectedServerID = "server-1"

        state.reconcileSelection(servers: [])
        #expect(state.selectedServerID == nil)
    }

    @Test("EditorTarget correctly identifies new vs existing server")
    func editorTargetIdentification() {
        let newTarget = SABnzbdNewsServerBrowserState.EditorTarget(server: nil)
        #expect(newTarget.id == "new-server")
        #expect(newTarget.server == nil)

        let server = Self.makeServer(name: "usenet-prime")
        let editTarget = SABnzbdNewsServerBrowserState.EditorTarget(server: server)
        #expect(editTarget.id == "usenet-prime")
        #expect(editTarget.server?.name == "usenet-prime")
    }
}
