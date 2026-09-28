import AppKit
import SwiftUI

/// COOLWEB_HEADLESS: for test runs. No Dock icon, never takes focus, window stays off-screen.
let headless = ProcessInfo.processInfo.environment["COOLWEB_HEADLESS"] != nil

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let browser = Browser()
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: BrowserView(browser: browser))
        window.delegate = self
        NSApp.mainMenu = makeMenu()
        placeTrafficLights()
        for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                     NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.placeTrafficLights()
            }
        }

        // Diagnostic: which view AppKit hands a click to at each control's spot (top-left origin, points).
        if ProcessInfo.processInfo.environment["COOLWEB_HITTEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                let frame = window.contentView!.superview!
                for (label, x, y) in [("sidebar toggle", 89.0, 26.0), ("+ new tab", 121.0, 26.0), ("back", 260.0, 26.0),
                                      ("URL field", 700.0, 26.0), ("bar gap", 200.0, 26.0), ("tab row", 150.0, 73.0),
                                      ("page", 800.0, 400.0)] {
                    let p = NSPoint(x: x, y: frame.bounds.height - y)
                    let hit = frame.hitTest(p)
                    print("\(label): \(hit.map { String(describing: type(of: $0)) } ?? "nil"), canMoveWindow=\(hit?.mouseDownCanMoveWindow ?? false)")
                }
                for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    if let v = window.standardWindowButton(b), let sv = v.superview {
                        let f = v.convert(v.bounds, to: nil)
                        print("light \(b.rawValue): x=\(f.minX) centerFromTop=\(frame.bounds.height - f.midY) superview=\(type(of: sv)) h=\(sv.bounds.height)")
                    }
                }
                fflush(stdout)
            }
        }

        // Diagnostic: real clicks through the window's event path, then check what they changed.
        if ProcessInfo.processInfo.environment["COOLWEB_CLICKTEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                func click(_ x: CGFloat, _ yFromTop: CGFloat) {
                    let p = NSPoint(x: x, y: window.contentView!.bounds.height - yFromTop)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                        window.sendEvent(e)
                    }
                }
                let before = browser.tabs.count
                click(121, 26)  // + new tab
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                    print("plus button: tabs \(before) -> \(browser.tabs.count)")
                    let first = browser.tabs.first?.id
                    click(150, 73)  // first tab row
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                        print("tab row: selected first tab = \(browser.selectedID == first)")
                        let visible = browser.sidebarVisible
                        click(89, 26)  // sidebar toggle
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                            print("sidebar toggle: visible \(visible) -> \(browser.sidebarVisible)")
                            fflush(stdout)
                        }
                    }
                }
            }
        }

        if headless {
            // On a window, so WebKit runs the page, but far off-screen and never activated.
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            window.orderBack(nil)
            return
        }
        window.setFrameAutosaveName("CoolWebMain")
        if !window.setFrameUsingName("CoolWebMain") { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Centers the close / minimize / zoom buttons in our 52 pt top bar. AppKit lays them out for a 28 pt title
    /// bar, so this makes the title bar container as tall as our bar and re-centers them; AppKit resets them on
    /// resize and full screen, hence the observers.
    private func placeTrafficLights() {
        guard let close = window.standardWindowButton(.closeButton), let titlebar = close.superview,
              let container = titlebar.superview else { return }
        let height = BrowserLayout.barHeight
        container.frame = NSRect(x: 0, y: window.frame.height - height, width: window.frame.width, height: height)
        titlebar.frame = container.bounds
        for (i, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let b = window.standardWindowButton(type) else { continue }
            b.setFrameOrigin(NSPoint(x: 16 + CGFloat(i) * 20, y: ((height - b.frame.height) / 2).rounded()))
        }
    }

    func windowWillClose(_ notification: Notification) {
        browser.closeAll()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        browser.closeAll()
        StorageServer.shared.stopAll()
    }

    // MARK: Menu

    private func makeMenu() -> NSMenu {
        let main = NSMenu()

        main.addSubmenu("CoolWeb", [
            item("Quit CoolWeb", "q", #selector(NSApplication.terminate(_:)), target: NSApp),
        ])
        main.addSubmenu("File", [
            item("New Tab", "t", #selector(newTab)),
            item("Open Location…", "l", #selector(openLocation)),
            item("Close Tab", "w", #selector(closeTab)),
        ])
        main.addSubmenu("Edit", [
            item("Undo", "z", Selector(("undo:")), target: nil),
            item("Redo", "Z", Selector(("redo:")), target: nil),
            .separator(),
            item("Cut", "x", #selector(NSText.cut(_:)), target: nil),
            item("Copy", "c", #selector(NSText.copy(_:)), target: nil),
            item("Paste", "v", #selector(NSText.paste(_:)), target: nil),
            item("Select All", "a", #selector(NSText.selectAll(_:)), target: nil),
        ])
        main.addSubmenu("View", [
            item("Toggle Sidebar", "s", #selector(toggleSidebar)),
            item("Reload Page", "r", #selector(reload)),
        ])
        main.addSubmenu("History", [
            item("Back", "[", #selector(back)),
            item("Forward", "]", #selector(forward)),
        ])
        var tabs = [item("Show Next Tab", "}", #selector(nextTab)), item("Show Previous Tab", "{", #selector(prevTab))]
        for n in 1...9 {
            let i = item("Tab \(n)", "\(n)", #selector(selectTab(_:)))
            i.tag = n - 1
            tabs.append(i)
        }
        main.addSubmenu("Window", tabs)
        return main
    }

    private func item(_ title: String, _ key: String, _ action: Selector, target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = target ?? self
        return i
    }

    @objc func newTab() { browser.newTab() }
    @objc func openLocation() { browser.focusAddressBar += 1 }
    @objc func closeTab() { browser.closeSelected() }
    @objc func toggleSidebar() { browser.sidebarVisible.toggle() }
    @objc func reload() { browser.selected?.webView.reload() }
    @objc func back() { browser.selected?.webView.goBack() }
    @objc func forward() { browser.selected?.webView.goForward() }
    @objc func nextTab() { browser.select(offset: 1) }
    @objc func prevTab() { browser.select(offset: -1) }
    @objc func selectTab(_ sender: NSMenuItem) {
        sender.tag == 8 ? browser.select(index: browser.tabs.count - 1) : browser.select(index: sender.tag)
    }
}

private extension NSMenu {
    func addSubmenu(_ title: String, _ items: [NSMenuItem]) {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        addItem(holder)
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--storage-helper"), CommandLine.arguments.count >= i + 4 {
    let a = CommandLine.arguments
    StorageHelper.run(root: a[i + 1], origin: a[i + 2], token: a[i + 3])
}
if CommandLine.arguments.contains("--bench") { SelfTest.bench() }
if let i = CommandLine.arguments.firstIndex(of: "--selftest") {
    SelfTest.run(scriptPath: CommandLine.arguments.dropFirst(i + 1).first)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(headless ? .accessory : .regular)
app.run()
