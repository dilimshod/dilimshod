import XCTest
@testable import RoadVisionCore

final class ChatTests: XCTestCase {
    func testRequestBody() throws {
        let data = try OpenAIChat.requestBody(model: "m", messages: [ChatMessage(role: .user, content: "Привет")],
                                              stream: true, extra: ["reasoning_effort": "low"])
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["model"] as? String, "m")
        XCTAssertEqual(obj["stream"] as? Bool, true)
        XCTAssertEqual(obj["reasoning_effort"] as? String, "low")
        let msgs = obj["messages"] as! [[String: String]]
        XCTAssertEqual(msgs[0]["role"], "user")
        XCTAssertEqual(msgs[0]["content"], "Привет")
    }

    func testStreamParsing() {
        XCTAssertEqual(OpenAIChat.parseStreamLine("data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}"), .delta("Hi"))
        XCTAssertEqual(OpenAIChat.parseStreamLine("data: {\"choices\":[{\"delta\":{\"reasoning\":\"think\"}}]}"), .ignore)
        XCTAssertEqual(OpenAIChat.parseStreamLine("data: [DONE]"), .done)
        XCTAssertEqual(OpenAIChat.parseStreamLine(": keep-alive"), .ignore)
        XCTAssertEqual(OpenAIChat.parseStreamLine("data: {\"error\":{\"message\":\"rate limit\"}}"), .error("rate limit"))
    }

    func testCompletionAndErrors() throws {
        let ok = Data("{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"Салом\"}}]}".utf8)
        XCTAssertEqual(try OpenAIChat.parseCompletion(ok), "Салом")
        XCTAssertEqual(OpenAIChat.parseError(Data("{\"error\":{\"message\":\"bad key\"}}".utf8)), "bad key")
        XCTAssertEqual(OpenAIChat.parseModelList(Data("{\"data\":[{\"id\":\"a\"},{\"id\":\"b\"},{\"id\":\"a\"}]}".utf8)), ["a", "b"])
    }

    func testPresets() {
        XCTAssertEqual(ChatPresets.preset(id: "groq")?.chatURL?.absoluteString, "https://api.groq.com/openai/v1/chat/completions")
        XCTAssertEqual(ChatPresets.preset(id: "pollinations")?.chatURL?.absoluteString, "https://text.pollinations.ai/openai")
        XCTAssertEqual(ChatPresets.preset(id: "gemini")?.chatURL?.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        XCTAssertEqual(ChatPresets.preset(id: "ollama")?.withBaseURL("http://10.0.0.5:11434/v1/").chatURL?.absoluteString,
                       "http://10.0.0.5:11434/v1/chat/completions")
        XCTAssertFalse(ChatPresets.preset(id: "pollinations")!.requiresAPIKey)
    }

    func testHistoryTrim() {
        let msgs = (0..<10).map { ChatMessage(role: $0 % 2 == 0 ? .user : .assistant, content: String(repeating: "x", count: 100)) }
        let t = ChatHistory.trimmed(msgs, maxCharacters: 350)
        XCTAssertLessThanOrEqual(t.count, 4)
        XCTAssertEqual(t.first?.role, .user)
        XCTAssertEqual(t.last?.id, msgs.last?.id)
    }

    func testSystemPromptContext() {
        var ctx = DrivingContext()
        ctx.speedKmh = 54
        ctx.roadName = "Амир Темур"
        ctx.lanesInDirection = 3
        ctx.totalLanes = 6
        let p = AssistantPrompt.systemPrompt(languageCode: "ru", context: ctx, includeContext: true)
        XCTAssertTrue(p.contains("Russian"))
        XCTAssertTrue(p.contains("54 км/ч"))
        XCTAssertTrue(p.contains("Полос в направлении движения (OpenStreetMap): 3, всего 6"))
        let p2 = AssistantPrompt.systemPrompt(languageCode: "uz", context: ctx, includeContext: false)
        XCTAssertTrue(p2.contains("Uzbek"))
        XCTAssertFalse(p2.contains("54 км/ч"))
    }
}
