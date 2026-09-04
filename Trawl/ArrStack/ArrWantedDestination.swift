import Foundation

enum ArrWantedDestination: Hashable {
    case media(ArrMediaDestination)
    case bazarrSeries(Int)
    case bazarrMovie(Int)
}
