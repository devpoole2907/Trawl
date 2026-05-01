enum SelectionMode: Equatable {
    case inactive
    case active

    var isEditing: Bool { self == .active }
}
