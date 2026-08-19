import AppKit
import SwiftUI
import Security

// MARK: - Конфиг

struct AccountConfig: Codable {
    var name: String
    var configDir: String
}

struct AppConfig: Codable {
    var accounts: [AccountConfig]
    var refreshSeconds: Double?
}

func expandPath(_ p: String) -> String { (p as NSString).expandingTildeInPath }

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
        AccountConfig(name: "Личный Max", configDir: "~/.claude"),
        AccountConfig(name: "Рабочий Team", configDir: "~/.claude-work"),
    ], refreshSeconds: 300)
}

// MARK: - Учётные данные

struct Creds {
    let accessToken: String
    let expiresAt: Date?
}

func parseCreds(_ data: Data) -> Creds? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = obj["claudeAiOauth"] as? [String: Any],
          let tok = oauth["accessToken"] as? String, !tok.isEmpty else { return nil }
    var exp: Date? = nil
    if let ms = oauth["expiresAt"] as? Double { exp = Date(timeIntervalSince1970: ms / 1000.0) }
    return Creds(accessToken: tok, expiresAt: exp)
}

let kcPrefix = "Claude Code-credentials"

// Все записи связки ключей, чьё имя сервиса начинается с префикса Claude Code.
// Читаются только атрибуты (без секретов) — системный запрос не показывается.
func claudeKeychainServices() -> [String] {
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
    return Array(Set(names)).sorted()
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

// MARK: - Запрос лимитов

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
    time.locale = Locale(identifier: "ru_RU")
    time.dateFormat = "HH:mm"
    if cal.isDateInToday(d) { return "до \(time.string(from: d))" }
    if cal.isDateInTomorrow(d) { return "до завтра \(time.string(from: d))" }
    let wd = DateFormatter()
    wd.locale = Locale(identifier: "ru_RU")
    wd.dateFormat = "EE HH:mm"
    return "до \(wd.string(from: d))"
}

let knownKeys: [(String, String)] = [
    ("five_hour", "Сессия 5 ч"),
    ("seven_day", "Неделя"),
    ("seven_day_opus", "Неделя Opus"),
    ("seven_day_sonnet", "Неделя Sonnet"),
    ("seven_day_oauth_apps", "Неделя (прилож.)"),
]

func makeLine(label: String, dict: [String: Any]) -> UsageLine? {
    guard let u = dict["utilization"] as? Double else { return nil }
    var resetText = ""
    if let rs = dict["resets_at"] as? String, let d = parseISO(rs) { resetText = fmtReset(d) }
    return UsageLine(label: label, pct: max(0, min(Int(u.rounded()), 999)), resetText: resetText)
}

func parseUsage(_ obj: [String: Any]) -> [UsageLine] {
    var lines: [UsageLine] = []
    var used = Set<String>()
    for (key, label) in knownKeys {
        if let d = obj[key] as? [String: Any], let line = makeLine(label: label, dict: d) {
            lines.append(line)
            used.insert(key)
        }
    }
    for (key, val) in obj.sorted(by: { $0.key < $1.key }) {
        guard !used.contains(key), let d = val as? [String: Any],
              let line = makeLine(label: key, dict: d) else { continue }
        lines.append(line)
    }
    // На случай, если ответ завёрнут во вложенный объект
    if lines.isEmpty {
        for (_, val) in obj {
            if let nested = val as? [String: Any] {
                let inner = parseUsage(nested)
                if !inner.isEmpty { return inner }
            }
        }
    }
    return lines
}

let userAgent = "claude-code/2.1.235"

func fetchUsage(token: String, completion: @escaping ([UsageLine]?, String?) -> Void) {
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    req.timeoutInterval = 15
    URLSession.shared.dataTask(with: req) { data, resp, err in
        if let err = err {
            completion(nil, "сеть: \(err.localizedDescription)")
            return
        }
        guard let http = resp as? HTTPURLResponse else {
            completion(nil, "нет ответа")
            return
        }
        switch http.statusCode {
        case 200:
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil, "некорректный JSON")
                return
            }
            let lines = parseUsage(obj)
            completion(lines.isEmpty ? nil : lines, lines.isEmpty ? "пустой ответ API" : nil)
        case 401:
            completion(nil, "токен истёк — открой Claude Code")
        case 429:
            completion(nil, "API просит подождать (429)")
        default:
            completion(nil, "HTTP \(http.statusCode)")
        }
    }.resume()
}

// MARK: - Хранилище состояния

final class Store: ObservableObject {
    @Published var statuses: [AccountStatus]
    @Published var refreshing = false
    let cfg: AppConfig
    let demo: Bool
    private var lastFetch: Date? = nil
    private var deniedServices = Set<String>()
    private var assignment: [String: String] = [:]

    init(cfg: AppConfig, demo: Bool) {
        self.cfg = cfg
        self.demo = demo
        if demo {
            self.statuses = Store.demoStatuses()
        } else {
            self.statuses = cfg.accounts.map { AccountStatus(name: $0.name) }
        }
    }

    static func demoStatuses() -> [AccountStatus] {
        [
            AccountStatus(name: "Личный Max", lines: [
                UsageLine(label: "Сессия 5 ч", pct: 42, resetText: "до 19:00"),
                UsageLine(label: "Неделя", pct: 63, resetText: "до чт 07:00"),
                UsageLine(label: "Неделя Opus", pct: 88, resetText: "до чт 07:00"),
            ], updatedAt: Date()),
            AccountStatus(name: "Рабочий Team", lines: [
                UsageLine(label: "Сессия 5 ч", pct: 12, resetText: "до 21:30"),
                UsageLine(label: "Неделя", pct: 55, resetText: "до пт 10:00"),
            ], updatedAt: Date()),
        ]
    }

    func refreshIfStale(maxAge: TimeInterval = 60) {
        if let lf = lastFetch, Date().timeIntervalSince(lf) < maxAge { return }
        refresh()
    }

    func forceRefresh() {
        deniedServices.removeAll()
        lastFetch = nil
        refresh()
    }

    func refresh() {
        if demo { return }
        lastFetch = Date()
        DispatchQueue.main.async { self.refreshing = true }
        let group = DispatchGroup()
        for (idx, acct) in cfg.accounts.enumerated() {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                self.fetchAccount(idx: idx, acct: acct) { group.leave() }
            }
        }
        group.notify(queue: .main) { self.refreshing = false }
    }

    private func fetchAccount(idx: Int, acct: AccountConfig, done: @escaping () -> Void) {
        let (creds, credErr) = loadCreds(acct: acct)
        guard let creds = creds else {
            DispatchQueue.main.async {
                self.statuses[idx].error = credErr
                done()
            }
            return
        }
        fetchUsage(token: creds.accessToken) { lines, err in
            DispatchQueue.main.async {
                if let lines = lines {
                    self.statuses[idx].lines = lines
                    self.statuses[idx].error = nil
                    self.statuses[idx].updatedAt = Date()
                } else {
                    self.statuses[idx].error = err ?? "неизвестная ошибка"
                }
                done()
            }
        }
    }

    // configDir -> имя сервиса в связке ключей. Дефолтный профиль — запись без суффикса,
    // кастомные — записи с хэшем пути; сопоставление по порядку аккаунтов в конфиге.
    private func keychainAssignment() -> [String: String] {
        if !assignment.isEmpty { return assignment }
        let defaultDir = expandPath("~/.claude")
        let services = claudeKeychainServices()
        let suffixed = services.filter { $0 != kcPrefix }
        var si = 0
        var map: [String: String] = [:]
        for acct in cfg.accounts {
            let dir = expandPath(acct.configDir)
            if dir == defaultDir {
                if services.contains(kcPrefix) { map[dir] = kcPrefix }
            } else if si < suffixed.count {
                map[dir] = suffixed[si]
                si += 1
            }
        }
        assignment = map
        return map
    }

    private func loadCreds(acct: AccountConfig) -> (Creds?, String?) {
        let dir = expandPath(acct.configDir)
        let fileURL = URL(fileURLWithPath: dir).appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: fileURL), let c = parseCreds(data) { return (c, nil) }
        guard let service = keychainAssignment()[dir] else {
            return (nil, "нет учётки — выполни /login в профиле")
        }
        if deniedServices.contains(service) {
            return (nil, "нет доступа к связке ключей — нажми ⟳")
        }
        let (data, status) = keychainReadData(service: service)
        if let data = data, let c = parseCreds(data) { return (c, nil) }
        if status == errSecUserCanceled {
            deniedServices.insert(service)
            return (nil, "доступ к связке ключей запрещён")
        }
        return (nil, "связка ключей: ошибка \(status)")
    }
}

// MARK: - Вьюхи

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
        .frame(width: 372)
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
                Text("загружаю…")
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
                .frame(width: 94, alignment: .leading)
                .lineLimit(1)
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
            Text(store.refreshing ? "обновляю…" : "NotchUsage")
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
            Color.clear.frame(width: 380, height: max(topInset, 1))
            PanelView(store: store)
            Spacer(minLength: 0)
        }
        .frame(width: 380)
    }
}

// MARK: - Контроллер чёлки

// Стандартный NSWindow зажимает фрейм под менюбар (constrainFrameRect) —
// для окна поверх чёлки это отключаем
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
        // Хостинг — сабвью обычного contentView, иначе SwiftUI сам ресайзит окно
        // и верхняя кромка уезжает от края экрана
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
            var x = s.frame.midX - 100
            var w: CGFloat = 200
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
        // Фолбэк без чёлки (крышка закрыта): зона наведения — верхний центр главного экрана
        if let s = NSScreen.main {
            notch = NSRect(x: s.frame.midX - 100, y: s.frame.maxY - 2, width: 200, height: 2)
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

    // Окно после раскладки SwiftUI само ужимается под контент — это ок,
    // но верхняя кромка должна оставаться прижатой к краю экрана
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
        if expanded { pinTop() }
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
        if size.width < 380 { size.width = 380 }
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

// MARK: - Режим --print (диагностика в терминале)

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
            print("\(st.name): ОШИБКА — \(e)")
        } else if st.lines.isEmpty {
            print("\(st.name): нет данных (таймаут)")
        } else {
            let parts = st.lines.map { l -> String in
                l.resetText.isEmpty ? "\(l.label) \(l.pct)%" : "\(l.label) \(l.pct)% (\(l.resetText))"
            }
            print("\(st.name): " + parts.joined(separator: "; "))
        }
    }
}

// MARK: - Точка входа

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: NotchController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let demo = CommandLine.arguments.contains("--demo")
        let store = Store(cfg: loadConfig(), demo: demo)
        let c = NotchController(store: store)
        controller = c
        c.start(showNow: demo || CommandLine.arguments.contains("--show"))
    }
}

@main enum Main {
    static func main() {
        if CommandLine.arguments.contains("--print") {
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
