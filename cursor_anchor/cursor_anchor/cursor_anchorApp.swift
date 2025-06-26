import SwiftUI
import AppKit
import CoreGraphics
import Carbon

// =================================================================================
// MARK: - Main Application Entry Point (CursorAnchorApp.swift)
// =================================================================================

@main
struct CursorAnchorApp: App {
    // The @NSApplicationDelegateAdaptor property wrapper creates and manages the app delegate instance.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            // The main window is hidden, and the UI is presented in a popover from the menu bar.
            // We inject the app delegate into the environment so SwiftUI views can access it.
            EmptyView()
                .environmentObject(appDelegate)
                .environmentObject(appDelegate.settings)
        }
    }
}


// =================================================================================
// MARK: - Application Delegate (AppDelegate.swift)
// =================================================================================
// The main controller for the application. It manages the app's lifecycle,
// status bar item, popover, and coordinates actions between other components.

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    var statusBarItem: NSStatusItem?
    var popover: NSPopover?
    
    // --- Centralized settings store ---
    // The AppDelegate owns the settings store, which manages all saved data.
    @ObservedObject var settings = SettingsStore()
    
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var hotzoneWindows: [NSWindow] = []

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        setupStatusBarItem()
        setupPopover()
        
        if settings.isHotkeyEnabled {
            startHotkeyMonitoring()
        }
    }
    
    private func setupStatusBarItem() {
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusBarItem?.button {
            button.image = NSImage(systemSymbolName: "location.fill", accessibilityDescription: "Cursor Anchor")
            button.action = #selector(togglePopover(_:))
        }
    }
    
    private func setupPopover() {
        popover = NSPopover()
        // --- UI CHANGE: Increased popover height ---
        popover?.contentSize = NSSize(width: 350, height: 340)
        popover?.behavior = .transient
        // Inject both the AppDelegate and its SettingsStore into the ContentView's environment.
        popover?.contentViewController = NSHostingController(rootView: ContentView()
            .environmentObject(self)
            .environmentObject(settings)
        )
    }
    
    // MARK: - Hotzone Management
    func showHotzoneSelection() {
        popover?.performClose(nil)
        closeHotzoneWindows() // Ensure no old windows are lingering.
        
        for screen in NSScreen.screens {
            let controller = HotzoneViewController(); controller.appDelegate = self
            let window = NSWindow(contentViewController: controller)
            window.styleMask = .borderless
            window.level = .floating
            window.isOpaque = false
            window.backgroundColor = .clear
            window.setFrame(screen.frame, display: true)
            window.makeKeyAndOrderFront(nil)
            hotzoneWindows.append(window)
        }
    }
    
    func hotzoneDidSelect(point: NSPoint) {
        settings.setHotzone(point: point)
        closeHotzoneWindows()
    }
    
    func hotzoneSelectionDidCancel() {
        closeHotzoneWindows()
    }
    
    private func closeHotzoneWindows() {
        hotzoneWindows.forEach { $0.close() }
        hotzoneWindows.removeAll()
    }
    
    // MARK: - Hotkey Monitoring
    func startHotkeyMonitoring() {
        stopHotkeyMonitoring()
        let signature = FourCharCode(1668248441)
        let hotKeyId = EventHotKeyID(signature: signature, id: 1)
        let eventTarget = GetEventDispatcherTarget()
        let carbonModifiers = UInt32(controlKey | optionKey)
        let keyCode = UInt32(settings.hotkeyKeyCode)
        
        var status = RegisterEventHotKey(keyCode, carbonModifiers, hotKeyId, eventTarget, 0, &hotKeyRef)
        if status != noErr { print("❌ ERROR: Failed to register hotkey. Status: \(status)"); return }
        
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        status = InstallEventHandler(eventTarget, hotkeyHandler, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandlerRef)
        if status == noErr { print("✅ Hotkey registered successfully for key code: \(keyCode)") }
        else { print("❌ ERROR: Failed to install event handler. Status: \(status)") }
    }
    
    func stopHotkeyMonitoring() {
        if let h = hotKeyRef { UnregisterEventHotKey(h); hotKeyRef = nil }
        if let h = eventHandlerRef { RemoveEventHandler(h); eventHandlerRef = nil }
    }
    
    @objc func hotkeyAction() {
        guard settings.isHotkeyEnabled else { return }
        moveCursorToHotzone()
    }
    
    private func moveCursorToHotzone() {
        if let point = settings.getHotzone() {
            CGWarpMouseCursorPosition(point)
        } else {
            // Fallback to center of the main screen if no hotzone is set.
            guard let mainScreen = NSScreen.main else { return }
            CGWarpMouseCursorPosition(CGPoint(x: mainScreen.frame.midX, y: mainScreen.frame.midY))
        }
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        if let b = statusBarItem?.button {
            popover?.isShown == true ? popover?.performClose(sender) : popover?.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        }
    }
}


// =================================================================================
// MARK: - Settings Store (SettingsStore.swift)
// =================================================================================
// This class centralizes all logic for loading and saving application settings
// from UserDefaults, acting as the single source of truth for the app's state.

class SettingsStore: ObservableObject {
    // --- @Published properties will automatically notify any listening SwiftUI views of changes. ---
    
    @Published var isHotkeyEnabled: Bool {
        didSet { UserDefaults.standard.set(isHotkeyEnabled, forKey: "isHotkeyEnabled") }
    }
    
    @Published var hotkeyKeyCode: Int {
        didSet { UserDefaults.standard.set(hotkeyKeyCode, forKey: "hotkeyKeyCode") }
    }
    
    @Published var hotzoneDescription: String {
        didSet { UserDefaults.standard.set(hotzoneDescription, forKey: "hotzoneDescription") }
    }
    
    private var hotzoneX: Double? {
        didSet { UserDefaults.standard.set(hotzoneX, forKey: "hotzoneX") }
    }
    
    private var hotzoneY: Double? {
        didSet { UserDefaults.standard.set(hotzoneY, forKey: "hotzoneY") }
    }

    init() {
        // Load values from UserDefaults on initialization, providing default values.
        self.isHotkeyEnabled = UserDefaults.standard.object(forKey: "isHotkeyEnabled") as? Bool ?? true
        self.hotkeyKeyCode = UserDefaults.standard.object(forKey: "hotkeyKeyCode") as? Int ?? kVK_ANSI_C
        self.hotzoneDescription = UserDefaults.standard.string(forKey: "hotzoneDescription") ?? "Not Defined"
        self.hotzoneX = UserDefaults.standard.object(forKey: "hotzoneX") as? Double
        self.hotzoneY = UserDefaults.standard.object(forKey: "hotzoneY") as? Double
    }
    
    func setHotzone(point: CGPoint) {
        self.hotzoneX = point.x
        self.hotzoneY = point.y
        self.hotzoneDescription = "(\(Int(point.x)), \(Int(point.y)))"
    }
    
    func getHotzone() -> CGPoint? {
        guard let x = hotzoneX, let y = hotzoneY else { return nil }
        return CGPoint(x: x, y: y)
    }
}


// =================================================================================
// MARK: - SwiftUI Views (ContentView.swift)
// =================================================================================

// The main view shown in the popover.
struct ContentView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @EnvironmentObject var settings: SettingsStore
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Cursor Anchor").font(.largeTitle).fontWeight(.bold)
            
            VStack(alignment: .leading, spacing: 10) {
                Text("Current Hotzone:").font(.headline)
                Text(settings.hotzoneDescription) // Read directly from settings
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Define/Redefine Hotzone") { appDelegate.showHotzoneSelection() }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 10) {
                Text("Global Hotkey:").font(.headline)
                Text(HotkeyManager.hotkeyToString(keyCode: settings.hotkeyKeyCode)) // Read directly from settings
                    .padding(8).background(Color(.windowBackgroundColor)).cornerRadius(6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Toggle("Enable Hotkey", isOn: $settings.isHotkeyEnabled) // Bind directly to settings
                .onChange(of: settings.isHotkeyEnabled) { _, isEnabled in
                    // Tell the app delegate to update the hotkey registration status.
                    if isEnabled {
                        appDelegate.startHotkeyMonitoring()
                    } else {
                        appDelegate.stopHotkeyMonitoring()
                    }
                }
            
            Spacer()
            
            Button("Quit Cursor Anchor") { NSApp.terminate(nil) }
        }
        .padding()
        // --- UI CHANGE: Increased frame height ---
        .frame(width: 350, height: 340)
    }
}


// =================================================================================
// MARK: - Hotzone Selection Components (HotzoneSelection.swift)
// =================================================================================

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


// =================================================================================
// MARK: - Hotkey Helpers (HotkeyManager.swift)
// =================================================================================

// A global function is required for the C-based Carbon API to call into Swift.
func hotkeyHandler(nextHandler: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData = userData else { return OSStatus(eventNotHandledErr) }
    let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    appDelegate.hotkeyAction()
    return noErr
}

class HotkeyManager {
    static func hotkeyToString(keyCode: Int) -> String {
        let modifiers = "⌃ ⌥ "
        if let char = characterForKeyCode(keyCode: keyCode) {
            return modifiers + char
        }
        return modifiers + "Key \(keyCode)"
    }
    
    static func characterForKeyCode(keyCode: Int) -> String? { return keyMap[keyCode] }
    
    private static let keyMap: [Int: String] = [
        kVK_ANSI_A:"A", kVK_ANSI_S:"S", kVK_ANSI_D:"D", kVK_ANSI_F:"F", kVK_ANSI_H:"H",
        kVK_ANSI_G:"G", kVK_ANSI_Z:"Z", kVK_ANSI_X:"X", kVK_ANSI_C:"C", kVK_ANSI_V:"V",
        kVK_ANSI_B:"B", kVK_ANSI_Q:"Q", kVK_ANSI_W:"W", kVK_ANSI_E:"E", kVK_ANSI_R:"R",
        kVK_ANSI_Y:"Y", kVK_ANSI_T:"T", kVK_ANSI_1:"1", kVK_ANSI_2:"2", kVK_ANSI_3:"3",
        kVK_ANSI_4:"4", kVK_ANSI_6:"6", kVK_ANSI_5:"5", kVK_ANSI_Equal:"=", kVK_ANSI_9:"9",
        kVK_ANSI_7:"7", kVK_ANSI_Minus:"-", kVK_ANSI_8:"8", kVK_ANSI_0:"0", kVK_ANSI_RightBracket:"]",
        kVK_ANSI_O:"O", kVK_ANSI_U:"U", kVK_ANSI_LeftBracket:"[", kVK_ANSI_I:"I", kVK_ANSI_P:"P",
        kVK_ANSI_L:"L", kVK_ANSI_J:"J", kVK_ANSI_Quote:"'", kVK_ANSI_K:"K", kVK_ANSI_Semicolon:";",
        kVK_ANSI_Backslash:"\\", kVK_ANSI_Comma:",", kVK_ANSI_Slash:"/", kVK_ANSI_N:"N", kVK_ANSI_M:"M",
        kVK_ANSI_Period:".", kVK_ANSI_Grave:"`", kVK_Space:"Space", kVK_Escape:"Esc"
    ]
}

