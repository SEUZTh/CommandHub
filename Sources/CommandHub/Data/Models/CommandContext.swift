import Foundation

struct CommandContext: Hashable {
    let url: String?
    let domain: String?
    let env: String?
    let sourceApp: String?

    init(
        url: String? = nil,
        domain: String? = nil,
        env: String? = nil,
        sourceApp: String? = nil
    ) {
        self.url = Self.normalizeURL(url)
        self.domain = Self.normalizeDomain(domain) ?? Self.normalizeDomain(from: url)
        self.env = Self.normalizeEnv(env)
        self.sourceApp = Self.normalizeValue(sourceApp)
    }

    var hasContextSignal: Bool {
        domain != nil || env != nil || sourceApp != nil
    }

    var hasFilterableScope: Bool {
        domain != nil || env != nil
    }

    var contextKey: String? {
        let components = [
            Self.normalizeSourceAppKey(sourceApp) ?? "",
            Self.normalizeDomain(domain) ?? "",
            Self.normalizeEnvKey(env) ?? ""
        ]

        guard components.contains(where: { !$0.isEmpty }) else {
            return nil
        }

        return components.joined(separator: "|")
    }

    var normalizedSourceAppKey: String? {
        Self.normalizeSourceAppKey(sourceApp)
    }

    static func normalizeValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        let lowered = trimmed.lowercased()
        guard lowered != "nil", lowered != "null" else {
            return nil
        }

        return lowered
    }

    static func normalizeEnv(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        let normalizedKey = trimmed.lowercased()
        guard normalizedKey != "nil", normalizedKey != "null" else {
            return nil
        }

        return trimmed
    }

    static func normalizeEnvKey(_ value: String?) -> String? {
        normalizeEnv(value)?.lowercased()
    }

    static func normalizeURL(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }

    static func normalizeDomain(_ value: String?) -> String? {
        guard let normalized = normalizeValue(value) else { return nil }

        var domain = normalized
        if let colonIndex = domain.firstIndex(of: ":"),
           !domain[..<colonIndex].contains("]") {
            domain = String(domain[..<colonIndex])
        }

        domain = domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domain.isEmpty ? nil : domain
    }

    static func normalizeDomain(from url: String?) -> String? {
        guard let url else { return nil }
        guard let components = URLComponents(string: url),
              let host = components.host else {
            return nil
        }

        return normalizeDomain(host)
    }

    static func normalizeSourceAppKey(_ value: String?) -> String? {
        normalizeValue(value)
    }
}
