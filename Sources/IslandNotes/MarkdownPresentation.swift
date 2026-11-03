import Foundation

enum MarkdownPresentation {
    struct Marker: Equatable {
        let range: NSRange
        let preserveWidth: Bool
    }

    struct TaskInfo: Equatable {
        let indentLength: Int
        let markerLocation: Int
        let stateLocation: Int
        let contentOffset: Int
        let isCompleted: Bool
    }

    struct BulletInfo: Equatable {
        let indentLength: Int
        let markerLocation: Int
        let contentOffset: Int
        let bullet: Character
    }

    struct QuoteInfo: Equatable {
        let indentLength: Int
        let markerLocation: Int
        let contentOffset: Int
    }

    struct OrderedListInfo: Equatable {
        let indentLength: Int
        let number: Int
        let contentOffset: Int
    }

    struct TaskToggle: Equatable {
        let range: NSRange
        let replacement: String
        let lineLocation: Int
        let indentLength: Int

        init(range: NSRange, replacement: String, lineLocation: Int, indentLength: Int = 0) {
            self.range = range
            self.replacement = replacement
            self.lineLocation = lineLocation
            self.indentLength = indentLength
        }
    }

    struct PinnedTaskItem: Equatable, Sendable {
        let displayText: String
        let lineLocation: Int
        let stateLocation: Int
    }

    struct NoteTaskOverview: Equatable, Sendable {
        let firstUnchecked: PinnedTaskItem?
        let uncheckedCount: Int
        let completedCount: Int

        var totalCount: Int { uncheckedCount + completedCount }

        static let empty = NoteTaskOverview(firstUnchecked: nil, uncheckedCount: 0, completedCount: 0)
    }

    enum LinePrefixKind: Equatable {
        case heading(level: Int)
        case task(completed: Bool)
        case bullet(Character)
        case quote
    }

    struct LinePrefix: Equatable {
        let kind: LinePrefixKind
        let lineRange: NSRange
        let indentLength: Int
        let prefixRange: NSRange
        let contentStart: Int
    }

    enum InlineKind: Equatable {
        case bold
        case italic
        case boldItalic
        case code
        case strikethrough
        case link
    }

    struct InlineSpan: Equatable {
        let kind: InlineKind
        let fullRange: NSRange
        let openRange: NSRange
        let innerRange: NSRange
        let closeRange: NSRange
    }

    struct ScopedAnalysis {
        var headings: [(range: NSRange, level: Int)] = []
        var boldRanges: [NSRange] = []
        var italicRanges: [NSRange] = []
        var codeRanges: [NSRange] = []
        var strikethroughRanges: [NSRange] = []
        var linkLabelRanges: [NSRange] = []
        var markers: [Marker] = []
        var linePrefixes: [LinePrefix] = []
        var inlineSpans: [InlineSpan] = []
    }

    private static let boldItalicRegex = try! NSRegularExpression(pattern: #"\*\*\*([^*\n]+)\*\*\*"#)
    private static let boldRegex = try! NSRegularExpression(
        pattern: #"\*\*([^*\n]+)\*\*|(?<![A-Za-z0-9_])__([^_\n]+)__(?![A-Za-z0-9_])"#
    )
    private static let italicRegex = try! NSRegularExpression(
        pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)|(?<![A-Za-z0-9_])_([^_\n]+)_(?![A-Za-z0-9_])"#
    )
    private static let codeRegex = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)
    private static let strikethroughRegex = try! NSRegularExpression(pattern: #"~~([^~\n]+)~~"#)
    private static let linkRegex = try! NSRegularExpression(pattern: #"\[([^]\n]+)\]\(([^)\n]+)\)"#)

    static func leadingIndentLength(in line: String) -> Int {
        var utf16Count = 0
        for ch in line {
            if ch == " " || ch == "\t" {
                utf16Count += ch.utf16.count
            } else {
                break
            }
        }
        return utf16Count
    }

    static func headingLevel(in line: String) -> Int? {
        let count = line.prefix(while: { $0 == "#" }).count
        return (1...6).contains(count) && line.dropFirst(count).hasPrefix(" ") ? count : nil
    }

    static func taskInfo(in line: String) -> TaskInfo? {
        var index = line.startIndex
        var indentUTF16 = 0
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            indentUTF16 += line[index].utf16.count
            index = line.index(after: index)
        }
        let remainder = line[index...]
        guard let bullet = remainder.first, bullet == "-" || bullet == "*" || bullet == "+" else {
            return nil
        }
        let afterBullet = remainder.dropFirst()
        guard afterBullet.hasPrefix(" [") else { return nil }
        let afterBracket = afterBullet.dropFirst(2)
        guard let stateChar = afterBracket.first, stateChar == " " || stateChar == "x" || stateChar == "X" else {
            return nil
        }
        let afterState = afterBracket.dropFirst()
        guard afterState.hasPrefix("] ") else { return nil }
        return TaskInfo(
            indentLength: indentUTF16,
            markerLocation: indentUTF16,
            stateLocation: indentUTF16 + 3,
            contentOffset: indentUTF16 + 6,
            isCompleted: stateChar != " "
        )
    }

    static func taskCompleted(in line: String) -> Bool? {
        taskInfo(in: line)?.isCompleted
    }

    static func bulletInfo(in line: String) -> BulletInfo? {
        guard taskInfo(in: line) == nil else { return nil }
        var index = line.startIndex
        var indentUTF16 = 0
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            indentUTF16 += line[index].utf16.count
            index = line.index(after: index)
        }
        let remainder = line[index...]
        guard let bullet = remainder.first, bullet == "-" || bullet == "*" || bullet == "+" else {
            return nil
        }
        guard remainder.dropFirst().hasPrefix(" ") else { return nil }
        return BulletInfo(
            indentLength: indentUTF16,
            markerLocation: indentUTF16,
            contentOffset: indentUTF16 + 2,
            bullet: bullet
        )
    }

    static func quoteInfo(in line: String) -> QuoteInfo? {
        var index = line.startIndex
        var indentUTF16 = 0
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            indentUTF16 += line[index].utf16.count
            index = line.index(after: index)
        }
        let remainder = line[index...]
        guard remainder.hasPrefix("> ") else { return nil }
        return QuoteInfo(
            indentLength: indentUTF16,
            markerLocation: indentUTF16,
            contentOffset: indentUTF16 + 2
        )
    }

    static func orderedListInfo(in line: String) -> OrderedListInfo? {
        var index = line.startIndex
        var indentUTF16 = 0
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            indentUTF16 += line[index].utf16.count
            index = line.index(after: index)
        }
        let remainder = line[index...]
        let digits = remainder.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, digits.count <= 6, let number = Int(digits) else { return nil }
        let afterDigits = remainder.dropFirst(digits.count)
        guard afterDigits.hasPrefix(". ") else { return nil }
        return OrderedListInfo(
            indentLength: indentUTF16,
            number: number,
            contentOffset: indentUTF16 + digits.utf16.count + 2
        )
    }

    static func taskToggle(in text: String, at location: Int) -> TaskToggle? {
        let source = text as NSString
        guard source.length > 0, location >= 0, location <= source.length else { return nil }
        let clamped = min(location, source.length - 1)
        let lineRange = source.lineRange(for: NSRange(location: clamped, length: 0))
        let line = source.substring(with: lineRange)
        guard let info = taskInfo(in: line) else { return nil }
        return TaskToggle(
            range: NSRange(location: lineRange.location + info.stateLocation, length: 1),
            replacement: info.isCompleted ? " " : "x",
            lineLocation: lineRange.location,
            indentLength: info.indentLength
        )
    }

    static func activeLineRange(in source: NSString, selection: NSRange) -> NSRange {
        guard source.length > 0 else { return NSRange(location: 0, length: 0) }
        let location = min(max(0, selection.location), source.length)
        let length = min(max(0, selection.length), source.length - location)
        return source.lineRange(for: NSRange(location: location, length: length))
    }

    static func analyzeLine(in text: String, source: NSString, at location: Int) -> ScopedAnalysis {
        guard source.length > 0 else { return ScopedAnalysis() }
        let clamped = min(max(0, location), source.length)
        let lineRange = source.lineRange(for: NSRange(location: clamped, length: 0))
        return analyze(in: text, source: source, range: lineRange)
    }

    static func analyze(
        in text: String,
        source: NSString,
        range: NSRange,
        activeLine: NSRange = NSRange(location: NSNotFound, length: 0)
    ) -> ScopedAnalysis {
        var result = ScopedAnalysis()
        guard range.length > 0, NSMaxRange(range) <= source.length else { return result }

        source.enumerateSubstrings(in: range, options: .byLines) { line, lineRange, _, _ in
            guard let line else { return }
            if let heading = headingLevel(in: line) {
                let prefixLen = heading + 1
                result.headings.append((lineRange, heading))
                result.markers.append(
                    Marker(range: NSRange(location: lineRange.location, length: prefixLen), preserveWidth: false)
                )
                result.linePrefixes.append(
                    LinePrefix(
                        kind: .heading(level: heading),
                        lineRange: lineRange,
                        indentLength: 0,
                        prefixRange: NSRange(location: lineRange.location, length: prefixLen),
                        contentStart: lineRange.location + prefixLen
                    )
                )
            } else if let task = taskInfo(in: line) {
                result.markers.append(
                    Marker(
                        range: NSRange(location: lineRange.location + task.markerLocation, length: 5),
                        preserveWidth: true
                    )
                )
                result.linePrefixes.append(
                    LinePrefix(
                        kind: .task(completed: task.isCompleted),
                        lineRange: lineRange,
                        indentLength: task.indentLength,
                        prefixRange: NSRange(location: lineRange.location + task.indentLength, length: 6),
                        contentStart: lineRange.location + task.contentOffset
                    )
                )
            } else if let bullet = bulletInfo(in: line) {
                result.markers.append(
                    Marker(
                        range: NSRange(location: lineRange.location + bullet.markerLocation, length: 1),
                        preserveWidth: true
                    )
                )
                result.linePrefixes.append(
                    LinePrefix(
                        kind: .bullet(bullet.bullet),
                        lineRange: lineRange,
                        indentLength: bullet.indentLength,
                        prefixRange: NSRange(location: lineRange.location + bullet.indentLength, length: 2),
                        contentStart: lineRange.location + bullet.contentOffset
                    )
                )
            } else if let quote = quoteInfo(in: line) {
                result.markers.append(
                    Marker(
                        range: NSRange(location: lineRange.location + quote.markerLocation, length: 1),
                        preserveWidth: true
                    )
                )
                result.linePrefixes.append(
                    LinePrefix(
                        kind: .quote,
                        lineRange: lineRange,
                        indentLength: quote.indentLength,
                        prefixRange: NSRange(location: lineRange.location + quote.indentLength, length: 2),
                        contentStart: lineRange.location + quote.contentOffset
                    )
                )
            }
        }

        for match in codeRegex.matches(in: text, range: range) {
            let openRange = NSRange(location: match.range.location, length: 1)
            let closeRange = NSRange(location: NSMaxRange(match.range) - 1, length: 1)
            let innerRange = match.range(at: 1)
            result.codeRanges.append(match.range)
            result.markers.append(Marker(range: openRange, preserveWidth: false))
            result.markers.append(Marker(range: closeRange, preserveWidth: false))
            result.inlineSpans.append(
                InlineSpan(
                    kind: .code,
                    fullRange: match.range,
                    openRange: openRange,
                    innerRange: innerRange,
                    closeRange: closeRange
                )
            )
        }

        var linkDestinationRanges: [NSRange] = []
        for match in linkRegex.matches(in: text, range: range) {
            guard !intersectsAny(match.range, in: result.codeRanges) else { continue }
            let openRange = NSRange(location: match.range.location, length: 1)
            let labelRange = match.range(at: 1)
            let labelEnd = NSMaxRange(labelRange)
            let tailRange = NSRange(location: labelEnd, length: NSMaxRange(match.range) - labelEnd)
            linkDestinationRanges.append(tailRange)
            result.linkLabelRanges.append(labelRange)
            result.markers.append(Marker(range: openRange, preserveWidth: false))
            result.markers.append(Marker(range: tailRange, preserveWidth: false))
            result.inlineSpans.append(
                InlineSpan(
                    kind: .link,
                    fullRange: match.range,
                    openRange: openRange,
                    innerRange: labelRange,
                    closeRange: tailRange
                )
            )
        }

        var boldItalicRanges: [NSRange] = []
        for match in boldItalicRegex.matches(in: text, range: range) {
            guard !intersectsAny(match.range, in: result.codeRanges),
                  !intersectsAny(match.range, in: linkDestinationRanges) else { continue }
            let openRange = NSRange(location: match.range.location, length: 3)
            let closeRange = NSRange(location: NSMaxRange(match.range) - 3, length: 3)
            let innerRange = match.range(at: 1)
            boldItalicRanges.append(match.range)
            result.boldRanges.append(match.range)
            result.italicRanges.append(match.range)
            result.markers.append(Marker(range: openRange, preserveWidth: false))
            result.markers.append(Marker(range: closeRange, preserveWidth: false))
            result.inlineSpans.append(
                InlineSpan(
                    kind: .boldItalic,
                    fullRange: match.range,
                    openRange: openRange,
                    innerRange: innerRange,
                    closeRange: closeRange
                )
            )
        }

        for match in boldRegex.matches(in: text, range: range) {
            guard !intersectsAny(match.range, in: result.codeRanges),
                  !intersectsAny(match.range, in: linkDestinationRanges),
                  !intersectsAny(match.range, in: boldItalicRanges) else { continue }
            let openRange = NSRange(location: match.range.location, length: 2)
            let closeRange = NSRange(location: NSMaxRange(match.range) - 2, length: 2)
            let innerRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            result.boldRanges.append(match.range)
            result.markers.append(Marker(range: openRange, preserveWidth: false))
            result.markers.append(Marker(range: closeRange, preserveWidth: false))
            result.inlineSpans.append(
                InlineSpan(
                    kind: .bold,
                    fullRange: match.range,
                    openRange: openRange,
                    innerRange: innerRange,
                    closeRange: closeRange
                )
            )
        }

        for match in italicRegex.matches(in: text, range: range) {
            guard !intersectsAny(match.range, in: result.codeRanges),
                  !intersectsAny(match.range, in: linkDestinationRanges),
                  !intersectsAny(match.range, in: boldItalicRanges) else { continue }
            let openRange = NSRange(location: match.range.location, length: 1)
            let closeRange = NSRange(location: NSMaxRange(match.range) - 1, length: 1)
            let innerRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            result.italicRanges.append(match.range)
            result.markers.append(Marker(range: openRange, preserveWidth: false))
            result.markers.append(Marker(range: closeRange, preserveWidth: false))
            result.inlineSpans.append(
                InlineSpan(
                    kind: .italic,
                    fullRange: match.range,
                    openRange: openRange,
                    innerRange: innerRange,
                    closeRange: closeRange
                )
            )
        }

        for match in strikethroughRegex.matches(in: text, range: range) {
            guard !intersectsAny(match.range, in: result.codeRanges),
                  !intersectsAny(match.range, in: linkDestinationRanges) else { continue }
            let openRange = NSRange(location: match.range.location, length: 2)
            let closeRange = NSRange(location: NSMaxRange(match.range) - 2, length: 2)
            let innerRange = match.range(at: 1)
            result.strikethroughRanges.append(match.range)
            result.markers.append(Marker(range: openRange, preserveWidth: false))
            result.markers.append(Marker(range: closeRange, preserveWidth: false))
            result.inlineSpans.append(
                InlineSpan(
                    kind: .strikethrough,
                    fullRange: match.range,
                    openRange: openRange,
                    innerRange: innerRange,
                    closeRange: closeRange
                )
            )
        }

        result.inlineSpans.sort { $0.fullRange.location < $1.fullRange.location }
        return result
    }

    static func markers(in text: String, activeLine: NSRange = NSRange(location: NSNotFound, length: 0)) -> [Marker] {
        let source = text as NSString
        let all = NSRange(location: 0, length: source.length)
        return analyze(in: text, source: source, range: all, activeLine: activeLine).markers
    }

    static func plainDisplayText(in rawLineBody: String) -> String {
        let trimmedRaw = rawLineBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty else { return "" }
        let source = trimmedRaw as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let analysis = analyze(in: trimmedRaw, source: source, range: fullRange)
        guard !analysis.inlineSpans.isEmpty else { return trimmedRaw }

        var removalRanges: [NSRange] = []
        removalRanges.reserveCapacity(analysis.inlineSpans.count * 2)
        for span in analysis.inlineSpans {
            if span.openRange.length > 0 { removalRanges.append(span.openRange) }
            if span.closeRange.length > 0 { removalRanges.append(span.closeRange) }
        }
        removalRanges.sort { lhs, rhs in
            if lhs.location != rhs.location { return lhs.location < rhs.location }
            return lhs.length < rhs.length
        }

        var merged: [NSRange] = []
        for range in removalRanges {
            if let last = merged.last, NSMaxRange(last) >= range.location {
                let end = max(NSMaxRange(last), NSMaxRange(range))
                merged[merged.count - 1] = NSRange(location: last.location, length: end - last.location)
            } else {
                merged.append(range)
            }
        }

        let mutable = NSMutableString(string: trimmedRaw)
        for range in merged.reversed() where NSMaxRange(range) <= mutable.length {
            mutable.deleteCharacters(in: range)
        }
        return (mutable as String).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func taskOverview(in text: String) -> NoteTaskOverview {
        let source = text as NSString
        guard source.length > 0 else { return .empty }

        var firstUnchecked: PinnedTaskItem?
        var uncheckedCount = 0
        var completedCount = 0
        var activeFenceMarker: Character?

        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: .byLines) { line, lineRange, _, _ in
            guard let line else { return }
            let trimmedLeading = line.drop(while: { $0 == " " || $0 == "\t" })
            if let firstChar = trimmedLeading.first, firstChar == "`" || firstChar == "~" {
                let fenceCount = trimmedLeading.prefix(while: { $0 == firstChar }).count
                if fenceCount >= 3 {
                    if activeFenceMarker == nil {
                        activeFenceMarker = firstChar
                        return
                    } else if activeFenceMarker == firstChar {
                        let rest = trimmedLeading.dropFirst(fenceCount).trimmingCharacters(in: .whitespaces)
                        if rest.isEmpty {
                            activeFenceMarker = nil
                            return
                        }
                    }
                }
            }
            guard activeFenceMarker == nil, let info = taskInfo(in: line) else { return }

            let nsLine = line as NSString
            guard info.contentOffset <= nsLine.length else { return }
            let rawBody = nsLine.substring(from: info.contentOffset)
            let displayText = plainDisplayText(in: rawBody)
            guard !displayText.isEmpty else { return }

            if info.isCompleted {
                completedCount += 1
            } else {
                uncheckedCount += 1
                if firstUnchecked == nil {
                    firstUnchecked = PinnedTaskItem(
                        displayText: displayText,
                        lineLocation: lineRange.location,
                        stateLocation: lineRange.location + info.stateLocation
                    )
                }
            }
        }

        return NoteTaskOverview(
            firstUnchecked: firstUnchecked,
            uncheckedCount: uncheckedCount,
            completedCount: completedCount
        )
    }

    private static func intersectsAny(_ target: NSRange, in ranges: [NSRange]) -> Bool {
        ranges.contains { NSIntersectionRange($0, target).length > 0 }
    }
}
