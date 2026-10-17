import AppKit
import ApplicationServices
import ScreenCaptureKit
import CryptoKit
import Carbon.HIToolbox
import SwiftUI
import Combine
import CoreImage.CIFilterBuiltins

enum OperatorError: Error { case denied(String) }
func deny(_ text: String) throws -> Never { throw OperatorError.denied(text) }

// MARK: - Range

// Core signs the range into every request; the model never sets it. "Chosen apps" is enforced
// here as well as in Core: screenshots include only those apps' windows, pointer actions must land
// on one of their windows, and keys go only to a chosen frontmost app.
let bundlePattern="^[A-Za-z0-9][A-Za-z0-9.-]{1,154}$"
struct Scope {
    let full: Bool
    let apps: Set<String>
    func allows(_ bundle: String?) -> Bool { full || bundle.map { apps.contains($0) } ?? false }
}
func readScope(_ request: [String:Any]) throws -> Scope {
    guard let raw=request["scope"] as? [String:Any], let mode=raw["mode"] as? String else { try deny("This request has no range. Update Nova Core.") }
    if mode == "full" { return Scope(full:true,apps:[]) }
    guard mode == "apps", let apps=raw["apps"] as? [String], apps.count <= 30,
          apps.allSatisfy({ $0.range(of:bundlePattern,options:.regularExpression) != nil }) else { try deny("Invalid range") }
    return Scope(full:false,apps:Set(apps).subtracting([Bundle.main.bundleIdentifier ?? "dev.nova.operator.macos"]))
}
/// The app that owns the frontmost visible window under a point, in CoreGraphics coordinates.
func appAt(_ p: CGPoint) -> String? {
    guard let windows=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] else { return nil }
    let own=ProcessInfo.processInfo.processIdentifier
    for window in windows {
        guard let pid=window[kCGWindowOwnerPID as String] as? pid_t, pid != own,
              (window[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
              let bounds=window[kCGWindowBounds as String] as? NSDictionary,
              let rect=CGRect(dictionaryRepresentation:bounds), rect.contains(p) else { continue }
        return NSRunningApplication(processIdentifier:pid)?.bundleIdentifier ?? "pid.\(pid)"
    }
    return nil
}
// Mirrors scopedKeyAllowed in core/policy.mjs.
let blockedCombos: Set<String>=["cmd+space","cmd+tab","cmd+shift+tab","cmd+shift+3","cmd+shift+4","cmd+shift+5","cmd+shift+6","cmd+shift+q","alt+space","cmd+alt+escape","cmd+alt+d"]
let scopedModifiers: [String:String]=["ctrl":"ctrl","control":"ctrl","alt":"alt","option":"alt","opt":"alt","shift":"shift","super":"cmd","cmd":"cmd","command":"cmd","meta":"cmd","win":"cmd","fn":"fn"]
func scopedKeyAllowed(_ text: String) -> Bool {
    let parts=text.lowercased().split(separator:"+").map(String.init)
    guard let key=parts.last else { return false }
    var mods=Set<String>()
    for part in parts.dropLast() { guard let mod=scopedModifiers[part] else { return false }; mods.insert(mod) }
    if mods.contains("ctrl") || mods.contains("fn") || (mods.contains("cmd") && mods.contains("alt")) { return false }
    if key.range(of:"^f[0-9]{1,2}$",options:.regularExpression) != nil { return false }
    return !blockedCombos.contains((["cmd","alt","shift"].filter { mods.contains($0) }+[key == "esc" ? "escape" : key]).joined(separator:"+"))
}
func checkPoint(_ scope: Scope, _ p: CGPoint) throws {
    if !scope.allows(appAt(p)) { try deny("That spot is outside the apps Nova may use") }
}
@MainActor func checkFrontmost(_ scope: Scope) throws {
    if !scope.allows(NSWorkspace.shared.frontmostApplication?.bundleIdentifier) { try deny("The app in front isn't one Nova may use. Open a chosen app with open_app first.") }
}
func checkKeys(_ scope: Scope, _ text: String?, modifiersOnly: Bool = false) throws {
    guard !scope.full, let text, !text.isEmpty else { return }
    if !scopedKeyAllowed(modifiersOnly ? text+"+a" : text) { try deny("\(text) works outside the chosen apps, so Nova can't press it in this range") }
}

// MARK: - Screen geometry

// Claude sees the main display downscaled to fit Anthropic's recommended size and
// replies in that image's pixels; every coordinate is mapped back here.
struct Display {
    let id: CGDirectDisplayID
    let bounds: CGRect
    let imageSize: CGSize
    static func main() -> Display {
        let id=CGMainDisplayID(), bounds=CGDisplayBounds(id)
        let scale=min(1,1366/max(bounds.width,bounds.height),(1_150_000/(bounds.width*bounds.height)).squareRoot())
        return Display(id:id,bounds:bounds,imageSize:CGSize(width:(bounds.width*scale).rounded(.down),height:(bounds.height*scale).rounded(.down)))
    }
    func point(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x:bounds.minX+x*bounds.width/imageSize.width,y:bounds.minY+y*bounds.height/imageSize.height)
    }
    func image(_ p: CGPoint) -> [Int] {
        [Int(((p.x-bounds.minX)*imageSize.width/bounds.width).rounded()),Int(((p.y-bounds.minY)*imageSize.height/bounds.height).rounded())]
    }
}

@MainActor
func capture(region: CGRect? = nil, scope: Scope) async throws -> [String:Any] {
    let display=Display.main()
    let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
    guard let screen=content.displays.first(where:{ $0.displayID == display.id }) else { try deny("Main display unavailable") }
    // Nova's own cursor stays out of what the AI sees. In "Chosen apps" only those apps are captured.
    let own=content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
    let filter=scope.full ? SCContentFilter(display:screen,excludingWindows:own)
        : SCContentFilter(display:screen,including:content.applications.filter { scope.apps.contains($0.bundleIdentifier) },exceptingWindows:[])
    let config=SCStreamConfiguration()
    config.showsCursor=false
    var size=display.imageSize
    if let region {
        config.sourceRect=region
        let fit=min(display.imageSize.width/region.width,display.imageSize.height/region.height)
        size=CGSize(width:max(1,(region.width*fit).rounded(.down)),height:max(1,(region.height*fit).rounded(.down)))
    }
    config.width=Int(size.width); config.height=Int(size.height)
    let image=try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
    guard let jpeg=NSBitmapImageRep(cgImage:image).representation(using:.jpeg,properties:[.compressionFactor:0.8]) else { try deny("Screenshot failed") }
    return ["image":jpeg.base64EncodedString(),"width":Int(size.width),"height":Int(size.height)]
}

// MARK: - Nova's cursor

final class CursorView: NSView {
    static let size=CGFloat(56), tip=CGPoint(x:8,y:6)
    var flash=false
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let points:[(CGFloat,CGFloat)]=[(8,6),(8,42),(17,33),(23,47),(30,44),(24,30),(36,30)]
        let path=NSBezierPath()
        path.move(to:NSPoint(x:points[0].0,y:points[0].1))
        for p in points.dropFirst() { path.line(to:NSPoint(x:p.0,y:p.1)) }
        path.close(); path.lineJoinStyle = .round; path.lineWidth=2.5
        NSGraphicsContext.saveGraphicsState()
        let glow=NSShadow(); glow.shadowColor=NSColor.systemCyan.withAlphaComponent(0.9); glow.shadowBlurRadius=flash ? 16 : 8; glow.shadowOffset = .zero; glow.set()
        (flash ? NSColor.white : NSColor(calibratedRed:0.2,green:0.8,blue:1,alpha:1)).setFill(); path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.setStroke(); path.stroke()
    }
    func pulse() {
        flash=true; needsDisplay=true
        Task { @MainActor in try? await Task.sleep(for:.milliseconds(180)); self.flash=false; self.needsDisplay=true }
    }
}

@MainActor
final class NovaCursor {
    static let shared=NovaCursor()
    let panel: NSPanel
    let view: CursorView
    var hide: Task<Void,Never>?
    init() {
        panel=NSPanel(contentRect:NSRect(x:0,y:0,width:CursorView.size,height:CursorView.size),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isOpaque=false; panel.backgroundColor = .clear; panel.hasShadow=false
        panel.level = .screenSaver; panel.ignoresMouseEvents=true
        panel.collectionBehavior=[.canJoinAllSpaces,.stationary,.fullScreenAuxiliary,.ignoresCycle]
        view=CursorView(frame:NSRect(x:0,y:0,width:CursorView.size,height:CursorView.size))
        panel.contentView=view; panel.alphaValue=0
    }
    // CoreGraphics points have a top-left origin; Cocoa windows have a bottom-left one.
    func origin(_ p: CGPoint) -> NSPoint {
        let height=NSScreen.screens.first?.frame.height ?? 0
        return NSPoint(x:p.x-CursorView.tip.x,y:height-p.y+CursorView.tip.y-CursorView.size)
    }
    func fly(to p: CGPoint) async {
        hide?.cancel()
        if panel.alphaValue < 0.05 { panel.setFrameOrigin(origin(realPointer())); panel.orderFrontRegardless() }
        panel.alphaValue=1
        let from=panel.frame.origin, to=origin(p)
        let frames=Int(min(33,max(11,hypot(to.x-from.x,to.y-from.y)/66)))
        for frame in 1...frames {
            let t=Double(frame)/Double(frames), eased=t < 0.5 ? 2*t*t : 1-pow(-2*t+2,2)/2
            panel.setFrameOrigin(NSPoint(x:from.x+(to.x-from.x)*eased,y:from.y+(to.y-from.y)*eased))
            try? await Task.sleep(for:.milliseconds(16))
        }
    }
    func idle() {
        hide?.cancel()
        hide=Task { @MainActor in
            try? await Task.sleep(for:.seconds(4))
            guard !Task.isCancelled else { return }
            for step in stride(from:0.9,through:0,by:-0.1) { self.panel.alphaValue=step; try? await Task.sleep(for:.milliseconds(30)) }
        }
    }
    func vanish() { hide?.cancel(); panel.alphaValue=0 }
}

// MARK: - Input

let source=CGEventSource(stateID:.hidSystemState)
func realPointer() -> CGPoint { CGEvent(source:nil)?.location ?? .zero }
func mouse(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton = .left, clicks: Int = 1, flags: CGEventFlags = []) {
    let event=CGEvent(mouseEventSource:source,mouseType:type,mouseCursorPosition:p,mouseButton:button)
    event?.setIntegerValueField(.mouseEventClickState,value:Int64(clicks)); event?.flags=flags
    event?.post(tap:.cghidEventTap)
}
func restorePointer(_ p: CGPoint) async {
    try? await Task.sleep(for:.milliseconds(40))
    CGWarpMouseCursorPosition(p); CGAssociateMouseAndMouseCursorPosition(1)
}

let modifierFlags: [String:CGEventFlags] = ["ctrl":.maskControl,"control":.maskControl,"alt":.maskAlternate,"option":.maskAlternate,"opt":.maskAlternate,"shift":.maskShift,"super":.maskCommand,"cmd":.maskCommand,"command":.maskCommand,"meta":.maskCommand,"win":.maskCommand,"fn":.maskSecondaryFn]
let modifierKeys: [String:CGKeyCode] = ["ctrl":59,"control":59,"alt":58,"option":58,"opt":58,"shift":56,"super":55,"cmd":55,"command":55,"meta":55,"win":55,"fn":63]
let keyCodes: [String:CGKeyCode] = {
    var codes: [String:CGKeyCode] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"=":24,"9":25,"7":26,"-":27,"8":28,"0":29,"]":30,"o":31,"u":32,"[":33,"i":34,"p":35,"l":37,"j":38,"'":39,"k":40,";":41,"\\":42,",":43,"/":44,"n":45,"m":46,".":47,"`":50,
        "return":36,"enter":36,"kp_enter":76,"tab":48,"space":49," ":49,"backspace":51,"escape":53,"esc":53,"delete":117,"forwarddelete":117,"home":115,"end":119,"page_up":116,"pageup":116,"prior":116,"page_down":121,"pagedown":121,"next":121,"left":123,"right":124,"down":125,"up":126,"capslock":57,"caps_lock":57,
        "f1":122,"f2":120,"f3":99,"f4":118,"f5":96,"f6":97,"f7":98,"f8":100,"f9":101,"f10":109,"f11":103,"f12":111,
        "minus":27,"equal":24,"comma":43,"period":47,"slash":44,"backslash":42,"semicolon":41,"apostrophe":39,"grave":50,"bracketleft":33,"bracketright":30]
    for (alias,name) in [("arrowleft","left"),("arrowright","right"),("arrowup","up"),("arrowdown","down")] { codes[alias]=codes[name] }
    return codes
}()

func modifiers(_ text: String?) throws -> CGEventFlags {
    guard let text, !text.isEmpty else { return [] }
    var flags: CGEventFlags = []
    for part in text.lowercased().split(separator:"+") {
        guard let flag=modifierFlags[String(part)] else { try deny("Unknown modifier \(part)") }
        flags.insert(flag)
    }
    return flags
}
func combo(_ text: String) throws -> (CGKeyCode,CGEventFlags) {
    let parts=text.split(separator:"+",omittingEmptySubsequences:false).map { String($0) }
    guard let last=parts.last, !last.isEmpty || text.hasSuffix("+") else { try deny("Empty key") }
    let keyName=last.isEmpty ? "+" : last
    let flags=try modifiers(parts.dropLast().joined(separator:"+"))
    let lower=keyName.lowercased().replacingOccurrences(of:"-",with:"_")
    if let code=keyCodes[lower] ?? keyCodes[keyName] { return (code,flags.union(keyName.count == 1 && keyName != lower ? .maskShift : [])) }
    if let code=modifierKeys[lower] { return (code,flags) }
    if keyName == "+" { return (24,flags.union(.maskShift)) }
    try deny("Unsupported key \(keyName)")
}
func press(_ code: CGKeyCode, _ flags: CGEventFlags, down: Bool) {
    let event=CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:down)
    event?.flags=flags; event?.post(tap:.cghidEventTap)
}
func typeText(_ text: String) async {
    for character in text {
        if character == "\n" || character == "\r\n" { press(36,[],down:true); press(36,[],down:false) }
        else {
            let units=Array(String(character).utf16)
            for down in [true,false] {
                let event=CGEvent(keyboardEventSource:source,virtualKey:0,keyDown:down)
                event?.flags=[]; event?.keyboardSetUnicodeString(stringLength:units.count,unicodeString:units)
                event?.post(tap:.cghidEventTap)
            }
        }
        try? await Task.sleep(for:.milliseconds(6))
    }
}

// MARK: - Actions

@MainActor var halted=false
@MainActor var heldAt: CGPoint?
@MainActor var lastPoint: CGPoint?

@MainActor
func halt() {
    halted=true
    if let p=heldAt { mouse(.leftMouseUp,p); heldAt=nil }
    NovaCursor.shared.vanish()
}

@MainActor
func perform(_ request: [String:Any]) async throws -> [String:Any] {
    let action=request["action"] as? String ?? ""
    let display=Display.main()
    if action == "begin" { halted=false; return ["width":Int(display.imageSize.width),"height":Int(display.imageSize.height)] }
    let scope=try readScope(request)
    let looking=["screenshot","zoom","cursor_position"].contains(action)
    if halted && !looking { try deny("Stopped on the Mac with Control-Option-S. Send a new request to start again.") }
    guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else { try deny("Allow Nova Operator in macOS Accessibility and Screen Recording settings.") }
    func coordinate(_ key: String = "coordinate") throws -> CGPoint? {
        guard let raw=request[key] else { return nil }
        guard let pair=raw as? [Double], pair.count == 2, pair.allSatisfy({ $0.isFinite }),
              (0...display.imageSize.width).contains(pair[0]), (0...display.imageSize.height).contains(pair[1]) else { try deny("Coordinate outside the screen") }
        let p=display.point(pair[0],pair[1])
        try checkPoint(scope,p)
        return p
    }
    func pointer() throws -> CGPoint { let p=lastPoint ?? realPointer(); try checkPoint(scope,p); return p }
    let cursor=NovaCursor.shared
    // Matthew's own input from the iPhone moves the real pointer, without Nova's cursor.
    let direct=request["direct"] as? Bool == true
    func fly(_ p: CGPoint) async { if !direct { await cursor.fly(to:p) } }
    func restore(_ p: CGPoint) async { if !direct { await restorePointer(p) } }
    defer { if heldAt == nil { cursor.idle() } }
    switch action {
    case "screenshot":
        return try await capture(scope:scope)
    case "zoom":
        guard let region=request["region"] as? [Double], region.count == 4, region.allSatisfy({ $0.isFinite }),
              region[2] > region[0], region[3] > region[1] else { try deny("Invalid zoom region") }
        let a=display.point(max(0,region[0]),max(0,region[1])), b=display.point(min(display.imageSize.width,region[2]),min(display.imageSize.height,region[3]))
        return try await capture(region:CGRect(x:a.x-display.bounds.minX,y:a.y-display.bounds.minY,width:b.x-a.x,height:b.y-a.y),scope:scope)
    case "open_app":
        guard let bundle=request["bundle_id"] as? String, bundle.range(of:bundlePattern,options:.regularExpression) != nil else { try deny("Missing app") }
        guard scope.allows(bundle) else { try deny("That app isn't one Nova may use") }
        guard let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundle) else { try deny("That app isn't installed") }
        let configuration=NSWorkspace.OpenConfiguration(); configuration.activates=true
        _ = try await NSWorkspace.shared.openApplication(at:url,configuration:configuration)
        try? await Task.sleep(for:.milliseconds(700))
    case "left_click","right_click","middle_click","double_click","triple_click":
        try checkKeys(scope,request["text"] as? String,modifiersOnly:true)
        let p=try coordinate() ?? pointer(), flags=try modifiers(request["text"] as? String)
        let (button,down,up):(CGMouseButton,CGEventType,CGEventType)=action == "right_click" ? (.right,.rightMouseDown,.rightMouseUp) : action == "middle_click" ? (.center,.otherMouseDown,.otherMouseUp) : (.left,.leftMouseDown,.leftMouseUp)
        let count=action == "double_click" ? 2 : action == "triple_click" ? 3 : 1
        let real=realPointer()
        await fly(p)
        mouse(.mouseMoved,p)
        for click in 1...count { mouse(down,p,button,clicks:click,flags:flags); mouse(up,p,button,clicks:click,flags:flags) }
        if !direct { cursor.view.pulse() }; lastPoint=p
        await restore(real)
    case "mouse_move":
        guard let p=try coordinate() else { try deny("Missing coordinate") }
        await fly(p)
        if heldAt != nil { mouse(.leftMouseDragged,p); heldAt=p } else { mouse(.mouseMoved,p) }
        lastPoint=p
    case "left_mouse_down":
        let p=try pointer()
        await cursor.fly(to:p); mouse(.leftMouseDown,p); heldAt=p
    case "left_mouse_up":
        let p=heldAt ?? lastPoint ?? realPointer()
        mouse(.leftMouseUp,p); heldAt=nil; cursor.view.pulse()
    case "left_click_drag":
        guard let start=try coordinate("start_coordinate"), let end=try coordinate() else { try deny("Missing drag coordinates") }
        try checkKeys(scope,request["text"] as? String,modifiersOnly:true)
        let flags=try modifiers(request["text"] as? String), real=realPointer()
        await fly(start)
        mouse(.mouseMoved,start); mouse(.leftMouseDown,start,flags:flags)
        for step in 1...16 {
            let t=CGFloat(step)/16, p=CGPoint(x:start.x+(end.x-start.x)*t,y:start.y+(end.y-start.y)*t)
            mouse(.leftMouseDragged,p,flags:flags)
            if !direct { cursor.panel.setFrameOrigin(cursor.origin(p)) }
            try? await Task.sleep(for:.milliseconds(20))
        }
        mouse(.leftMouseUp,end,flags:flags); lastPoint=end
        await restore(real)
    case "cursor_position":
        return ["text":"\(display.image(lastPoint ?? realPointer()))"]
    case "scroll":
        try checkKeys(scope,request["text"] as? String,modifiersOnly:true)
        let p=try coordinate() ?? pointer(), flags=try modifiers(request["text"] as? String)
        guard let direction=request["scroll_direction"] as? String, ["up","down","left","right"].contains(direction) else { try deny("Invalid scroll direction") }
        let amount=Int32(max(1,min(30,(request["scroll_amount"] as? Double ?? 3))))
        let real=realPointer()
        await fly(p); mouse(.mouseMoved,p)
        for _ in 0..<amount {
            let vertical:Int32=direction == "up" ? 3 : direction == "down" ? -3 : 0, horizontal:Int32=direction == "left" ? 3 : direction == "right" ? -3 : 0
            let event=CGEvent(scrollWheelEvent2Source:source,units:.line,wheelCount:2,wheel1:vertical,wheel2:horizontal,wheel3:0)
            event?.location=p; event?.flags=flags; event?.post(tap:.cghidEventTap)
            try? await Task.sleep(for:.milliseconds(15))
        }
        lastPoint=p
        await restore(real)
    case "type":
        guard let text=request["text"] as? String, !text.isEmpty, text.count <= 5000 else { try deny("Type 1–5000 characters") }
        try checkFrontmost(scope)
        await typeText(text)
    case "key":
        guard let text=request["text"] as? String else { try deny("Missing key") }
        try checkKeys(scope,text); try checkFrontmost(scope)
        let (code,flags)=try combo(text), times=Int(max(1,min(100,request["repeat"] as? Double ?? 1)))
        for _ in 0..<times { press(code,flags,down:true); press(code,flags,down:false); try? await Task.sleep(for:.milliseconds(15)) }
    case "hold_key":
        guard let text=request["text"] as? String else { try deny("Missing key") }
        try checkKeys(scope,text); try checkFrontmost(scope)
        let (code,flags)=try combo(text), duration=max(0,min(30,request["duration"] as? Double ?? 1))
        press(code,flags,down:true)
        try? await Task.sleep(for:.milliseconds(Int(duration*1000)))
        press(code,flags,down:false)
    default:
        try deny("Unsupported action \(action)")
    }
    if halted && !looking { try deny("Stopped on the Mac with Control-Option-S.") }
    return ["text":"OK"]
}

// MARK: - Authorization

func authorize(_ envelope: [String:String]) throws -> [String:Any] {
    guard let dataDirectory=Locations.current?.data else { try deny("Unsigned configuration") }
    // Trusted configuration is part of the signed bundle. The caller/model
    // cannot select a different key and mint its own authorization.
    let keyURL=URL(fileURLWithPath:dataDirectory).appendingPathComponent("operator.key")
    let attributes=try FileManager.default.attributesOfItem(atPath:keyURL.path)
    guard (attributes[.posixPermissions] as? Int ?? 0) & 0o077 == 0 else {try deny("Unsafe key permissions")}
    let key=SymmetricKey(data:try Data(contentsOf:keyURL))
    guard let payload=Data(base64Encoded:envelope["payload"] ?? ""),let mac=Data(base64Encoded:envelope["mac"] ?? ""),
          HMAC<SHA256>.isValidAuthenticationCode(mac,authenticating:payload,using:key),
          let request=try JSONSerialization.jsonObject(with:payload) as? [String:Any],
          let expires=request["expires"] as? Double, expires > Date().timeIntervalSince1970, expires <= Date().timeIntervalSince1970+10,
          let nonce=request["nonce"] as? String, nonce.range(of:"^[a-f0-9]{32}$",options:.regularExpression) != nil else {try deny("Invalid or expired action authorization")}
    let directory=keyURL.deletingLastPathComponent().appendingPathComponent("operator-nonces")
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    let fd=open(directory.appendingPathComponent(nonce).path,O_WRONLY|O_CREAT|O_EXCL,0o600)
    guard fd >= 0 else {try deny("Action token already used")}; close(fd)
    return request
}

func permissionState() -> [String:Any] { ["accessibility":AXIsProcessTrusted(),"screenRecording":CGPreflightScreenCaptureAccess()] }
/// Shows macOS's own prompts. Granting stays a person's choice in System Settings.
func requestPermissions() {
    if !AXIsProcessTrusted() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary) }
    if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
}
func openPrivacySettings(_ pane: String) {
    if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
}
func encode(_ value:[String:Any]) -> Data { (try? JSONSerialization.data(withJSONObject:value,options:.sortedKeys)) ?? Data("{\"error\":\"Encoding failed\"}".utf8) }

@MainActor
func respond(_ raw: Data) async -> [String:Any] {
    do {
        guard raw.count < 20000, let message=try JSONSerialization.jsonObject(with:raw) as? [String:Any],
              let command=message["command"] as? String else { try deny("Unsupported request") }
        if command == "permissions" { return permissionState() }
        // The owner iPhone can ask for the prompts to appear on the Mac; someone at the Mac still decides.
        if command == "request_permissions" { requestPermissions(); return permissionState() }
        if command == "show_setup" { SetupWindow.shared.show(); return ["shown":true] }
        guard command == "execute", let envelope=message["envelope"] as? [String:String] else { try deny("Unsupported request") }
        return try await perform(try authorize(envelope))
    } catch OperatorError.denied(let reason) { return ["error":reason] }
    catch { return ["error":"macOS operation failed. Check permissions and try again."] }
}

// MARK: - Socket

// Core talks to this long-running app over a Unix socket in a 0700 directory, so
// macOS attributes Accessibility and Screen Recording to Nova Operator itself.
// sun_path is limited to 104 bytes, which rules out the project's .nova-data path.
let supportDirectory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
    .appendingPathComponent("Nova Operator",isDirectory:true)
let socketURL=supportDirectory.appendingPathComponent("operator.sock")

/// Where Core, its runtime and Nova's saved data live; mirrors core/paths.mjs.
/// A development build signs explicit checkout paths into Info.plist. A packaged app
/// (NovaLayout=app) derives them from its own signed bundle and Application Support,
/// so it keeps working after the app is moved and needs no checkout or system Node.
struct Locations {
    let layout:String, node:String, root:String, data:String
    static let current:Locations? = {
        let bundle=Bundle.main
        if bundle.object(forInfoDictionaryKey:"NovaLayout") as? String == "app" {
            guard let resources=bundle.resourcePath else { return nil }
            return Locations(layout:"app",node:bundle.bundleURL.appendingPathComponent("Contents/Helpers/node").path,root:resources,data:supportDirectory.path)
        }
        guard let node=bundle.object(forInfoDictionaryKey:"NovaNodePath") as? String,
              let root=bundle.object(forInfoDictionaryKey:"NovaCoreRoot") as? String,
              let data=bundle.object(forInfoDictionaryKey:"NovaCoreDataDirectory") as? String else { return nil }
        return Locations(layout:"development",node:node,root:root,data:data)
    }()
}

func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    var address=sockaddr_un(); address.sun_family=sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of:&address.sun_path) { buffer in for (i,byte) in path.utf8.prefix(buffer.count-1).enumerated() { buffer[i]=byte } }
    return withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { body($0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
}

func tellRunning(_ command: String) -> Bool {
    let client=socket(AF_UNIX,SOCK_STREAM,0)
    guard client >= 0, withAddress(socketURL.path,{ connect(client,$0,$1) }) == 0 else { close(client); return false }
    let data=encode(["command":command])
    data.withUnsafeBytes { bytes in _ = write(client,bytes.baseAddress,data.count) }
    shutdown(client,SHUT_WR)
    var buffer=[UInt8](repeating:0,count:1024)
    let count=read(client,&buffer,buffer.count)
    close(client)
    return count > 0
}

func startServer() throws {
    let path=socketURL.path
    try FileManager.default.createDirectory(at:socketURL.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    chmod(socketURL.deletingLastPathComponent().path,0o700)
    if tellRunning("permissions") { try deny("Nova Operator is already running") }
    unlink(path)
    let server=socket(AF_UNIX,SOCK_STREAM,0)
    guard server >= 0, withAddress(path,{ bind(server,$0,$1) }) == 0, listen(server,8) == 0 else { try deny("Could not open the Nova Operator socket") }
    chmod(path,0o600)
    Thread.detachNewThread {
        while true {
            let client=accept(server,nil,nil)
            guard client >= 0 else { continue }
            var uid=uid_t(0), gid=gid_t(0)
            if getpeereid(client,&uid,&gid) == 0, uid == getuid() { serve(client) }
            close(client)
        }
    }
}

func serve(_ client: Int32) {
    var timeout=timeval(tv_sec:5,tv_usec:0)
    setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
    var raw=Data(), buffer=[UInt8](repeating:0,count:4096)
    while raw.count < 20000 {
        let count=read(client,&buffer,buffer.count)
        if count <= 0 { break }
        raw.append(contentsOf:buffer[0..<count])
    }
    let done=DispatchSemaphore(value:0)
    var reply=Data()
    Task { @MainActor in reply=encode(await respond(raw)); done.signal() }
    done.wait()
    reply.withUnsafeBytes { bytes in
        var offset=0
        while offset < bytes.count {
            let written=write(client,bytes.baseAddress!+offset,bytes.count-offset)
            if written <= 0 { break }
            offset+=written
        }
    }
}

// MARK: - Setup window

/// Runs Nova Core's local setup commands. Paths come from the signed bundle (Locations), and a key is
/// passed on stdin so it never appears in a process list.
enum CoreCLI {
    static func run(_ arguments: [String], input: String? = nil) async -> [String:Any] {
        guard let locations=Locations.current else { return ["error":"Rebuild Nova Operator with npm run operator:build."] }
        let (node,root,data)=(locations.node,locations.root,locations.data)
        return await withCheckedContinuation { done in
            DispatchQueue.global().async {
                let process=Process(), output=Pipe(), stdin=Pipe()
                process.executableURL=URL(fileURLWithPath:node)
                process.arguments=[root+"/core/cli.mjs"]+arguments+["--json"]
                process.currentDirectoryURL=URL(fileURLWithPath:root)
                // Core resolves its key, logs and database from NOVA_DATA_DIR (core/paths.mjs).
                process.environment=["HOME":NSHomeDirectory(),"PATH":"/usr/bin:/bin:/usr/sbin:/sbin","NOVA_DATA_DIR":data,"NOVA_DB":data+"/nova.sqlite"]
                process.standardOutput=output; process.standardError=FileHandle.nullDevice; process.standardInput=stdin
                do { try process.run() } catch { done.resume(returning:["error":"Could not start Nova Core's setup tool."]); return }
                if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
                try? stdin.fileHandleForWriting.close()
                let bytes=output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let line=String(decoding:bytes,as:UTF8.self).split(separator:"\n").last.map(String.init) ?? ""
                done.resume(returning:(try? JSONSerialization.jsonObject(with:Data(line.utf8))) as? [String:Any] ?? ["error":"Nova Core's setup tool didn't answer."])
            }
        }
    }
}

struct PairingCode { let short: String; let link: String?; let expires: Date; let owner: Bool }
struct PairedDevice: Identifiable { let id: String; let name: String; let owner: Bool; let created: String }
struct ConnectionCheck: Identifiable {
    let id: String, title: String, status: String, message: String
    let hint: String?
    var symbol: String { status == "pass" ? "checkmark.circle.fill" : status == "fail" ? "xmark.circle.fill" : status == "warning" ? "exclamationmark.triangle.fill" : "questionmark.circle" }
    var color: Color { status == "pass" ? .green : status == "fail" ? .red : status == "warning" ? .orange : .secondary }
}

@MainActor
final class SetupModel: ObservableObject {
    @Published var computer=""
    @Published var tailscaleInstalled=false
    @Published var tailscaleRunning=false
    @Published var funnel=false
    @Published var url: String?
    @Published var devices: [PairedDevice]=[]
    @Published var stopped=false
    @Published var level="chat"
    @Published var claude: String?
    @Published var openai: String?
    @Published var provider="anthropic"
    @Published var code: PairingCode?
    @Published var ownerCode=true
    @Published var notice: String?
    @Published var busy=false
    @Published var accessibility=AXIsProcessTrusted()
    @Published var screenRecording=CGPreflightScreenCaptureAccess()
    @Published var keyProvider="anthropic"
    @Published var key=""
    @Published var keyResult: (ok: Bool, text: String)?
    @Published var connectionChecks: [ConnectionCheck]=[]
    @Published var diagnosticReport=""
    @Published var checkingConnection=false
    @Published var reportCopied=false
    @Published var now=Date()
    var loaded=false

    func refresh() async {
        let s=await CoreCLI.run(["setup"])
        if let error=s["error"] as? String { notice=error; return }
        computer=s["computer"] as? String ?? ""
        let tail=s["tailscale"] as? [String:Any] ?? [:]
        tailscaleInstalled=tail["installed"] as? Bool ?? false; tailscaleRunning=tail["running"] as? Bool ?? false
        funnel=tail["funnel"] as? Bool ?? false; url=tail["url"] as? String
        stopped=s["stopped"] as? Bool ?? false
        level=(s["access"] as? [String:Any])?["level"] as? String ?? "chat"
        let ai=s["ai"] as? [String:Any] ?? [:]
        provider=ai["selected"] as? String ?? "anthropic"
        claude=(ai["anthropic"] as? [String:Any])?["storage"] as? String
        openai=(ai["openai"] as? [String:Any])?["storage"] as? String
        devices=(s["devices"] as? [[String:Any]] ?? []).map { PairedDevice(id:$0["id"] as? String ?? "",name:$0["name"] as? String ?? "Device",owner:$0["owner"] as? Bool ?? false,created:$0["created_at"] as? String ?? "") }
        if !loaded { ownerCode = !devices.contains(where:\.owner); loaded=true }
        tick()
    }
    func tick() {
        now=Date(); accessibility=AXIsProcessTrusted(); screenRecording=CGPreflightScreenCaptureAccess()
        if let code, code.expires <= now { self.code=nil }
    }
    func perform(_ arguments: [String], input: String? = nil) async -> [String:Any] {
        busy=true; defer { busy=false }
        let result=await CoreCLI.run(arguments,input:input)
        notice=result["error"] as? String
        await refresh()
        return result
    }
    func pair() async {
        let r=await perform(["pair"]+(ownerCode ? ["--owner"] : []))
        guard let short=r["short"] as? String, let expires=r["expiresMs"] as? Double else { return }
        code=PairingCode(short:short,link:r["link"] as? String,expires:Date(timeIntervalSince1970:expires/1000),owner:ownerCode)
    }
    func saveKey() async {
        let value=key.trimmingCharacters(in:.whitespacesAndNewlines)
        key=""
        let r=await perform(["key","set",keyProvider],input:value)
        if let error=r["error"] as? String { keyResult=(false,error); notice=nil }
        else if let test=r["test"] as? [String:Any] { keyResult=(test["ok"] as? Bool ?? false,"Saved in the Keychain. "+(test["message"] as? String ?? "")) }
    }
    func checkConnection() async {
        guard !busy else { return }
        busy=true; checkingConnection=true; reportCopied=false
        defer { busy=false; checkingConnection=false }
        let result=await CoreCLI.run(["diagnostics"])
        guard result["schemaVersion"] as? Int == 1,
              let rows=result["checks"] as? [[String:Any]],
              let data=try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]) else {
            connectionChecks=[]; diagnosticReport=""
            notice="The connection check could not finish. Reopen Nova on the Mac and try again."
            return
        }
        connectionChecks=rows.compactMap { row in
            guard let id=row["id"] as? String, let title=row["title"] as? String,
                  let status=row["status"] as? String, let message=row["message"] as? String else { return nil }
            return ConnectionCheck(id:id,title:title,status:status,message:message,hint:row["hint"] as? String)
        }
        diagnosticReport=String(decoding:data,as:UTF8.self)
        notice=nil
    }
    func copyDiagnosticReport() {
        guard !diagnosticReport.isEmpty else { return }
        NSPasteboard.general.clearContents()
        reportCopied=NSPasteboard.general.setString(diagnosticReport,forType:.string)
    }
}

struct NovaBadge: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .fill(LinearGradient(colors: [Color.blue.opacity(0.12), Color.purple.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(spacing: 10) {
                HStack(spacing: 15) {
                    Capsule().frame(width: 12, height: 23).rotationEffect(.degrees(3))
                    Capsule().frame(width: 12, height: 23).rotationEffect(.degrees(-3))
                }
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 0))
                    p.addQuadCurve(to: CGPoint(x: 19, y: 0), control: CGPoint(x: 9.5, y: 12))
                }.stroke(style: StrokeStyle(lineWidth: 3, lineCap: .round)).frame(width: 19, height: 7)
            }
            .foregroundStyle(Color(red: 0.25, green: 0.67, blue: 0.90))
            RoundedRectangle(cornerRadius: 23, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.75)
        }
        .frame(width: 80, height: 80)
        .accessibilityElement().accessibilityLabel("Nova, smiling")
    }
}

struct NovaMacBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [Color.purple.opacity(0.08), .clear], center: .topTrailing, startRadius: 0, endRadius: 650)
        }.ignoresSafeArea().allowsHitTesting(false)
    }
}

struct SetupCard<Content: View>: View {
    let title: String, symbol: String, done: Bool
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing:8) {
                Image(systemName:done ? "checkmark.circle.fill" : symbol).foregroundStyle(done ? Color.green : Color.accentColor).font(.title3)
                Text(title).font(.headline)
            }
            .accessibilityElement(children:.combine).accessibilityAddTraits(.isHeader)
            .accessibilityValue(done ? "Done" : "To do")
            content
        }
        .padding(22).frame(maxWidth:.infinity,alignment:.leading)
        .background(RoundedRectangle(cornerRadius:22,style:.continuous).fill(Color(nsColor: .controlBackgroundColor).opacity(0.75)))
        .overlay { RoundedRectangle(cornerRadius:22,style:.continuous).strokeBorder(Color.primary.opacity(0.07),lineWidth:0.5) }
    }
}

func qrImage(_ text: String) -> NSImage? {
    let filter=CIFilter.qrCodeGenerator()
    filter.message=Data(text.utf8); filter.correctionLevel="M"
    guard let output=filter.outputImage?.transformed(by:CGAffineTransform(scaleX:10,y:10)) else { return nil }
    let rep=NSCIImageRep(ciImage:output), image=NSImage(size:rep.size)
    image.addRepresentation(rep)
    return image
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    @State var confirmRevoke: PairedDevice?
    @State var confirmFull=false
    @State var showConnectionChecks=false
    let timer=Timer.publish(every:1,on:.main,in:.common).autoconnect()
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:14) {
                HStack(spacing:16) {
                    NovaBadge()
                    VStack(alignment:.leading,spacing:4) {
                        Text("Nova").font(.system(size:32,weight:.semibold)).tracking(-1)
                        Text("Your ideas. Nova’s here to help.\nConnect your iPhone and make Nova yours.")
                            .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                }
                if let notice=model.notice { Label(notice,systemImage:"exclamationmark.triangle.fill").foregroundStyle(.orange) }
                if model.stopped {
                    SetupCard(title:"Nova is stopped",symbol:"stop.circle",done:false) {
                        Text("Someone pressed Emergency stop. Nova won't do anything until you resume it here on the Mac.")
                        Button("Resume Nova") { Task { _ = await model.perform(["resume"]) } }.controlSize(.large)
                    }
                }
                connection
                diagnosticsCard
                pairing
                rangeCard
                permissionsCard
                aiCard
                devicesCard
            }
            .padding(28)
        }
        .background(NovaMacBackground())
        .tint(.blue)
        .buttonStyle(.bordered)
        .controlSize(.large)
        .frame(minWidth:560,minHeight:600)
        .onReceive(timer) { _ in model.tick() }
        .confirmationDialog("Remove \(confirmRevoke?.name ?? "this device")?",isPresented:Binding(get:{ confirmRevoke != nil },set:{ if !$0 { confirmRevoke=nil } }),presenting:confirmRevoke) { device in
            Button("Remove",role:.destructive) { Task { _ = await model.perform(["revoke",device.id]) } }
        } message: { _ in Text("It will need a new pairing code to use Nova again.") }
        .confirmationDialog("Let Nova use the whole Mac?",isPresented:$confirmFull) {
            Button("Allow Whole Mac") { Task { _ = await model.perform(["access","full"]) } }
        } message: { Text("Nova will see the whole screen and use any app with the mouse and keyboard, without asking each time. You can stop it any time with Control-Option-S.") }
    }

    var connection: some View {
        SetupCard(title:"Private connection",symbol:"lock.shield",done:model.url != nil && !model.funnel) {
            if !model.tailscaleInstalled {
                Text("Nova connects your iPhone to this Mac through Tailscale, a free private network only your devices can join.")
                Link("Get Tailscale for Mac",destination:URL(string:"https://tailscale.com/download/mac")!)
            } else if !model.tailscaleRunning {
                Text("Open Tailscale and sign in. Use the same account on your iPhone.")
                Button("Open Tailscale") { NSWorkspace.shared.open(URL(fileURLWithPath:"/Applications/Tailscale.app")) }
            } else if let url=model.url {
                Text(url).font(.body.monospaced()).textSelection(.enabled)
                Text("Only devices signed in to your Tailscale can reach this address, and each one still has to pair.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Turn on private access so your iPhone can reach Nova on this Mac. Nothing is opened to the public internet.")
                Button("Turn On Private Access") { Task { _ = await model.perform(["serve","on"]) } }.disabled(model.busy)
            }
            if model.funnel {
                Label("Tailscale Funnel is on, which makes a site on this Mac public. Nova still requires pairing, but turn Funnel off in Tailscale unless you need it.",systemImage:"exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }

    var pairing: some View {
        SetupCard(title:"Connect your iPhone",symbol:"iphone.radiowaves.left.and.right",done:!model.devices.isEmpty) {
            if let code=model.code {
                HStack(alignment:.top,spacing:18) {
                    if let link=code.link, let image=qrImage(link) {
                        Image(nsImage:image).interpolation(.none).resizable().frame(width:200,height:200)
                            .padding(8).background(Color.white).clipShape(RoundedRectangle(cornerRadius:10))
                            .accessibilityLabel("Pairing QR code. Scan it with the Nova app on your iPhone.")
                    }
                    VStack(alignment:.leading,spacing:8) {
                        Text("Open Nova on your iPhone and scan this code.").fixedSize(horizontal:false,vertical:true)
                        Text(code.short).font(.system(size:30,weight:.medium,design:.monospaced)).textSelection(.enabled)
                            .accessibilityLabel("Code \(code.short.map { String($0) }.joined(separator:" "))")
                        let left=max(0,Int(code.expires.timeIntervalSince(model.now)))
                        Text("Works once. Expires in \(left/60):\(String(format:"%02d",left%60)).").foregroundStyle(.secondary)
                        if code.owner { Label("This iPhone will be able to control the Mac",systemImage:"crown").font(.callout) }
                        if code.link == nil { Text("Turn on private access first so the QR code includes this Mac's address.").font(.callout).foregroundStyle(.orange) }
                        Button("New Code") { Task { await model.pair() } }
                    }
                }
            } else {
                Toggle("This iPhone controls the Mac",isOn:$model.ownerCode)
                Text(model.ownerCode ? "This iPhone will control the Mac. If another phone controls it, control transfers to this one." : "Conversation only. Turn this on if you want this iPhone to control the Mac, even when Whole Mac access is already enabled.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Show Pairing Code") { Task { await model.pair() } }.controlSize(.large).disabled(model.busy)
            }
        }
    }

    var diagnosticsCard: some View {
        SetupCard(title:"Connection check",symbol:"stethoscope",done:!model.connectionChecks.isEmpty && model.connectionChecks.allSatisfy { $0.status == "pass" }) {
            Text("Find out what needs attention on this Mac. This check won’t change your settings or run an AI task.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(model.checkingConnection ? "Checking…" : "Check Connection") {
                    Task {
                        await model.checkConnection()
                        showConnectionChecks=model.connectionChecks.contains { $0.status != "pass" }
                    }
                }
                    .disabled(model.busy)
                if model.checkingConnection { ProgressView().controlSize(.small).accessibilityLabel("Checking the connection") }
                if !model.diagnosticReport.isEmpty {
                    Button(model.reportCopied ? "Report Copied" : "Copy Support Report") { model.copyDiagnosticReport() }
                        .disabled(model.checkingConnection)
                }
            }
            if !model.connectionChecks.isEmpty {
                Text(model.connectionChecks.allSatisfy { $0.status == "pass" } ? "All \(model.connectionChecks.count) Mac checks passed." : "Some checks need attention.")
                    .font(.callout.bold())
                DisclosureGroup("Show all checks",isExpanded:$showConnectionChecks) {
                    VStack(alignment:.leading,spacing:12) {
                        ForEach(model.connectionChecks) { check in
                            HStack(alignment:.top,spacing:10) {
                                Image(systemName:check.symbol).foregroundStyle(check.color).frame(width:18)
                                VStack(alignment:.leading,spacing:3) {
                                    Text(check.title).font(.callout.bold())
                                    Text(check.message).font(.callout)
                                    if let hint=check.hint { Text(hint).font(.callout).foregroundStyle(.secondary) }
                                }
                            }
                            .accessibilityElement(children:.ignore)
                            .accessibilityLabel(check.title+". "+check.message+(check.hint.map { " "+$0 } ?? ""))
                            .accessibilityValue(check.status)
                        }
                    }.padding(.top,8).accessibilityElement(children:.contain)
                }
                Text("Mac checks only. Confirm the iPhone connection and try an AI task separately.")
                    .font(.callout).foregroundStyle(.secondary)
                DisclosureGroup("Preview support report") {
                    ScrollView {
                        Text(model.diagnosticReport).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth:.infinity,alignment:.leading)
                    }.frame(maxHeight:180)
                }
                Text("The report contains check results and runtime versions. It excludes keys, codes, hostnames, device names, task text, screenshots and logs. Nothing is sent automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var rangeCard: some View {
        SetupCard(title:"Your access settings",symbol:"slider.horizontal.3",done:true) {
            Text(["chat":"Just chat. Nova talks and researches the web, but can't see or use this Mac.",
                  "apps":"Chosen apps and folders, picked on your iPhone.",
                  "full":"Whole Mac. Nova can see the screen and use any app."][model.level] ?? model.level)
            HStack {
                Button("Just Chat") { Task { _ = await model.perform(["access","chat"]) } }.disabled(model.level == "chat")
                Button("Whole Mac…") { confirmFull=true }.disabled(model.level == "full")
            }
            Text("To choose specific apps and folders, use Range in the Nova app on your iPhone.").font(.callout).foregroundStyle(.secondary)
        }
    }

    var permissionsCard: some View {
        SetupCard(title:"Mac permissions",symbol:"hand.raised",done:model.level == "chat" || (model.accessibility && model.screenRecording)) {
            if model.level == "chat" { Text("Not needed while Nova's range is Just chat.").foregroundStyle(.secondary) }
            permissionRow("Screen Recording","lets Nova see the apps it may use.",model.screenRecording,"Privacy_ScreenCapture")
            permissionRow("Accessibility","lets Nova click and type in those apps.",model.accessibility,"Privacy_Accessibility")
        }
    }
    func permissionRow(_ name: String, _ purpose: String, _ allowed: Bool, _ pane: String) -> some View {
        HStack {
            Image(systemName:allowed ? "checkmark.circle.fill" : "circle").foregroundStyle(allowed ? Color.green : Color.secondary)
            VStack(alignment:.leading) { Text(name).bold(); Text(purpose).font(.callout).foregroundStyle(.secondary) }
            Spacer()
            if !allowed { Button("Allow…") { requestPermissions(); openPrivacySettings(pane) } }
        }
        .accessibilityElement(children:.combine).accessibilityValue(allowed ? "Allowed" : "Not allowed")
    }

    var aiCard: some View {
        SetupCard(title:"Your AI provider",symbol:"sparkles",done:(model.provider == "openai" ? model.openai : model.claude) != nil) {
            providerRow("Claude","anthropic",model.claude)
            providerRow("OpenAI","openai",model.openai)
            if model.claude == "file" {
                Button("Move Claude Key to the Keychain") { Task { _ = await model.perform(["key","import"]) } }
            }
            Picker("Provider",selection:$model.keyProvider) { Text("Claude").tag("anthropic"); Text("OpenAI").tag("openai") }.pickerStyle(.segmented)
            if model.keyProvider == "openai" {
                Label("OpenAI bills API use separately. A ChatGPT Plus or Pro subscription doesn't include it.",systemImage:"info.circle").font(.callout)
            }
            HStack {
                SecureField(model.keyProvider == "openai" ? "OpenAI API key (sk-…)" : "Claude API key (sk-ant-…)",text:$model.key)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("API key")
                Button("Save & Test") { Task { await model.saveKey() } }.disabled(model.key.isEmpty || model.busy)
            }
            Text("Saved in this Mac's Keychain. Testing only lists models, so it doesn't cost anything.").font(.callout).foregroundStyle(.secondary)
            if let result=model.keyResult { Label(result.text,systemImage:result.ok ? "checkmark.circle" : "exclamationmark.triangle").foregroundStyle(result.ok ? Color.green : Color.orange) }
        }
    }
    func providerRow(_ name: String, _ id: String, _ storage: String?) -> some View {
        HStack {
            Text(name).bold()
            Text(storage == nil ? "Not connected" : storage == "keychain" ? "In the Keychain" : "In .env.local").foregroundStyle(.secondary)
            Spacer()
            if model.provider == id && storage != nil { Text("In use").font(.callout.bold()).foregroundStyle(Color.accentColor) }
            else if storage != nil { Button("Use") { Task { _ = await model.perform(["provider",id]) } } }
        }
    }

    var devicesCard: some View {
        SetupCard(title:"Paired devices",symbol:"person.2",done:false) {
            if model.devices.isEmpty { Text("Nothing is paired yet.").foregroundStyle(.secondary) }
            ForEach(model.devices) { device in
                HStack {
                    Image(systemName:device.owner ? "crown.fill" : "iphone").foregroundStyle(device.owner ? Color.yellow : Color.secondary)
                    VStack(alignment:.leading) {
                        Text(device.name).bold()
                        Text(device.owner ? "Controls this Mac" : "Can chat").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove…") { confirmRevoke=device }
                }
                .accessibilityElement(children:.combine)
            }
        }
    }
}

@MainActor
final class SetupWindow {
    static let shared=SetupWindow()
    let model=SetupModel()
    var window: NSWindow?
    func show(pairing: Bool = false) {
        if window == nil {
            let w=NSWindow(contentRect:NSRect(x:0,y:0,width:720,height:820),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
            w.title="Nova"; w.isReleasedWhenClosed=false
            w.titlebarAppearsTransparent=true
            w.toolbarStyle = .unified
            w.minSize=NSSize(width:560,height:600)
            w.contentView=NSHostingView(rootView:SetupView(model:model))
            w.center()
            window=w
        }
        NSApp.activate(ignoringOtherApps:true)
        window?.makeKeyAndOrderFront(nil)
        Task { await model.refresh(); if pairing { await model.pair() } }
    }
}

// MARK: - Menu bar app

func registerStopShortcut() {
    var spec=EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(),{ _,_,_ in Task { @MainActor in halt() }; return noErr },1,&spec,nil,nil)
    var reference: EventHotKeyRef?
    RegisterEventHotKey(UInt32(kVK_ANSI_S),UInt32(controlKey|optionKey),EventHotKeyID(signature:0x4E4F5641,id:1),GetApplicationEventTarget(),0,&reference)
}

@MainActor
final class StatusMenu: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try startServer() }
        catch {
            // Opening Applications/Nova Operator while the menu-bar copy is already
            // running used to exit quietly. Ask that copy to show the setup window.
            if tellRunning("show_setup") { exit(0) }
            print("Nova Operator: \(error)"); exit(0)
        }
        item=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        item.button?.image=NSImage(systemSymbolName:"cursorarrow.rays",accessibilityDescription:"Nova Operator")
        let menu=NSMenu(); menu.delegate=self; item.menu=menu
        registerStopShortcut()
        // Permissions are asked for only when someone chooses a range that needs them.
        // Until anything is paired, open setup so a new Mac starts in the right place.
        Task { @MainActor in
            let setup=await CoreCLI.run(["setup"])
            if (setup["devices"] as? [Any])?.isEmpty == true { SetupWindow.shared.show() }
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let setup=NSMenuItem(title:"Set Up Nova…",action:#selector(openSetup),keyEquivalent:",")
        setup.target=self; menu.addItem(setup)
        let pair=NSMenuItem(title:"Pair iPhone…",action:#selector(openPairing),keyEquivalent:"p")
        pair.target=self; menu.addItem(pair)
        menu.addItem(.separator())
        let state=permissionState()
        for (name,key) in [("Accessibility","accessibility"),("Screen Recording","screenRecording")] {
            let line=NSMenuItem(title:"\(name): \(state[key] as? Bool == true ? "Allowed" : "Not allowed")",action:nil,keyEquivalent:"")
            line.isEnabled=false; menu.addItem(line)
        }
        menu.addItem(.separator())
        let stop=NSMenuItem(title:halted ? "Stopped (send a new request to resume)" : "Stop Nova  ⌃⌥S",action:#selector(stopNova),keyEquivalent:"")
        stop.target=self; stop.isEnabled = !halted; menu.addItem(stop)
        let ask=NSMenuItem(title:"Ask for Mac Permissions…",action:#selector(request),keyEquivalent:"")
        ask.target=self; menu.addItem(ask)
        menu.addItem(NSMenuItem(title:"Quit Nova Operator",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"))
    }
    @objc func request() { requestPermissions() }
    @objc func stopNova() { halt() }
    @objc func openSetup() { SetupWindow.shared.show() }
    @objc func openPairing() { SetupWindow.shared.show(pairing:true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSetup()
        return true
    }
}

@main
struct NovaOperator {
    @MainActor static func main() {
        // Prints the resolved locations (no keys or saved data) so tests can check they match Core's.
        if CommandLine.arguments.dropFirst().first == "paths" {
            guard let l=Locations.current else { FileHandle.standardError.write(Data("Unsigned configuration\n".utf8)); exit(1) }
            FileHandle.standardOutput.write(encode(["layout":l.layout,"node":l.node,"root":l.root,"data":l.data,"socket":socketURL.path])); exit(0)
        }
        if CommandLine.arguments.dropFirst().first == "self-test" {
            var rejected=0
            for bad in ["cmd+bogus","hyper+a",""] { if (try? combo(bad)) == nil { rejected+=1 } }
            let good=["Return","ctrl+s","super+space","cmd+shift+4","Page_Down","F5","A"].allSatisfy { (try? combo($0)) != nil }
            let scoped=["cmd+c","return","shift+tab","a"].allSatisfy(scopedKeyAllowed) && !["cmd+space","super+tab","ctrl+up","f11","cmd+alt+escape","alt+space"].contains(where:scopedKeyAllowed)
            let ranged=(try? readScope([:])) == nil && (try? readScope(["scope":["mode":"apps","apps":["bad app"]]])) == nil
                && (try? readScope(["scope":["mode":"apps","apps":["com.apple.Notes","dev.nova.operator.macos"]]]))?.apps == ["com.apple.Notes"]
            let passed=rejected == 3 && good && scoped && ranged
            FileHandle.standardOutput.write(encode(["negativeKeyTests":rejected,"scopedKeys":scoped,"ranges":ranged,"passed":passed])); exit(passed ? 0 : 1)
        }
        // Renders the setup window to a PNG for review without starting the executor.
        // The pairing code shown with --code is a placeholder, not a real invitation.
        if CommandLine.arguments.dropFirst().first == "preview-setup", CommandLine.arguments.count > 2 {
            let path=CommandLine.arguments[2]
            NSApplication.shared.setActivationPolicy(.prohibited)
            Task { @MainActor in
                let model=SetupModel()
                if CommandLine.arguments.contains("--design-preview") {
                    model.computer = "Your Mac"
                    model.tailscaleInstalled = true; model.tailscaleRunning = true
                    model.url = "https://your-mac.example.ts.net"
                    model.claude = "keychain"; model.level = "chat"
                    model.accessibility = false; model.screenRecording = false
                } else { await model.refresh() }
                if CommandLine.arguments.contains("--code") {
                    model.code=PairingCode(short:"7KQ4-M2XD",link:"nova://pair?v=1&u=https%3A%2F%2Fexample.ts.net&c=preview-only&n=Mac",expires:Date().addingTimeInterval(562),owner:true)
                }
                let size=NSRect(x:0,y:0,width:720,height:1800)
                let window=NSWindow(contentRect:size,styleMask:[.borderless],backing:.buffered,defer:false)
                window.appearance=NSAppearance(named:CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
                let view=NSHostingView(rootView:SetupView(model:model).frame(width:size.width,height:size.height).background(Color(nsColor:.windowBackgroundColor)))
                window.contentView=view; view.frame=size; view.layoutSubtreeIfNeeded()
                try? await Task.sleep(for:.milliseconds(400))
                guard let rep=view.bitmapImageRepForCachingDisplay(in:view.bounds) else { exit(1) }
                view.cacheDisplay(in:view.bounds,to:rep)
                try? rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path))
                exit(0)
            }
            NSApplication.shared.run()
        }
        let app=NSApplication.shared
        let delegate=StatusMenu()
        app.delegate=delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
