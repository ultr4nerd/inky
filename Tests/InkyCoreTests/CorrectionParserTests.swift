import Testing
@testable import InkyCore

@Test func parsesFencedJSON() throws {
    let raw = """
    ```json
    {"edits":[{"original":"this are","replacement":"this is","explanation":"Singular 'this' takes 'is'."}],
     "corrected":"hey @name this is a test"}
    ```
    """
    let c = try CorrectionParser.parse(raw)
    #expect(c.edits.count == 1)
    #expect(c.edits[0].replacement == "this is")
    #expect(c.corrected == "hey @name this is a test")
}

@Test func failsWithoutJSON() {
    #expect(throws: CorrectionParser.ParseError.self) { try CorrectionParser.parse("no json here") }
}

@Test func parsesCategoryAndTone() throws {
    let raw = #"{"tone":"friendly · informal","edits":[{"original":"sent","replacement":"send","category":"correctness","explanation":"x"},{"original":"very good","replacement":"great","category":"weird","explanation":"y"}],"corrected":"z"}"#
    let c = try CorrectionParser.parse(raw)
    #expect(c.tone == "friendly · informal")
    #expect(c.edits[0].kind == .correctness)
    #expect(c.edits[1].kind == .correctness) // unknown falls back
    let planned = EditPlanner.plan(text: "can you sent it", edits: [Edit(original: "sent", replacement: "send", explanation: "", category: "clarity")])
    #expect(planned.first?.category == .clarity)
}
