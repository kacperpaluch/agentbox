import Foundation

/// A counted noun in Polish takes one of three forms: 1 projekt, 3 projekty, 5 projektów — and
/// 22 projekty but 12 projektów. `"\(n) projektów"` was right only for some numbers.
public struct PolishNoun: Sendable {
    public let one: String, few: String, many: String
    public init(_ one: String, _ few: String, _ many: String) { self.one = one; self.few = few; self.many = many }

    public func form(_ count: Int) -> String {
        let last = abs(count) % 10, lastTwo = abs(count) % 100
        if count == 1 { return one }
        if (2...4).contains(last), !(12...14).contains(lastTwo) { return few }
        return many
    }
    /// "3 projekty".
    public func callAsFunction(_ count: Int) -> String { "\(count) \(form(count))" }

    // Nominative and accusative: "Usunięto 3 projekty", "3 projekty".
    public static let project = PolishNoun("projekt", "projekty", "projektów")
    public static let skill = PolishNoun("skill", "skille", "skilli")
    public static let server = PolishNoun("serwer MCP", "serwery MCP", "serwerów MCP")
    public static let document = PolishNoun("dokument", "dokumenty", "dokumentów")
    public static let item = PolishNoun("element", "elementy", "elementów")
    public static let subfolder = PolishNoun("podfolder", "podfoldery", "podfolderów")
    // Genitive, after "do", "z", a negation: "do 1 skilla", "z 3 projektów".
    public static let projectGenitive = PolishNoun("projektu", "projektów", "projektów")
    public static let skillGenitive = PolishNoun("skilla", "skilli", "skilli")
    public static let serverGenitive = PolishNoun("serwera MCP", "serwerów MCP", "serwerów MCP")
    public static let documentGenitive = PolishNoun("dokumentu", "dokumentów", "dokumentów")
}
