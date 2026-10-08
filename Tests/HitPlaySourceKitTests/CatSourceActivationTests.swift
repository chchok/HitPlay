import Combine
import XCTest
@testable import HitPlayCatSource

final class CatSourceActivationTests: XCTestCase {
    @MainActor
    func testFailedActivationDoesNotRelabelExistingRuntimeOrPersistFailedSelection() async throws {
        let suite = "CatActivationRollback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let previousID = UUID()
        let lastActivatedKey = "hitplay.catsource.subscriptions.v1.lastActivated"
        defaults.set(previousID.uuidString, forKey: lastActivatedKey)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActivationFailureStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); defaults.removePersistentDomain(forName: suite) }
        let store = CatSourceStore(defaults: defaults, session: session)
        let previousRuntime = ExistingSourceRuntime()
        store.runtime = previousRuntime
        let failing = CatSourceStore.Subscription(name: "无法启动的源", url: "https://source.fixture/index.js")
        await store.activate(failing, loadHome: false)
        XCTAssertNotNil(store.engineError)
        XCTAssertTrue(store.runtime === previousRuntime)
        XCTAssertTrue(store.runtime.isRunning)
        XCTAssertEqual(store.selectedSubscriptionID, previousID, "旧运行时必须继续归属于原来的源")
        XCTAssertNotEqual(store.selectedSubscriptionID, failing.id)
        XCTAssertEqual(store.lastActivatedID, previousID)
        XCTAssertEqual(defaults.string(forKey: lastActivatedKey), previousID.uuidString)
    }
}

@MainActor
private final class ExistingSourceRuntime: ObservableObject, CatEngineRuntimeProtocol {
    var isRunning = true
    let port: Int? = 54321
    var baseURL: URL? { URL(string: "http://127.0.0.1:54321") }
    var websiteURL: URL? { baseURL?.appendingPathComponent("website") }
    var lastError: String? { nil }
    func client() -> CatSourceClient { CatSourceClient(baseURL: baseURL!) }
    func stop() { isRunning = false }
    func start(packageDir: URL, pythonExtend: String?) async throws {}
}

private final class ActivationFailureStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 503,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
