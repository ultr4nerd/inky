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
