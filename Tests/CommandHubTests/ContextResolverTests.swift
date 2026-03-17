import XCTest
@testable import CommandHub

final class ContextResolverTests: XCTestCase {
    func testResolveEnvPrefersExplicitQueryParameter() {
        let url = "https://prod.example.com/dashboard?env=stg"
        XCTAssertEqual(ContextResolver.resolveEnv(from: url), "staging")
    }

    func testResolveEnvSupportsSubdomainTokens() {
        let url = "https://api-prod-eu.example.com/pods"
        XCTAssertEqual(ContextResolver.resolveEnv(from: url), "prod")
    }

    func testResolveEnvFallsBackToPathSegments() {
        let url = "https://example.com/env/prod/dashboard"
        XCTAssertEqual(ContextResolver.resolveEnv(from: url), "prod")
    }

    func testResolveEnvAvoidsSubstringFalsePositives() {
        let url = "https://product.example.com/dashboard"
        XCTAssertNil(ContextResolver.resolveEnv(from: url))
    }

    func testContextKeyIsNormalizedAndStable() {
        let context = CommandContext(
            url: "https://Prod.Example.com:443/path",
            domain: "Prod.Example.com.:443",
            env: "PROD",
            sourceApp: "Com.Google.Chrome"
        )

        XCTAssertEqual(context.domain, "prod.example.com")
        XCTAssertEqual(context.env, "prod")
        XCTAssertEqual(context.sourceApp, "com.google.chrome")
        XCTAssertEqual(context.contextKey, "com.google.chrome|prod.example.com|prod")
    }
}
