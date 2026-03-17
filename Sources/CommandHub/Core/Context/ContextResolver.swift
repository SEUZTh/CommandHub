import AppKit
import Foundation

protocol ContextResolving {
    func resolve() -> ContextResolution
}

struct ContextResolution: Hashable {
    enum Status: Hashable {
        case webContext(domain: String, env: String?)
        case browserWebContextUnavailable(appName: String)
        case browserPermissionRequired(appName: String)
        case noWebContext(appName: String)
    }

    let context: CommandContext?
    let status: Status

    var statusText: String {
        switch status {
        case let .webContext(domain, env):
            if let env {
                return "Current: \(domain) (\(env))"
            }
            return "Current: \(domain)"
        case let .browserWebContextUnavailable(appName):
            return "Current: \(appName), web context unavailable"
        case .browserPermissionRequired:
            return "Browser context permission required"
        case let .noWebContext(appName):
            return "Current: \(appName), no web context"
        }
    }

    var canFilterToCurrentEnv: Bool {
        context?.hasFilterableScope == true
    }
}

final class ContextResolver: ContextResolving {
    static let shared = ContextResolver()

    private enum SupportedBrowser {
        case chrome
        case safari

        init?(application: NSRunningApplication?) {
            switch application?.bundleIdentifier?.lowercased() {
            case "com.google.chrome":
                self = .chrome
            case "com.apple.safari":
                self = .safari
            default:
                return nil
            }
        }

        var applicationName: String {
            switch self {
            case .chrome:
                return "Google Chrome"
            case .safari:
                return "Safari"
            }
        }

        var scriptSource: String {
            switch self {
            case .chrome:
                return """
                tell application "Google Chrome"
                    get URL of active tab of front window
                end tell
                """
            case .safari:
                return """
                tell application "Safari"
                    get URL of current tab of front window
                end tell
                """
            }
        }
    }

    private enum BrowserURLResult {
        case success(String)
        case permissionDenied
        case unavailable
    }

    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func resolve() -> ContextResolution {
        let frontmostApp = workspace.frontmostApplication
        let appName = frontmostApp?.localizedName ?? "Unknown"
        let sourceApp = CommandContext.normalizeSourceAppKey(
            frontmostApp?.bundleIdentifier ?? frontmostApp?.localizedName
        )

        guard let browser = SupportedBrowser(application: frontmostApp) else {
            let context = CommandContext(sourceApp: sourceApp)
            return ContextResolution(
                context: context.hasContextSignal ? context : nil,
                status: .noWebContext(appName: appName)
            )
        }

        switch readURL(from: browser) {
        case let .success(url):
            let context = buildWebContext(url: url, sourceApp: sourceApp)

            if let domain = context.domain {
                return ContextResolution(
                    context: context,
                    status: .webContext(domain: domain, env: context.env)
                )
            }

            return ContextResolution(
                context: CommandContext(sourceApp: sourceApp),
                status: .browserWebContextUnavailable(appName: appName)
            )
        case .permissionDenied:
            return ContextResolution(
                context: CommandContext(sourceApp: sourceApp),
                status: .browserPermissionRequired(appName: appName)
            )
        case .unavailable:
            return ContextResolution(
                context: CommandContext(sourceApp: sourceApp),
                status: .browserWebContextUnavailable(appName: appName)
            )
        }
    }

    static func resolveEnv(from url: String) -> String? {
        guard let components = URLComponents(string: url) else {
            return nil
        }

        if let queryEnv = components.queryItems?.first(where: { $0.name.lowercased() == "env" })?.value,
           let normalizedQueryEnv = CommandContext.normalizeEnv(queryEnv) {
            if let canonical = canonicalEnv(from: normalizedQueryEnv) {
                return canonical
            }
            return normalizedQueryEnv
        }

        let host = CommandContext.normalizeDomain(components.host)
        let hostLabels = (host ?? "").split(separator: ".").map(String.init)

        let subdomainLabels: [String]
        let remainingLabels: [String]
        if hostLabels.count > 2 {
            subdomainLabels = Array(hostLabels.dropLast(2))
            remainingLabels = Array(hostLabels.suffix(2))
        } else {
            subdomainLabels = hostLabels
            remainingLabels = []
        }

        for token in tokenize(labels: subdomainLabels) {
            if let canonical = canonicalEnv(from: token) {
                return canonical
            }
        }

        for token in tokenize(labels: remainingLabels) {
            if let canonical = canonicalEnv(from: token) {
                return canonical
            }
        }

        let pathTokens = components.path
            .split(separator: "/")
            .prefix(2)
            .flatMap { tokenize(segment: String($0)) }

        for token in pathTokens {
            if let canonical = canonicalEnv(from: token) {
                return canonical
            }
        }

        return nil
    }

    private func buildWebContext(url: String, sourceApp: String?) -> CommandContext {
        let domain = CommandContext.normalizeDomain(from: url)
        return CommandContext(
            url: url,
            domain: domain,
            env: Self.resolveEnv(from: url),
            sourceApp: sourceApp
        )
    }

    private func readURL(from browser: SupportedBrowser) -> BrowserURLResult {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: browser.scriptSource) else {
            return .unavailable
        }

        let output = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 {
                return .permissionDenied
            }
            return .unavailable
        }

        guard let url = output.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !url.isEmpty else {
            return .unavailable
        }

        return .success(url)
    }

    private static func tokenize(labels: [String]) -> [String] {
        labels.flatMap { tokenize(segment: $0) }
    }

    private static func tokenize(segment: String) -> [String] {
        segment
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { String($0).lowercased() }
    }

    private static func canonicalEnv(from rawValue: String) -> String? {
        let normalized = CommandContext.normalizeValue(rawValue)

        switch normalized {
        case "prod", "production", "prd", "live", "online":
            return "prod"
        case "staging", "stage", "stg", "pre", "preprod", "preview":
            return "staging"
        case "dev", "development", "sandbox":
            return "dev"
        case "qa":
            return "qa"
        case "test", "testing":
            return "test"
        case "uat":
            return "uat"
        case "local", "localhost", "127.0.0.1":
            return "local"
        default:
            return nil
        }
    }
}
