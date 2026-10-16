import AppKit
import ApplicationServices
import ScreenCaptureKit
import CryptoKit
import Carbon.HIToolbox

enum OperatorError: Error { case denied(String) }
func deny(_ text: String) throws -> Never { throw OperatorError.denied(text) }

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
func capture(region: CGRect? = nil) async throws -> [String:Any] {
    let display=Display.main()
    let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
    guard let screen=content.displays.first(where:{ $0.displayID == display.id }) else { try deny("Main display unavailable") }
    // Nova's own cursor stays out of what Claude sees.
    let own=content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
    let config=SCStreamConfiguration()
    config.showsCursor=false
    var size=display.imageSize
    if let region {
        config.sourceRect=region
        let fit=min(display.imageSize.width/region.width,display.imageSize.height/region.height)
        size=CGSize(width:max(1,(region.width*fit).rounded(.down)),height:max(1,(region.height*fit).rounded(.down)))
    }
    config.width=Int(size.width); config.height=Int(size.height)
    let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(display:screen,excludingWindows:own),configuration:config)
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
        let from=panel.frame.origin, to=origin(p)
        let duration=min(0.55,max(0.18,hypot(to.x-from.x,to.y-from.y)/2200))
        await withCheckedContinuation { (done: CheckedContinuation<Void,Never>) in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration=duration; context.timingFunction=CAMediaTimingFunction(name:.easeInEaseOut)
                self.panel.animator().setFrameOrigin(to); self.panel.animator().alphaValue=1
            }, completionHandler:{ done.resume() })
        }
    }
    func idle() {
        hide?.cancel()
        hide=Task { @MainActor in
            try? await Task.sleep(for:.seconds(4))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration=0.4; self.panel.animator().alphaValue=0 },completionHandler:nil)
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
    if halted { try deny("Stopped on the Mac with Control-Option-S. Send a new request to start again.") }
    guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else { try deny("Allow Nova Operator in macOS Accessibility and Screen Recording settings.") }
    func coordinate(_ key: String = "coordinate") throws -> CGPoint? {
        guard let raw=request[key] else { return nil }
        guard let pair=raw as? [Double], pair.count == 2, pair.allSatisfy({ $0.isFinite }),
              (0...display.imageSize.width).contains(pair[0]), (0...display.imageSize.height).contains(pair[1]) else { try deny("Coordinate outside the screen") }
        return display.point(pair[0],pair[1])
    }
    let cursor=NovaCursor.shared
    defer { if heldAt == nil { cursor.idle() } }
    switch action {
    case "screenshot":
        return try await capture()
    case "zoom":
        guard let region=request["region"] as? [Double], region.count == 4, region.allSatisfy({ $0.isFinite }),
              region[2] > region[0], region[3] > region[1] else { try deny("Invalid zoom region") }
        let a=display.point(max(0,region[0]),max(0,region[1])), b=display.point(min(display.imageSize.width,region[2]),min(display.imageSize.height,region[3]))
        return try await capture(region:CGRect(x:a.x-display.bounds.minX,y:a.y-display.bounds.minY,width:b.x-a.x,height:b.y-a.y))
    case "left_click","right_click","middle_click","double_click","triple_click":
        let p=try coordinate() ?? lastPoint ?? realPointer(), flags=try modifiers(request["text"] as? String)
        let (button,down,up):(CGMouseButton,CGEventType,CGEventType)=action == "right_click" ? (.right,.rightMouseDown,.rightMouseUp) : action == "middle_click" ? (.center,.otherMouseDown,.otherMouseUp) : (.left,.leftMouseDown,.leftMouseUp)
        let count=action == "double_click" ? 2 : action == "triple_click" ? 3 : 1
        let real=realPointer()
        await cursor.fly(to:p)
        mouse(.mouseMoved,p)
        for click in 1...count { mouse(down,p,button,clicks:click,flags:flags); mouse(up,p,button,clicks:click,flags:flags) }
        cursor.view.pulse(); lastPoint=p
        await restorePointer(real)
    case "mouse_move":
        guard let p=try coordinate() else { try deny("Missing coordinate") }
        await cursor.fly(to:p)
        if heldAt != nil { mouse(.leftMouseDragged,p); heldAt=p } else { mouse(.mouseMoved,p) }
        lastPoint=p
    case "left_mouse_down":
        let p=lastPoint ?? realPointer()
        await cursor.fly(to:p); mouse(.leftMouseDown,p); heldAt=p
    case "left_mouse_up":
        let p=heldAt ?? lastPoint ?? realPointer()
        mouse(.leftMouseUp,p); heldAt=nil; cursor.view.pulse()
    case "left_click_drag":
        guard let start=try coordinate("start_coordinate"), let end=try coordinate() else { try deny("Missing drag coordinates") }
        let flags=try modifiers(request["text"] as? String), real=realPointer()
        await cursor.fly(to:start)
        mouse(.mouseMoved,start); mouse(.leftMouseDown,start,flags:flags)
        for step in 1...16 {
            let t=CGFloat(step)/16, p=CGPoint(x:start.x+(end.x-start.x)*t,y:start.y+(end.y-start.y)*t)
            mouse(.leftMouseDragged,p,flags:flags)
            cursor.panel.setFrameOrigin(cursor.origin(p))
            try? await Task.sleep(for:.milliseconds(20))
        }
        mouse(.leftMouseUp,end,flags:flags); lastPoint=end
        await restorePointer(real)
    case "cursor_position":
        return ["text":"\(display.image(lastPoint ?? realPointer()))"]
    case "scroll":
        let p=try coordinate() ?? lastPoint ?? realPointer(), flags=try modifiers(request["text"] as? String)
        guard let direction=request["scroll_direction"] as? String, ["up","down","left","right"].contains(direction) else { try deny("Invalid scroll direction") }
        let amount=Int32(max(1,min(30,(request["scroll_amount"] as? Double ?? 3))))
        let real=realPointer()
        await cursor.fly(to:p); mouse(.mouseMoved,p)
        for _ in 0..<amount {
            let vertical:Int32=direction == "up" ? 3 : direction == "down" ? -3 : 0, horizontal:Int32=direction == "left" ? 3 : direction == "right" ? -3 : 0
            let event=CGEvent(scrollWheelEvent2Source:source,units:.line,wheelCount:2,wheel1:vertical,wheel2:horizontal,wheel3:0)
            event?.location=p; event?.flags=flags; event?.post(tap:.cghidEventTap)
            try? await Task.sleep(for:.milliseconds(15))
        }
        lastPoint=p
        await restorePointer(real)
    case "type":
        guard let text=request["text"] as? String, !text.isEmpty, text.count <= 5000 else { try deny("Type 1–5000 characters") }
        await typeText(text)
    case "key":
        guard let text=request["text"] as? String else { try deny("Missing key") }
        let (code,flags)=try combo(text), times=Int(max(1,min(100,request["repeat"] as? Double ?? 1)))
        for _ in 0..<times { press(code,flags,down:true); press(code,flags,down:false); try? await Task.sleep(for:.milliseconds(15)) }
    case "hold_key":
        guard let text=request["text"] as? String else { try deny("Missing key") }
        let (code,flags)=try combo(text), duration=max(0,min(30,request["duration"] as? Double ?? 1))
        press(code,flags,down:true)
        try? await Task.sleep(for:.milliseconds(Int(duration*1000)))
        press(code,flags,down:false)
    default:
        try deny("Unsupported action \(action)")
    }
    if halted { try deny("Stopped on the Mac with Control-Option-S.") }
    return ["text":"OK"]
}

// MARK: - Authorization

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
    catch { return ["error":"macOS operation failed. Check permissions and try again."] }
}

// MARK: - Socket

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
        catch { print("Nova Operator: \(error)"); exit(0) }
        item=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        item.button?.image=NSImage(systemSymbolName:"cursorarrow.rays",accessibilityDescription:"Nova Operator")
        let menu=NSMenu(); menu.delegate=self; item.menu=menu
        registerStopShortcut()
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
        let stop=NSMenuItem(title:halted ? "Stopped (send a new request to resume)" : "Stop Nova  ⌃⌥S",action:#selector(stopNova),keyEquivalent:"")
        stop.target=self; stop.isEnabled = !halted; menu.addItem(stop)
        let ask=NSMenuItem(title:"Request Permissions…",action:#selector(request),keyEquivalent:"")
        ask.target=self; menu.addItem(ask)
        menu.addItem(NSMenuItem(title:"Quit Nova Operator",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"))
    }
    @objc func request() { requestPermissions() }
    @objc func stopNova() { halt() }
}

@main
struct NovaOperator {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().first == "self-test" {
            var rejected=0
            for bad in ["cmd+bogus","hyper+a",""] { if (try? combo(bad)) == nil { rejected+=1 } }
            let good=["Return","ctrl+s","super+space","cmd+shift+4","Page_Down","F5","A"].allSatisfy { (try? combo($0)) != nil }
            let passed=rejected == 3 && good
            FileHandle.standardOutput.write(encode(["negativeKeyTests":rejected,"passed":passed])); exit(passed ? 0 : 1)
        }
        let app=NSApplication.shared
        let delegate=StatusMenu()
        app.delegate=delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
