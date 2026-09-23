import Foundation

/// Anything a list's search field can filter.
///
/// The type supplies the text worth searching; the matching rule lives in one
/// place so Containers, Images, Volumes and Networks cannot drift into
/// behaving differently.
public protocol Searchable {
    /// The fields this item can be found by, in no particular order.
    var searchableText: [String] { get }
}

extension Searchable {
    /// Whether this item matches what was typed.
    ///
    /// Every whitespace-separated word must appear somewhere, in any field and
    /// in any order, so "nginx 80" finds the nginx container publishing port
    /// 80 without the user having to know which column holds which. Matching
    /// ignores case and diacritics, because typing `café` to find `cafe` — or
    /// the reverse — is not a distinction anyone wants enforced here.
    public func matches(_ query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return true }
        let haystack = searchableText
        return terms.allSatisfy { term in
            haystack.contains { $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}

extension Collection where Element: Searchable {
    /// The elements matching `query`, or all of them when nothing is typed.
    public func matching(_ query: String) -> [Element] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Array(self) }
        return filter { $0.matches(trimmed) }
    }
}

extension ContainerItem: Searchable {
    public var searchableText: [String] {
        // Status is included so "running" works as a filter, which is the first
        // thing people try.
        var text = [id, image, status.rawValue]
        // The port mapping's id reads "0.0.0.0:8080->80/tcp", so either side of
        // the arrow is findable by typing the number.
        text.append(contentsOf: ports.map(\.id))
        text.append(contentsOf: networks.map(\.ipv4Address))
        text.append(contentsOf: networks.map(\.network))
        text.append(contentsOf: labels.map { "\($0.key)=\($0.value)" })
        return text
    }
}

extension ImageItem: Searchable {
    public var searchableText: [String] {
        [reference, displayReference, digest]
    }
}

extension VolumeItem: Searchable {
    public var searchableText: [String] {
        [name, driver, source]
    }
}

extension NetworkItem: Searchable {
    public var searchableText: [String] {
        [name, mode.title, subnet, gateway].compactMap { $0 }
    }
}

extension ImageItem {
    /// A tag that sorts sensibly: untagged images collect at the end rather
    /// than at the top, where an empty string would put them.
    public var sortableTag: String { tag ?? "\u{10FFFF}" }
}

extension ContainerItem {
    /// Containers that have never run sort as oldest, so the ones that started
    /// most recently stay together at one end of the column.
    public var sortableStartDate: Date { startedAt ?? .distantPast }
}
