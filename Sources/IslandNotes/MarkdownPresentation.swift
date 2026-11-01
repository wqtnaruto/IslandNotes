import Foundation

enum MarkdownPresentation {
    struct Marker: Equatable {
        let range: NSRange
        let preserveWidth: Bool
    }

    struct ScopedAnalysis {
        var headings: [(range: NSRange, level: Int)] = []
        var boldRanges: [NSRange] = []
        var italicRanges: [NSRange] = []
        var codeRanges: [NSRange] = []
        var linkLabelRanges: [NSRange] = []
        var markers: [Marker] = []
    }

    private static let boldRegex = try! NSRegularExpression(pattern: #"\*\*([^*\n]+)\*\*"#)
    private static let italicRegex = try! NSRegularExpression(pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)|_([^_\n]+)_"#)
    private static let codeRegex = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)
    private static let linkRegex = try! NSRegularExpression(pattern: #"\[([^]\n]+)\]\(([^)\n]+)\)"#)

    static func headingLevel(in line: String) -> Int? {
        let count = line.prefix(while: { $0 == "#" }).count
        return (1...6).contains(count) && line.dropFirst(count).hasPrefix(" ") ? count : nil
    }

    static func taskCompleted(in line: String) -> Bool? {
        if line.hasPrefix("- [ ] ") { return false }
        if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") { return true }
        return nil
    }

    static func taskToggle(in text: String, at location: Int) -> (range: NSRange, replacement: String)? {
        let source = text as NSString
        guard source.length > 0, location >= 0, location <= source.length else { return nil }
        let clamped = min(location, source.length - 1)
        let lineRange = source.lineRange(for: NSRange(location: clamped, length: 0))
        let line = source.substring(with: lineRange)
        guard let completed = taskCompleted(in: line) else { return nil }
        return (NSRange(location: lineRange.location + 3, length: 1), completed ? " " : "x")
    }

    static func activeLineRange(in source: NSString, selection: NSRange) -> NSRange {
        guard source.length > 0 else { return NSRange(location: 0, length: 0) }
        let location = min(max(0, selection.location), source.length)
        let length = min(max(0, selection.length), source.length - location)
        return source.lineRange(for: NSRange(location: location, length: length))
    }

    static func analyze(in text: String, source: NSString, range: NSRange, activeLine: NSRange) -> ScopedAnalysis {
        var result = ScopedAnalysis()
        guard range.length > 0, NSMaxRange(range) <= source.length else { return result }

        source.enumerateSubstrings(in: range, options: .byLines) { line, lineRange, _, _ in
            guard let line else { return }
            let heading = headingLevel(in: line)
            if let heading {
                result.headings.append((lineRange, heading))
            }
            let isInactiveLine = NSIntersectionRange(lineRange, activeLine).length == 0
                && lineRange.location != activeLine.location
            guard isInactiveLine else { return }
            if let heading {
                result.markers.append(Marker(range: NSRange(location: lineRange.location, length: heading + 1), preserveWidth: false))
            }
            if taskCompleted(in: line) != nil {
                result.markers.append(Marker(range: NSRange(location: lineRange.location, length: 5), preserveWidth: true))
            }
        }

        for match in boldRegex.matches(in: text, range: range) {
            result.boldRanges.append(match.range)
            if NSIntersectionRange(match.range, activeLine).length == 0 {
                result.markers.append(Marker(range: NSRange(location: match.range.location, length: 2), preserveWidth: false))
                result.markers.append(Marker(range: NSRange(location: NSMaxRange(match.range) - 2, length: 2), preserveWidth: false))
            }
        }

        for match in italicRegex.matches(in: text, range: range) {
            result.italicRanges.append(match.range)
            if NSIntersectionRange(match.range, activeLine).length == 0 {
                result.markers.append(Marker(range: NSRange(location: match.range.location, length: 1), preserveWidth: false))
                result.markers.append(Marker(range: NSRange(location: NSMaxRange(match.range) - 1, length: 1), preserveWidth: false))
            }
        }

        for match in codeRegex.matches(in: text, range: range) {
            result.codeRanges.append(match.range)
            if NSIntersectionRange(match.range, activeLine).length == 0 {
                result.markers.append(Marker(range: NSRange(location: match.range.location, length: 1), preserveWidth: false))
                result.markers.append(Marker(range: NSRange(location: NSMaxRange(match.range) - 1, length: 1), preserveWidth: false))
            }
        }

        for match in linkRegex.matches(in: text, range: range) {
            let labelRange = match.range(at: 1)
            result.linkLabelRanges.append(labelRange)
            if NSIntersectionRange(match.range, activeLine).length == 0 {
                let labelEnd = NSMaxRange(labelRange)
                result.markers.append(Marker(range: NSRange(location: match.range.location, length: 1), preserveWidth: false))
                result.markers.append(Marker(range: NSRange(location: labelEnd, length: NSMaxRange(match.range) - labelEnd), preserveWidth: false))
            }
        }

        return result
    }

    static func markers(in text: String, activeLine: NSRange) -> [Marker] {
        let source = text as NSString
        let all = NSRange(location: 0, length: source.length)
        return analyze(in: text, source: source, range: all, activeLine: activeLine).markers
    }
}
