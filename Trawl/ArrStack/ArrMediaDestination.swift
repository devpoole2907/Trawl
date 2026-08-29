import SwiftUI

/// Unified navigation target for Radarr/Sonarr media detail screens.
///
/// Replaces the per-screen destination types (`SeriesDestination`, `MovieDestination`,
/// `ArrSeriesLookupDestination`, `ArrMovieLookupDestination`, `MoreDestination.calendarSeries`/
/// `.calendarMovie`, ...) that used to be declared ad-hoc by every screen that could push into
/// a movie or series detail view. Push one of these cases via `NavigationLink(value:)` or
/// `NavigationPath.append(_:)` anywhere inside a view tree that has `.arrMediaNavigationDestinations()`
/// applied, and the shared modifier takes care of constructing the right detail view + ViewModel.
enum ArrMediaDestination: Hashable {
    /// An in-library Radarr movie, resolved by its Radarr library ID.
    case movie(id: Int)
    /// A Radarr discover/lookup result that may or may not already be in the library.
    /// `RadarrMovie`'s `Hashable` conformance is ID-based, so two lookup results that share
    /// the same `id` (e.g. `0` for anything Radarr hasn't added yet) are considered equal here too.
    case movieLookup(RadarrMovie)
    /// An in-library Sonarr series, resolved by its Sonarr library ID.
    case series(id: Int)
    /// A Sonarr discover/lookup result that may or may not already be in the library.
    /// `SonarrSeries`'s `Hashable` conformance is ID-based, so two lookup results that share
    /// the same `id` (e.g. `0` for anything Sonarr hasn't added yet) are considered equal here too.
    case seriesLookup(SonarrSeries)
}

/// Registers `navigationDestination(for: ArrMediaDestination.self)` once and builds the
/// corresponding detail view, sourcing `ArrServiceManager`/`SyncService` from the environment.
///
/// Library-mode cases (`.movie`, `.series`) construct a fresh `RadarrViewModel`/`SonarrViewModel`
/// per push, preloaded from `ArrServiceManager.calendarViewModel` - the same app-wide, eagerly
/// loaded library cache `ArrCalendarView` and `MoreView`'s calendar destinations already relied
/// on before this modifier existed. That avoids an empty-state flash on first render while the
/// detail view's own self-healing `.task` fetches a fresh copy.
///
/// Discover-mode cases (`.movieLookup`, `.seriesLookup`) construct a plain, unpreloaded ViewModel;
/// the detail view falls back to its `discoverMovie`/`discoverSeries` object until (if ever) a
/// library match loads in.
private struct ArrMediaNavigationDestinationsModifier: ViewModifier {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(SyncService.self) private var syncService

    var onLibraryChanged: (() async -> Void)?
    var zoomNamespace: Namespace.ID?

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: ArrMediaDestination.self) { destination in
                destinationView(for: destination)
                    .environment(syncService)
            }
    }

    @ViewBuilder
    private func destinationView(for destination: ArrMediaDestination) -> some View {
        switch destination {
        case .movie(let id):
            RadarrMovieDetailView(movieId: id, viewModel: makeRadarrViewModel())

        case .series(let id):
            SonarrSeriesDetailView(seriesId: id, viewModel: makeSonarrViewModel())

        case .movieLookup(let movie):
            zoomed(destination) {
                RadarrMovieDetailView(movie: movie, viewModel: makeRadarrViewModel(), onAdded: onLibraryChanged)
            }

        case .seriesLookup(let series):
            zoomed(destination) {
                SonarrSeriesDetailView(series: series, viewModel: makeSonarrViewModel(), onAdded: onLibraryChanged)
            }
        }
    }

    @ViewBuilder
    private func zoomed<Content: View>(
        _ destination: ArrMediaDestination,
        @ViewBuilder content: () -> Content
    ) -> some View {
        #if os(iOS)
        if let zoomNamespace {
            content().navigationTransition(.zoom(sourceID: destination, in: zoomNamespace))
        } else {
            content()
        }
        #else
        content()
        #endif
    }

    private func makeRadarrViewModel() -> RadarrViewModel {
        RadarrViewModel(
            serviceManager: serviceManager,
            preloadedMovies: serviceManager.calendarViewModel?.radarrMovies ?? []
        )
    }

    private func makeSonarrViewModel() -> SonarrViewModel {
        SonarrViewModel(
            serviceManager: serviceManager,
            preloadedSeries: serviceManager.calendarViewModel?.sonarrSeries ?? []
        )
    }
}

extension View {
    /// Registers navigation for `ArrMediaDestination` values pushed anywhere below this view.
    /// Apply once per navigation stack (e.g. directly on the screen that owns/embeds the
    /// `NavigationStack`, or on a view that's always present between the stack root and any
    /// push site, such as `ArrCalendarView` or `ArrWantedView`'s own body).
    ///
    /// - Parameters:
    ///   - onLibraryChanged: Invoked after a discover-mode "Add to library" completes. Mirrors
    ///     the old per-site `onAdded:` callback (e.g. Search passes a library-refresh closure).
    ///   - zoomNamespace: Optional namespace shared with `.matchedTransitionSource(id:in:)` on the
    ///     pushing card, so the detail view continues a `.navigationTransition(.zoom)` (iOS only).
    func arrMediaNavigationDestinations(
        onLibraryChanged: (() async -> Void)? = nil,
        zoomNamespace: Namespace.ID? = nil
    ) -> some View {
        modifier(ArrMediaNavigationDestinationsModifier(onLibraryChanged: onLibraryChanged, zoomNamespace: zoomNamespace))
    }
}
