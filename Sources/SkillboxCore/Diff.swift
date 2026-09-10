import Foundation

/// One line of a rendered difference between what a file holds and what a synchronization would
/// write into it.
public struct DiffLine: Hashable, Sendable, Identifiable {
    public enum Kind: Sendable { case same, added, removed, gap }
    public var kind: Kind
    public var text: String
    /// Position in the rendered list; a file can legitimately contain the same line many times.
    public var id: Int
    public init(kind: Kind, text: String, id: Int) { self.kind = kind; self.text = text; self.id = id }
}

public enum TextDiff {
    /// The difference between two texts, as lines to display.
    ///
    /// The matching itself is `CollectionDifference` from the standard library — there is no reason
    /// to write a diff algorithm here. This only turns its two lists of offsets back into one
    /// readable sequence and drops the untouched middle of long files: an `AGENTS.md` is mostly
    /// unchanged text, and the point of the view is the part that is not.
    public static func lines(old: String, new: String, context: Int = 3) -> [DiffLine] {
        let oldLines = old.isEmpty ? [] : old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = new.isEmpty ? [] : new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let difference = newLines.difference(from: oldLines)
        var removed: [Int: String] = [:], inserted: [Int: String] = [:]
        for change in difference {
            switch change {
            case .remove(let offset, let element, _): removed[offset] = element
            case .insert(let offset, let element, _): inserted[offset] = element
            }
        }
        var merged: [(kind: DiffLine.Kind, text: String)] = []
        var oldIndex = 0, newIndex = 0
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if let text = removed[oldIndex] { merged.append((.removed, text)); oldIndex += 1; continue }
            if let text = inserted[newIndex] { merged.append((.added, text)); newIndex += 1; continue }
            guard oldIndex < oldLines.count, newIndex < newLines.count else { break }
            merged.append((.same, oldLines[oldIndex])); oldIndex += 1; newIndex += 1
        }
        return collapsed(merged, context: context)
    }

    /// Replaces every run of untouched lines longer than twice `context` with a single marker,
    /// keeping `context` lines on each side of it.
    private static func collapsed(_ merged: [(kind: DiffLine.Kind, text: String)], context: Int) -> [DiffLine] {
        // Nothing changed, so there is nothing to show. An empty result says exactly that, instead
        // of a marker announcing that the whole file stayed the same.
        guard merged.contains(where: { $0.kind != .same }) else { return [] }
        var keep = Array(repeating: false, count: merged.count)
        for (index, line) in merged.enumerated() where line.kind != .same {
            for near in max(0, index - context)...min(merged.count - 1, index + context) { keep[near] = true }
        }
        var result: [DiffLine] = []
        var skipped = 0
        for (index, line) in merged.enumerated() {
            guard keep[index] else { skipped += 1; continue }
            if skipped > 0 {
                result.append(DiffLine(kind: .gap, text: "… \(skipped) \(skipped == 1 ? "linia bez zmian" : "linii bez zmian")", id: result.count))
                skipped = 0
            }
            result.append(DiffLine(kind: line.kind, text: line.text, id: result.count))
        }
        if skipped > 0 { result.append(DiffLine(kind: .gap, text: "… \(skipped) \(skipped == 1 ? "linia bez zmian" : "linii bez zmian")", id: result.count)) }
        return result
    }

    /// The difference between a file on disk and the content a synchronization would put there.
    /// An empty `content` means the file is to be removed, so everything in it counts as removed.
    public static func lines(file: String, content: String, context: Int = 3) -> [DiffLine] {
        let existing = (try? String(contentsOf: URL(fileURLWithPath: file), encoding: .utf8)) ?? ""
        return lines(old: existing, new: content, context: context)
    }
}
