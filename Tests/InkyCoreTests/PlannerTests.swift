import Foundation
import Testing
@testable import InkyCore

@Test func masksAndUnmasksMentions() {
    let text = "hey @Ana this are a test"
    let m = MentionMasker.mask(text, protected: [NSRange(location: 4, length: 4)])
    #expect(m.text == "hey ⟦m1⟧ this are a test")
    #expect(MentionMasker.unmask(m.text, m.placeholders) == text)
}

@Test func plansEditsLastToFirstAndAppliesThem() {
    let text = "i has went to the meeting and we discuss about it"
    let edits = [
        Edit(original: "i has went", replacement: "I went", explanation: ""),
        Edit(original: "we discuss about", replacement: "we discussed", explanation: ""),
    ]
    let planned = EditPlanner.plan(text: text, edits: edits)
    #expect(planned.count == 2)
    #expect(planned[0].range.location > planned[1].range.location)
    #expect(EditPlanner.apply(planned, to: text) == "I went to the meeting and we discussed it")
}

@Test func neverTouchesProtectedRanges() {
    let text = "hey @Ana this are a test"
    let edits = [Edit(original: "@Ana this are", replacement: "@Anabel this is", explanation: "")]
    #expect(EditPlanner.plan(text: text, edits: edits, protected: [NSRange(location: 4, length: 4)]).isEmpty)
}

@Test func splitsWholeTextEditsAroundPlaceholders() {
    let edits = [Edit(original: "hola ⟦m1⟧ cómo estás", replacement: "hi ⟦m1⟧ how are you", explanation: "t")]
    let prepared = EditPlanner.prepare(edits, placeholders: ["⟦m1⟧": "@Ana"])
    #expect(prepared.map(\.original) == ["hola ", " cómo estás"])
    #expect(prepared.map(\.replacement) == ["hi ", " how are you"])

    let text = "hola @Ana cómo estás"
    let planned = EditPlanner.plan(text: text, edits: prepared, protected: [NSRange(location: 5, length: 4)])
    #expect(EditPlanner.apply(planned, to: text) == "hi @Ana how are you")
}

@Test func dropsEditsThatMoveMentions() {
    let edits = [Edit(original: "⟦m1⟧ and ⟦m2⟧", replacement: "⟦m2⟧ and ⟦m1⟧", explanation: "")]
    #expect(EditPlanner.prepare(edits, placeholders: ["⟦m1⟧": "@a", "⟦m2⟧": "@b"]).isEmpty)
}
