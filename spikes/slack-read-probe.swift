import AppKit
import ApplicationServices
print("trusted:", AXIsProcessTrusted())
guard AXIsProcessTrusted() else { exit(1) }
guard let slack = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tinyspeck.slackmacgap").first else { print("Slack not running"); exit(1) }
let app = AXUIElementCreateApplication(slack.processIdentifier)
let r = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
print("set AXManualAccessibility:", r.rawValue)
Thread.sleep(forTimeInterval: 2.5)
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
func settable(_ e: AXUIElement, _ a: String) -> Bool { var b: DarwinBoolean = false; AXUIElementIsAttributeSettable(e, a as CFString, &b); return b.boolValue }
var found: AXUIElement?
func walk(_ e: AXUIElement, _ d: Int) {
  if d > 40 || found != nil { return }
  if (attr(e, kAXRoleAttribute) as? String) == "AXTextArea", (attr(e, kAXFocusedAttribute) as? Bool) == true { found = e; return }
  for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(c, d+1) }
}
if let w = attr(app, kAXFocusedWindowAttribute) { walk(w as! AXUIElement, 0) }
guard let el = found else { print("no focused textarea"); exit(1) }
print("role:", attr(el, kAXRoleAttribute) ?? "nil", "| subrole:", attr(el, kAXSubroleAttribute) ?? "nil", "| desc:", attr(el, kAXRoleDescriptionAttribute) ?? "nil")
var names: CFArray?; AXUIElementCopyAttributeNames(el, &names); print("attrs:", (names as? [String])?.sorted().joined(separator: ",") ?? "")
var pnames: CFArray?; AXUIElementCopyParameterizedAttributeNames(el, &pnames); print("param attrs:", (pnames as? [String])?.joined(separator: ",") ?? "")
let value = attr(el, kAXValueAttribute) as? String
print("value readable:", value != nil, "| length:", value?.count ?? -1)
print("numChars:", attr(el, kAXNumberOfCharactersAttribute) ?? "nil")
if let sr = attr(el, kAXSelectedTextRangeAttribute) { var cf = CFRange(); AXValueGetValue(sr as! AXValue, .cfRange, &cf); print("selectedRange:", cf.location, cf.length) } else { print("selectedRange: nil") }
for a in [kAXValueAttribute, kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute] { print("settable \(a):", settable(el, a)) }
let n = min(value?.count ?? 0, 5)
if n > 0 {
  var range = CFRange(location: 0, length: n)
  let rv = AXValueCreate(.cfRange, &range)!
  var out: AnyObject?
  let br = AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, rv, &out)
  if br == .success { var rect = CGRect(); AXValueGetValue(out as! AXValue, .cgRect, &rect); print("boundsForRange(0,\(n)):", rect) } else { print("boundsForRange error:", br.rawValue) }
  var range2 = CFRange(location: 0, length: value!.utf16.count)
  let rv2 = AXValueCreate(.cfRange, &range2)!
  var astr: AnyObject?
  if AXUIElementCopyParameterizedAttributeValue(el, kAXAttributedStringForRangeParameterizedAttribute as CFString, rv2, &astr) == .success, let a = astr as? NSAttributedString {
    var keys = Set<String>(); a.enumerateAttributes(in: NSRange(location: 0, length: a.length)) { at, _, _ in at.keys.forEach { keys.insert($0.rawValue) } }
    print("attributedString keys:", keys.sorted())
  } else { print("attributedString: unavailable") }
}
