import Foundation

// MARK: - Syntax layer

/// Sonarr and Radarr tokenise naming formats with different patterns: Sonarr escapes
/// braces as `{{`/`}}`, while Radarr has no escape but allows `{` and `}` as token
/// decoration and nested tags such as `{imdb-{ImdbId}}`.
enum ArrNamingSyntaxDialect: Hashable {
    case sonarr
    case radarr

    init(_ serviceType: ArrServiceType) {
        self = serviceType == .radarr ? .radarr : .sonarr
    }

    // Upstream `FileNameBuilder.TitleRegex`, with its named groups removed (ICU does
    // not allow Radarr's duplicate `prefix` name). Only match ranges are used here.
    private static let sonarrTokenExpression = try! NSRegularExpression(
        pattern: #"\{\{|\}\}|\{[- ._\[(]*[a-z0-9]+(?:[- ._]+[a-z0-9]+)?(?::[ ,a-z0-9+-]+(?<![- ]))?[- ._)\]]*\}"#,
        options: [.caseInsensitive]
    )

    private static let radarrTokenExpression = try! NSRegularExpression(
        pattern: #"(?:\{[-{ ._\[(]*(?:imdb(?:id)?-|edition-))?\{[-{ ._\[(]*[a-z0-9]+(?:[- ._]+[a-z0-9]+)?(?::[ ,a-z0-9|+-]+(?<![- ]))?[-} ._)\]]*\}"#,
        options: [.caseInsensitive]
    )

    var tokenExpression: NSRegularExpression {
        switch self {
        case .sonarr: Self.sonarrTokenExpression
        case .radarr: Self.radarrTokenExpression
        }
    }

    var prefixCharacters: Set<Character> {
        switch self {
        case .sonarr: ["-", " ", ".", "_", "[", "("]
        case .radarr: ["-", "{", " ", ".", "_", "[", "("]
        }
    }

    var suffixCharacters: Set<Character> {
        switch self {
        case .sonarr: ["-", " ", ".", "_", ")", "]"]
        case .radarr: ["-", "}", " ", ".", "_", ")", "]"]
        }
    }
}

/// A naming format split into the exact pieces the server stored.
///
/// Joining every piece's `spelling` reproduces the input character for character.
/// That is the contract everything above this layer depends on: the builder may
/// regroup pieces into friendlier blocks, but it never respells one it was not
/// explicitly asked to change.
enum ArrNamingSyntax {
    static func pieces(of format: String, dialect: ArrNamingSyntaxDialect) -> [ArrNamingSyntaxPiece] {
        var pieces: [ArrNamingSyntaxPiece] = []
        var cursor = format.startIndex
        let matches = dialect.tokenExpression.matches(in: format, range: NSRange(format.startIndex..., in: format))
        for match in matches {
            guard let range = Range(match.range, in: format), range.lowerBound >= cursor else { continue }
            if cursor < range.lowerBound {
                pieces.append(.literal(String(format[cursor..<range.lowerBound])))
            }
            let spelling = String(format[range])
            if dialect == .sonarr, spelling == "{{" || spelling == "}}" {
                pieces.append(.escapedBrace(spelling))
            } else {
                pieces.append(.token(ArrNamingTokenSyntax(spelling: spelling, dialect: dialect)))
            }
            cursor = range.upperBound
        }
        if cursor < format.endIndex {
            pieces.append(.literal(String(format[cursor...])))
        }
        return pieces
    }

    /// Pieces flattened so literal text can be matched a character at a time - a
    /// compound block such as `S{season:00}E{episode:00}` starts in the middle of a
    /// literal run like ` - S`.
    static func atoms(of format: String, dialect: ArrNamingSyntaxDialect) -> [ArrNamingSyntaxAtom] {
        pieces(of: format, dialect: dialect).flatMap { piece -> [ArrNamingSyntaxAtom] in
            switch piece {
            case .literal(let text): text.map { .character($0) }
            case .escapedBrace(let text): [.escapedBrace(text)]
            case .token(let token): [.token(token)]
            }
        }
    }

    static func tokens(in format: String, dialect: ArrNamingSyntaxDialect) -> [ArrNamingTokenSyntax] {
        pieces(of: format, dialect: dialect).compactMap {
            if case .token(let token) = $0 { return token }
            return nil
        }
    }
}

enum ArrNamingSyntaxPiece: Hashable {
    case literal(String)
    /// Sonarr's `{{` or `}}`, which it writes as a single brace.
    case escapedBrace(String)
    case token(ArrNamingTokenSyntax)

    var spelling: String {
        switch self {
        case .literal(let text), .escapedBrace(let text): text
        case .token(let token): token.spelling
        }
    }
}

enum ArrNamingSyntaxAtom: Hashable {
    case character(Character)
    case escapedBrace(String)
    case token(ArrNamingTokenSyntax)

    var spelling: String {
        switch self {
        case .character(let character): String(character)
        case .escapedBrace(let text): text
        case .token(let token): token.spelling
        }
    }
}

/// One `{…}` token, decomposed only for recognition and preview. `spelling` is
/// authoritative and is what gets saved.
struct ArrNamingTokenSyntax: Hashable {
    enum CaseStyle: Hashable {
        case asWritten
        case lowercase
        case uppercase
    }

    let spelling: String
    /// Decoration written only when the token has a value, such as the `-` in `{-Release Group}`.
    let prefix: String
    /// The name plus any `:format`, without decoration.
    let body: String
    let suffix: String

    init(spelling: String, dialect: ArrNamingSyntaxDialect) {
        self.spelling = spelling
        var inner = Substring(spelling.dropFirst().dropLast())
        let prefix = inner.prefix { dialect.prefixCharacters.contains($0) }
        inner = inner.dropFirst(prefix.count)
        let suffixCount = inner.reversed().prefix { dialect.suffixCharacters.contains($0) }.count
        self.prefix = String(prefix)
        self.suffix = String(inner.suffix(suffixCount))
        self.body = String(inner.dropLast(suffixCount))
    }

    var isDecorated: Bool { !prefix.isEmpty || !suffix.isEmpty }

    var name: String {
        String(body.prefix { $0 != ":" })
    }

    /// Truncation, a number format, or a filter such as `{Custom Formats:-HDR}`.
    var format: String? {
        guard let colon = body.firstIndex(of: ":") else { return nil }
        return String(body[body.index(after: colon)...])
    }

    /// The servers compare token names ignoring case, whitespace, `_` and punctuation,
    /// so `{Series.Title}` and `{series title}` both resolve as Series Title.
    var normalizedName: String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    var normalizedKey: String { "\(normalizedName):\(format ?? "")" }

    /// A truncation, filter or language option, as opposed to a number format.
    var hasOption: Bool {
        guard let format, !format.isEmpty else { return false }
        return !format.allSatisfy { $0 == "0" }
    }

    /// The punctuation between the name's two words. A value's spaces are written as
    /// this, which is how `{Series.Title}` produces `Example.Show`.
    var separator: String {
        guard let wordEnd = name.firstIndex(where: { !($0.isLetter || $0.isNumber) }) else { return "" }
        return String(name[wordEnd...].prefix { ArrNamingArrangement.isSeparatorCharacter($0) })
    }

    /// An all-lowercase token writes a lowercase value and an all-uppercase one an
    /// uppercase value; mixed case writes the value as it is.
    var caseStyle: CaseStyle {
        let letters = name.filter(\.isLetter)
        guard !letters.isEmpty else { return .asWritten }
        if letters.allSatisfy(\.isLowercase) { return .lowercase }
        if letters.allSatisfy(\.isUppercase) { return .uppercase }
        return .asWritten
    }
}

// MARK: - Preview

/// A format rendered with the catalog's sample values, flagging what it could not show.
struct ArrNamingRenderedFormat: Hashable {
    let text: String
    /// Tokens with no sample. The server may well write them; this preview cannot.
    let unresolvedTokens: [String]
    /// Tokens whose options (truncation, filters, languages) the sample does not reflect.
    let approximatedTokens: [String]

    var isVerifiable: Bool { unresolvedTokens.isEmpty && approximatedTokens.isEmpty }
}

enum ArrNamingFormatPreview {
    static let emptyText = "No format yet"

    static func preview(for format: String, groups: [ArrNamingTokenGroup], dialect: ArrNamingSyntaxDialect = .sonarr) -> String {
        guard !format.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return emptyText }
        return render(format, groups: groups, dialect: dialect).text
    }

    /// Mirrors the servers' `FileNameBuilder` closely enough to read before saving:
    /// token case and separators are applied to the sample, decoration is written
    /// around it, then repeated identical separators collapse and trailing ones go.
    static func render(_ format: String, groups: [ArrNamingTokenGroup], dialect: ArrNamingSyntaxDialect = .sonarr) -> ArrNamingRenderedFormat {
        let samples = SampleIndex(groups: groups)
        var output = ""
        var unresolved: [String] = []
        var approximated: [String] = []

        for piece in ArrNamingSyntax.pieces(of: format, dialect: dialect) {
            switch piece {
            case .literal(let text):
                output += text
            case .escapedBrace(let text):
                output += String(text.prefix(1))
            case .token(let token):
                guard let value = samples.value(for: token) else {
                    output += token.spelling
                    unresolved.append(token.spelling)
                    continue
                }
                output += value
                if let tokenFormat = token.format, !tokenFormat.allSatisfy({ $0 == "0" }) {
                    approximated.append(token.spelling)
                }
            }
        }

        let collapsed = output.replacingOccurrences(of: #"([- ._])\1+"#, with: "$1", options: .regularExpression)
        let trimmed = collapsed
            .replacingOccurrences(of: #"[- ._]+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ArrNamingRenderedFormat(text: trimmed, unresolvedTokens: unresolved, approximatedTokens: approximated)
    }

    private struct SampleIndex {
        private var exact: [String: String] = [:]
        private var normalized: [String: (sample: String, separator: String)] = [:]

        init(groups: [ArrNamingTokenGroup]) {
            for token in groups.flatMap(\.tokens) {
                let key = token.value.lowercased()
                if exact[key] == nil { exact[key] = token.sample }

                let pieces = ArrNamingSyntax.pieces(of: token.value, dialect: .sonarr)
                guard pieces.count == 1, case .token(let syntax) = pieces[0], !syntax.isDecorated else { continue }
                // Prefer the space-separated spelling as the base, so another
                // separator can be applied to its spaces.
                if let existing = normalized[syntax.normalizedKey], existing.separator == " " || existing.separator.isEmpty {
                    continue
                }
                normalized[syntax.normalizedKey] = (token.sample, syntax.separator)
            }
        }

        func value(for token: ArrNamingTokenSyntax) -> String? {
            // A catalog value spelled exactly, decoration and all (`{-Release Group}`).
            if let sample = exact[token.spelling.lowercased()] {
                return applyCase(sample, token.caseStyle)
            }

            let base: String
            if let entry = normalized[token.normalizedKey] {
                base = entry.sample
            } else if let tokenFormat = token.format, !tokenFormat.isEmpty, tokenFormat.allSatisfy({ $0 == "0" }),
                      let entry = normalized["\(token.normalizedName):"], let number = Int(entry.sample) {
                base = String(repeating: "0", count: max(tokenFormat.count - String(number).count, 0)) + String(number)
            } else if let tokenFormat = token.format, !tokenFormat.allSatisfy({ $0 == "0" }),
                      let entry = normalized["\(token.normalizedName):"] {
                base = entry.sample
            } else {
                return nil
            }

            var value = applyCase(base, token.caseStyle)
            let separator = token.separator
            if !separator.isEmpty, separator != " " {
                value = value.replacingOccurrences(of: " ", with: separator)
            }
            return token.prefix + value + token.suffix
        }

        private func applyCase(_ value: String, _ style: ArrNamingTokenSyntax.CaseStyle) -> String {
            switch style {
            case .asWritten: value
            case .lowercase: value.lowercased()
            case .uppercase: value.uppercased()
            }
        }
    }
}

// MARK: - Validation

/// The field rules Sonarr and Radarr enforce on save (`FileNameValidation`), checked
/// locally so Save is only offered for a format the server's own validator accepts.
/// The servers also parse rendered samples, which cannot be reproduced here, so a
/// format passing these rules can still be rejected and the save path handles that.
enum ArrNamingFormatValidation {
    private static func expression(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let seasonEpisodePattern = expression(#"s?\{season(?::0+)?\}[- ._]?[ex]\{episode(?::0+)?\}"#)
    private static let season = expression(#"\{season(?::0+)?\}"#)
    private static let episode = expression(#"\{episode(?::0+)?\}"#)
    private static let absolute = expression(#"\{absolute(?::0+)?\}"#)
    private static let airDate = expression(#"\{Air(?:\s|\W|_)Date\}"#)
    private static let original = expression(#"\{original[- ._](?:title|filename)\}"#)
    private static let seriesTitle = expression(#"\{Series[- ._](?:Clean)?Title(?:The)?(?:Without)?(?:Year)?(?::[0-9-]+)?\}"#)
    private static let seasonFolder = expression(#"\{season(?::\d+)?\}"#)
    private static let movieTitle = expression(#"\{Movie[- ._](?:Clean)?(?:OriginalTitle|Title(?:The)?)(?::[a-z0-9|-]+)?\}"#)
    private static let releaseYear = expression(#"\{[-{ ._\[(]*Release[- ._]Year[-} ._)\]]*\}"#)

    /// Why the server would refuse `format`, in the builder's own terms, or nil.
    static func issue(for format: String, target: ArrNamingFormatEditorTarget) -> String? {
        guard !format.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Add at least one block."
        }

        func contains(_ expression: NSRegularExpression) -> Bool {
            expression.firstMatch(in: format, range: NSRange(format.startIndex..., in: format)) != nil
        }

        let hasEpisodeNumbering = contains(seasonEpisodePattern) || (contains(season) && contains(episode)) || contains(original)

        switch target {
        case .sonarr(.standardEpisode):
            return hasEpisodeNumbering ? nil : "Include the episode number, or the original title or filename."
        case .sonarr(.dailyEpisode):
            return hasEpisodeNumbering || contains(airDate) ? nil : "Include the air date or episode number, or the original title or filename."
        case .sonarr(.animeEpisode):
            return hasEpisodeNumbering || contains(absolute) ? nil : "Include the absolute or episode number, or the original title or filename."
        case .sonarr(.seriesFolder):
            return contains(seriesTitle) ? nil : "Include the show name."
        case .sonarr(.seasonFolder):
            return contains(seasonFolder) ? nil : "Include the season number."
        case .sonarr(.specialsFolder):
            return nil
        case .radarr(.standardMovie):
            return (contains(movieTitle) && contains(releaseYear)) || contains(original)
                ? nil : "Include the movie name and year, or the original title or filename."
        case .radarr(.movieFolder):
            return contains(movieTitle) ? nil : "Include the movie name."
        }
    }
}

// MARK: - Presentation layer

/// One friendly piece of a filename. `spelling` is the exact syntax it stands for.
struct ArrNamingBlock: Identifiable, Hashable {
    enum Kind: Hashable {
        /// A catalog block such as Episode number; the definition's variants are its choices.
        case element(definitionID: String)
        /// A token this format's catalog does not offer. Kept verbatim and shown as custom.
        case unknownToken
        /// Literal text that is not a plain separator: `Season`, `(`, a `/` folder break.
        case text
    }

    let id: UUID
    var kind: Kind
    var spelling: String

    init(id: UUID = UUID(), kind: Kind, spelling: String) {
        self.id = id
        self.kind = kind
        self.spelling = spelling
    }

    var isFolderBreak: Bool { kind == .text && (spelling == "/" || spelling == "\\") }

    private static let decorationPrefixes: Set<Character> = ["-", "{", " ", ".", "_", "[", "("]
    private static let decorationSuffixes: Set<Character> = ["-", "}", " ", ".", "_", ")", "]"]

    /// Whether this block attaches directly to the block before it, so no separator
    /// is written or offered between them: an optional-prefix token such as
    /// `{-Release Group}`, a closing bracket, or a folder break.
    var attachesToPrevious: Bool {
        if isFolderBreak { return true }
        switch kind {
        case .text:
            return spelling.first.map { ")]".contains($0) } ?? false
        case .element, .unknownToken:
            let characters = Array(spelling.prefix(2))
            return characters.count == 2 && characters[0] == "{" && Self.decorationPrefixes.contains(characters[1])
        }
    }

    var attachesToNext: Bool {
        if isFolderBreak { return true }
        switch kind {
        case .text:
            return spelling.last.map { "([".contains($0) } ?? false
        case .element, .unknownToken:
            let characters = Array(spelling.suffix(2))
            // A Radarr tag (`{imdb-{ImdbId}}`) ends in `}}` because it nests, not
            // because it carries a suffix.
            let isNestedTag = spelling.hasSuffix("}}") && spelling.dropFirst().contains("{")
            return characters.count == 2 && characters[1] == "}" && Self.decorationSuffixes.contains(characters[0]) && !isNestedTag
        }
    }
}

enum ArrNamingSeparatorStyle: String, CaseIterable, Identifiable, Hashable {
    case dashes
    case spaces
    case dots

    var id: String { rawValue }

    var join: String {
        switch self {
        case .dashes: " - "
        case .spaces: " "
        case .dots: "."
        }
    }

    var title: String {
        switch self {
        case .dashes: "Dashes"
        case .spaces: "Spaces"
        case .dots: "Dots"
        }
    }
}

enum ArrNamingSeparatorState: Hashable {
    /// No boundary between two ordinary blocks, so there is nothing to choose.
    case none
    case uniform(ArrNamingSeparatorStyle)
    /// The existing format joins blocks in more than one way, or in a way none of
    /// the offered styles spell. Shown as Custom and never normalised implicitly.
    case custom
}

/// A format as blocks and the text joining them.
///
/// `leading + blocks[0] + joins[0] + blocks[1] + … + trailing` is the serialized
/// format. Parsing assigns every character of the input to exactly one of those
/// parts, which is why an untouched format round-trips exactly.
struct ArrNamingArrangement: Hashable {
    var leading: String
    var blocks: [ArrNamingBlock]
    /// `joins[i]` sits between `blocks[i]` and `blocks[i + 1]`.
    var joins: [String]
    var trailing: String

    init(leading: String = "", blocks: [ArrNamingBlock] = [], joins: [String] = [], trailing: String = "") {
        precondition(joins.count == max(blocks.count - 1, 0), "Every adjacent pair of blocks needs exactly one join.")
        self.leading = leading
        self.blocks = blocks
        self.joins = joins
        self.trailing = trailing
    }

    var serialized: String {
        var output = leading
        for (index, block) in blocks.enumerated() {
            if index > 0 { output += joins[index - 1] }
            output += block.spelling
        }
        return output + trailing
    }

    func index(of blockID: UUID) -> Int? {
        blocks.firstIndex { $0.id == blockID }
    }

    // MARK: Parsing

    static func parse(_ format: String, catalog: ArrNamingBlockCatalog) -> ArrNamingArrangement {
        enum Element {
            case block(ArrNamingBlock)
            case run(String)
        }

        let atoms = ArrNamingSyntax.atoms(of: format, dialect: catalog.dialect)
        var elements: [Element] = []
        var run = ""
        var position = 0
        while position < atoms.count {
            if let match = catalog.match(atoms, at: position) {
                if !run.isEmpty { elements.append(.run(run)); run = "" }
                let spelling = atoms[position..<(position + match.length)].map(\.spelling).joined()
                elements.append(.block(ArrNamingBlock(kind: .element(definitionID: match.definitionID), spelling: spelling)))
                position += match.length
            } else if case .token(let token) = atoms[position] {
                if !run.isEmpty { elements.append(.run(run)); run = "" }
                elements.append(.block(ArrNamingBlock(kind: .unknownToken, spelling: token.spelling)))
                position += 1
            } else {
                run += atoms[position].spelling
                position += 1
            }
        }
        if !run.isEmpty { elements.append(.run(run)) }

        var leading = ""
        var blocks: [ArrNamingBlock] = []
        var joins: [String] = []
        var pending = ""

        func place(_ block: ArrNamingBlock, after separator: String) {
            if blocks.isEmpty {
                leading += separator
            } else {
                joins.append(separator)
            }
            blocks.append(block)
        }

        for element in elements {
            switch element {
            case .block(let block):
                place(block, after: pending)
                pending = ""
            case .run(let text):
                let head = text.prefix { isSeparatorCharacter($0) }
                guard head.count < text.count else {
                    pending += text
                    continue
                }
                let tail = text.reversed().prefix { isSeparatorCharacter($0) }.count
                let core = text.dropFirst(head.count).dropLast(tail)
                place(ArrNamingBlock(kind: .text, spelling: String(core)), after: pending + head)
                pending = String(text.suffix(tail))
            }
        }

        return ArrNamingArrangement(leading: leading, blocks: blocks, joins: joins, trailing: pending)
    }

    /// Characters that only ever *join* blocks. Everything else in a literal run is
    /// text the person wrote and becomes a visible block.
    static func isSeparatorCharacter(_ character: Character) -> Bool {
        character == " " || character == "-" || character == "." || character == "_"
    }

    // MARK: Separators

    /// A boundary a separator style applies to: two ordinary blocks, neither of
    /// which carries its own punctuation. Joins touching text, brackets, folder
    /// breaks or optional-prefix tokens belong to that punctuation instead.
    func isStyledBoundary(_ joinIndex: Int) -> Bool {
        let left = blocks[joinIndex]
        let right = blocks[joinIndex + 1]
        return left.kind != .text && right.kind != .text && !left.attachesToNext && !right.attachesToPrevious
    }

    var separatorState: ArrNamingSeparatorState {
        let styled = joins.indices.filter(isStyledBoundary).map { joins[$0] }
        guard let first = styled.first else { return .none }
        guard styled.allSatisfy({ $0 == first }),
              let style = ArrNamingSeparatorStyle.allCases.first(where: { $0.join == first }) else {
            return .custom
        }
        return .uniform(style)
    }

    /// The join a newly created boundary gets: the uniform style when there is one,
    /// otherwise the most common existing styled join, otherwise the default.
    func preferredJoin(default defaultStyle: ArrNamingSeparatorStyle) -> String {
        switch separatorState {
        case .uniform(let style):
            return style.join
        case .none:
            return defaultStyle.join
        case .custom:
            let styled = joins.indices.filter(isStyledBoundary).map { joins[$0] }.filter { !$0.isEmpty }
            var counts: [String: Int] = [:]
            for join in styled { counts[join, default: 0] += 1 }
            // Ties go to the earliest join, so the result does not depend on hashing.
            var best: String?
            for join in styled where best == nil || counts[join, default: 0] > counts[best!, default: 0] {
                best = join
            }
            return best ?? defaultStyle.join
        }
    }

    /// Replaces every styled join. Punctuation that belongs to text, brackets,
    /// folder breaks and optional tokens is left exactly as it was.
    func applyingSeparator(_ style: ArrNamingSeparatorStyle) -> ArrNamingArrangement {
        var result = self
        for index in joins.indices where isStyledBoundary(index) {
            result.joins[index] = style.join
        }
        return result
    }

    // MARK: Mutations

    /// Inserts `block` so it ends up at `index`. An existing join is reused where it
    /// still separates the same kind of boundary; attached punctuation gets none.
    func inserting(_ block: ArrNamingBlock, at index: Int, defaultSeparator: ArrNamingSeparatorStyle) -> ArrNamingArrangement {
        let index = min(max(index, 0), blocks.count)
        let preferred = preferredJoin(default: defaultSeparator)
        var result = self
        result.blocks.insert(block, at: index)
        guard !blocks.isEmpty else { return result }

        func join(_ left: ArrNamingBlock, _ right: ArrNamingBlock, reusing existing: String?) -> String {
            if left.attachesToNext || right.attachesToPrevious { return "" }
            if let existing, !existing.isEmpty { return existing }
            return preferred
        }

        if index == 0 {
            result.joins.insert(join(block, blocks[0], reusing: nil), at: 0)
        } else if index == blocks.count {
            result.joins.append(join(blocks[index - 1], block, reusing: nil))
        } else {
            let existing = joins[index - 1]
            result.joins[index - 1] = join(blocks[index - 1], block, reusing: existing)
            result.joins.insert(join(block, blocks[index], reusing: existing), at: index)
        }
        return result
    }

    func removing(_ blockID: UUID, defaultSeparator: ArrNamingSeparatorStyle) -> ArrNamingArrangement {
        guard let index = index(of: blockID) else { return self }
        var result = self
        result.blocks.remove(at: index)
        guard !joins.isEmpty else { return result }

        if index == 0 {
            result.joins.remove(at: 0)
        } else if index == blocks.count - 1 {
            result.joins.remove(at: index - 1)
        } else {
            // The joins either side of the removed block collapse into one between
            // its neighbours, keeping whichever still describes that boundary.
            let removed = blocks[index]
            let left = blocks[index - 1]
            let right = blocks[index + 1]
            let before = joins[index - 1]
            let after = joins[index]
            result.joins.remove(at: index)
            if left.attachesToNext || right.attachesToPrevious {
                result.joins[index - 1] = ""
            } else if !before.isEmpty, !removed.attachesToPrevious {
                result.joins[index - 1] = before
            } else if !after.isEmpty, !removed.attachesToNext {
                result.joins[index - 1] = after
            } else {
                result.joins[index - 1] = preferredJoin(default: defaultSeparator)
            }
        }
        return result
    }

    /// Moves a block so it ends up at `destination` in the resulting order.
    func moving(_ blockID: UUID, to destination: Int, defaultSeparator: ArrNamingSeparatorStyle) -> ArrNamingArrangement {
        guard let source = index(of: blockID) else { return self }
        let destination = min(max(destination, 0), blocks.count - 1)
        guard destination != source else { return self }
        return removing(blockID, defaultSeparator: defaultSeparator)
            .inserting(blocks[source], at: destination, defaultSeparator: defaultSeparator)
    }

    func replacingSpelling(of blockID: UUID, with spelling: String, kind: ArrNamingBlock.Kind? = nil) -> ArrNamingArrangement {
        guard let index = index(of: blockID) else { return self }
        var result = self
        result.blocks[index].spelling = spelling
        if let kind { result.blocks[index].kind = kind }
        return result
    }
}

// MARK: - Undo history

/// Snapshots of an arrangement. Every committed action is one step, however many
/// intermediate positions a drag visited, because only the drop commits.
struct ArrNamingDraftHistory: Hashable {
    private(set) var current: ArrNamingArrangement
    private(set) var undoStack: [ArrNamingArrangement] = []
    private(set) var redoStack: [ArrNamingArrangement] = []

    init(_ arrangement: ArrNamingArrangement) {
        current = arrangement
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Records `next`. An identical arrangement is not a step, so a drop back where
    /// a block started leaves nothing to undo.
    mutating func commit(_ next: ArrNamingArrangement) {
        guard next != current else { return }
        undoStack.append(current)
        current = next
        redoStack.removeAll()
    }

    mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(current)
        current = previous
    }

    mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(current)
        current = next
    }
}

// MARK: - Block catalog

struct ArrNamingBlockVariant: Identifiable, Hashable {
    let spelling: String
    var id: String { spelling }
}

struct ArrNamingBlockDefinition: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String
    /// The token catalog group it belongs with, used to group less common blocks.
    let group: String
    let isCommon: Bool
    let variants: [ArrNamingBlockVariant]
}

struct ArrNamingBlockGroup: Identifiable, Hashable {
    let title: String
    let definitions: [ArrNamingBlockDefinition]
    var id: String { title }
}

/// The friendly blocks one format field offers, built from `ArrNamingTokenCatalog`
/// so labels, samples and field restrictions come from one place.
struct ArrNamingBlockCatalog {
    let target: ArrNamingFormatEditorTarget
    let definitions: [ArrNamingBlockDefinition]

    private let patterns: [(definitionID: String, atoms: [ArrNamingSyntaxAtom])]

    init(target: ArrNamingFormatEditorTarget) {
        self.target = target
        let dialect = ArrNamingSyntaxDialect(target.serviceType)
        let groups = target.tokenGroups
        let offered = Set(groups.flatMap(\.tokens).map { $0.value.lowercased() })
        let common = Self.commonDefinitionIDs(for: target)

        // A variant is offered only when this field's catalog has every token in it,
        // so a folder builder never offers an episode token.
        func isOffered(_ spelling: String) -> Bool {
            ArrNamingSyntax.tokens(in: spelling, dialect: dialect).allSatisfy { offered.contains($0.spelling.lowercased()) }
        }

        var definitions: [ArrNamingBlockDefinition] = []
        for template in Self.friendlyTemplates where template.isOffered(target) {
            let variants = template.variants.filter(isOffered).map(ArrNamingBlockVariant.init)
            guard !variants.isEmpty else { continue }
            definitions.append(ArrNamingBlockDefinition(
                id: template.id,
                title: template.title,
                systemImage: template.systemImage,
                group: template.group,
                isCommon: common.contains(template.id),
                variants: variants
            ))
        }

        // Every other catalog token stays reachable as its own less common block.
        let covered = Set(definitions.flatMap(\.variants).map { $0.spelling.lowercased() })
        for group in groups {
            for token in group.tokens where !covered.contains(token.value.lowercased()) {
                let id = "token:\(token.value.lowercased())"
                guard !definitions.contains(where: { $0.id == id }) else { continue }
                definitions.append(ArrNamingBlockDefinition(
                    id: id,
                    title: token.title,
                    systemImage: token.systemImage,
                    group: group.title,
                    isCommon: false,
                    variants: [ArrNamingBlockVariant(spelling: token.value)]
                ))
            }
        }
        self.definitions = definitions

        self.patterns = definitions
            .flatMap { definition in
                definition.variants.map { (definitionID: definition.id, atoms: ArrNamingSyntax.atoms(of: $0.spelling, dialect: dialect)) }
            }
            .sorted { $0.atoms.count > $1.atoms.count }
    }

    var dialect: ArrNamingSyntaxDialect { ArrNamingSyntaxDialect(target.serviceType) }

    var commonDefinitions: [ArrNamingBlockDefinition] {
        let order = Self.commonDefinitionIDs(for: target)
        return definitions
            .filter(\.isCommon)
            .sorted { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
    }

    /// Less common blocks, grouped in the token catalog's own order.
    var additionalGroups: [ArrNamingBlockGroup] {
        let rest = definitions.filter { !$0.isCommon }
        var titles: [String] = []
        for definition in rest where !titles.contains(definition.group) {
            titles.append(definition.group)
        }
        return titles.map { title in
            ArrNamingBlockGroup(title: title, definitions: rest.filter { $0.group == title })
        }
    }

    func definition(id: String) -> ArrNamingBlockDefinition? {
        definitions.first { $0.id == id }
    }

    func definition(for block: ArrNamingBlock) -> ArrNamingBlockDefinition? {
        guard case .element(let id) = block.kind else { return nil }
        return definition(id: id)
    }

    var isFolderFormat: Bool { target.isFolderFormat }

    /// Folders are usually a title and little else, where a dash would be odd;
    /// files follow the servers' own ` - ` defaults.
    var defaultSeparator: ArrNamingSeparatorStyle { isFolderFormat ? .spaces : .dashes }

    /// Illustrative only: the servers add the real extension, and it is never saved.
    var previewFileExtension: String? { isFolderFormat ? nil : ".mkv" }

    func render(_ format: String) -> ArrNamingRenderedFormat {
        ArrNamingFormatPreview.render(format, groups: target.tokenGroups, dialect: dialect)
    }

    // MARK: Presentation

    func title(for block: ArrNamingBlock) -> String {
        switch block.kind {
        case .element: definition(for: block)?.title ?? "Custom"
        case .unknownToken: "Custom"
        case .text: block.isFolderBreak ? "Subfolder" : "Text"
        }
    }

    func systemImage(for block: ArrNamingBlock) -> String {
        switch block.kind {
        case .element: definition(for: block)?.systemImage ?? "curlybraces"
        case .unknownToken: "curlybraces"
        case .text: block.isFolderBreak ? "folder" : "textformat"
        }
    }

    /// What this block writes into a filename, using the catalog's sample values.
    func sample(for block: ArrNamingBlock) -> String {
        switch block.kind {
        case .text: text(of: block)
        case .element, .unknownToken: sample(forSpelling: block.spelling)
        }
    }

    func sample(forSpelling spelling: String) -> String {
        render(spelling).text
    }

    /// A text block's literal output. Sonarr writes `{{` as `{`; Radarr has no escape.
    func text(of block: ArrNamingBlock) -> String {
        guard dialect == .sonarr else { return block.spelling }
        return block.spelling.replacingOccurrences(of: "{{", with: "{").replacingOccurrences(of: "}}", with: "}")
    }

    /// The spelling for text a person typed. Braces are escaped for Sonarr so they
    /// stay literal; Radarr cannot escape them, so they are dropped.
    func spelling(forText text: String) -> String {
        switch dialect {
        case .sonarr:
            text.replacingOccurrences(of: "{", with: "{{").replacingOccurrences(of: "}", with: "}}")
        case .radarr:
            text.filter { $0 != "{" && $0 != "}" }
        }
    }

    /// The variant a block currently spells, compared the way the server compares
    /// tokens. Nil for a decorated or otherwise customised spelling.
    func selectedVariant(for block: ArrNamingBlock) -> ArrNamingBlockVariant? {
        definition(for: block)?.variants.first { $0.spelling.lowercased() == block.spelling.lowercased() }
    }

    /// The spelling a block gets when a person picks `variant`. A single decorated,
    /// re-separated, re-cased or truncated token (`{[Quality Full]}`,
    /// `{Series.Title}`, `{Episode Title:30}`) keeps that styling on the new token;
    /// everything else takes the variant as written. A number format is not carried
    /// over, since choosing an unpadded variant means exactly that.
    func spelling(for block: ArrNamingBlock, choosing variant: ArrNamingBlockVariant) -> String {
        let current = ArrNamingSyntax.pieces(of: block.spelling, dialect: dialect)
        let chosen = ArrNamingSyntax.pieces(of: variant.spelling, dialect: dialect)
        guard current.count == 1, case .token(let existing) = current[0],
              chosen.count == 1, case .token(let replacement) = chosen[0], !replacement.isDecorated,
              existing.isDecorated || !existing.separator.isEmpty && existing.separator != " "
                || existing.caseStyle != .asWritten || existing.hasOption else {
            return variant.spelling
        }

        var name = replacement.name
        let separator = existing.separator
        if !separator.isEmpty, separator != " " {
            name = name.replacingOccurrences(of: " ", with: separator)
        }
        switch existing.caseStyle {
        case .asWritten: break
        case .lowercase: name = name.lowercased()
        case .uppercase: name = name.uppercased()
        }
        let carriedOption = existing.hasOption ? existing.format : nil
        let format = (replacement.format ?? carriedOption).map { ":\($0)" } ?? ""
        return "{\(existing.prefix)\(name)\(format)\(existing.suffix)}"
    }

    // MARK: Recognition

    /// The longest catalog variant starting at `position`. Tokens compare without
    /// regard to case, as the servers match them; literal text must match exactly.
    /// A single token that differs only in decoration, separator, case or an option
    /// the variant does not set (`{[Quality Full]}`, `{Series.Title}`,
    /// `{Episode Title:30}`) is recognised as its plain variant, with its own
    /// spelling left untouched.
    func match(_ atoms: [ArrNamingSyntaxAtom], at position: Int) -> (definitionID: String, length: Int)? {
        for pattern in patterns where position + pattern.atoms.count <= atoms.count {
            let candidate = atoms[position..<(position + pattern.atoms.count)]
            if zip(candidate, pattern.atoms).allSatisfy(Self.atomsMatch) {
                return (pattern.definitionID, pattern.atoms.count)
            }
        }
        guard case .token(let token) = atoms[position] else { return nil }
        for pattern in patterns where pattern.atoms.count == 1 {
            if case .token(let variant) = pattern.atoms[0], !variant.isDecorated,
               variant.normalizedName == token.normalizedName,
               variant.format == nil || variant.format == token.format {
                return (pattern.definitionID, 1)
            }
        }
        return nil
    }

    private static func atomsMatch(_ lhs: ArrNamingSyntaxAtom, _ rhs: ArrNamingSyntaxAtom) -> Bool {
        switch (lhs, rhs) {
        case (.token(let a), .token(let b)): a.spelling.lowercased() == b.spelling.lowercased()
        default: lhs == rhs
        }
    }

    // MARK: Friendly templates

    private enum FieldScope {
        case any
        case folders
        case files
    }

    private struct Template {
        let id: String
        let title: String
        let systemImage: String
        let group: String
        let scope: FieldScope
        /// Spellings checked against upstream `FileNameBuilder`; each is dropped for
        /// any field whose token catalog lacks one of its tokens.
        let variants: [String]

        func isOffered(_ target: ArrNamingFormatEditorTarget) -> Bool {
            switch scope {
            case .any: true
            case .folders: target.isFolderFormat
            case .files: !target.isFolderFormat
            }
        }
    }

    private static let friendlyTemplates: [Template] = [
        Template(id: "showName", title: "Show name", systemImage: "tv", group: "Series", scope: .any, variants: [
            "{Series Title}", "{Series TitleYear}", "{Series CleanTitle}", "{Series TitleThe}"
        ]),
        Template(id: "movieName", title: "Movie name", systemImage: "film", group: "Movie", scope: .any, variants: [
            "{Movie Title}", "{Movie CleanTitle}", "{Movie TitleThe}", "{Movie OriginalTitle}"
        ]),
        Template(id: "seasonNumber", title: "Season number", systemImage: "number", group: "Season", scope: .folders, variants: [
            "Season {season:00}", "Season {Season}"
        ]),
        Template(id: "episodeNumber", title: "Episode number", systemImage: "number.square", group: "Episode", scope: .files, variants: [
            "S{season:00}E{episode:00}", "{season}x{episode:00}"
        ]),
        Template(id: "absoluteNumber", title: "Absolute number", systemImage: "number", group: "Episode", scope: .files, variants: [
            "{absolute:000}", "{Absolute}"
        ]),
        Template(id: "airDate", title: "Air date", systemImage: "calendar", group: "Episode", scope: .files, variants: [
            "{Air-Date}", "{Air Date}"
        ]),
        Template(id: "episodeTitle", title: "Episode title", systemImage: "quote.bubble", group: "Episode", scope: .files, variants: [
            "{Episode CleanTitle}", "{Episode Title}"
        ]),
        Template(id: "year", title: "Year", systemImage: "calendar", group: "Year", scope: .any, variants: [
            "({Release Year})", "{Release Year}", "({Series Year})", "{Series Year}"
        ]),
        Template(id: "quality", title: "Quality", systemImage: "sparkles.tv", group: "Quality", scope: .files, variants: [
            "{Quality Full}", "{Quality Title}"
        ]),
        Template(id: "videoInfo", title: "Video information", systemImage: "video", group: "Media Info", scope: .files, variants: [
            "{MediaInfo Simple}", "{MediaInfo Full}", "{MediaInfo VideoCodec}", "{MediaInfo VideoDynamicRangeType}"
        ]),
        Template(id: "releaseGroup", title: "Release group", systemImage: "person.2", group: "Release", scope: .files, variants: [
            "{-Release Group}", "{Release Group}"
        ])
    ]

    private static func commonDefinitionIDs(for target: ArrNamingFormatEditorTarget) -> [String] {
        switch target {
        case .sonarr(.standardEpisode):
            ["showName", "year", "episodeNumber", "episodeTitle", "quality", "videoInfo", "releaseGroup"]
        case .sonarr(.dailyEpisode):
            ["showName", "year", "airDate", "episodeTitle", "quality", "videoInfo", "releaseGroup"]
        case .sonarr(.animeEpisode):
            ["showName", "year", "absoluteNumber", "episodeNumber", "episodeTitle", "quality", "videoInfo", "releaseGroup"]
        case .sonarr(.seriesFolder):
            ["showName", "year"]
        case .sonarr(.seasonFolder), .sonarr(.specialsFolder):
            ["seasonNumber", "showName"]
        case .radarr(.standardMovie):
            ["movieName", "year", "quality", "videoInfo", "releaseGroup"]
        case .radarr(.movieFolder):
            ["movieName", "year"]
        }
    }
}

extension ArrNamingFormatEditorTarget {
    var isFolderFormat: Bool {
        switch self {
        case .sonarr(let field):
            switch field {
            case .standardEpisode, .dailyEpisode, .animeEpisode: false
            case .seriesFolder, .seasonFolder, .specialsFolder: true
            }
        case .radarr(let field):
            field == .movieFolder
        }
    }
}
