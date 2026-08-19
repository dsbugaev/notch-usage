import AppKit
import SwiftUI
import Security
import CryptoKit
import Combine

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

// The gear button: reveal the config in the default editor, creating it first
// if the app was launched without install.sh ever generating one
func openConfigInEditor() {
    let url = configURL()
    if !FileManager.default.fileExists(atPath: url.path) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(loadConfig()) { try? data.write(to: url) }
    }
    NSWorkspace.shared.open(url)
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

// Keychain reads go through a separate helper binary that is built once and
// cached: macOS grants "Always Allow" to that stable file, so rebuilding the
// main app never re-triggers permission dialogs. Falls back to a direct read
// when the helper is missing (e.g. running the bare binary from src).
let helperName = "NotchUsage Credentials"

func keychainReadViaHelper(service: String) -> (Data?, OSStatus)? {
    let url = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().appendingPathComponent(helperName)
    guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
    let p = Process()
    p.executableURL = url
    p.arguments = [service]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    // No timeout: the first run sits on the permission dialog until the user
    // answers; reads are serialized on credsQueue so dialogs come one at a time
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    switch p.terminationStatus {
    case 0: return (data, errSecSuccess)
    case 44: return (nil, errSecUserCanceled)
    case 45: return (nil, errSecItemNotFound)
    default: return (nil, errSecIO)
    }
}

// Single read+parse step shared by loadCreds and kcDebug so the two never drift
func tryReadService(_ service: String) -> (creds: Creds?, status: OSStatus, data: Data?) {
    let (data, status) = keychainReadViaHelper(service: service) ?? keychainReadData(service: service)
    return (data.flatMap(parseCreds), status, data)
}

// Which records to actually read for a profile. The bare record is canonical
// for the default ~/.claude profile: when it exists, never touch the hashed
// variant — stale hashed duplicates from old Claude Code versions otherwise
// trigger keychain permission prompts for a dead record
func effectiveCandidates(configDir: String, existing: Set<String>) -> [String] {
    var candidates = candidateServices(configDir: configDir).filter { existing.contains($0) }
    if candidates.count > 1 && candidates.first == kcPrefix {
        candidates = [kcPrefix]
    }
    return candidates
}

// MARK: - Usage API

struct UsageLine: Identifiable {
    let id = UUID()
    let label: String
    let pct: Int
    let resetText: String
    var known = true
}

// The panel hides unrecognized zero buckets (internal/experimental API keys);
// --print always shows everything, so new buckets are discoverable
func panelVisibleLines(_ lines: [UsageLine]) -> [UsageLine] {
    lines.filter { $0.known || $0.pct >= 1 }
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
        // "tomorrow"/"завтра" as a single localized word + our compact time —
        // full relative DateFormatter output ("Tomorrow at 1:49 AM") overflows
        let rel = RelativeDateTimeFormatter()
        rel.locale = appLocale
        rel.dateTimeStyle = .named
        let word = rel.localizedString(from: DateComponents(day: 1))
        return "→ \(word) \(time.string(from: d))"
    }
    let wd = DateFormatter()
    wd.locale = appLocale
    wd.dateFormat = "EE HH:mm"
    return "→ \(wd.string(from: d))"
}

// Known usage buckets, in display order. Unknown buckets the API may add are
// kept with their raw key name; the panel shows them only when non-zero.
let knownBuckets: [(key: String, label: String)] = [
    ("five_hour", "5h session"),
    ("seven_day", "Week (all)"),
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
    return UsageLine(label: label, pct: Int(min(max(u.rounded(), 0), 999)), resetText: resetText,
                     known: defaultLabels[key] != nil || labels[key] != nil)
}

// Labels for entries of the "limits" array; scoped windows get "<kind>:<model>"
// keys so configs can override them precisely (e.g. "weekly_scoped:Fable")
let knownLimitKinds: Set<String> = ["session", "weekly_all", "weekly_scoped"]
let legacyLabelKeys = ["session": "five_hour", "weekly_all": "seven_day"]

func defaultLimitLabel(kind: String, scopeName: String?) -> String {
    switch kind {
    case "session": return "5h session"
    case "weekly_all": return "Week (all)"
    case "weekly_scoped": return scopeName.map { "Week \($0)" } ?? "Week (scoped)"
    default: return scopeName.map { "\(kind) \($0)" } ?? kind
    }
}

// Preferred source: the "limits" array — unlike the flat top-level buckets it
// carries per-model scoped weekly windows (the Fable | All models split)
func parseLimitsArray(_ obj: [String: Any], labels: [String: String]) -> [UsageLine] {
    guard let arr = obj["limits"] as? [[String: Any]] else { return [] }
    var lines: [UsageLine] = []
    for item in arr {
        guard let kind = item["kind"] as? String,
              let n = item["percent"] as? NSNumber else { continue }
        let u = n.doubleValue
        guard u.isFinite else { continue }
        var scopeName: String? = nil
        if let scope = item["scope"] as? [String: Any],
           let model = scope["model"] as? [String: Any],
           let dn = model["display_name"] as? String, !dn.isEmpty {
            scopeName = dn
        }
        let key = scopeName.map { "\(kind):\($0)" } ?? kind
        var resetText = ""
        if let rs = item["resets_at"] as? String, let d = parseISO(rs) { resetText = fmtReset(d) }
        let label = labels[key] ?? labels[kind]
            ?? legacyLabelKeys[kind].flatMap { labels[$0] }
            ?? defaultLimitLabel(kind: kind, scopeName: scopeName)
        lines.append(UsageLine(label: label, pct: Int(min(max(u.rounded(), 0), 999)),
                               resetText: resetText, known: knownLimitKinds.contains(kind)))
    }
    return lines
}

func parseUsage(_ obj: [String: Any], labels: [String: String]) -> [UsageLine] {
    let fromLimits = parseLimitsArray(obj, labels: labels)
    if !fromLimits.isEmpty { return fromLimits }

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
        lines.append(line)
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

// Fallback snapshot; detectCLIVersion() replaces it with the installed CLI's
// real version (the endpoint throttles unknown user agents). Thread-safe:
// detection runs on a background queue while fetches read from credsQueue.
final class UserAgentHolder {
    private var value = "claude-code/2.1.235"
    private let lock = NSLock()
    var current: String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func set(_ v: String) {
        lock.lock()
        value = v
        lock.unlock()
    }
}
let userAgentHolder = UserAgentHolder()

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
    userAgentHolder.set("claude-code/\(ver[range])")
}

func fetchUsage(token: String, labels: [String: String],
                completion: @escaping ([UsageLine]?, String?, Int?) -> Void) {
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue(userAgentHolder.current, forHTTPHeaderField: "User-Agent")
    req.timeoutInterval = 15
    URLSession.shared.dataTask(with: req) { data, resp, err in
        if let err = err {
            completion(nil, "network: \(err.localizedDescription)", nil)
            return
        }
        guard let http = resp as? HTTPURLResponse else {
            completion(nil, "no response", nil)
            return
        }
        switch http.statusCode {
        case 200:
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil, "malformed JSON", 200)
                return
            }
            let lines = parseUsage(obj, labels: labels)
            completion(lines.isEmpty ? nil : lines, lines.isEmpty ? "empty API response" : nil, 200)
        case 401:
            completion(nil, "token expired — open Claude Code", 401)
        case 429:
            completion(nil, "rate-limited by usage API (429)", 429)
        default:
            completion(nil, "HTTP \(http.statusCode)", http.statusCode)
        }
    }.resume()
}

// MARK: - Store

// I/O boundaries injected into Store so its behavior is unit-testable
struct CredsProvider {
    var listServices: () -> Set<String> = { claudeKeychainServices() }
    var readFile: (String) -> Creds? = { dir in
        let url = URL(fileURLWithPath: dir).appendingPathComponent(".credentials.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parseCreds(data)
    }
    var readService: (String) -> (creds: Creds?, status: OSStatus, data: Data?) = { tryReadService($0) }
}

typealias UsageFetch = (String, [String: String], @escaping ([UsageLine]?, String?, Int?) -> Void) -> Void

final class Store: ObservableObject {
    @Published var statuses: [AccountStatus]
    @Published var refreshing = false
    private(set) var cfg: AppConfig
    let demo: Bool
    private(set) var labels: [String: String]
    // Bumped on config reload; in-flight fetches from older generations are dropped
    private var generation = 0
    private var lastFetch: Date? = nil
    // All keychain access is serialized on credsQueue: deniedServices is only
    // touched there, and first-run permission dialogs appear one at a time
    private let credsQueue = DispatchQueue(label: "ru.bugaev.notchusage.creds", qos: .userInitiated)
    private var deniedServices = Set<String>()
    // Claude Code resets a record's "Always Allow" list every time it rotates
    // the token, so every keychain read risks a permission dialog. Cache the
    // token in memory and go back to the keychain only on startup or when the
    // API says the token died (401) — dialogs then coincide with real rotations.
    private var tokenCache: [String: String] = [:]

    let provider: CredsProvider
    let fetchFn: UsageFetch

    init(cfg: AppConfig, demo: Bool,
         provider: CredsProvider = CredsProvider(),
         fetch: @escaping UsageFetch = { fetchUsage(token: $0, labels: $1, completion: $2) }) {
        self.cfg = cfg
        self.demo = demo
        self.provider = provider
        self.fetchFn = fetch
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
                UsageLine(label: "Week (all)", pct: 63, resetText: "→ Thu 07:00"),
                UsageLine(label: "Week Fable", pct: 88, resetText: "→ Thu 07:00"),
            ], updatedAt: Date()),
            AccountStatus(name: "Work Team", lines: [
                UsageLine(label: "5h session", pct: 12, resetText: "→ 21:30"),
                UsageLine(label: "Week (all)", pct: 55, resetText: "→ Fri 10:00"),
            ], updatedAt: Date()),
        ]
    }

    func refreshIfStale(maxAge: TimeInterval = 60, interactive: Bool = false) {
        // Transient errors (e.g. Claude Code rotating a keychain record mid-read)
        // should not stick on screen for the whole refresh interval
        let age = statuses.contains { $0.error != nil } ? min(15, maxAge) : maxAge
        if let lf = lastFetch, Date().timeIntervalSince(lf) < age { return }
        refresh(interactive: interactive)
    }

    func forceRefresh() {
        credsQueue.async {
            self.deniedServices.removeAll()
            self.tokenCache.removeAll()
        }
        lastFetch = nil
        refresh(interactive: true)
    }

    // Called from the main thread (timers, hover, the ⟳ button, runPrint).
    // interactive=true marks a deliberate user action: only then may the
    // keychain be read (and its permission dialog shown). Background cycles
    // live off the in-memory token cache.
    func refresh(interactive: Bool = false) {
        if demo { return }
        lastFetch = Date()
        refreshing = true
        let gen = generation
        let accounts = cfg.accounts
        let labelsSnapshot = labels
        let group = DispatchGroup()
        for _ in accounts { group.enter() }
        credsQueue.async {
            let existing = self.provider.listServices()
            for (idx, acct) in accounts.enumerated() {
                self.fetchAccount(idx: idx, acct: acct, existing: existing, gen: gen,
                                  labels: labelsSnapshot, interactive: interactive,
                                  allowRetry: true) {
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { self.refreshing = false }
    }

    // credsQueue only
    private func fetchAccount(idx: Int, acct: AccountConfig, existing: Set<String>, gen: Int,
                              labels: [String: String], interactive: Bool, allowRetry: Bool,
                              done: @escaping () -> Void) {
        let dir = expandPath(acct.configDir)
        let (creds, credErr) = loadCreds(acct: acct, existing: existing, interactive: interactive)
        guard let creds else {
            DispatchQueue.main.async {
                if self.generation == gen { self.statuses[idx].error = credErr }
                done()
            }
            return
        }
        fetchFn(creds.accessToken, labels) { lines, err, http in
            if http == 401, allowRetry {
                // The cached token died (Claude rotated it) — drop it and
                // re-read the keychain once
                self.credsQueue.async {
                    self.tokenCache[dir] = nil
                    self.fetchAccount(idx: idx, acct: acct, existing: existing, gen: gen,
                                      labels: labels, interactive: interactive,
                                      allowRetry: false, done: done)
                }
                return
            }
            DispatchQueue.main.async {
                if self.generation == gen {
                    if let lines {
                        self.statuses[idx].lines = lines
                        self.statuses[idx].error = nil
                        self.statuses[idx].updatedAt = Date()
                    } else {
                        self.statuses[idx].error = err ?? "unknown error"
                    }
                }
                done()
            }
        }
    }

    // Hot config reload: keep already-loaded data for profiles that stayed
    func applyConfig(_ newCfg: AppConfig) {
        if demo { return }
        var byDir: [String: AccountStatus] = [:]
        for (i, acct) in cfg.accounts.enumerated() where i < statuses.count {
            byDir[expandPath(acct.configDir)] = statuses[i]
        }
        cfg = newCfg
        labels = defaultLabels.merging(newCfg.labels ?? [:]) { _, custom in custom }
        appLocale = newCfg.locale.map { Locale(identifier: $0) } ?? Locale.current
        generation += 1
        statuses = newCfg.accounts.map { acct in
            if let old = byDir[expandPath(acct.configDir)] {
                return AccountStatus(name: acct.name, lines: old.lines,
                                     error: old.error, updatedAt: old.updatedAt)
            }
            return AccountStatus(name: acct.name)
        }
        lastFetch = nil
        // A config edit is a deliberate user action
        refresh(interactive: true)
    }

    // Resolve one account's credentials on credsQueue and hand them to the
    // callback (terminal diagnostics are a deliberate user action)
    func withCreds(acct: AccountConfig, _ body: @escaping (Creds?, String?) -> Void) {
        credsQueue.async {
            let existing = self.provider.listServices()
            let (creds, err) = self.loadCreds(acct: acct, existing: existing, interactive: true)
            body(creds, err)
        }
    }

    // credsQueue only
    private func loadCreds(acct: AccountConfig, existing: Set<String>,
                           interactive: Bool) -> (Creds?, String?) {
        let dir = expandPath(acct.configDir)
        if let cached = tokenCache[dir] { return (Creds(accessToken: cached), nil) }
        // A .credentials.json file inside the profile dir wins over the keychain
        // (mirrors Claude Code's own lookup order); file reads never prompt
        if let c = provider.readFile(dir) {
            tokenCache[dir] = c.accessToken
            return (c, nil)
        }
        // Keychain reads can pop a permission dialog (Claude resets the ACL on
        // every token rotation) — only a deliberate user action may trigger one
        guard interactive else {
            return (nil, "needs authorization — hover the notch or press ⟳")
        }

        let candidates = effectiveCandidates(configDir: dir, existing: existing)
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
            let r = provider.readService(service)
            if let c = r.creds {
                tokenCache[dir] = c.accessToken
                return (c, nil)
            }
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
                let effective = effectiveCandidates(configDir: dir, existing: Set(existing))
                print("account [\(acct.name)] dir [\(dir)]:")
                for c in candidateServices(configDir: dir) {
                    guard existing.contains(c) else {
                        print("  candidate \(c): MISSING")
                        continue
                    }
                    guard effective.contains(c) else {
                        print("  candidate \(c): skipped (stale duplicate, not read)")
                        continue
                    }
                    let r = tryReadService(c)
                    let bytes = r.data?.count ?? 0
                    print("  candidate \(c): present, read status \(r.status), bytes \(bytes), parses \(r.creds != nil)")
                    if r.creds == nil, let data = r.data, bytes > 0,
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        print("    top-level keys: \(obj.keys.sorted().joined(separator: ", "))")
                    }
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
        // Never let layout measurement compress the panel vertically — an
        // undersized window clips the footer and the bottom rounding
        .fixedSize(horizontal: false, vertical: true)
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
            if !st.lines.isEmpty {
                // Stale data beats a bare error: keep the last numbers visible
                ForEach(panelVisibleLines(st.lines)) { line in lineView(line) }
                if let e = st.error {
                    Text(e)
                        .font(.system(size: 9))
                        .foregroundColor(Color.orange.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            } else if let e = st.error {
                Text(e)
                    .font(.system(size: 11))
                    .foregroundColor(Color.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("loading…")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
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
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var footer: some View {
        HStack(spacing: 12) {
            Text(store.refreshing ? "updating…" : "NotchUsage")
                .font(.system(size: 9))
                .foregroundColor(Color.white.opacity(0.3))
            Spacer()
            Button { openConfigInEditor() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.6))
            }
            .buttonStyle(.plain)
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
    var configSource: DispatchSourceFileSystemObject?
    var reloadPending = false
    var topInsetValue: CGFloat = 8
    var statusesSub: AnyCancellable?

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
            topInsetValue = inset + 6
            hosting.rootView = ContainerView(store: store, topInset: topInsetValue)
            NSLog("notch rect: %@", NSStringFromRect(notch))
            return
        }
        // No notch (lid closed): hover zone is the top center of the main display
        if let s = NSScreen.main {
            notch = NSRect(x: s.frame.midX - PanelMetrics.fallbackZoneWidth / 2, y: s.frame.maxY - 2,
                           width: PanelMetrics.fallbackZoneWidth, height: 2)
            screenTop = s.frame.maxY
            topInsetValue = 8
            hosting.rootView = ContainerView(store: store, topInset: topInsetValue)
            NSLog("no notch, fallback zone: %@", NSStringFromRect(notch))
        }
    }

    func start(showNow: Bool) {
        let poll = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(poll, forMode: .common)
        pollTimer = poll
        restartRefreshTimer()
        watchConfig()
        statusesSub = store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.relayoutIfNeeded() }
            }
        store.refresh()
        if showNow {
            forcedUntil = Date().addingTimeInterval(store.demo ? 600 : 15)
            expand()
        }
    }

    func restartRefreshTimer() {
        refreshTimer?.invalidate()
        let interval = max(store.cfg.refreshSeconds ?? 300, 60)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.store.refresh()
        }
    }

    // Watch the config file and hot-apply edits (editors atomic-save via
    // rename, so re-subscribe when the inode goes away)
    func watchConfig() {
        configSource?.cancel()
        configSource = nil
        let fd = open(configURL().path, O_EVTONLY)
        guard fd >= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.watchConfig() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let events = src.data
            self.scheduleConfigReload()
            if events.contains(.delete) || events.contains(.rename) {
                self.watchConfig()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        configSource = src
    }

    func scheduleConfigReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.reloadPending = false
            self.store.applyConfig(loadConfig())
            self.restartRefreshTimer()
            if self.expanded { self.layoutAndShow() }
            NSLog("config reloaded")
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
        // Hovering is a deliberate user action: keychain access (and its
        // permission dialog, when Claude has rotated the token) is allowed
        store.refreshIfStale(interactive: true)
        layoutAndShow()
    }

    // NSHostingView's fittingSize/intrinsicContentSize misreport for this
    // content; NSHostingController.sizeThatFits measures it reliably.
    // Propose zero height: the bottom Spacer collapses while the panel's
    // fixedSize keeps its natural height, so the result is exactly the content
    func desiredSize() -> NSSize {
        let ideal = NSHostingController(rootView: ContainerView(store: store, topInset: topInsetValue))
            .sizeThatFits(in: NSSize(width: PanelMetrics.containerWidth, height: 0))
        var size = NSSize(width: PanelMetrics.containerWidth, height: ideal.height)
        NSLog("measure ideal=%@", NSStringFromSize(ideal))
        if size.height < 120 || size.height > 900 { size.height = 520 }
        return size
    }

    func layoutAndShow() {
        let size = desiredSize()
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

    // Content height changes while the panel is open (data arrives after the
    // loading state, config reloads) — re-fit the window, keeping the top pinned
    func relayoutIfNeeded() {
        guard expanded else { return }
        let size = desiredSize()
        if abs(size.height - window.frame.height) > 2 {
            let x = (notch != .zero ? notch.midX : screenTop) - size.width / 2
            window.setFrame(
                NSRect(x: x, y: screenTop - size.height, width: size.width, height: size.height),
                display: true
            )
        }
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

// MARK: - --raw mode (dump the endpoint response as-is, no parsing)

func runRaw(cfg: AppConfig) {
    let store = Store(cfg: cfg, demo: false)
    let group = DispatchGroup()
    for acct in cfg.accounts {
        group.enter()
        store.withCreds(acct: acct) { creds, err in
            guard let creds else {
                print("[\(acct.name)] ERROR — \(err ?? "no credentials")")
                group.leave()
                return
            }
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue(userAgentHolder.current, forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                print("[\(acct.name)] HTTP \(code)\n\(body)")
                group.leave()
            }.resume()
        }
    }
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        if group.wait(timeout: .now()) == .success { break }
    }
}

// MARK: - --print mode (terminal diagnostics)

func runPrint(cfg: AppConfig) {
    let store = Store(cfg: cfg, demo: false)
    store.refresh(interactive: true)
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
    let defaultHashed = "\(kcPrefix)-\(sha256Hex(expandPath("~/.claude")).prefix(8))"
    check(effectiveCandidates(configDir: "~/.claude", existing: [kcPrefix, defaultHashed]) == [kcPrefix],
          "bare record wins: stale hashed duplicate never read")
    check(effectiveCandidates(configDir: "~/.claude", existing: [defaultHashed]) == [defaultHashed],
          "hashed fallback used only when bare record is absent")

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
    check(lines.map(\.label) == ["5h session", "Week (all)", "mystery_used", "mystery_zero"],
          "parseUsage: known order first, unknown kept with raw keys")
    check(lines[0].pct == 33 && lines[1].pct == 8, "parseUsage: rounding and Int utilization")
    check(lines[0].resetText.hasPrefix("→ "), "parseUsage: reset text present")
    check(panelVisibleLines(lines).map(\.label) == ["5h session", "Week (all)", "mystery_used"],
          "panelVisibleLines hides zero unknown buckets only")
    let wrapped = parseUsage(["data": usage], labels: defaultLabels)
    check(wrapped.count == 4, "parseUsage: unwraps nested container")

    let limitsUsage: [String: Any] = [
        "five_hour": ["utilization": 99.0],
        "limits": [
            ["kind": "session", "percent": 12, "resets_at": future],
            ["kind": "weekly_all", "percent": 36],
            ["kind": "weekly_scoped", "percent": 55,
             "scope": ["model": ["display_name": "Fable"]]],
            ["kind": "mystery_kind", "percent": 0],
        ],
    ]
    let ll = parseUsage(limitsUsage, labels: defaultLabels)
    check(ll.map(\.label) == ["5h session", "Week (all)", "Week Fable", "mystery_kind"],
          "limits array preferred over flat buckets, scoped model named from API")
    check(ll[0].pct == 12 && ll[2].pct == 55, "limits percents parsed")
    check(ll[0].resetText.hasPrefix("→ "), "limits resets_at parsed")
    check(panelVisibleLines(ll).count == 3, "unknown zero limit kind hidden in panel")
    check(parseUsage(limitsUsage, labels: ["weekly_scoped:Fable": "Неделя Fable"])[2].label == "Неделя Fable",
          "scoped label override by kind:model key")
    check(parseUsage(limitsUsage, labels: ["five_hour": "Сессия 5 ч"])[0].label == "Сессия 5 ч",
          "legacy bucket label keys still apply to limit kinds")
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

    // --- Store behavior (seam: refresh(interactive:) + statuses; keychain/network faked) ---

    final class TestEnv {
        let lock = NSLock()
        var keychainReads = 0
        var fetchCalls = 0
        var lastToken: String? = nil
        var responses: [([UsageLine]?, String?, Int?)] = []
        func snapshot() -> (reads: Int, fetches: Int, token: String?) {
            lock.lock()
            defer { lock.unlock() }
            return (keychainReads, fetchCalls, lastToken)
        }
    }

    func makeStore(_ env: TestEnv) -> Store {
        var p = CredsProvider()
        p.listServices = { [kcPrefix] }
        p.readFile = { _ in nil }
        p.readService = { _ in
            env.lock.lock()
            env.keychainReads += 1
            let n = env.keychainReads
            env.lock.unlock()
            return (Creds(accessToken: "tok-\(n)"), errSecSuccess, Data([1]))
        }
        let cfg = AppConfig(accounts: [AccountConfig(name: "T", configDir: "~/.claude")],
                            refreshSeconds: 300)
        return Store(cfg: cfg, demo: false, provider: p, fetch: { token, _, completion in
            env.lock.lock()
            env.fetchCalls += 1
            env.lastToken = token
            let resp = env.responses.isEmpty
                ? ([UsageLine(label: "L", pct: 1, resetText: "")], nil, Optional(200))
                : env.responses.removeFirst()
            env.lock.unlock()
            completion(resp.0, resp.1, resp.2)
        })
    }

    func spin(_ cond: () -> Bool, _ timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            if cond() { return true }
        }
        return cond()
    }

    // S1: a background refresh with no cached token must not touch the keychain
    let env1 = TestEnv()
    let store1 = makeStore(env1)
    store1.refresh(interactive: false)
    check(spin({ store1.statuses[0].error != nil }), "S1: background refresh reports an error state")
    check(env1.snapshot().reads == 0, "S1: background refresh performed no keychain reads")
    check(store1.statuses[0].error?.contains("authorization") == true, "S1: error asks for authorization")

    // S2: an interactive refresh reads the keychain once and shows data
    let env2 = TestEnv()
    let store2 = makeStore(env2)
    store2.refresh(interactive: true)
    check(spin({ !store2.statuses[0].lines.isEmpty }), "S2: interactive refresh loads data")
    check(env2.snapshot().reads == 1, "S2: exactly one keychain read")
    check(env2.snapshot().token == "tok-1", "S2: fetch used the token from the keychain")
    check(store2.statuses[0].error == nil, "S2: no error after success")

    // S3: the next background refresh runs off the cached token, no keychain reads
    store2.refresh(interactive: false)
    check(spin({ env2.snapshot().fetches == 2 }), "S3: background refresh fetched via cache")
    check(env2.snapshot().reads == 1, "S3: keychain read count unchanged")
    check(env2.snapshot().token == "tok-1", "S3: cached token reused")

    // S4: a background 401 (token rotated) must not read the keychain and
    // must keep the stale data visible
    env2.lock.lock()
    env2.responses = [(nil, "token expired — open Claude Code", 401)]
    env2.lock.unlock()
    store2.refresh(interactive: false)
    check(spin({ store2.statuses[0].error != nil }), "S4: background 401 surfaces an error")
    check(store2.statuses[0].error?.contains("authorization") == true, "S4: error asks for authorization")
    check(env2.snapshot().reads == 1, "S4: still no extra keychain reads in background")
    check(!store2.statuses[0].lines.isEmpty, "S4: stale data kept alongside the error")

    // S5: an interactive 401 re-reads the keychain once and retries with the fresh token
    let env5 = TestEnv()
    env5.responses = [(nil, "token expired — open Claude Code", 401),
                      ([UsageLine(label: "L2", pct: 7, resetText: "")], nil, 200)]
    let store5 = makeStore(env5)
    store5.refresh(interactive: true)
    check(spin({ store5.statuses[0].lines.first?.label == "L2" }), "S5: retry succeeded with fresh token")
    check(env5.snapshot().reads == 2, "S5: exactly one re-read after 401")
    check(env5.snapshot().token == "tok-2", "S5: retry used the fresh token")
    check(store5.statuses[0].error == nil, "S5: no error after successful retry")

    // S6: two 401s in a row stop after one retry and keep the error, no loop
    let env6 = TestEnv()
    env6.responses = [(nil, "token expired — open Claude Code", 401),
                      (nil, "token expired — open Claude Code", 401)]
    let store6 = makeStore(env6)
    store6.refresh(interactive: true)
    check(spin({ store6.statuses[0].error != nil }), "S6: second 401 surfaces the error")
    check(env6.snapshot().fetches == 2 && env6.snapshot().reads == 2, "S6: exactly one retry, then stop")

    print(failures == 0 ? "SELFTEST PASSED" : "SELFTEST FAILED: \(failures)")
    return failures
}

// MARK: - Entry point

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: NotchController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Async: the CLI (node) can take seconds to answer --version; the panel
        // must not wait, the first fetch just uses the fallback UA
        DispatchQueue.global(qos: .utility).async { detectCLIVersion() }
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
        if CommandLine.arguments.contains("--raw") {
            detectCLIVersion()
            runRaw(cfg: loadConfig())
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
