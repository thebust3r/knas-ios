import SwiftUI
import WebKit

let gold = Color(red: 1, green: 0.82, blue: 0.23)
let navy = Color(red: 0.04, green: 0.08, blue: 0.31)
let deep = Color(red: 0.02, green: 0.04, blue: 0.16)
let edge = Color(red: 0.61, green: 0.72, blue: 1)
let key = Color(red: 0.13, green: 0.22, blue: 0.55)

@main
struct KNASRemoteApp: App {
    @StateObject private var knas = KNAS()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Root()
                .environmentObject(knas)
                .preferredColorScheme(.dark)
                .onAppear { knas.start() }
                .onChange(of: phase) { p in
                    if p == .active, knas.connected { knas.startPolling() }
                    if p == .background { knas.stopPolling() }
                }
        }
    }
}

struct Root: View {
    @EnvironmentObject var knas: KNAS
    var body: some View {
        ZStack(alignment: .bottom) {
            if knas.connected {
                TabView {
                    RemoteScreen().tabItem { Label("Remote", systemImage: "av.remote") }
                    WhatsOn().tabItem { Label("What's On", systemImage: "list.bullet.rectangle") }
                    More().tabItem { Label("More", systemImage: "ellipsis.circle") }
                }
                .accentColor(gold)
            } else {
                SetupScreen()
            }
            if let t = knas.toast {
                Text(t)
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.85)))
                    .overlay(Capsule().stroke(edge, lineWidth: 1))
                    .padding(.bottom, 70)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: knas.toast)
    }
}

// ------------------------------------------------------------ setup

struct SetupScreen: View {
    @EnvironmentObject var knas: KNAS
    @State private var typed = ""
    var body: some View {
        ZStack {
            navy.ignoresSafeArea()
            VStack(spacing: 16) {
                Text("KNAS Remote").font(.system(size: 42, weight: .heavy)).italic().foregroundColor(gold)
                Text(knas.setupTitle).font(.system(size: 24, weight: .bold))
                Text(knas.setupMessage).font(.system(size: 16)).foregroundColor(Color(white: 0.88)).multilineTextAlignment(.center)
                if knas.finding { ProgressView().scaleEffect(1.4).padding(6) }
                TextField("192.168.1.50", text: $typed)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 24))
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.1)))
                Button { Task { await knas.connect(typed) } } label: { BigLabel("Connect") }
                Button { Task { await knas.find() } } label: { BigLabel("Find KNAS automatically") }.disabled(knas.finding)
            }
            .padding(24)
            .frame(maxWidth: 460)
        }
        .onAppear { if typed.isEmpty { typed = KNAS.short(knas.address) } }
    }
}

struct BigLabel: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.system(size: 19, weight: .semibold)).foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(RoundedRectangle(cornerRadius: 10).fill(key))
    }
}

// ------------------------------------------------------------ the remote

struct RemoteScreen: View {
    @EnvironmentObject var knas: KNAS
    @State private var keypad = false
    @State private var confirmOff = false
    @State private var vol: Double = 50
    @State private var dragging = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [navy, deep], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    header
                    if knas.selected == nil {
                        Text("No TVs are on.\nOpen KNAS on a TV, and it shows up here.")
                            .multilineTextAlignment(.center).foregroundColor(Color(white: 0.8)).padding(.top, 30)
                    } else {
                        HStack(spacing: 12) {
                            Pill("Back", "arrow.uturn.backward") { knas.press("back") }
                            Pill("Guide", "list.dash.header.rectangle") { knas.press("guide") }
                            Pill("Info", "info.circle") { knas.press("info") }
                        }
                        DPad()
                        HStack(alignment: .top, spacing: 28) {
                            Rocker(title: "VOL", up: "plus", down: "minus", onUp: { knas.press("volup") }, onDown: { knas.press("voldown") })
                            VStack(spacing: 12) {
                                Round("speaker.slash.fill", "Mute") { knas.press("mute") }
                                Round("number", "123") { keypad = true }
                                Round("arrow.left.arrow.right", "Last") { knas.press("left") }
                            }
                            Rocker(title: "CH", up: "chevron.up", down: "chevron.down", onUp: { knas.press("up") }, onDown: { knas.press("down") })
                        }
                        volumeSlider
                    }
                    Button { confirmOff = true } label: {
                        Label("Turn off all TVs", systemImage: "power").font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white).frame(maxWidth: .infinity, minHeight: 46)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.62, green: 0.1, blue: 0.08)))
                    }
                    .padding(.top, 6)
                }
                .padding(18)
                .frame(maxWidth: 500)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $keypad) { Keypad().environmentObject(knas) }
        .alert("Turn off all TVs?", isPresented: $confirmOff) {
            Button("Turn off", role: .destructive) { knas.allOff() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Every TV with KNAS goes to the good-night screen. Any button wakes it.") }
        .onChange(of: knas.selected?.vol ?? "") { v in if !dragging, let d = Double(v) { vol = d } }
        .onAppear { if let d = knas.selected?.volume { vol = d } }
    }

    var header: some View {
        VStack(spacing: 6) {
            Menu {
                ForEach(knas.tvsOn) { tv in
                    Button { knas.select(tv) } label: {
                        if tv.id == knas.selected?.id { Label(tv.name, systemImage: "checkmark") } else { Text(tv.name) }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "tv")
                    Text(knas.selected?.name ?? "No TV").font(.system(size: 20, weight: .bold))
                    if knas.tvsOn.count > 1 { Image(systemName: "chevron.down").font(.system(size: 13, weight: .bold)) }
                }
                .foregroundColor(gold)
            }
            if let tv = knas.selected {
                Text(tv.asleep ? "Off (good-night screen)" : [tv.ch.isEmpty ? "" : "Ch \(tv.ch)", tv.chname].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                if !tv.show.isEmpty && !tv.asleep {
                    Text(tv.show).font(.system(size: 14)).foregroundColor(Color(white: 0.75)).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(edge.opacity(0.6), lineWidth: 1.5))
    }

    var volumeSlider: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").foregroundColor(edge)
            Slider(value: $vol, in: 0...100, step: 1) { editing in
                dragging = editing
                if !editing { knas.setVolume(vol) }
            }
            .accentColor(gold)
            Image(systemName: "speaker.wave.3.fill").foregroundColor(edge)
        }
        .padding(.horizontal, 6)
    }
}

struct Pill: View {
    let title: String, icon: String, action: () -> Void
    init(_ t: String, _ i: String, action: @escaping () -> Void) { title = t; icon = i; self.action = action }
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Capsule().fill(key))
                .overlay(Capsule().stroke(edge.opacity(0.5), lineWidth: 1))
        }
    }
}

struct Round: View {
    let icon: String, title: String, action: () -> Void
    init(_ i: String, _ t: String, action: @escaping () -> Void) { icon = i; title = t; self.action = action }
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(width: 58, height: 58)
            .background(Circle().fill(key))
            .overlay(Circle().stroke(edge.opacity(0.5), lineWidth: 1))
        }
    }
}

struct Rocker: View {
    let title: String, up: String, down: String
    let onUp: () -> Void, onDown: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            Button(action: onUp) { Image(systemName: up).font(.system(size: 22, weight: .bold)).frame(width: 74, height: 70) }
            Text(title).font(.system(size: 13, weight: .heavy)).foregroundColor(gold)
            Button(action: onDown) { Image(systemName: down).font(.system(size: 22, weight: .bold)).frame(width: 74, height: 70) }
        }
        .foregroundColor(.white)
        .background(RoundedRectangle(cornerRadius: 37).fill(key))
        .overlay(RoundedRectangle(cornerRadius: 37).stroke(edge.opacity(0.5), lineWidth: 1))
    }
}

struct DPad: View {
    @EnvironmentObject var knas: KNAS
    var body: some View {
        ZStack {
            Circle().fill(key).overlay(Circle().stroke(edge.opacity(0.5), lineWidth: 1.5))
            VStack(spacing: 0) {
                arrow("chevron.up", "up")
                HStack(spacing: 0) {
                    arrow("chevron.left", "left")
                    Button { knas.press("ok") } label: {
                        Text("OK").font(.system(size: 22, weight: .heavy)).foregroundColor(navy)
                            .frame(width: 86, height: 86).background(Circle().fill(gold))
                    }
                    arrow("chevron.right", "right")
                }
                arrow("chevron.down", "down")
            }
        }
        .frame(width: 250, height: 250)
    }

    func arrow(_ icon: String, _ k: String) -> some View {
        Button { knas.press(k) } label: {
            Image(systemName: icon).font(.system(size: 26, weight: .bold)).foregroundColor(.white).frame(width: 82, height: 82)
        }
    }
}

struct Keypad: View {
    @EnvironmentObject var knas: KNAS
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["⌫", "0", "Go"]]
    var body: some View {
        ZStack {
            deep.ignoresSafeArea()
            VStack(spacing: 14) {
                Text(typed.isEmpty ? "Channel" : typed).font(.system(size: 44, weight: .heavy, design: .monospaced))
                    .foregroundColor(typed.isEmpty ? Color(white: 0.5) : gold).frame(height: 60).padding(.top, 24)
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: 14) {
                        ForEach(row, id: \.self) { k in
                            Button { tap(k) } label: {
                                Text(k).font(.system(size: 28, weight: .bold)).foregroundColor(k == "Go" ? navy : .white)
                                    .frame(width: 88, height: 70)
                                    .background(RoundedRectangle(cornerRadius: 14).fill(k == "Go" ? gold : key))
                            }
                        }
                    }
                }
                Spacer()
            }
        }
    }

    func tap(_ k: String) {
        Haptics.tap()
        switch k {
        case "⌫": if !typed.isEmpty { typed.removeLast() }
        case "Go": if !typed.isEmpty { knas.tune(typed); dismiss() }
        default: if typed.count < 4 { typed += k }
        }
    }
}

// ------------------------------------------------------------ what's on

struct WhatsOn: View {
    @EnvironmentObject var knas: KNAS
    var body: some View {
        NavigationView {
            Group {
                if let tv = knas.selected {
                    List(tv.channels) { c in
                        Button { knas.tune(c.num) } label: { row(c.num, c.name, current: tv.ch == c.num) }
                            .listRowBackground(tv.ch == c.num ? key.opacity(0.6) : Color.clear)
                    }
                    .listStyle(.plain)
                    .refreshable { await knas.refreshOnNow() }
                } else {
                    Text("No TVs are on.").foregroundColor(Color(white: 0.7))
                }
            }
            .navigationTitle(knas.selected?.name ?? "What's On")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
        .task {
            while !Task.isCancelled {
                await knas.refreshOnNow()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    func row(_ num: String, _ name: String, current: Bool) -> some View {
        let info = knas.onNow[num]
        return HStack(alignment: .top, spacing: 12) {
            Text(num).font(.system(size: 20, weight: .heavy, design: .rounded)).foregroundColor(gold).frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 16, weight: .bold)).foregroundColor(.white)
                if let now = info?.now, !now.t.isEmpty {
                    Text(now.t).font(.system(size: 14)).foregroundColor(Color(white: 0.85)).lineLimit(1)
                    if let s = now.s, let e = now.e, e > s {
                        ProgressView(value: min(1, max(0, (Date().timeIntervalSince1970 - s) / (e - s)))).accentColor(gold)
                    }
                }
                if let next = info?.next, !next.t.isEmpty {
                    Text("Next: \(next.t)").font(.system(size: 12)).foregroundColor(Color(white: 0.6)).lineLimit(1)
                }
            }
            Spacer()
            if current { Image(systemName: "play.fill").foregroundColor(gold) }
        }
        .padding(.vertical, 4)
    }
}

// ------------------------------------------------------------ more: everything else from the phone page

struct More: View {
    @EnvironmentObject var knas: KNAS
    var body: some View {
        NavigationView {
            PhonePage(url: URL(string: "http://\(knas.address)/phone"))
                .navigationTitle("More")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Address") { knas.disconnect() }
                    }
                }
        }
        .navigationViewStyle(.stack)
    }
}

struct PhonePage: UIViewRepresentable {
    let url: URL?
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.applicationNameForUserAgent = "KNASApp/ios-remote"
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.isOpaque = false
        w.backgroundColor = .black
        if let u = url { w.load(URLRequest(url: u)) }
        return w
    }
    func updateUIView(_ w: WKWebView, context: Context) {}
}
