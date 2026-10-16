import AppKit
import ApplicationServices
import ScreenCaptureKit
import CryptoKit

enum OperatorError: Error { case denied(String) }
let apps = ["Chrome":"com.google.Chrome", "Safari":"com.apple.Safari", "TextEdit":"com.apple.TextEdit", "Calculator":"com.apple.calculator", "Notes":"com.apple.Notes", "Finder":"com.apple.finder"]
let keys: [String:(CGKeyCode, CGEventFlags)] = ["return":(36,[]),"tab":(48,[]),"escape":(53,[]),"backspace":(51,[]),"up":(126,[]),"down":(125,[]),"left":(123,[]),"right":(124,[]),"cmd+a":(0,.maskCommand),"cmd+l":(37,.maskCommand),"cmd+n":(45,.maskCommand),"cmd+s":(1,.maskCommand)]

func deny(_ text: String) throws -> Never { throw OperatorError.denied(text) }
func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success ? value : nil
}
func text(_ element: AXUIElement, _ name: String) -> String { attr(element,name) as? String ?? "" }
func fingerprint(_ element: AXUIElement, depth: Int = 0, remaining: inout Int) -> String {
    guard depth < 9, remaining > 0 else { return "" }
    remaining -= 1
    var value = [kAXRoleAttribute,kAXSubroleAttribute,kAXTitleAttribute,kAXDescriptionAttribute].map { text(element,$0) }.joined(separator:"|")
    // Do not collect secure-field values, including in the snapshot hash.
    if text(element,kAXSubroleAttribute) != kAXSecureTextFieldSubrole { value += "|" + text(element,kAXValueAttribute).prefix(1000) }
    for child in (attr(element,kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(100) { value += fingerprint(child,depth:depth+1,remaining:&remaining) }
    return value
}
func containsCredential(_ value: String) -> Bool {
    value.range(of:"sk-(ant-|proj-)[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----",options:.regularExpression) != nil
}
func sha(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }

@MainActor
func capture(_ window: SCWindow) async throws -> Data {
    let filter=SCContentFilter(desktopIndependentWindow:window)
    let config=SCStreamConfiguration()
    let scale=min(1,min(1200/window.frame.width,900/window.frame.height))
    config.width=max(1,Int(window.frame.width*scale));config.height=max(1,Int(window.frame.height*scale))
    config.showsCursor=false;config.ignoreShadowsSingleWindow=true
    let image=try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
    guard let png=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else {try deny("Screenshot failed")}
    return png
}

@MainActor
func current(_ app: String) async throws -> (NSRunningApplication, SCWindow, String) {
    guard let bundle = apps[app], let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == bundle else { try deny("Selected app is not in front. Bring it forward and try again.") }
    guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else { try deny("Allow Nova Operator in macOS Accessibility and Screen Recording settings.") }
    let content = try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
    guard let window = content.windows.first(where: { $0.owningApplication?.processID == front.processIdentifier && $0.windowLayer == 0 && $0.frame.width > 50 && $0.frame.height > 50 }) else { try deny("No visible window in the selected app.") }
    let axApp = AXUIElementCreateApplication(front.processIdentifier)
    guard let raw = attr(axApp,kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { try deny("Cannot identify the focused window.") }
    let axWindow = unsafeBitCast(raw,to:AXUIElement.self)
    var position = CGPoint.zero, size = CGSize.zero
    guard let p = attr(axWindow,kAXPositionAttribute), let s = attr(axWindow,kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID(),
          AXValueGetValue(unsafeBitCast(p,to:AXValue.self),.cgPoint,&position),
          AXValueGetValue(unsafeBitCast(s,to:AXValue.self),.cgSize,&size),
          abs(position.x-window.frame.minX) < 3, abs(position.y-window.frame.minY) < 3,
          abs(size.width-window.frame.width) < 3, abs(size.height-window.frame.height) < 3 else { try deny("Focused window changed. Capture a fresh screen.") }
    var remaining = 400
    let contents=fingerprint(axWindow,remaining:&remaining)
    guard !containsCredential(contents) else {try deny("A visible credential was detected. Close or hide it before sharing this window.")}
    let state = "\(front.processIdentifier)|\(window.windowID)|\(window.frame)|" + contents
    return (front,window,sha(Data(state.utf8)))
}

func pressable(_ element: AXUIElement) -> AXUIElement? {
    var current: AXUIElement? = element
    for _ in 0..<3 {
        guard let candidate=current else { return nil }
        var names: CFArray?
        if AXUIElementCopyActionNames(candidate,&names) == .success, (names as? [String] ?? []).contains(kAXPressAction) { return candidate }
        guard let parent=attr(candidate,kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
        current=unsafeBitCast(parent,to:AXUIElement.self)
    }
    return nil
}

func validate(_ request: [String:Any]) throws {
    guard let kind = request["kind"] as? String, ["activate","observe","click","type","key","scroll"].contains(kind),
          let app = request["app"] as? String, apps[app] != nil else { try deny("Unknown operation or app") }
    if ["click","scroll"].contains(kind) {
        guard let x=request["x"] as? Double, let y=request["y"] as? Double, x.isFinite, y.isFinite, (0...1000).contains(x), (0...1000).contains(y) else { try deny("Coordinates outside selected window") }
    }
    if kind == "scroll", !["up","down"].contains(request["direction"] as? String ?? "") { try deny("Invalid scroll direction") }
    if kind == "type" {
        guard let value=request["text"] as? String, !value.isEmpty, value.utf16.count <= 500,
              !value.unicodeScalars.contains(where: {$0.value < 32 || $0.value == 127}) else { try deny("Type only printable text, at most 500 characters. Submit keys separately.") }
    }
    if kind == "key", keys[request["key"] as? String ?? ""] == nil { try deny("Key combination not allowed") }
    if !["activate","observe"].contains(kind), request["snapshot"] as? String == nil { try deny("Missing approved snapshot") }
}

@MainActor
func perform(_ request: [String:Any]) async throws -> [String:Any] {
    try validate(request)
    let app=request["app"] as! String, kind=request["kind"] as! String
    if kind == "activate" {
        guard let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:apps[app]!) else { try deny("App is not installed") }
        let config=NSWorkspace.OpenConfiguration(); config.activates=true
        _ = try await NSWorkspace.shared.openApplication(at:url,configuration:config)
        return ["message":"Opened \(app)"]
    }
    let (front,window,snapshot)=try await current(app)
    let png=try await capture(window)
    let (_,afterWindow,after)=try await current(app)
    guard snapshot == after, window.windowID == afterWindow.windowID else {try deny("Window changed during capture")}
    let reviewedSnapshot=sha(Data((snapshot+sha(png)).utf8))
    if kind == "observe" {
        return ["snapshot":reviewedSnapshot,"png":png.base64EncodedString(),"app":app]
    }
    guard request["snapshot"] as? String == reviewedSnapshot else { try deny("The window changed after review. Request a fresh screen before acting.") }
    guard (request["expires"] as? Double ?? 0) > Date().timeIntervalSince1970 else {try deny("Action authorization expired before input")}
    let axApp=AXUIElementCreateApplication(front.processIdentifier)
    if let raw=attr(axApp,kAXFocusedUIElementAttribute), CFGetTypeID(raw)==AXUIElementGetTypeID(), text(unsafeBitCast(raw,to:AXUIElement.self),kAXSubroleAttribute)==kAXSecureTextFieldSubrole { try deny("Password fields require direct user interaction") }
    // Targeted events go to this PID, never the global keyboard destination.
    if kind == "type" {
        let units=Array((request["text"] as! String).utf16)
        guard let down=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true), let up=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:false) else { try deny("Could not create input event") }
        down.keyboardSetUnicodeString(stringLength:units.count,unicodeString:units)
        up.keyboardSetUnicodeString(stringLength:units.count,unicodeString:units)
        down.flags=[];up.flags=[]
        down.postToPid(front.processIdentifier); up.postToPid(front.processIdentifier)
    } else if kind == "key" {
        let (code,flags)=keys[request["key"] as! String]!
        for pressed in [true,false] { let event=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:pressed); event?.flags=flags; event?.postToPid(front.processIdentifier) }
    } else {
        let point=CGPoint(x:window.frame.minX+(request["x"] as! Double)/1000*window.frame.width,y:window.frame.minY+(request["y"] as! Double)/1000*window.frame.height)
        guard window.frame.insetBy(dx:2,dy:2).contains(point) else { try deny("Window edge actions are denied") }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(point.x),Float(point.y),&hit) == .success, let hit else { try deny("Cannot identify the click target") }
        var hitPid:pid_t=0; AXUIElementGetPid(hit,&hitPid)
        guard hitPid == front.processIdentifier else { try deny("Another app covers the target") }
        // Many apps (including SwiftUI ones like Calculator) ignore mouse events posted
        // to their PID, so press the control through Accessibility when it supports it.
        if kind == "click", let control=pressable(hit) {
            guard AXUIElementPerformAction(control,kAXPressAction as CFString) == .success else { try deny("The control did not accept the click") }
        } else if kind == "click" {
            for type in [CGEventType.leftMouseDown,.leftMouseUp] { let event=CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:point,mouseButton:.left);event?.flags=[];event?.setIntegerValueField(.mouseEventClickState,value:1);event?.postToPid(front.processIdentifier) }
        } else {
            let event=CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:request["direction"] as? String == "up" ? 300 : -300,wheel2:0,wheel3:0)
            event?.flags=[];event?.location=point; event?.postToPid(front.processIdentifier)
        }
    }
    return ["message":"Approved \(kind) input delivered to \(app). Verify the next screen for the outcome."]
}

func authorize(_ envelope: [String:String]) throws -> [String:Any] {
    guard let dataDirectory=Bundle.main.object(forInfoDictionaryKey:"NovaCoreDataDirectory") as? String else { try deny("Unsigned configuration") }
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
func requestPermissions() {
    if !AXIsProcessTrusted() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary) }
    if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
}
func encode(_ value:[String:Any]) -> Data { (try? JSONSerialization.data(withJSONObject:value,options:.sortedKeys)) ?? Data("{\"error\":\"Encoding failed\"}".utf8) }

@MainActor
func respond(_ raw: Data) async -> [String:Any] {
    do {
        guard raw.count < 20000, let message=try JSONSerialization.jsonObject(with:raw) as? [String:Any],
              let command=message["command"] as? String else { try deny("Unsupported request") }
        if command == "permissions" { return permissionState() }
        guard command == "execute", let envelope=message["envelope"] as? [String:String] else { try deny("Unsupported request") }
        return try await perform(try authorize(envelope))
    } catch OperatorError.denied(let reason) { return ["error":reason] }
    catch { return ["error":"macOS operation failed. Check permissions and capture a fresh screen."] }
}

// Core talks to this long-running app over a Unix socket in a 0700 directory, so
// macOS attributes Accessibility and Screen Recording to Nova Operator itself.
// sun_path is limited to 104 bytes, which rules out the project's .nova-data path.
let socketURL=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
    .appendingPathComponent("Nova Operator",isDirectory:true).appendingPathComponent("operator.sock")

func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    var address=sockaddr_un(); address.sun_family=sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of:&address.sun_path) { buffer in for (i,byte) in path.utf8.prefix(buffer.count-1).enumerated() { buffer[i]=byte } }
    return withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { body($0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
}

func startServer() throws {
    let path=socketURL.path
    try FileManager.default.createDirectory(at:socketURL.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    chmod(socketURL.deletingLastPathComponent().path,0o700)
    let probe=socket(AF_UNIX,SOCK_STREAM,0)
    let running=withAddress(path) { connect(probe,$0,$1) } == 0
    close(probe)
    if running { try deny("Nova Operator is already running") }
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

@MainActor
final class StatusMenu: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try startServer() }
        catch { print("Nova Operator: \(error)"); exit(0) }
        item=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        item.button?.image=NSImage(systemSymbolName:"cursorarrow.rays",accessibilityDescription:"Nova Operator")
        let menu=NSMenu(); menu.delegate=self; item.menu=menu
        // Asking on launch adds Nova Operator to both System Settings lists.
        requestPermissions()
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state=permissionState()
        for (name,key) in [("Accessibility","accessibility"),("Screen Recording","screenRecording")] {
            let line=NSMenuItem(title:"\(name): \(state[key] as? Bool == true ? "Allowed" : "Not allowed")",action:nil,keyEquivalent:"")
            line.isEnabled=false; menu.addItem(line)
        }
        menu.addItem(.separator())
        let ask=NSMenuItem(title:"Request Permissions…",action:#selector(request),keyEquivalent:"")
        ask.target=self; menu.addItem(ask)
        menu.addItem(NSMenuItem(title:"Quit Nova Operator",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"))
    }
    @objc func request() { requestPermissions() }
}

@main
struct NovaOperator {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().first == "self-test" {
            for invalid:[String:Any] in [["kind":"shell","app":"TextEdit"],["kind":"click","app":"TextEdit","x":-1,"y":500],["kind":"type","app":"TextEdit","text":"a\nb"],["kind":"key","app":"TextEdit","key":"cmd+space"],["kind":"observe","app":"Terminal"]] {
                var rejected=false; do {try validate(invalid)} catch {rejected=true}
                guard rejected else { FileHandle.standardOutput.write(encode(["error":"Native validation test failed"])); exit(1) }
            }
            FileHandle.standardOutput.write(encode(["negativeValidationTests":5,"passed":true])); exit(0)
        }
        let app=NSApplication.shared
        let delegate=StatusMenu()
        app.delegate=delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
