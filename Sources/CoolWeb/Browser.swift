import AppKit
import Combine
import WebKit

/// Guest artifacts from guest/build.sh. COOLWEB_GUEST overrides; default is <package>/guest/out.
let guestDirectory: URL = {
    if let env = ProcessInfo.processInfo.environment["COOLWEB_GUEST"] { return URL(fileURLWithPath: env) }
    return URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("guest/out")
}()

/// Injected into every page, in order: storage handles, then VMWorker.
let injectedScripts: [String] = ["web/vmfs", "web/vmworker"].map { name in
    let url = Bundle.module.url(forResource: name, withExtension: "js")!
    return (try? String(contentsOf: url)) ?? ""
}

final class Tab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()
    let webView: WKWebView
    let vms: VMWorkerHost
    weak var browser: Browser?

    @Published var title = "New Tab"
    @Published var url: URL?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress = 0.0
    @Published var favicon: NSImage?

    private var observers: [NSKeyValueObservation] = []

    init(url: URL?, browser: Browser) {
        self.browser = browser
        vms = VMWorkerHost(guestDir: guestDirectory)

        let config = WKWebViewConfiguration()
        config.userContentController.addScriptMessageHandler(vms, contentWorld: .page, name: VMWorkerHost.handlerName)
        for source in injectedScripts {
            config.userContentController.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        super.init()

        vms.webView = webView
        vms.onChange = { [weak self] in self?.objectWillChange.send() }
        webView.navigationDelegate = self
        webView.uiDelegate = self

        observers = [
            webView.observe(\.title) { [weak self] wv, _ in
                self?.title = Tab.title(wv)
                // Test hook: pages under test report results through document.title.
                if ProcessInfo.processInfo.environment["COOLWEB_TRACE_TITLES"] != nil { FileHandle.standardError.write(Data("[title] \(wv.title ?? "")\n".utf8)) }
            },
            webView.observe(\.url) { [weak self] wv, _ in self?.url = wv.url },
            webView.observe(\.canGoBack) { [weak self] wv, _ in self?.canGoBack = wv.canGoBack },
            webView.observe(\.canGoForward) { [weak self] wv, _ in self?.canGoForward = wv.canGoForward },
            webView.observe(\.isLoading) { [weak self] wv, _ in self?.isLoading = wv.isLoading },
            webView.observe(\.estimatedProgress) { [weak self] wv, _ in self?.progress = wv.estimatedProgress },
        ]

        if let url { webView.load(URLRequest(url: url)) }
    }

    func close() {
        vms.terminateAll()
        webView.stopLoading()
        observers.removeAll()
    }

    private static func title(_ wv: WKWebView) -> String {
        if let t = wv.title, !t.isEmpty { return t }
        if let host = wv.url?.host, !host.isEmpty { return host }
        return "New Tab"
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A new document replaces the old one; its VMWorkers go with it, like Web Workers.
        vms.terminateAll()
        favicon = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadFavicon()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        vms.terminateAll()
        webView.reload()
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank and window.open open a new tab.
        if let url = action.request.url { browser?.newTab(url: url) }
        return nil
    }

    private func loadFavicon() {
        guard let scheme = webView.url?.scheme, scheme == "http" || scheme == "https" else { return }
        let js = "(document.querySelector('link[rel~=\"icon\"]')||{}).href || (location.origin + '/favicon.ico')"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let href = result as? String, let url = URL(string: href) else { return }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data, let image = NSImage(data: data) else { return }
                DispatchQueue.main.async { self?.favicon = image }
            }.resume()
        }
    }
}

final class Browser: ObservableObject {
    /// First tab on launch. COOLWEB_URL overrides; run.sh points it at the local examples server.
    static let home = ProcessInfo.processInfo.environment["COOLWEB_URL"].flatMap(URL.init(string:))

    @Published private(set) var tabs: [Tab] = []
    @Published var selectedID: UUID?
    @Published var sidebarVisible = true
    /// Incremented to ask the address bar to take focus.
    @Published var focusAddressBar = 0

    private var tabChanges: [UUID: AnyCancellable] = [:]

    var selected: Tab? { tabs.first { $0.id == selectedID } }

    init() {
        newTab(url: Browser.home)
    }

    func newTab(url: URL? = nil) {
        let tab = Tab(url: url ?? URL(string: "about:blank"), browser: self)
        // Republish tab changes so the sidebar and toolbar redraw.
        tabChanges[tab.id] = tab.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        tabs.append(tab)
        selectedID = tab.id
        if url == nil { focusAddressBar += 1 }
    }

    func close(_ tab: Tab) {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.close()
        tabChanges[tab.id] = nil
        tabs.remove(at: i)
        if selectedID == tab.id {
            selectedID = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)].id
        }
        if tabs.isEmpty { newTab() }
    }

    func closeSelected() { if let t = selected { close(t) } }

    func select(offset: Int) {
        guard let i = tabs.firstIndex(where: { $0.id == selectedID }), !tabs.isEmpty else { return }
        selectedID = tabs[(i + offset + tabs.count) % tabs.count].id
    }

    func select(index: Int) {
        guard !tabs.isEmpty else { return }
        selectedID = tabs[min(index, tabs.count - 1)].id
    }

    func closeAll() { tabs.forEach { $0.close() } }

    /// URL bar input: a URL, a bare host, or a search.
    func navigate(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let url: URL?
        if text.contains("://") || text.hasPrefix("about:") {
            url = URL(string: text)
        } else if !text.contains(" "), text.hasPrefix("localhost") || text.hasPrefix("127.0.0.1") {
            url = URL(string: "http://" + text)
        } else if !text.contains(" "), text.contains(".") {
            url = URL(string: "https://" + text)
        } else {
            var q = URLComponents(string: "https://duckduckgo.com/")!
            q.queryItems = [URLQueryItem(name: "q", value: text)]
            url = q.url
        }
        guard let url else { return }
        if let tab = selected { tab.webView.load(URLRequest(url: url)) } else { newTab(url: url) }
    }
}
