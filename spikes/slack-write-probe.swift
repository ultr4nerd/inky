import AppKit
import ApplicationServices
let slack = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tinyspeck.slackmacgap").first!
let app = AXUIElementCreateApplication(slack.processIdentifier)
AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
let osa = Process(); osa.launchPath = "/usr/bin/osascript"; osa.arguments = ["-e","tell application \"Slack\" to activate"]; try! osa.run(); osa.waitUntilExit()
Thread.sleep(forTimeInterval: 1.5)
print("slack active:", NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
var found: AXUIElement?
func walk(_ e: AXUIElement, _ d: Int) {
  if d > 40 || found != nil { return }
  if (attr(e, kAXRoleAttribute) as? String) == "AXTextArea", (attr(e, kAXFocusedAttribute) as? Bool) == true { found = e; return }
  for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(c, d+1) }
}
walk(attr(app, kAXFocusedWindowAttribute) as! AXUIElement, 0)
guard let el = found else { print("no textarea"); exit(1) }
func param(_ a: String, _ p: AnyObject) -> (AXError, AnyObject?) { var o: AnyObject?; let r = AXUIElementCopyParameterizedAttributeValue(el, a as CFString, p, &o); return (r, o) }
func rv(_ loc: Int, _ len: Int) -> AXValue { var r = CFRange(location: loc, length: len); return AXValueCreate(.cfRange, &r)! }
func dump(_ label: String) {
  let v = attr(el, kAXValueAttribute) as? String ?? ""
  print("[\(label)] value:", v.debugDescription, "utf16:", v.utf16.count)
  let (r, o) = param(kAXAttributedStringForRangeParameterizedAttribute, rv(0, v.utf16.count))
  if r == .success, let a = o as? NSAttributedString {
    a.enumerateAttributes(in: NSRange(location: 0, length: a.length)) { at, range, _ in
      let keys = at.keys.map(\.rawValue).filter { !["AXFont","AXForegroundColor","AXBackgroundColor"].contains($0) }
      if !keys.isEmpty || at.keys.contains(where: { $0.rawValue.contains("Link") || $0.rawValue.contains("Attachment") }) {
        print("   run \(range) \((a.string as NSString).substring(with: range).debugDescription): \(at.map { "\($0.key.rawValue)=\(String(describing: $0.value).prefix(60))" })")
      }
    }
  } else { print("   attributed err", r.rawValue) }
  // children (mentions may be child elements)
  for c in (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
    print("   child role:", attr(c, kAXRoleAttribute) ?? "?", "title/value:", (attr(c, kAXValueAttribute) ?? attr(c, kAXTitleAttribute) ?? attr(c, kAXDescriptionAttribute) ?? "nil" as AnyObject), "dom:", attr(c, "AXDOMClassList") ?? "nil")
  }
}
dump("before")
let v = attr(el, kAXValueAttribute) as? String ?? ""
let ns = v as NSString
for w in ["hey", "this are", "meeting"] {
  let r = ns.range(of: w); if r.location == NSNotFound { print("not found", w); continue }
  let (e, o) = param(kAXBoundsForRangeParameterizedAttribute, rv(r.location, r.length))
  var rect = CGRect(); if e == .success { AXValueGetValue(o as! AXValue, .cgRect, &rect) }
  print("bounds \(w.debugDescription) @\(r.location):", e.rawValue, rect)
}
func tmBounds(_ loc: Int, _ len: Int) {
  AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, rv(loc, len))
  Thread.sleep(forTimeInterval: 0.2)
  if let tmr = attr(el, "AXSelectedTextMarkerRange") {
    let (e, o) = param("AXBoundsForTextMarkerRange", tmr)
    var rect = CGRect(); if e == .success { AXValueGetValue(o as! AXValue, .cgRect, &rect) }
    print("  textmarker bounds @\(loc),\(len):", e.rawValue, rect)
  } else { print("  no selected text marker range") }
  var cf = CFRange(); if let sr = attr(el, kAXSelectedTextRangeAttribute) { AXValueGetValue(sr as! AXValue, .cfRange, &cf) }
  print("  selection now:", cf.location, cf.length)
}
for w in ["hey", "this are", "meeting"] { let r = ns.range(of: w); tmBounds(r.location, r.length) }
func frames(_ e: AXUIElement, _ d: Int) { for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { print(String(repeating: "  ", count: d), attr(c, kAXRoleAttribute) ?? "?", (attr(c, kAXValueAttribute) as? String)?.debugDescription ?? "", attr(c, "AXFrame").map { String(describing: $0).components(separatedBy: "{value = ").last ?? "" } ?? ""); frames(c, d+1) } }
frames(el, 1)
print("window frame:", attr(attr(app, kAXFocusedWindowAttribute) as! AXUIElement, "AXFrame") ?? "nil")
// WRITE TEST
let target = ns.range(of: "this are")
guard target.location != NSNotFound else { exit(0) }
let arr = [rv(target.location, target.length), "this is" as CFString] as CFArray
var (e1, o1) = param("AXReplaceRangeWithText", arr)
print("AXReplaceRangeWithText [range,text]:", e1.rawValue, o1 ?? "nil")
Thread.sleep(forTimeInterval: 0.5)
var after = attr(el, kAXValueAttribute) as? String ?? ""
if !after.contains("this is") {
  print("fallback: select range + set AXSelectedText")
  let s1 = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, rv(target.location, target.length))
  let s2 = AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, "this is" as CFString)
  print("set range:", s1.rawValue, "set text:", s2.rawValue)
  Thread.sleep(forTimeInterval: 0.5)
}
after = attr(el, kAXValueAttribute) as? String ?? ""
if !after.contains("this is") {
  print("fallback 2: select range + type via CGEvent")
  AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, rv(target.location, target.length))
  Thread.sleep(forTimeInterval: 0.3)
  let src = CGEventSource(stateID: .hidSystemState)
  let chars = Array("this is".utf16)
  let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)!; down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
  let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)!
  down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
  Thread.sleep(forTimeInterval: 0.6)
}
dump("after")
