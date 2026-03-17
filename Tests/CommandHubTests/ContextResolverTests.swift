import XCTest
@testable import CommandHub

final class ContextResolverTests: XCTestCase {
    func testResolveEnvPrefersExplicitQueryParameter() {
        let url = "https://prod.example.com/dashboard?env=stg"
        XCTAssertEqual(ContextResolver.resolveEnv(from: url), "staging")
    }

    func testResolveEnvPreservesCustomQueryEnvironmentName() {
        let url = "http://asnet-ops-web.taobao.net/xterm_host.html?xterm_host=11.122.102.85&env=ECE-H-126E&host=10.126.1.1"
        XCTAssertEqual(ContextResolver.resolveEnv(from: url), "ECE-H-126E")
    }

    func testResolveEnvTrimsCustomQueryEnvironmentName() {
        let url = "http://asnet-ops-web.taobao.net/xterm_host.html?env=%20ECE-H-126E%20&host=vm010126005039"
        XCTAssertEqual(ContextResolver.resolveEnv(from: url), "ECE-H-126E")
    }

    func testResolveEnvIgnoresUnrelatedQueryFieldsWhenCustomEnvironmentExists() {
        let url = "http://asnet-ops-web.taobao.net/xterm_host.html?env=ECE-H-126E&host=vm010126005039&container_id=fee4f2db5e24&container_host_name=docker010126005041&xterm_host=11.122.102.85"
        XCTAssertEqual(ContextResolver.resolveEnv(from: url), "ECE-H-126E")
    }

    func testResolveEnvRejectsEmptyOrNullQueryValues() {
        XCTAssertNil(ContextResolver.resolveEnv(from: "https://example.com/dashboard?env="))
        XCTAssertNil(ContextResolver.resolveEnv(from: "https://example.com/dashboard?env=nil"))
        XCTAssertNil(ContextResolver.resolveEnv(from: "https://example.com/dashboard?env=null"))
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
            env: "ECE-H-126E",
            sourceApp: "Com.Google.Chrome"
        )

        XCTAssertEqual(context.domain, "prod.example.com")
        XCTAssertEqual(context.env, "ECE-H-126E")
        XCTAssertEqual(context.sourceApp, "com.google.chrome")
        XCTAssertEqual(context.contextKey, "com.google.chrome|prod.example.com|ece-h-126e")
    }
}
