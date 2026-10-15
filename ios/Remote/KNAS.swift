import Foundation
import SwiftUI
import UIKit

// ------------------------------------------------------------ what KNAS sends back

struct TV: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let on: Bool
    let ch: String
    let chname: String
    let show: String
    let list: [[String]]
    let hidden: [String]
    let vol: String
    let muted: Bool
    let asleep: Bool

    var channels: [Channel] {
        list.compactMap { $0.count >= 2 && !hidden.contains($0[0]) ? Channel(num: $0[0], name: $0[1]) : nil }
    }
    var volume: Double? { Double(vol) }

    enum K: String, CodingKey { case id, name, on, ch, chname, show, list, hidden, vol, muted, asleep }

    // forgiving: a missing field or a number where text was expected doesn't throw the whole list away
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        func text(_ k: K) -> String {
            if let s = try? c.decode(String.self, forKey: k) { return s }
            if let i = try? c.decode(Int.self, forKey: k) { return String(i) }
            if let x = try? c.decode(Double.self, forKey: k) { return String(x) }
            return ""
        }
        func flag(_ k: K) -> Bool {
            if let b = try? c.decode(Bool.self, forKey: k) { return b }
            return ["1", "true", "True"].contains(text(k))
        }
        id = text(.id)
        name = text(.name).isEmpty ? "TV" : text(.name)
        on = flag(.on)
        ch = text(.ch); chname = text(.chname); show = text(.show); vol = text(.vol)
        muted = flag(.muted); asleep = flag(.asleep)
        hidden = (try? c.decode([String].self, forKey: .hidden)) ?? []
        if let l = try? c.decode([[String]].self, forKey: .list) { list = l } else { list = [] }
    }
}

struct Channel: Identifiable, Hashable { let num: String; let name: String; var id: String { num } }

struct TVList: Decodable { let tvs: [TV] }

struct Program: Decodable { let t: String; let st: String?; let s: Double?; let e: Double? }
struct OnNowChannel: Decodable { let now: Program?; let next: Program?; let web: Bool? }
struct OnNow: Decodable { let ok: Bool; let now: Double?; let channels: [String: OnNowChannel]?; let message: String? }
struct Reply: Decodable { let ok: Bool?; let message: String? }

// ------------------------------------------------------------ talking to KNAS

@MainActor
final class KNAS: ObservableObject {
    static let port = 8642

    @Published var address: String = UserDefaults.standard.string(forKey: "address") ?? ""
    @Published var connected = false
    @Published var tvs: [TV] = []
    @Published var selectedID: String = UserDefaults.standard.string(forKey: "tv") ?? ""
    @Published var onNow: [String: OnNowChannel] = [:]
    @Published var finding = false
    @Published var setupTitle = "Where's KNAS?"
    @Published var setupMessage = "Type your NAS's address, or let the app look for it."
    @Published var toast: String?
    @Published var away = false
    @Published var lastError = ""
    @Published var tab = 0
    @Published var loadedOnce = false

    private var retry: Task<Void, Never>?
    private var misses = 0

    private var poller: Task<Void, Never>?
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 6
        c.timeoutIntervalForResource = 8
        return URLSession(configuration: c)
    }()

    var tvsOn: [TV] { tvs.filter { $0.on } }
    var selected: TV? { tvsOn.first { $0.id == selectedID } ?? tvsOn.first }

    func select(_ tv: TV) {
        selectedID = tv.id
        UserDefaults.standard.set(tv.id, forKey: "tv")
        onNow = [:]
    }

    // ---------------- address

    static func clean(_ input: String) -> String {
        var a = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["http://", "https://"] where a.lowercased().hasPrefix(p) { a = String(a.dropFirst(p.count)) }
        if let slash = a.firstIndex(of: "/") { a = String(a[..<slash]) }
        if !a.isEmpty && !a.contains(":") { a += ":\(port)" }
        return a
    }

    static func short(_ hp: String) -> String { hp.hasSuffix(":\(port)") ? String(hp.dropLast(":\(port)".count)) : hp }

    nonisolated static func isKNAS(_ hp: String, timeout: TimeInterval) async -> Bool {
        guard let url = URL(string: "http://\(hp)/api/version") else { return false }
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout
        do {
            let (data, _) = try await URLSession(configuration: c).data(from: url)
            return String(decoding: data, as: UTF8.self).contains("\"settings_file\"")
        } catch { return false }
    }

    func start() {
        if address.isEmpty { Task { await find() } } else { Task { await connect(home.isEmpty ? address : home) } }
    }

    // ---------------- home address + away addresses (Tailscale)

    /// The address at home (saved), and addresses that reach KNAS from away (Tailscale), which KNAS tells us while we're home.
    var home: String { UserDefaults.standard.string(forKey: "address") ?? "" }
    var awayAddresses: [String] { UserDefaults.standard.stringArray(forKey: "away") ?? [] }

    static func isTailscale(_ hp: String) -> Bool {
        let host = hp.split(separator: ":").first.map(String.init) ?? hp
        if host.hasSuffix(".ts.net") { return true }
        let p = host.split(separator: ".").compactMap { Int($0) }
        return p.count == 4 && p[0] == 100 && (64...127).contains(p[1])
    }

    /// Ask KNAS for its away-from-home addresses and remember them.
    func learnAway(_ hp: String) async {
        struct V: Decodable { let away: [String]? }
        guard let url = URL(string: "http://\(hp)/api/version"),
              let r = try? await session.data(from: url),
              let v = try? JSONDecoder().decode(V.self, from: r.0) else { return }
        var list = awayAddresses
        for a in v.away ?? [] where !list.contains(a) { list.append(a) }
        UserDefaults.standard.set(Array(list.prefix(6)), forKey: "away")
    }

    /// Home first, then the away addresses. Returns the one that answered.
    func reachable() async -> String? {
        var tries: [String] = []
        if !home.isEmpty { tries.append(home) }
        for a in awayAddresses where !tries.contains(a) { tries.append(a) }
        for hp in tries { if await KNAS.isKNAS(hp, timeout: hp == home ? 3 : 5) { return hp } }
        return nil
    }

    private func use(_ hp: String, note: Bool) {
        let wasAway = away
        address = hp
        away = false
        connected = true
        misses = 0
        startPolling()
        if KNAS.isTailscale(hp) { if note || wasAway { show("Connected through Tailscale") } }
        else { if wasAway { show("Welcome home!") }; Task { await learnAway(hp) } }
    }

    func connect(_ input: String) async {
        let hp = KNAS.clean(input)
        guard !hp.isEmpty else { setupTitle = "Where's KNAS?"; setupMessage = "Type your NAS's address, like 192.168.1.50."; return }
        retry?.cancel()
        away = false
        setupTitle = "Connecting…"
        setupMessage = "Checking \(hp)…"
        if await KNAS.isKNAS(hp, timeout: 5) {
            if KNAS.isTailscale(hp) {                   // typed a Tailscale address: keep it as the away address
                var list = awayAddresses
                if !list.contains(hp) { list.insert(hp, at: 0) }
                UserDefaults.standard.set(list, forKey: "away")
                if home.isEmpty { UserDefaults.standard.set(hp, forKey: "address") }
            } else {
                UserDefaults.standard.set(hp, forKey: "address")
            }
            use(hp, note: false)
            return
        }
        connected = false
        if hp == home || awayAddresses.contains(hp) {
            if let other = await reachable() { use(other, note: true); return }   // away from home: Tailscale
            if KNAS.awayFrom(hp) || KNAS.isTailscale(hp) { goneAway(); return }
        }
        setupTitle = "Can't reach KNAS"
        setupMessage = "Nothing answered at \(hp). Check that KNAS is running, that this phone is on your home Wi-Fi, and that the address is right."
    }

    /// Not on Wi-Fi, or on a different network than KNAS (like at work or on cellular).
    static func awayFrom(_ hp: String) -> Bool {
        guard let me = wifiAddress() else { return true }
        let host = hp.split(separator: ":").first.map(String.init) ?? hp
        let a = me.split(separator: ".").prefix(3), b = host.split(separator: ".").prefix(3)
        return b.count == 3 && a != b
    }

    /// Show "you're away from home" and keep checking quietly; reconnect by itself when back home or when Tailscale comes on.
    func goneAway() {
        poller?.cancel()
        connected = false
        away = true
        setupTitle = "You're away from home"
        setupMessage = awayAddresses.isEmpty
            ? "Join your home Wi-Fi to control your TV. The remote reconnects by itself when you're back."
            : "Join your home Wi-Fi, or turn on Tailscale, to control your TV. The remote reconnects by itself."
        retry?.cancel()
        retry = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self = self, !(self.home.isEmpty && self.awayAddresses.isEmpty) else { return }
                if let hp = await self.reachable() { self.use(hp, note: true); return }
                if !self.home.isEmpty && !KNAS.awayFrom(self.home) {          // home again, but KNAS isn't answering
                    self.away = false
                    self.setupTitle = "Can't reach KNAS"
                    self.setupMessage = "You're on your home network, but KNAS isn't answering at \(self.home). Check that it's running."
                }
            }
        }
    }

    func disconnect() {
        poller?.cancel()
        retry?.cancel()
        away = false
        connected = false
        setupTitle = "Change address"
        setupMessage = "Type your NAS's address, or let the app look for it."
    }

    func find() async {
        guard !finding else { return }
        guard let me = KNAS.wifiAddress(), let dot = me.lastIndex(of: ".") else {
            setupTitle = "Not on Wi-Fi"
            setupMessage = "Connect this phone to your home Wi-Fi, or type your NAS's address."
            return
        }
        finding = true
        setupTitle = "Finding KNAS…"
        setupMessage = "Looking on your home network (about 15 seconds)…"
        let base = String(me[...dot])
        var found: String?
        var start = 1
        while found == nil && start < 255 {
            let batch = Array(start..<min(start + 40, 255))
            start += 40
            found = await withTaskGroup(of: String?.self) { group -> String? in
                for n in batch {
                    let hp = "\(base)\(n):8642"
                    group.addTask { await KNAS.isKNAS(hp, timeout: 1.5) ? hp : nil }
                }
                for await r in group { if let r = r { group.cancelAll(); return r } }
                return nil
            }
        }
        finding = false
        if let f = found { await connect(f) }
        else {
            setupTitle = "Couldn't find KNAS"
            setupMessage = "Type your NAS's address instead (it's in your NAS's network settings, like 192.168.1.50). If your iPhone asked about finding devices on your network, tap Allow."
        }
    }

    static func wifiAddress() -> String? {
        var addr: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = ptr.pointee
            guard let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: i.ifa_name)
            guard name == "en0" || name == "en1" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                addr = String(cString: host)
            }
        }
        return addr
    }

    // ---------------- keeping the TV list fresh

    func startPolling() {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshTVs()
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
        }
    }

    func stopPolling() { poller?.cancel() }

    func refreshTVs() async {
        guard let url = URL(string: "http://\(address)/api/remote/tvs") else { return }
        do {
            let (data, _) = try await session.data(from: url)
            let list = try JSONDecoder().decode(TVList.self, from: data)
            misses = 0
            lastError = ""
            loadedOnce = true
            if list.tvs != tvs { tvs = list.tvs }
        } catch {
            lastError = (error as? DecodingError).map { _ in "KNAS sent something the app didn't understand." } ?? error.localizedDescription
            misses += 1
            if misses >= 2 && connected {                  // lost KNAS for about 5 seconds: try home and Tailscale
                misses = 0
                if let hp = await reachable() {
                    if hp != address { use(hp, note: true) }
                } else if KNAS.awayFrom(home.isEmpty ? address : home) || KNAS.isTailscale(address) {
                    goneAway()
                } else {
                    poller?.cancel()
                    connected = false
                    setupTitle = "Can't reach KNAS"
                    setupMessage = "KNAS stopped answering at \(address). Check that it's running, then tap Connect."
                }
            }
        }
    }

    func refreshOnNow() async {
        guard let tv = selected, let url = URL(string: "http://\(address)/api/remote/onnow?id=\(tv.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") else { return }
        do {
            let (data, _) = try await session.data(from: url)
            let r = try JSONDecoder().decode(OnNow.self, from: data)
            onNow = r.channels ?? [:]
        } catch { }
    }

    // ---------------- buttons

    private func post(_ path: String, _ body: [String: Any]) async -> Reply? {
        guard let url = URL(string: "http://\(address)\(path)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, _) = try await session.data(for: req)
            return try? JSONDecoder().decode(Reply.self, from: data)
        } catch {
            show("Couldn't reach KNAS")
            return nil
        }
    }

    func press(_ key: String) {
        guard let tv = selected else { show("No TV is on"); return }
        Haptics.tap()
        Task { _ = await post("/api/remote/send", ["id": tv.id, "key": key]) }
    }

    func tune(_ num: String) {
        guard let tv = selected else { show("No TV is on"); return }
        Haptics.tap()
        Task {
            _ = await post("/api/remote/send", ["id": tv.id, "tune": num])
            try? await Task.sleep(nanoseconds: 600_000_000)
            await refreshTVs()
        }
    }

    func setVolume(_ v: Double) {
        guard let tv = selected else { return }
        Task { _ = await post("/api/remote/send", ["id": tv.id, "vol": Int(v.rounded())]) }
    }

    func allOff() {
        Haptics.heavy()
        Task {
            let r = await post("/api/remote/alloff", [:])
            show(r?.message ?? "Turned off the TVs")
            await refreshTVs()
        }
    }

    func show(_ msg: String) {
        toast = msg
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if toast == msg { toast = nil }
        }
    }
}

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func heavy() { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
}
