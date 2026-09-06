//
//  QueueDownloadCollisions.swift
//  Trawl
//
//  Detects the same physical download sitting in more than one Arr instance's
//  queue at the same moment.
//

import Foundation
import SwiftUI

/// Finds live download-id collisions across the Arr queues Trawl already polls.
///
/// This is deliberately *not* a `ConfigurationIssueKind` on `ConfigurationAudit`.
/// That audit is about how services are configured: it caches a verdict for five
/// minutes and lets a user permanently dismiss one finding by a stable
/// `discriminator`. A queue collision is neither. It is live, transient fact about
/// what is downloading right now - two instances sharing one download client and
/// having both grabbed the same release - and it can appear and resolve itself
/// within a single 5-second poll. Folding it into the audit would mean either a
/// five-minute-stale "collision" banner still showing after the download finished
/// importing, or a dismissal recorded against today's colliding download id that
/// then wrongly silences a *different* collision next week, because the
/// discriminator has nothing stable to key on other than the download id itself.
/// So this lives beside the queue data it reads, is recomputed on every poll, and
/// is never dismissable - there is nothing to remember, only something to watch.
///
/// The detector is a pure function over the same `ArrInstanced<ArrQueueItem>` rows
/// `ArrServiceManager.queueItemsBySource` already holds, so it needs no network
/// calls of its own and is unit-testable with plain fixtures - no servers - exactly
/// like `ConfigurationAudit` is pure over `ConfigurationSnapshot`.
nonisolated enum QueueDownloadCollisionDetector {
    /// One download id present in more than one instance's queue at once.
    struct Collision: Identifiable, Equatable {
        let downloadId: String
        /// Every queue row sharing this download id, one per instance it appeared
        /// in. Always two or more distinct instances - see `find`.
        let entries: [ArrInstanced<ArrQueueItem>]

        var id: String { downloadId }

        /// The instances racing for this download, HD/4K-ordered like every other
        /// badge row, for a banner that wants to name who is involved.
        var instances: [ArrInstanceRef] {
            entries.map(\.instance).sorted { $0.ordinal < $1.ordinal }
        }
    }

    /// Groups queue rows by download id and reports every group spanning more
    /// than one *instance*.
    ///
    /// Grouping key is `downloadId`, lowercased and trimmed - download clients
    /// hand out ids as hex hashes (torrent) or opaque tokens (SABnzbd/NZBGet), and
    /// nothing in either API guarantees consistent casing between two Arr
    /// instances' own re-reporting of the same client's id.
    static func find(in queueRows: [ArrInstanced<ArrQueueItem>]) -> [Collision] {
        // Nil and empty download ids are excluded from grouping entirely, not
        // normalized to some shared "unknown" bucket. An item still queued for
        // grab (no client has accepted it yet) or one Arr's decode failing to
        // populate the field reports no id - and two such rows are not "the same
        // download with no id", they are two unrelated rows that both happen to
        // be missing a fact. Grouping them would manufacture a collision out of
        // absence.
        var byDownloadId: [String: [ArrInstanced<ArrQueueItem>]] = [:]
        for row in queueRows {
            guard let rawId = row.value.downloadId else { continue }
            let normalized = rawId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { continue }
            byDownloadId[normalized, default: []].append(row)
        }

        return byDownloadId.compactMap { downloadId, rows -> Collision? in
            // Distinct *instances*, not distinct rows. The same instance can
            // legitimately report the same download id twice - Sonarr shows one
            // queue entry per episode, so a season pack downloading five
            // episodes at once produces five rows sharing one downloadId inside
            // a single instance's own queue. That is one download doing its job,
            // not a collision, and it must never be flagged. It is also why an
            // instance reached under two different `ArrInstanceRef`s can't be
            // told apart from a genuine second server here: `ArrInstanceRef.id`
            // is the configured profile's stable id, so the *same* physical
            // server added twice by mistake would already show as two profiles
            // fighting over one library elsewhere in the app - that is a setup
            // problem for the configuration audit, not this detector's concern.
            let distinctInstances = Set(rows.map(\.instance.id))
            guard distinctInstances.count > 1 else { return nil }

            // One row per instance for display, preferring the first seen -
            // `entries` names who is involved, not how many episodes are in
            // flight on each side.
            var seenInstances: Set<UUID> = []
            var representativeRows: [ArrInstanced<ArrQueueItem>] = []
            for row in rows where seenInstances.insert(row.instance.id).inserted {
                representativeRows.append(row)
            }

            return Collision(downloadId: downloadId, entries: representativeRows)
        }
        .sorted { $0.downloadId < $1.downloadId }
    }
}

/// The Downloads tab's own notice that two instances are racing for one download.
///
/// Built on `TrawlInlineCallout` rather than `ConfigurationAttentionBanner`: that
/// banner opens the Setup Check sheet and reads from `ConfigurationAuditStore`,
/// neither of which applies here - there is no configuration to repair and no
/// audit result to hand it. `TrawlInlineCallout` is the notice style that already
/// means "true about your setup for as long as this condition holds, and gone the
/// moment it doesn't," which is exactly this. No `onDismiss`: unlike the Prowlarr
/// nudge, waving this away would hide the one warning that the loser's import is
/// about to fail silently, for a condition that clears itself in one poll anyway.
struct QueueDownloadCollisionBanner: View {
    let collision: QueueDownloadCollisionDetector.Collision

    var body: some View {
        TrawlInlineCallout(
            icon: "arrow.triangle.branch",
            tint: .orange,
            title: "Two Servers Grabbed the Same Release",
            message: message
        )
    }

    private var message: String {
        let names = collision.instances.map(\.qualifiedLabel).joined(separator: " and ")
        let title = collision.entries.compactMap(\.value.title).first
        if let title {
            return "\(names) are both importing \"\(title)\" from the same download. Whichever finishes first will win the file; the other's import will fail."
        }
        return "\(names) are both importing the same download. Whichever finishes first will win the file; the other's import will fail."
    }
}
