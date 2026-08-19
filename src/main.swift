import AppKit
import SwiftUI
import Security
import CryptoKit

// MARK: - Config

struct AccountConfig: Codable {
    var name: String
    var configDir: String
}

struct AppConfig: Codable {
    var accounts: [AccountConfig]
    var refreshSeconds: Double?
    var labels: [String: String]?
    var locale: String?
}

// Locale for reset-time formatting; overridable via the "locale" config key
var appLocale = Locale.current

// NSString.expandingTildeInPath also normalizes trailing slashes away
func expandPath(_ p: String) -> String {
    (p as NSString).expandingTildeInPath
}

func configURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/notch-usage/config.json")
}

func loadConfig() -> AppConfig {
    if let data = try? Data(contentsOf: configURL()),
       let cfg = try? JSONDecoder().decode(AppConfig.self, from: data),
       !cfg.accounts.isEmpty {
        return cfg
    }
    return AppConfig(accounts: [
        AccountConfig(name: "Claude", configDir: "~/.claude"),
    ], refreshSeconds: 300)
}

// MARK: - Credentials

struct Creds {
    let accessToken: String
}

func parseCreds(_ data: Data) -> Creds? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    // Normal shape: {"claudeAiOauth": {"accessToken": ...}}; accept a flat object too
    let oauth = (obj["claudeAiOauth"] as? [String: Any]) ?? obj
    guard let tok = oauth["accessToken"] as? String, !tok.isEmpty else { return nil }
    return Creds(accessToken: tok)
}

let kcPrefix = "Claude Code-credentials"

func sha256Hex(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

// Claude Code stores credentials as "Claude Code-credentials" for the default
// ~/.claude profile and as "Claude Code-credentials-<first 8 hex of sha256(configDir)>"
// for profiles selected via CLAUDE_CONFIG_DIR (verified on Claude Code 2.1.235).
func candidateServices(configDir: String) -> [String] {
    let dir = expandPath(configDir)
    let hashed = "\(kcPrefix)-\(sha256Hex(dir).prefix(8))"
    if dir == expandPath("~/.claude") {
        return [kcPrefix, hashed]
    }
    return [hashed]
}

// Attribute-only listing: never triggers the keychain permission dialog.
func claudeKeychainServices() -> Set<String> {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecMatchLimit as String: kSecMatchLimitAll,
        kSecReturnAttributes as String: true,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let arr = result as? [[String: Any]] else { return [] }
    let names = arr.compactMap { $0[kSecAttrService as String] as? String }
        .filter { $0.hasPrefix(kcPrefix) }
    return Set(names)
}

func keychainReadData(service: String) -> (Data?, OSStatus) {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecReturnData as String: true,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    return (result as? Data, status)
}

// Single read+parse step shared by loadCreds and kcDebug so the two never drift
func tryReadService(_ service: String) -> (creds: Creds?, status: OSStatus, bytes: Int) {
    let (data, status) = keychainReadData(service: service)
    return (data.flatMap(parseCreds), status, data?.count ?? 0)
}

// MARK: - Usage API

struct UsageLine: Identifiable {
    let id = UUID()
    let label: String
    let pct: Int
    let resetText: String
}

struct AccountStatus: Identifiable {
    let id = UUID()
    let name: String
    var lines: [UsageLine] = []
    var error: String? = nil
    var updatedAt: Date? = nil
}

let isoPlain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()
let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
func parseISO(_ s: String) -> Date? { isoPlain.date(from: s) ?? isoFrac.date(from: s) }

func fmtReset(_ d: Date) -> String {
    if d <= Date() { return "" }
    let cal = Calendar.current
    let time = DateFormatter()
    time.locale = appLocale
    time.dateFormat = "HH:mm"
    if cal.isDateInToday(d) { return "→ \(time.string(from: d))" }
    if cal.isDateInTomorrow(d) {
        let rel = DateFormatter()
        rel.locale = appLocale
        rel.doesRelativeDateFormatting = true
        rel.dateStyle = .medium
        rel.timeStyle = .short
        return "→ \(rel.string(from: d))"
    }
    let wd = DateFormatter()
    wd.locale = appLocale
    wd.dateFormat = "EE HH:mm"
    return "→ \(wd.string(from: d))"
}

// Known usage buckets, in display order. Unknown buckets (internal/experimental
// keys the API may add) are shown with their raw key name, and only when non-zero.
let knownBuckets: [(key: String, label: String)] = [
    ("five_hour", "5h session"),
    ("seven_day", "Week"),
    ("seven_day_opus", "Week Opus"),
    ("seven_day_sonnet", "Week Sonnet"),
    ("seven_day_oauth_apps", "Week (apps)"),
]
let knownKeyOrder = knownBuckets.map(\.key)
let defaultLabels = Dictionary(uniqueKeysWithValues: knownBuckets.map { ($0.key, $0.label) })

func makeLine(key: String, dict: [String: Any], labels: [String: String]) -> UsageLine? {
    guard let n = dict["utilization"] as? NSNumber else { return nil }
    let u = n.doubleValue
    // Clamp in Double space: Int(hugeDouble) traps before any Int-side clamp could run
    guard u.isFinite else { return nil }
    var resetText = ""
    if let rs = dict["resets_at"] as? String, let d = parseISO(rs) { resetText = fmtReset(d) }
    let label = labels[key] ?? defaultLabels[key] ?? key
    return UsageLine(label: label, pct: Int(min(max(u.rounded(), 0), 999)), resetText: resetText)
}

func parseUsage(_ obj: [String: Any], labels: [String: String]) -> [UsageLine] {
    var lines: [UsageLine] = []
    var used = Set<String>()
    for key in knownKeyOrder {
        if let d = obj[key] as? [String: Any], let line = makeLine(key: key, dict: d, labels: labels) {
            lines.append(line)
            used.insert(key)
        }
    }
    for (key, val) in obj.sorted(by: { $0.key < $1.key }) {
        guard !used.contains(key), let d = val as? [String: Any],
              let line = makeLine(key: key, dict: d, labels: labels) else { continue }
        if line.pct >= 1 { lines.append(line) }
    }
    if lines.isEmpty {
        for (_, val) in obj {
            if let nested = val as? [String: Any] {
                let inner = parseUsage(nested, labels: labels)
                if !inner.isEmpty { return inner }
            }
        }
    }
    return lines
}

// Fallback snapshot; detectCLIVersion() replaces it at startup with the
// installed CLI's real version (the endpoint throttles unknown user agents)
var userAgent = "claude-code/2.1.235"

func runProcess(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    let sem = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        p.waitUntilExit()
        sem.signal()
    }
    if sem.wait(timeout: .now() + timeout) == .timedOut {
        p.terminate()
        return nil
    }
    guard p.terminationStatus == 0 else { return nil }
    return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
}

// Ask the installed claude CLI for its version once at startup, so the
// User-Agent tracks reality instead of drifting from a hand-copied constant.
// Runs before any concurrent fetch touches userAgent.
func detectCLIVersion() {
    let home = NSHomeDirectory()
    var bin = [
        "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        "\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }
    if bin == nil,
       let found = runProcess("/bin/zsh", ["-lc", "whence -p claude"])?
           .trimmingCharacters(in: .whitespacesAndNewlines),
       !found.isEmpty {
        bin = found
    }
    guard let bin,
          let ver = runProcess(bin, ["--version"]),
          let range = ver.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return }
    userAgent = "claude-code/\(ver[range])"
}

func fetchUsage(token: String, labels: [String: String], completion: @escaping ([UsageLine]?, String?) -> Void) {
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    req.timeoutInterval = 15
    URLSession.shared.dataTask(with: req) { data, resp, err in
        if let err = err {
            completion(nil, "network: \(err.localizedDescription)")
            return
        }
        guard let http = resp as? HTTPURLResponse else {
            completion(nil, "no response")
            return
        }
        switch http.statusCode {
        case 200:
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil, "malformed JSON")
                return
            }
            let lines = parseUsage(obj, labels: labels)
            completion(lines.isEmpty ? nil : lines, lines.isEmpty ? "empty API response" : nil)
        case 401:
            completion(nil, "token expired — open Claude Code")
        case 429:
            completion(nil, "rate-limited by usage API (429)")
        default:
            completion(nil, "HTTP \(http.statusCode)")
        }
    }.resume()
}

// MARK: - Store

final class Store: ObservableObject {
    @Published var statuses: [AccountStatus]
    @Published var refreshing = false
    let cfg: AppConfig
    let demo: Bool
    let labels: [String: String]
    private var lastFetch: Date? = nil
    // All keychain access is serialized on credsQueue: deniedServices is only
    // touched there, and first-run permission dialogs appear one at a time
    private let credsQueue = DispatchQueue(label: "ru.bugaev.notchusage.creds", qos: .userInitiated)
    private var deniedServices = Set<String>()

    init(cfg: AppConfig, demo: Bool) {
        self.cfg = cfg
        self.demo = demo
        self.labels = defaultLabels.merging(cfg.labels ?? [:]) { _, custom in custom }
        if let id = cfg.locale { appLocale = Locale(identifier: id) }
        if demo {
            self.statuses = Store.demoStatuses()
        } else {
            self.statuses = cfg.accounts.map { AccountStatus(name: $0.name) }
        }
    }

    static func demoStatuses() -> [AccountStatus] {
        [
            AccountStatus(name: "Personal Max", lines: [
                UsageLine(label: "5h session", pct: 42, resetText: "→ 19:00"),
                UsageLine(label: "Week", pct: 63, resetText: "→ Thu 07:00"),
                UsageLine(label: "Week Opus", pct: 88, resetText: "→ Thu 07:00"),
            ], updatedAt: Date()),
            AccountStatus(name: "Work Team", lines: [
                UsageLine(label: "5h session", pct: 12, resetText: "→ 21:30"),
                UsageLine(label: "Week", pct: 55, resetText: "→ Fri 10:00"),
            ], updatedAt: Date()),
        ]
    }

    func refreshIfStale(maxAge: TimeInterval = 60) {
        if let lf = lastFetch, Date().timeIntervalSince(lf) < maxAge { return }
        refresh()
    }

    func forceRefresh() {
        credsQueue.async { self.deniedServices.removeAll() }
        lastFetch = nil
        refresh()
    }

    // Called from the main thread (timers, hover, the ⟳ button, runPrint)
    func refresh() {
        if demo { return }
        lastFetch = Date()
        refreshing = true
        let group = DispatchGroup()
        for _ in cfg.accounts { group.enter() }
        credsQueue.async {
            let existing = claudeKeychainServices()
            for (idx, acct) in self.cfg.accounts.enumerated() {
                let (creds, credErr) = self.loadCreds(acct: acct, existing: existing)
                guard let creds else {
                    DispatchQueue.main.async {
                        self.statuses[idx].error = credErr
                        group.leave()
                    }
                    continue
                }
                fetchUsage(token: creds.accessToken, labels: self.labels) { lines, err in
                    DispatchQueue.main.async {
                        if let lines {
                            self.statuses[idx].lines = lines
                            self.statuses[idx].error = nil
                            self.statuses[idx].updatedAt = Date()
                        } else {
                            self.statuses[idx].error = err ?? "unknown error"
                        }
                        group.leave()
                    }
                }
            }
        }
        group.notify(queue: .main) { self.refreshing = false }
    }

    // credsQueue only
    private func loadCreds(acct: AccountConfig, existing: Set<String>) -> (Creds?, String?) {
        let dir = expandPath(acct.configDir)
        // A .credentials.json file inside the profile dir wins over the keychain
        // (mirrors Claude Code's own lookup order)
        let fileURL = URL(fileURLWithPath: dir).appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: fileURL), let c = parseCreds(data) { return (c, nil) }

        let candidates = candidateServices(configDir: dir).filter { existing.contains($0) }
        if candidates.isEmpty {
            return (nil, "no keychain record — run /login in this profile")
        }
        var lastStatus: OSStatus = errSecSuccess
        var denied = false
        for service in candidates {
            if deniedServices.contains(service) {
                denied = true
                continue
            }
            let r = tryReadService(service)
            if let c = r.creds { return (c, nil) }
            if r.status == errSecUserCanceled {
                deniedServices.insert(service)
                denied = true
                continue
            }
            lastStatus = r.status
        }
        if denied { return (nil, "keychain access denied — press ⟳ to retry") }
        if lastStatus == errSecSuccess {
            return (nil, "keychain record unreadable — re-run /login")
        }
        return (nil, "keychain error \(lastStatus)")
    }

    // Diagnostic dump for --kc-debug: service names and match results, no secrets.
    func kcDebug() {
        credsQueue.sync {
            let existing = claudeKeychainServices().sorted()
            print("keychain items with prefix [\(kcPrefix)]:")
            for s in existing { print("  \(s)") }
            for acct in cfg.accounts {
                let dir = expandPath(acct.configDir)
                print("account [\(acct.name)] dir [\(dir)]:")
                for c in candidateServices(configDir: dir) {
                    guard existing.contains(c) else {
                        print("  candidate \(c): MISSING")
                        continue
                    }
                    let r = tryReadService(c)
                    print("  candidate \(c): present, read status \(r.status), bytes \(r.bytes), parses \(r.creds != nil)")
                }
            }
        }
    }
}

// MARK: - Views

enum PanelMetrics {
    static let panelWidth: CGFloat = 372
    static let containerWidth: CGFloat = 380
    static let fallbackZoneWidth: CGFloat = 200
}

struct PanelView: View {
    @ObservedObject var store: Store
    static let hhmm: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    let barW: CGFloat = 92

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(store.statuses) { st in
                accountView(st)
            }
            footer
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(width: PanelMetrics.panelWidth)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    func accountView(_ st: AccountStatus) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(st.error == nil ? Color.green.opacity(0.9) : Color.orange)
                    .frame(width: 6, height: 6)
                Text(st.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                if let u = st.updatedAt {
                    Text(Self.hhmm.string(from: u))
                        .font(.system(size: 9))
                        .foregroundColor(Color.white.opacity(0.35))
                }
            }
            if let e = st.error {
                Text(e)
                    .font(.system(size: 11))
                    .foregroundColor(Color.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            } else if st.lines.isEmpty {
                Text("loading…")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            } else {
                ForEach(st.lines) { line in lineView(line) }
            }
        }
    }

    func lineView(_ l: UsageLine) -> some View {
        HStack(spacing: 8) {
            Text(l.label)
                .font(.system(size: 11))
                .foregroundColor(Color.white.opacity(0.7))
                .frame(width: 100, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(color(l.pct))
                    .frame(width: barW * CGFloat(min(l.pct, 100)) / 100.0)
            }
            .frame(width: barW, height: 5)
            Text("\(l.pct)%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundColor(color(l.pct))
                .frame(width: 40, alignment: .trailing)
            Text(l.resetText)
                .font(.system(size: 10))
                .foregroundColor(Color.white.opacity(0.45))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var footer: some View {
        HStack {
            Text(store.refreshing ? "updating…" : "NotchUsage")
                .font(.system(size: 9))
                .foregroundColor(Color.white.opacity(0.3))
            Spacer()
            Button { store.forceRefresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
    }

    func color(_ p: Int) -> Color {
        p >= 85 ? .red : (p >= 60 ? .orange : Color(red: 0.3, green: 0.85, blue: 0.4))
    }
}

struct ContainerView: View {
    @ObservedObject var store: Store
    let topInset: CGFloat
    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(width: PanelMetrics.containerWidth, height: max(topInset, 1))
            PanelView(store: store)
            Spacer(minLength: 0)
        }
        .frame(width: PanelMetrics.containerWidth)
    }
}

// MARK: - Notch controller

// Plain NSWindow clamps frames below the menu bar (constrainFrameRect);
// a window hugging the notch must opt out of that
final class NotchPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

final class NotchController: NSObject {
    let store: Store
    let window: NSPanel
    let hosting: NSHostingView<ContainerView>
    var expanded = false
    var pollTimer: Timer?
    var refreshTimer: Timer?
    var enterTicks = 0
    var exitTicks = 0
    var notch: NSRect = .zero
    var screenTop: CGFloat = 0
    var forcedUntil: Date? = nil

    init(store: Store) {
        self.store = store
        let panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        self.window = panel
        self.hosting = NSHostingView(rootView: ContainerView(store: store, topInset: 1))
        super.init()
        // Host SwiftUI inside a plain contentView; as the contentView itself it
        // would drive window resizing and fight our frame management
        hosting.sizingOptions = []
        let container = NSView()
        container.autoresizesSubviews = true
        panel.contentView = container
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        updateNotchRect()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        // SwiftUI may re-fit the window height after layout; re-anchor the top
        // edge on the resize event itself instead of polling for drift
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowResized),
            name: NSWindow.didResizeNotification, object: panel
        )
    }

    @objc func windowResized() {
        if expanded { pinTop() }
    }

    @objc func screensChanged() {
        updateNotchRect()
        if expanded { layoutAndShow() }
    }

    func updateNotchRect() {
        notch = .zero
        for s in NSScreen.screens {
            let inset = s.safeAreaInsets.top
            guard inset > 0 else { continue }
            var x = s.frame.midX - PanelMetrics.fallbackZoneWidth / 2
            var w = PanelMetrics.fallbackZoneWidth
            if let tl = s.auxiliaryTopLeftArea, let tr = s.auxiliaryTopRightArea {
                x = tl.maxX
                w = tr.minX - tl.maxX
            }
            notch = NSRect(x: x, y: s.frame.maxY - inset, width: w, height: inset)
            screenTop = s.frame.maxY
            hosting.rootView = ContainerView(store: store, topInset: inset + 6)
            NSLog("notch rect: %@", NSStringFromRect(notch))
            return
        }
        // No notch (lid closed): hover zone is the top center of the main display
        if let s = NSScreen.main {
            notch = NSRect(x: s.frame.midX - PanelMetrics.fallbackZoneWidth / 2, y: s.frame.maxY - 2,
                           width: PanelMetrics.fallbackZoneWidth, height: 2)
            screenTop = s.frame.maxY
            hosting.rootView = ContainerView(store: store, topInset: 8)
            NSLog("no notch, fallback zone: %@", NSStringFromRect(notch))
        }
    }

    func start(showNow: Bool) {
        let poll = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(poll, forMode: .common)
        pollTimer = poll
        let interval = max(store.cfg.refreshSeconds ?? 300, 60)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.store.refresh()
        }
        store.refresh()
        if showNow {
            forcedUntil = Date().addingTimeInterval(store.demo ? 600 : 15)
            expand()
        }
    }

    // SwiftUI re-fits the window height after layout; that is fine, but the
    // top edge must stay glued to the screen edge
    func pinTop() {
        let f = window.frame
        if abs(f.maxY - screenTop) > 0.5 {
            window.setFrame(
                NSRect(x: f.origin.x, y: screenTop - f.height, width: f.width, height: f.height),
                display: true
            )
        }
    }

    func tick() {
        if let f = forcedUntil {
            if Date() < f { return }
            forcedUntil = nil
        }
        let m = NSEvent.mouseLocation
        if expanded {
            if window.frame.insetBy(dx: -12, dy: -12).contains(m) {
                exitTicks = 0
            } else {
                exitTicks += 1
                if exitTicks >= 4 { collapse() }
            }
        } else {
            guard notch != .zero else { return }
            if notch.insetBy(dx: -2, dy: -4).contains(m) {
                enterTicks += 1
                if enterTicks >= 2 { expand() }
            } else {
                enterTicks = 0
            }
        }
    }

    func expand() {
        guard !expanded else { return }
        expanded = true
        enterTicks = 0
        exitTicks = 0
        store.refreshIfStale()
        layoutAndShow()
    }

    func layoutAndShow() {
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        if size.width < PanelMetrics.containerWidth { size.width = PanelMetrics.containerWidth }
        if size.height < 60 { size.height = 200 }
        let x = (notch != .zero ? notch.midX : screenTop) - size.width / 2
        let y = screenTop - size.height
        window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            window.animator().alphaValue = 1
        }
        NSLog("expanded: %@", NSStringFromRect(window.frame))
    }

    func collapse() {
        guard expanded else { return }
        expanded = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            window.animator().alphaValue = 0
        }, completionHandler: {
            self.window.orderOut(nil)
        })
    }
}

// MARK: - --print mode (terminal diagnostics)

func runPrint(cfg: AppConfig) {
    let store = Store(cfg: cfg, demo: false)
    store.refresh()
    let deadline = Date().addingTimeInterval(45)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        if store.statuses.allSatisfy({ $0.error != nil || !$0.lines.isEmpty }) { break }
    }
    for st in store.statuses {
        if let e = st.error {
            print("\(st.name): ERROR — \(e)")
        } else if st.lines.isEmpty {
            print("\(st.name): no data (timeout)")
        } else {
            let parts = st.lines.map { l -> String in
                l.resetText.isEmpty ? "\(l.label) \(l.pct)%" : "\(l.label) \(l.pct)% (\(l.resetText))"
            }
            print("\(st.name): " + parts.joined(separator: "; "))
        }
    }
}

// MARK: - --selftest (pure-function unit checks, no network/keychain)

func runSelfTest() -> Int {
    var failures = 0
    func check(_ cond: Bool, _ name: String) {
        if cond { print("ok   \(name)") } else { failures += 1; print("FAIL \(name)") }
    }

    check(sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
          "sha256Hex known vector")

    let home = FileManager.default.homeDirectoryForCurrentUser.path
    check(expandPath("~/.claude") == "\(home)/.claude", "expandPath tilde")
    check(expandPath("~/.claude-work/") == "\(home)/.claude-work", "expandPath strips trailing slash")

    let def = candidateServices(configDir: "~/.claude")
    check(def.count == 2 && def[0] == kcPrefix && def[1].hasPrefix("\(kcPrefix)-"),
          "default profile: bare service first, hashed second")
    let custom = candidateServices(configDir: "~/some-profile")
    let expectedSuffix = sha256Hex(expandPath("~/some-profile")).prefix(8)
    check(custom == ["\(kcPrefix)-\(expectedSuffix)"], "custom profile: hashed service only")

    let nested = #"{"claudeAiOauth":{"accessToken":"tok-1","expiresAt":1755600000000}}"#
    let flat = #"{"accessToken":"tok-2"}"#
    check(parseCreds(Data(nested.utf8))?.accessToken == "tok-1", "parseCreds nested shape")
    check(parseCreds(Data(flat.utf8))?.accessToken == "tok-2", "parseCreds flat shape")
    check(parseCreds(Data()) == nil, "parseCreds empty data")
    check(parseCreds(Data("garbage".utf8)) == nil, "parseCreds garbage")

    let future = isoPlain.string(from: Date(timeIntervalSinceNow: 3600))
    let usage: [String: Any] = [
        "five_hour": ["utilization": 33.4, "resets_at": future],
        "seven_day": ["utilization": 8],
        "mystery_zero": ["utilization": 0.2],
        "mystery_used": ["utilization": 7.0],
        "not_a_bucket": "string",
    ]
    let lines = parseUsage(usage, labels: defaultLabels)
    check(lines.map(\.label) == ["5h session", "Week", "mystery_used"],
          "parseUsage: known order, zero unknown hidden, non-zero unknown shown")
    check(lines[0].pct == 33 && lines[1].pct == 8, "parseUsage: rounding and Int utilization")
    check(lines[0].resetText.hasPrefix("→ "), "parseUsage: reset text present")
    let wrapped = parseUsage(["data": usage], labels: defaultLabels)
    check(wrapped.count == 3, "parseUsage: unwraps nested container")
    let custom_labels = parseUsage(["five_hour": ["utilization": 1.0]],
                                   labels: ["five_hour": "Сессия 5 ч"])
    check(custom_labels.first?.label == "Сессия 5 ч", "parseUsage: label override")
    check(makeLine(key: "x", dict: ["utilization": 1e30], labels: [:])?.pct == 999, "makeLine clamps huge values")
    check(makeLine(key: "x", dict: ["utilization": Double.nan], labels: [:]) == nil, "makeLine rejects NaN")

    check(fmtReset(Date(timeIntervalSinceNow: -60)) == "", "fmtReset past date empty")
    check(fmtReset(Date(timeIntervalSinceNow: 60)).hasPrefix("→ "), "fmtReset future arrow")
    if let t1 = Calendar.current.date(byAdding: .day, value: 1, to: Date()),
       let tomorrowNoon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: t1) {
        check(fmtReset(tomorrowNoon).hasPrefix("→ "), "fmtReset tomorrow branch")
    }

    print(failures == 0 ? "SELFTEST PASSED" : "SELFTEST FAILED: \(failures)")
    return failures
}

// MARK: - Entry point

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: NotchController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        detectCLIVersion()
        let demo = CommandLine.arguments.contains("--demo")
        let store = Store(cfg: loadConfig(), demo: demo)
        let c = NotchController(store: store)
        controller = c
        c.start(showNow: demo || CommandLine.arguments.contains("--show"))
    }
}

@main enum Main {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            exit(runSelfTest() == 0 ? 0 : 1)
        }
        if CommandLine.arguments.contains("--kc-debug") {
            Store(cfg: loadConfig(), demo: false).kcDebug()
            return
        }
        if CommandLine.arguments.contains("--print") {
            detectCLIVersion()
            runPrint(cfg: loadConfig())
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
