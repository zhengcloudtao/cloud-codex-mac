import XCTest
@testable import CloudCodex

final class ModelProviderTests: XCTestCase {
    private func provider(_ url: String = "https://example.invalid/v1") -> ModelProviderConfiguration {
        ModelProviderConfiguration(enabled: true, name: "测试服务", baseURL: url, modelID: "custom-model")
    }

    func testRejectsCredentialURLsAndRemoteCleartext() {
        for url in ["http://example.invalid/v1", "https://user:password@example.invalid/v1",
                    "https://example.invalid/v1?token=value", "https://example.invalid/v1#fragment", "not-a-url"] {
            XCTAssertThrowsError(try provider(url).validated())
        }
        XCTAssertNoThrow(try provider("http://127.0.0.1:1234/v1").validated())
        XCTAssertNoThrow(try provider("http://[::1]:1234/v1").validated())
    }

    func testNormalizationAndDisabledConfiguration() throws {
        var value = provider(" https://example.invalid/v1/// ")
        value.modelID = " custom-model "
        let normalized = try value.validated()
        XCTAssertEqual(normalized.baseURL, "https://example.invalid/v1")
        XCTAssertEqual(normalized.modelID, "custom-model")
        XCTAssertNoThrow(try ModelProviderConfiguration().validated())
        XCTAssertTrue(ModelProviderConfiguration().arguments.isEmpty)
        value.enabled = false
        value.baseURL = "https://user:password@example.invalid/v1"
        XCTAssertThrowsError(try value.validated())
    }

    func testPersistenceHasNoCredentialAndArgumentsUseEnvironmentReference() throws {
        let value = provider()
        let encoded = try JSONEncoder().encode(value)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["enabled", "name", "baseURL", "modelID", "reasoningEffort"]))
        XCTAssertTrue(value.arguments.contains("model_providers.cloudcodex_custom.env_key=\"CLOUDCODEX_MODEL_API_KEY\""))
        XCTAssertTrue(value.arguments.contains("model_providers.cloudcodex_custom.requires_openai_auth=false"))
        XCTAssertEqual(value.modelOption?.model, "custom-model")
        XCTAssertEqual(value.modelOption?.supportedEfforts, ["none"])
        XCTAssertEqual(value.modelOption?.serviceTiers, [])
    }

    func testProviderValuesRemainSingleArgumentsAndEscapeTOML() {
        var value = provider()
        value.name = "quoted \"name\"\nnext"
        XCTAssertEqual(ModelProviderConfiguration.quoted(value.name), "\"quoted \\\"name\\\"\\nnext\"")
        XCTAssertEqual(value.arguments.count, 28)
        XCTAssertEqual(ModelProviderConfiguration.quoted("https://example.invalid/v1"), "\"https://example.invalid/v1\"")
    }

    @MainActor
    func testThirdPartyDoesNotInheritOrOverwriteChatGPTCreditPause() throws {
        let suite = "CloudCodexProviderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(provider()), forKey: ModelProviderConfiguration.defaultsKey)
        defaults.set("includedQuotaExhausted", forKey: "cloudcodex.creditUsagePause.v1")
        let app = AppModel(remoteDefaults: defaults)
        XCTAssertTrue(app.customModelProvider.enabled)
        XCTAssertNil(app.creditUsagePauseReason)
        app.observeCreditUsage(AccountOverview.parse([:]))
        XCTAssertNil(app.creditUsagePauseReason)
        XCTAssertEqual(defaults.string(forKey: "cloudcodex.creditUsagePause.v1"), "includedQuotaExhausted")
    }
}

private final class ProviderProbeProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let denied = request.url?.host == "denied.invalid"
        let response = HTTPURLResponse(url: request.url!, statusCode: denied ? 401 : 200,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let authorized = request.httpMethod == "GET" && request.url?.path == "/v1/models"
            && request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only"
        let data = Data((authorized ? "{\"data\":[{\"id\":\"custom-model\"}]}" : "{}").utf8)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension ModelProviderTests {
    func testNamedPresetsAndCredentialIsolation() throws {
        XCTAssertEqual(SupportedModelService.allCases.map(\.rawValue), ["deepseek", "aliyun", "volcengine"])
        var value = ModelProviderConfiguration(enabled: true)
        value.select(.deepseek)
        XCTAssertEqual(try value.validated().baseURL, "https://api.deepseek.com")
        XCTAssertEqual(value.modelID, "deepseek-flash")
        XCTAssertEqual(value.reasoningEffort, "high")
        let deepseekAccount = value.credentialAccount
        value.select(.aliyun)
        XCTAssertEqual(value.modelID, "auto")
        let aliyunAccount = value.credentialAccount
        value.select(.aliyun, subscription: false)
        XCTAssertThrowsError(try value.validated()) // A real workspace address is mandatory.
        value.baseURL = "https://fixture.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
        XCTAssertNoThrow(try value.validated())
        XCTAssertNotEqual(value.credentialAccount, aliyunAccount)
        value.select(.volcengine)
        XCTAssertEqual(value.modelID, "ark-code-latest")
        let volcanoAccount = value.credentialAccount
        value.select(.volcengine, subscription: false)
        XCTAssertThrowsError(try value.validated()) // A provisioned model/endpoint ID is mandatory.
        value.modelID = "fixture-endpoint"
        XCTAssertNoThrow(try value.validated())
        XCTAssertNotEqual(value.credentialAccount, volcanoAccount)
        XCTAssertNotEqual(deepseekAccount, aliyunAccount)
    }

    func testNamedProvidersRejectWrongEndpointsAndUnsupportedEfforts() throws {
        for service in SupportedModelService.allCases {
            var value = ModelProviderConfiguration(enabled: true)
            value.select(service)
            XCTAssertNoThrow(try value.validated())
            for url in ["https://example.invalid/v1", "https://api.deepseek.com.evil.invalid",
                        "http://localhost:9000", "https://ark.cn-beijing.volces.com/api/v3",
                        "https://coding.dashscope.aliyuncs.com/v1"] {
                value.baseURL = url
                XCTAssertThrowsError(try value.validated(), "\(service): \(url)")
            }
            value.select(service)
            value.reasoningEffort = "none"
            XCTAssertThrowsError(try value.validated())
        }
        var value = ModelProviderConfiguration(enabled: true)
        value.select(.aliyun, subscription: false)
        value.baseURL = "https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
        XCTAssertThrowsError(try value.validated())
        value.select(.volcengine, subscription: false)
        value.modelID = "fixture-endpoint"
        value.baseURL = "https://ark.cn-beijing.volces.com/api/coding/v3"
        XCTAssertThrowsError(try value.validated())
    }

    func testLegacyConfigurationStaysOnOriginalRoute() throws {
        let old = provider()
        let decoded = try JSONDecoder().decode(ModelProviderConfiguration.self, from: JSONEncoder().encode(old))
        XCTAssertNil(decoded.service)
        XCTAssertEqual(decoded.credentialAccount, "custom-api-key")
        XCTAssertEqual(decoded.baseURL, old.baseURL)
        XCTAssertEqual(try decoded.launchArguments(), old.arguments)
    }

    func testNamedModelCatalogsAndLaunchArguments() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for service in SupportedModelService.allCases {
            var value = ModelProviderConfiguration(enabled: true)
            value.select(service)
            let arguments = try value.launchArguments(catalogDirectory: directory)
            let assignment = try XCTUnwrap(arguments.last)
            let path = try JSONDecoder().decode(String.self, from: Data(assignment.dropFirst("model_catalog_json=".count).utf8))
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let model = try XCTUnwrap((catalog["models"] as? [[String: Any]])?.first)
            XCTAssertEqual(model["slug"] as? String, value.modelID)
            XCTAssertEqual(model["apply_patch_tool_type"] as? String, service == .aliyun ? nil : "freeform")
            XCTAssertEqual(model["shell_type"] as? String, service == .deepseek ? "shell_command" : "default")
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("API_KEY"))
            XCTAssertEqual(try value.launchArguments(catalogDirectory: directory), arguments)
            if let fixtures = ProcessInfo.processInfo.environment["CLOUDCODEX_CATALOG_FIXTURES"] {
                let destination = URL(fileURLWithPath: fixtures, isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try data.write(to: destination.appendingPathComponent(service.rawValue + ".json"))
            }
        }
    }

    func testProbeUsesReadOnlyModelListAndReportsItsLimits() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProviderProbeProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let message = try await ModelProviderConnectionProbe.check(provider(), key: "fixture-only", session: session)
        XCTAssertTrue(message.contains("模型 ID 已找到"))
        XCTAssertTrue(message.contains("尚未验证 Responses"))
        do {
            _ = try await ModelProviderConnectionProbe.check(provider("https://denied.invalid/v1"), key: "fixture-only", session: session)
            XCTFail("HTTP 401 must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTP 401"))
            XCTAssertFalse(error.localizedDescription.contains("fixture-only"))
        }
    }

    func testThreadRemembersProviderForSwitchingBack() throws {
        let thread = try XCTUnwrap(CodexThread(json: ["id": "fixture-thread", "cwd": "/tmp",
                                                   "modelProvider": ModelProviderConfiguration.providerID]))
        XCTAssertEqual(thread.modelProvider, ModelProviderConfiguration.providerID)
        let roundTrip = try JSONDecoder().decode(CodexThread.self, from: JSONEncoder().encode(thread))
        XCTAssertEqual(roundTrip.modelProvider, thread.modelProvider)
    }
}
