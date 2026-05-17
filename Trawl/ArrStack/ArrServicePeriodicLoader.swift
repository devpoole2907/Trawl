import SwiftUI

extension View {
    /// Loads data for each key in parallel on appear, then repeats every `interval`.
    /// Restarts when `keys` changes; cancels cleanly when the view disappears.
    /// Use this overload when `Key` has a nonisolated `Hashable` conformance (e.g. `nonisolated enum`).
    func loadServicesPeriodically<Key: Hashable & Sendable>(
        _ keys: [Key],
        refreshEvery interval: Duration = .seconds(30),
        load: @escaping @Sendable (Key) async -> Void
    ) -> some View {
        self.task(id: keys) {
            await parallelLoad(keys, load: load)
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { break }
                await parallelLoad(keys, load: load)
            }
        }
    }

    /// Overload for types whose `Hashable` conformance is actor-isolated (e.g. private enums in a
    /// `@MainActor`-defaulted module). Pass a stable `id` value derived from `keys` instead.
    func loadServicesPeriodically<ID: Hashable & Sendable, Key: Sendable>(
        id: ID,
        keys: [Key],
        refreshEvery interval: Duration = .seconds(30),
        load: @escaping @Sendable (Key) async -> Void
    ) -> some View {
        self.task(id: id) {
            await parallelLoad(keys, load: load)
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { break }
                await parallelLoad(keys, load: load)
            }
        }
    }
}

private func parallelLoad<Key: Sendable>(
    _ keys: [Key],
    load: @escaping @Sendable (Key) async -> Void
) async {
    await withTaskGroup(of: Void.self) { group in
        for key in keys {
            group.addTask { await load(key) }
        }
    }
}
