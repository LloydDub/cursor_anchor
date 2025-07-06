import SwiftUI
import AppKit
import CoreGraphics
import Carbon

// =================================================================================
// MARK: - Global Hotkey Handler
// =================================================================================
// A global function is required for the C-based Carbon API to call into our Swift code.
// It acts as a stable entry point for the system to call.

func hotkeyHandler(nextHandler: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus {
    // Ensure the user data (a pointer to our AppDelegate instance) is valid.
    guard let userData = userData else { return OSStatus(eventNotHandledErr) }

    // Reconstruct the AppDelegate instance from the raw pointer.
    let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    
    // Call the instance method on our app delegate to perform the action.
    appDelegate.hotkeyAction()
    
    // Indicate that we have successfully handled the event.
    return noErr
}


// =================================================================================
// MARK: - Main Application Entry Point (CursorAnchorApp.swift)
// =================================================================================

@main
struct CursorAnchorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            // The main window is hidden. We inject the app delegate and its settings
            // into the environment so all SwiftUI views can access them.
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
// status bar item, and coordinates actions between other components.

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    var statusBarItem: NSStatusItem?
    var popover: NSPopover?
    
    @ObservedObject var settings = SettingsStore()
    
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var hotzoneWindows: [NSWindow] = []
    var preferencesWindow: NSWindow?

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
        popover?.contentSize = NSSize(width: 350, height: 280)
        popover?.behavior = .transient
        popover?.contentViewController = NSHostingController(rootView: ContentView()
            .environmentObject(self)
            .environmentObject(settings)
        )
    }
    
    // MARK: - Settings Management
    func applySettings(keyCode: Int, modifiers: NSEvent.ModifierFlags, isEnabled: Bool) {
        print("Applying new settings... KeyCode: \(keyCode), Modifiers: \(modifiers.rawValue), Enabled: \(isEnabled)")
        settings.hotkeyKeyCode = keyCode
        settings.hotkeyModifiers = modifiers
        settings.isHotkeyEnabled = isEnabled
        
        if isEnabled {
            startHotkeyMonitoring()
        } else {
            stopHotkeyMonitoring()
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
    
    // MARK: - Preferences Window
    func showPreferences() {
        popover?.performClose(nil)
        if preferencesWindow == nil {
            let view = PreferencesView().environmentObject(settings).environmentObject(self)
            preferencesWindow = NSWindow(contentViewController: NSHostingController(rootView: view))
            preferencesWindow?.styleMask = [.titled, .closable]
            preferencesWindow?.title = "Cursor Anchor Preferences"
            preferencesWindow?.delegate = self
        }
        preferencesWindow?.center()
        preferencesWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func closePreferences() {
        preferencesWindow?.close()
    }

    // MARK: - Hotkey Monitoring
    func startHotkeyMonitoring() {
        stopHotkeyMonitoring()
        let signature = FourCharCode(1668248441)
        let hotKeyId = EventHotKeyID(signature: signature, id: 1)
        let eventTarget = GetEventDispatcherTarget()
        
        // Use the fully customizable key code and modifiers
        let carbonModifiers = convertToCarbonFlags(settings.hotkeyModifiers)
        let keyCode = UInt32(settings.hotkeyKeyCode)
        
        var status = RegisterEventHotKey(keyCode, carbonModifiers, hotKeyId, eventTarget, 0, &hotKeyRef)
        if status != noErr { print("❌ ERROR: Failed to register hotkey. Status: \(status)"); return }
        
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        status = InstallEventHandler(eventTarget, hotkeyHandler, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandlerRef)
        if status == noErr { print("✅ Hotkey registered successfully for key code: \(keyCode) with modifiers: \(carbonModifiers)") }
        else { print("❌ ERROR: Failed to install event handler. Status: \(status)") }
    }
    
    func stopHotkeyMonitoring() {
        if let h = hotKeyRef { UnregisterEventHotKey(h); hotKeyRef = nil }
        if let h = eventHandlerRef { RemoveEventHandler(h); eventHandlerRef = nil }
    }
    
    private func convertToCarbonFlags(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbonFlags: UInt32 = 0
        if flags.contains(.control) { carbonFlags |= UInt32(controlKey) }
        if flags.contains(.option) { carbonFlags |= UInt32(optionKey) }
        if flags.contains(.shift) { carbonFlags |= UInt32(shiftKey) }
        if flags.contains(.command) { carbonFlags |= UInt32(cmdKey) }
        return carbonFlags
    }
    
    @objc func hotkeyAction() {
        guard settings.isHotkeyEnabled else { return }
        moveCursorToHotzone()
    }
    
    private func moveCursorToHotzone() {
        if let point = settings.getHotzone() {
            CGWarpMouseCursorPosition(point)
        } else {
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

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) == preferencesWindow {
            preferencesWindow?.makeFirstResponder(nil)
            preferencesWindow = nil
        }
    }
}

// =================================================================================
// MARK: - Settings Store (SettingsStore.swift)
// =================================================================================

class SettingsStore: ObservableObject {
    @Published var isHotkeyEnabled: Bool {
        didSet { UserDefaults.standard.set(isHotkeyEnabled, forKey: "isHotkeyEnabled") }
    }
    @Published var hotkeyKeyCode: Int {
        didSet { UserDefaults.standard.set(hotkeyKeyCode, forKey: "hotkeyKeyCode") }
    }
    @Published var hotkeyModifiers: NSEvent.ModifierFlags {
        didSet { UserDefaults.standard.set(hotkeyModifiers.rawValue, forKey: "hotkeyModifiers") }
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
        self.isHotkeyEnabled = UserDefaults.standard.object(forKey: "isHotkeyEnabled") as? Bool ?? true
        self.hotkeyKeyCode = UserDefaults.standard.object(forKey: "hotkeyKeyCode") as? Int ?? kVK_ANSI_C
        let storedModifiers = UserDefaults.standard.object(forKey: "hotkeyModifiers") as? UInt ?? (NSEvent.ModifierFlags.control.rawValue | NSEvent.ModifierFlags.option.rawValue)
        self.hotkeyModifiers = NSEvent.ModifierFlags(rawValue: storedModifiers)
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
// MARK: - SwiftUI Views (All Views)
// =================================================================================

// The main view shown in the popover.
struct ContentView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @EnvironmentObject var settings: SettingsStore
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Cursor Anchor").font(.largeTitle).fontWeight(.bold)
            VStack(alignment: .leading) {
                Text("Current Hotzone:").font(.headline)
                Text(settings.hotzoneDescription)
            }
            Button("Define/Redefine Hotzone") { appDelegate.showHotzoneSelection() }
            Divider()
            Button("Preferences...") { appDelegate.showPreferences() }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding().frame(width: 350, height: 280)
    }
}

// The dedicated view for all preferences.
struct PreferencesView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @EnvironmentObject var settings: SettingsStore
    
    @State private var tempKeyCode: Int
    @State private var tempModifiers: NSEvent.ModifierFlags
    @State private var tempIsEnabled: Bool
    
    init() {
        _tempKeyCode = State(initialValue: 0)
        _tempModifiers = State(initialValue: [])
        _tempIsEnabled = State(initialValue: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("General").font(.title2).fontWeight(.bold)
            Toggle("Enable Hotkey", isOn: $tempIsEnabled)
            
            Divider()

            Text("Hotkey").font(.title2).fontWeight(.bold)
            Text("Click the field below and press a key combination.")
            HotkeyRecorder(keyCode: $tempKeyCode, modifiers: $tempModifiers)
                .frame(width: 200, height: 24)
            
            Spacer()
            
            HStack {
                Spacer()
                Button("Cancel") { appDelegate.closePreferences() }
                Button("Save") {
                    appDelegate.applySettings(keyCode: tempKeyCode, modifiers: tempModifiers, isEnabled: tempIsEnabled)
                    appDelegate.closePreferences()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 450, height: 300)
        .onAppear {
            self.tempKeyCode = settings.hotkeyKeyCode
            self.tempModifiers = settings.hotkeyModifiers
            self.tempIsEnabled = settings.isHotkeyEnabled
        }
    }
}

// A wrapper to make the KeyCaptureField usable in SwiftUI.
struct HotkeyRecorder: NSViewRepresentable {
    @Binding var keyCode: Int
    @Binding var modifiers: NSEvent.ModifierFlags

    func makeNSView(context: Context) -> KeyCaptureField {
        let field = KeyCaptureField()
        field.onValueChange = { newCode, newModifiers in
            self.keyCode = newCode
            self.modifiers = newModifiers
        }
        return field
    }

    func updateNSView(_ nsView: KeyCaptureField, context: Context) {
        // This is the single source of truth for the view's appearance.
        // It's called whenever the @State in the parent view changes.
        nsView.stringValue = HotkeyManager.hotkeyToString(keyCode: keyCode, modifiers: modifiers)
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

// A custom text field for recording hotkeys.
class KeyCaptureField: NSTextField {
    var onValueChange: (Int, NSEvent.ModifierFlags) -> Void = { _,_  in }
    
    override func becomeFirstResponder() -> Bool {
        self.stringValue = "Press hotkey..."
        self.focusRingType = .none
        return super.becomeFirstResponder()
    }
    
    override func textDidEndEditing(_ notification: Notification) {
        // This is now handled by the updateNSView method in the wrapper.
    }

    // This method is called when modifier keys like Control, Option, Shift, or Command are pressed or released.
    override func flagsChanged(with event: NSEvent) {
        // Update the live display with only the current modifiers.
        let sanitizedModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        self.stringValue = HotkeyManager.hotkeyToString(keyCode: -1, modifiers: sanitizedModifiers)
        super.flagsChanged(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // A hotkey must have at least one modifier key.
        let sanitizedModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !sanitizedModifiers.isEmpty else { return }
        
        let newKeyCode = Int(event.keyCode)
        
        // --- FIX: This is the definitive fix for the display bug. ---
        // 1. Immediately notify the SwiftUI binding that the value has changed.
        onValueChange(newKeyCode, sanitizedModifiers)
        
        // 2. Then, resign focus to "lock in" the new value.
        self.window?.makeFirstResponder(nil)
    }
}

// A helper class for managing hotkeys.
class HotkeyManager {
    static func hotkeyToString(keyCode: Int, modifiers: NSEvent.ModifierFlags) -> String {
        var string = ""
        if modifiers.contains(.control) { string += "⌃ " }
        if modifiers.contains(.option) { string += "⌥ " }
        if modifiers.contains(.shift) { string += "⇧ " }
        if modifiers.contains(.command) { string += "⌘ " }
        
        // If the key code is -1, it means we're only displaying modifiers.
        if keyCode != -1, let char = characterForKeyCode(keyCode: keyCode) {
            return string + char
        }
        
        return string
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

