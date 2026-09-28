import SwiftUI
import WebKit

enum BrowserLayout {
    static let sidebarWidth: CGFloat = 240
    static let barHeight: CGFloat = 52
}
private let sidebarWidth = BrowserLayout.sidebarWidth
private let barHeight = BrowserLayout.barHeight

struct BrowserView: View {
    @ObservedObject var browser: Browser

    var body: some View {
        VStack(spacing: 0) {
            TopBar(browser: browser)
                .frame(height: barHeight)
            HStack(spacing: 0) {
                if browser.sidebarVisible {
                    Sidebar(browser: browser)
                        .frame(width: sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                ContentCard(tab: browser.selected)
                    .padding(.leading, browser.sidebarVisible ? 0 : 8)
                    .padding([.trailing, .bottom], 8)
            }
        }
        .background(VisualEffect().ignoresSafeArea())
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.18), value: browser.sidebarVisible)
    }
}

// MARK: Top bar

private struct TopBar: View {
    @ObservedObject var browser: Browser

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                Spacer().frame(width: 72) // traffic lights
                IconButton("sidebar.left", help: "Toggle sidebar (⌘S)") { browser.sidebarVisible.toggle() }
                IconButton("plus", help: "New tab (⌘T)") { browser.newTab() }
            }
            .frame(width: browser.sidebarVisible ? sidebarWidth : nil, alignment: .leading)

            let tab = browser.selected
            IconButton("chevron.left", help: "Back (⌘[)") { tab?.webView.goBack() }
                .disabled(!(tab?.canGoBack ?? false))
            IconButton("chevron.right", help: "Forward (⌘])") { tab?.webView.goForward() }
                .disabled(!(tab?.canGoForward ?? false))
            IconButton(tab?.isLoading == true ? "xmark" : "arrow.clockwise", help: "Reload (⌘R)") {
                if tab?.isLoading == true { tab?.webView.stopLoading() } else { tab?.webView.reload() }
            }
            AddressBar(browser: browser)
                .padding(.trailing, 8)
        }
    }
}

private struct AddressBar: View {
    @ObservedObject var browser: Browser
    @State private var text = ""
    @FocusState private var focused: Bool

    private var tab: Tab? { browser.selected }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tab?.url?.scheme == "https" ? "lock.fill" : "globe")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Search or enter address", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit {
                    browser.navigate(text)
                    focused = false
                }
                .onExitCommand {
                    sync()
                    focused = false
                }
            if let vms = tab?.vms, vms.runningCount > 0 {
                Label("\(vms.runningCount)", systemImage: "cpu")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help("VMWorkers running in this tab")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(focused ? 0.1 : 0.06)))
        .overlay(alignment: .bottomLeading) {
            if let tab, tab.isLoading {
                GeometryReader { g in
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(8, g.size.width * tab.progress), height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .padding(.horizontal, 6)
                .allowsHitTesting(false)
            }
        }
        .onAppear { sync() }
        .onChange(of: tab?.url) { _ in if !focused { sync() } }
        .onChange(of: browser.selectedID) { _ in sync() }
        .onChange(of: browser.focusAddressBar) { _ in focused = true }
    }

    private func sync() {
        let url = tab?.url?.absoluteString ?? ""
        text = url == "about:blank" ? "" : url
    }
}

// MARK: Sidebar

private struct Sidebar: View {
    @ObservedObject var browser: Browser

    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(browser.tabs) { tab in
                    TabRow(tab: tab, selected: tab.id == browser.selectedID,
                           select: { browser.selectedID = tab.id },
                           close: { browser.close(tab) })
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
        }
    }
}

private struct TabRow: View {
    @ObservedObject var tab: Tab
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    // A Button, not a tap gesture: buttons take the first click in an unfocused window, and work with the
    // keyboard and VoiceOver. The close button sits on top, beside it, so the two never nest.
    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: select) {
                HStack(spacing: 10) {
                    Group {
                        if let icon = tab.favicon {
                            Image(nsImage: icon).resizable().interpolation(.high)
                        } else if tab.isLoading {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "globe").foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 16, height: 16)

                    Text(tab.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 10)
                .padding(.trailing, 34)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tab.title)
            .accessibilityAddTraits(selected ? .isSelected : [])

            if selected || hovering {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.trailing, 6)
                .help("Close tab (⌘W)")
                .accessibilityLabel("Close \(tab.title)")
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(selected ? 0.12 : hovering ? 0.05 : 0))
        )
        .onHover { hovering = $0 }
    }
}

// MARK: Content

private struct ContentCard: View {
    let tab: Tab?

    var body: some View {
        WebViewSlot(webView: tab?.webView)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 1)
    }
}

/// Hosts whichever tab's WKWebView is selected; the others stay alive off screen.
private struct WebViewSlot: NSViewRepresentable {
    let webView: WKWebView?

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        return v
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard container.subviews.first !== webView else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        guard let webView else { return }
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

// MARK: Pieces

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    init(_ symbol: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hovering && enabled ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
