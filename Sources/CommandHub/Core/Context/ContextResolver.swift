import Foundation

final class ContextResolver {
    static func resolve() -> CommandContext {
        CommandContext(url: nil, env: "unknown")
    }
}
