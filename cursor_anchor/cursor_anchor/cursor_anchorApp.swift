import SwiftUI
import AppKit
import CoreGraphics
import Carbon

// --- Global function to handle the Carbon hotkey event ---
func hotkeyHandler(nextHandler: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData = userData else { return OSStatus(eventNotHandledErr) }
    let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    appDelegate.hotkeyAction()
    return noErr
}

// MARK: - Hotzone Selection Components
class HotzoneViewController: NSViewController {
    weak var appDelegate: AppDelegate?
    override func loadView() { self.view = HotzoneSelectionView(frame: .zero) }
    override func viewDidLoad() { super.viewDidLoad(); (self.view as? HotzoneSelectionView)?.appDelegate = self.appDelegate }
    override func viewDidAppear() { super.viewDidAppear(); self.view.window?.makeFirstResponder(self.view) }
}

class HotzoneSelectionView: NSView {
    weak var appDelegate: AppDelegate?
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.withAlphaComponent(0.4).setFill(); bounds.fill()
        let instructions = "Click anywhere to set the new hotzone\n(Press Esc to cancel)"
        let paragraphStyle = NSMutableParagraphStyle(); paragraphStyle.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 32, weight: .bold), .foregroundColor: NSColor.white.withAlphaComponent(0.9), .paragraphStyle: paragraphStyle]
        let stringSize = instructions.size(withAttributes: attributes)
        let drawRect = NSRect(x: (bounds.width - stringSize.width) / 2, y: (bounds.height - stringSize.height) / 2, width: stringSize.width, height: stringSize.height)
        instructions.draw(in: drawRect, withAttributes: attributes)
    }
    override func mouseDown(with event: NSEvent) {
        guard let cgEvent = CGEvent(source: nil) else { print("❌ Could not create CGEvent."); return }
        appDelegate?.hotzoneDidSelect(point: cgEvent.location)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == kVK_Escape { appDelegate?.hotzoneSelectionDidCancel() } else { super.keyDown(with: event) }
    }
}


// MARK: - Application Delegate (The Main Controller)
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarItem: NSStatusItem?
    var popover: NSPopover?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var hotzoneWindows: [NSWindow] = []

    // --- SIMPLIFIED: Settings are now managed with @AppStorage directly where possible ---
    @AppStorage("isHotkeyEnabled") private var isHotkeyEnabled: Bool = true
    @AppStorage("hotzoneX") private var hotzoneX: Double?
    @AppStorage("hotzoneY") private var hotzoneY: Double?
    @AppStorage("hotzoneDescription") private var hotzoneDescription: String = "Not Defined"
    
    // The hotkey is now fixed and no longer needs to be stored or published.
    private let fixedKeyCode = kVK_ANSI_C
    private let fixedCarbonModifiers = UInt32(controlKey | optionKey)

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusBarItem?.button {
            button.image = NSImage(systemSymbolName: "location.fill", accessibilityDescription: "Cursor Anchor")
            button.action = #selector(togglePopover(_:))
        }
        popover = NSPopover()
        // --- UI FIX: Increased the popover size for better layout ---
        popover?.contentSize = NSSize(width: 350, height: 340)
        popover?.behavior = .transient
        // Pass a simple reference, no environment object needed anymore.
        popover?.contentViewController = NSHostingController(rootView: ContentView(appDelegate: self))
        
        // Register the hotkey on launch if it's enabled.
        if isHotkeyEnabled {
            startHotkeyMonitoring()
        }
    }
    
    // MARK: - Hotzone Management
    func showHotzoneSelection() {
        popover?.performClose(nil)
        closeHotzoneWindows()
        for screen in NSScreen.screens {
            let controller = HotzoneViewController(); controller.appDelegate = self
            let window = NSWindow(contentViewController: controller)
            window.styleMask = .borderless; window.level = .floating; window.isOpaque = false; window.backgroundColor = .clear
            window.setFrame(screen.frame, display: true); window.makeKeyAndOrderFront(nil)
            hotzoneWindows.append(window)
        }
    }
    private func closeHotzoneWindows() { hotzoneWindows.forEach { $0.close() }; hotzoneWindows.removeAll() }
    
    func hotzoneDidSelect(point: NSPoint) {
        self.hotzoneX = point.x
        self.hotzoneY = point.y
        self.hotzoneDescription = "(\(Int(point.x)), \(Int(point.y)))"
        closeHotzoneWindows()
    }
    func hotzoneSelectionDidCancel() { closeHotzoneWindows() }
    
    // MARK: - Hotkey Monitoring
    func startHotkeyMonitoring() {
        stopHotkeyMonitoring()
        let signature = FourCharCode(1668248441)
        let hotKeyId = EventHotKeyID(signature: signature, id: 1)
        let eventTarget = GetEventDispatcherTarget()
        
        // Use the fixed key code and modifiers
        var status = RegisterEventHotKey(UInt32(fixedKeyCode), fixedCarbonModifiers, hotKeyId, eventTarget, 0, &hotKeyRef)
        if status == noErr { print("✅ Carbon hotkey registered successfully.") }
        else { print("❌ ERROR: Failed to register hotkey. Status: \(status)") }
        
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        status = InstallEventHandler(eventTarget, hotkeyHandler, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandlerRef)
        if status != noErr { print("❌ ERROR: Failed to install event handler. Status: \(status)") }
    }
    
    func stopHotkeyMonitoring() {
        if let h = hotKeyRef { UnregisterEventHotKey(h); hotKeyRef = nil }
        if let h = eventHandlerRef { RemoveEventHandler(h); eventHandlerRef = nil }
    }
    
    @objc func hotkeyAction() {
        guard isHotkeyEnabled else { return }
        moveCursorToHotzone()
    }
    
    private func moveCursorToHotzone() {
        if let x = self.hotzoneX, let y = self.hotzoneY {
            CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
        } else {
            guard let mainScreen = NSScreen.main else { return }
            CGWarpMouseCursorPosition(CGPoint(x: mainScreen.frame.midX, y: mainScreen.frame.midY))
        }
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        if let b = statusBarItem?.button { popover?.isShown == true ? popover?.performClose(sender) : popover?.show(relativeTo: b.bounds, of: b, preferredEdge: .minY) }
    }
}

// MARK: - Main Application Entry Point
@main
struct CursorAnchorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}

// MARK: - SwiftUI Views

// The main view shown in the popover.
struct ContentView: View {
    // --- SIMPLIFIED: A simple reference to the app delegate is sufficient ---
    var appDelegate: AppDelegate?
    
    @AppStorage("isHotkeyEnabled") private var isHotkeyEnabled: Bool = true
    @AppStorage("hotzoneDescription") private var hotzoneDescription: String = "Not Defined"
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Cursor Anchor").font(.largeTitle).fontWeight(.bold)
            
            VStack(alignment: .leading, spacing: 10) {
                Text("Current Hotzone:")
                    .font(.headline)
                Text(hotzoneDescription)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Define/Redefine Hotzone") { appDelegate?.showHotzoneSelection() }
            
            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Global Hotkey:")
                    .font(.headline)
                // Display the fixed hotkey string
                Text("⌃ ⌥ C")
                    .padding(8)
                    .background(Color(.windowBackgroundColor))
                    .cornerRadius(6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Toggle("Enable Hotkey", isOn: $isHotkeyEnabled)
                .onChange(of: isHotkeyEnabled) { _, isEnabled in
                    if isEnabled {
                        appDelegate?.startHotkeyMonitoring()
                    } else {
                        appDelegate?.stopHotkeyMonitoring()
                    }
                }
            
            Spacer()
            
            Button("Quit Cursor Anchor") {
                NSApp.terminate(nil)
            }
        }
        .padding()
        // --- UI FIX: Increased frame height for better spacing ---
        .frame(width: 350, height: 340)
    }
}

