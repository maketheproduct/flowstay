@testable import FlowstayCore
import XCTest

final class OpenRouterModelSelectionTests: XCTestCase {
    private func model(_ id: String, created: Int?) throws -> OpenRouterModel {
        var json: [String: Any] = [
            "id": id,
            "name": id,
            "context_length": 128_000,
            "pricing": ["prompt": "0", "completion": "0"],
        ]
        if let created {
            json["created"] = created
        }
        return try JSONDecoder().decode(OpenRouterModel.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testPrefersNewestModelFromPreferredProvider() throws {
        let models = try [
            model("cohere/north-mini-code:free", created: 300),
            model("google/gemma-3-27b-it:free", created: 100),
            model("google/gemma-4-31b-it:free", created: 200),
            model("meta-llama/llama-5-8b-instruct:free", created: 250),
        ]

        XCTAssertEqual(OpenRouterProvider.preferredFreeModel(from: models)?.id, "google/gemma-4-31b-it:free")
    }

    func testSkipsCodeAndSafetyModels() throws {
        let models = try [
            model("cohere/north-mini-code:free", created: 300),
            model("nvidia/nemotron-3.5-content-safety:free", created: 200),
            model("liquid/lfm-2.5-2.6b:free", created: 100),
        ]

        XCTAssertEqual(OpenRouterProvider.preferredFreeModel(from: models)?.id, "liquid/lfm-2.5-2.6b:free")
    }

    func testDecodesCachedModelsWithoutCreatedDate() throws {
        let models = try [model("qwen/qwen-4-8b:free", created: nil)]

        XCTAssertNil(models[0].created)
        XCTAssertEqual(OpenRouterProvider.preferredFreeModel(from: models)?.id, "qwen/qwen-4-8b:free")
    }

    func testReturnsNilWithNoModels() {
        XCTAssertNil(OpenRouterProvider.preferredFreeModel(from: []))
    }
}
