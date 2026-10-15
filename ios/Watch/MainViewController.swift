import UIKit
import WebKit
import AVKit

/// One app, two flavors (set by KNASMode in Info.plist):
///   "tv"     → KNAS 42: the cable box full screen (/tv)
///   "remote" → KNAS Remote: the phone remote and menu (/phone)
/// Hold two fingers on the screen for a second to open the app's menu.
final class MainViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, UITextFieldDelegate {

    static let port = 8642
    let mode = (Bundle.main.object(forInfoDictionaryKey: "KNASMode") as? String) ?? "tv"
    var isTV: Bool { mode == "tv" }
    var path: String { isTV ? "/tv" : "/phone" }
    var appName: String { isTV ? "KNAS 42" : "KNAS Remote" }

    let prefs = UserDefaults.standard
    var saved: String {
        get { prefs.string(forKey: "address") ?? "" }
        set { prefs.set(newValue, forKey: "address") }
    }
    var current = ""
    var finding = false
    var awayTimer: Timer?
    var awayAddresses: [String] { prefs.stringArray(forKey: "away") ?? [] }

    static func isTailscale(_ hp: String) -> Bool {
        let host = hp.split(separator: ":").first.map(String.init) ?? hp
        if host.hasSuffix(".ts.net") { return true }
        let p = host.split(separator: ".").compactMap { Int($0) }
        return p.count == 4 && p[0] == 100 && (64...127).contains(p[1])
    }

    /// KNAS tells us its away-from-home (Tailscale) addresses while we're home; remember them.
    func learnAway(_ hp: String) {
        guard let url = URL(string: "http://\(hp)/api/version") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            struct V: Decodable { let away: [String]? }
            guard let d = data, let v = try? JSONDecoder().decode(V.self, from: d), let list = v.away, !list.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                var all = self.awayAddresses
                for a in list where !all.contains(a) { all.append(a) }
                self.prefs.set(Array(all.prefix(6)), forKey: "away")
            }
        }.resume()
    }

    /// Lost KNAS: try home, then Tailscale; otherwise show "you're away from home".
    func recover() {
        Task { @MainActor in
            if let hp = await reachable() { if hp != current || web.url == nil { display(hp) } else { web.reload() } }
            else { goneAway() }
        }
    }

    /// Home first, then the away addresses.
    func reachable() async -> String? {
        var tries: [String] = []
        if !saved.isEmpty { tries.append(saved) }
        for a in awayAddresses where !tries.contains(a) { tries.append(a) }
        for hp in tries { if await MainViewController.isKNAS(hp, timeout: hp == saved ? 3 : 5) { return hp } }
        return nil
    }

    /// Not on Wi-Fi, or on a different network than KNAS (like at work or on cellular).
    static func awayFrom(_ hp: String) -> Bool {
        guard let me = wifiAddress() else { return true }
        let host = hp.split(separator: ":").first.map(String.init) ?? hp
        let a = me.split(separator: ".").prefix(3), b = host.split(separator: ".").prefix(3)
        return b.count == 3 && a != b
    }

    /// "You're away from home": keep checking, and tune back in by itself when you're home.
    func goneAway() {
        web.isHidden = true
        showSetup("You're away from home", awayAddresses.isEmpty
            ? "Join your home Wi-Fi to watch KNAS. It tunes back in by itself when you're back."
            : "Join your home Wi-Fi, or turn on Tailscale, to watch KNAS. It tunes back in by itself.")
        awayTimer?.invalidate()
        awayTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self = self, !self.saved.isEmpty, !self.setup.isHidden else { return }
            Task { @MainActor in
                if let hp = await self.reachable() { self.awayTimer?.invalidate(); self.display(hp) }
            }
        }
    }

    var web: WKWebView!
    let setup = UIView()
    let titleLabel = UILabel()
    let msgLabel = UILabel()
    let field = UITextField()
    let connectBtn = UIButton(type: .system)
    let findBtn = UIButton(type: .system)
    let spinner = UIActivityIndicatorView(style: .large)

    override var prefersStatusBarHidden: Bool { isTV }
    override var prefersHomeIndicatorAutoHidden: Bool { isTV }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []     // channels start by themselves, like a TV
        cfg.allowsAirPlayForMediaPlayback = true
        cfg.applicationNameForUserAgent = "KNASApp/ios"       // the cable box skips its own full-screen request
        web = FullScreenWebView(frame: view.bounds, configuration: cfg)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        web.navigationDelegate = self
        web.uiDelegate = self
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.scrollView.contentInsetAdjustmentBehavior = isTV ? .never : .automatic
        web.scrollView.bounces = !isTV
        if isTV { web.scrollView.isScrollEnabled = false }   // swipes go to the cable box (channels, guide)
        if #available(iOS 15.0, *) { web.underPageBackgroundColor = .black }
        web.isHidden = true
        view.addSubview(web)

        let hold = UILongPressGestureRecognizer(target: self, action: #selector(menuGesture(_:)))
        hold.numberOfTouchesRequired = 2
        hold.minimumPressDuration = 0.8
        hold.cancelsTouchesInView = false
        view.addGestureRecognizer(hold)

        buildSetup()
        NotificationCenter.default.addObserver(self, selector: #selector(cameBack), name: UIApplication.willEnterForegroundNotification, object: nil)

        if saved.isEmpty {
            showSetup("Where's KNAS?", "Looking for KNAS on your home network…")
            find()
        } else {
            open(saved)
        }
    }

    // ------------------------------------------------------------ setup screen

    func buildSetup() {
        setup.backgroundColor = UIColor(red: 0.04, green: 0.08, blue: 0.31, alpha: 1)
        setup.frame = view.bounds
        setup.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        setup.isHidden = true
        view.addSubview(setup)

        let logo = UILabel()
        logo.text = appName
        logo.font = UIFont.italicSystemFont(ofSize: 44).withWeight(.heavy)
        logo.textColor = UIColor(red: 1, green: 0.82, blue: 0.23, alpha: 1)
        logo.textAlignment = .center

        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        msgLabel.font = .systemFont(ofSize: 17)
        msgLabel.textColor = UIColor(red: 0.87, green: 0.9, blue: 1, alpha: 1)
        msgLabel.textAlignment = .center
        msgLabel.numberOfLines = 0

        field.placeholder = "192.168.1.50"
        field.font = .systemFont(ofSize: 24)
        field.borderStyle = .roundedRect
        field.keyboardType = .decimalPad
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.textAlignment = .center
        field.delegate = self
        field.heightAnchor.constraint(equalToConstant: 50).isActive = true

        for (b, t, a) in [(connectBtn, "Connect", #selector(connectTapped)), (findBtn, "Find KNAS automatically", #selector(findTapped))] {
            b.setTitle(t, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 20, weight: .semibold)
            b.backgroundColor = UIColor(red: 0.17, green: 0.33, blue: 0.78, alpha: 1)
            b.setTitleColor(.white, for: .normal)
            b.layer.cornerRadius = 10
            b.heightAnchor.constraint(equalToConstant: 50).isActive = true
            b.addTarget(self, action: a, for: .touchUpInside)
        }
        spinner.color = .white
        spinner.hidesWhenStopped = true

        let hint = UILabel()
        hint.text = "Tip: hold two fingers on the screen for a second to open the menu (reload, change address)."
        hint.font = .systemFont(ofSize: 14)
        hint.textColor = UIColor(red: 0.61, green: 0.72, blue: 1, alpha: 1)
        hint.textAlignment = .center
        hint.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [logo, titleLabel, msgLabel, spinner, field, connectBtn, findBtn, hint])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        setup.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: setup.safeAreaLayoutGuide.centerYAnchor),
            stack.centerXAnchor.constraint(equalTo: setup.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: setup.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: setup.trailingAnchor, constant: -24),
        ])
        let w = stack.widthAnchor.constraint(equalToConstant: 460)
        w.priority = .defaultHigh
        w.isActive = true
        setup.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(hideKeyboard)))
    }

    @objc func hideKeyboard() { view.endEditing(true) }

    func showSetup(_ title: String, _ msg: String) {
        titleLabel.text = title
        msgLabel.text = msg
        if field.text?.isEmpty ?? true, !saved.isEmpty { field.text = MainViewController.shortAddress(saved) }
        setup.isHidden = false
        view.bringSubviewToFront(setup)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool { connectTapped(); return true }
    @objc func connectTapped() { view.endEditing(true); open(field.text ?? "") }
    @objc func findTapped() { view.endEditing(true); titleLabel.text = "Finding KNAS…"; find() }

    // ------------------------------------------------------------ address

    static func clean(_ input: String) -> String {
        var a = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["http://", "https://"] where a.lowercased().hasPrefix(p) { a = String(a.dropFirst(p.count)) }
        if let slash = a.firstIndex(of: "/") { a = String(a[..<slash]) }
        if !a.isEmpty && !a.contains(":") { a += ":\(port)" }
        return a
    }

    static func shortAddress(_ hp: String) -> String {
        hp.hasSuffix(":\(port)") ? String(hp.dropLast(":\(port)".count)) : hp
    }

    nonisolated static func isKNAS(_ hp: String, timeout: TimeInterval) async -> Bool {
        guard let url = URL(string: "http://\(hp)/api/version") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        do {
            let (data, _) = try await URLSession(configuration: cfg).data(for: req)
            return String(decoding: data, as: UTF8.self).contains("\"settings_file\"")
        } catch { return false }
    }

    func open(_ address: String) {
        let hp = MainViewController.clean(address)
        if hp.isEmpty { showSetup("Where's KNAS?", "Type your NAS's address, like 192.168.1.50."); return }
        field.text = MainViewController.shortAddress(hp)
        spinner.startAnimating()
        Task { @MainActor in
            let ok = await MainViewController.isKNAS(hp, timeout: 5)
            spinner.stopAnimating()
            guard ok else {
                if hp == saved || awayAddresses.contains(hp) {
                    if let other = await reachable(), other != hp { display(other); return }     // away from home: Tailscale
                    if MainViewController.awayFrom(hp) || MainViewController.isTailscale(hp) { goneAway(); return }
                }
                showSetup("Can't reach KNAS", "Nothing answered at \(hp). Check that KNAS is running, that this phone is on your home Wi-Fi, and that the address is right.")
                return
            }
            awayTimer?.invalidate()
            display(hp)
        }
    }

    /// Show KNAS from this address (home, or Tailscale when away).
    func display(_ hp: String) {
            awayTimer?.invalidate()
            if MainViewController.isTailscale(hp) {
                var list = awayAddresses
                if !list.contains(hp) { list.insert(hp, at: 0); prefs.set(list, forKey: "away") }
                if saved.isEmpty { saved = hp }
            } else {
                saved = hp
                learnAway(hp)
            }
            current = hp
            setup.isHidden = true
            web.isHidden = false
            if let url = URL(string: "http://\(hp)\(path)") { web.load(URLRequest(url: url)) }
    }

    /// The phone's own address on Wi-Fi, like 192.168.1.23
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

    func find() {
        if finding { return }
        guard let me = MainViewController.wifiAddress(), let dot = me.lastIndex(of: ".") else {
            showSetup("Not on Wi-Fi", "Connect this phone to your home Wi-Fi, or type your NAS's address.")
            return
        }
        finding = true
        findBtn.isEnabled = false
        spinner.startAnimating()
        msgLabel.text = "Looking for KNAS on your home network… (about 15 seconds)"
        let base = String(me[...dot])
        Task { @MainActor in
            var found: String?
            var start = 1
            while found == nil && start < 255 {          // 40 addresses at a time
                let batch = Array(start..<min(start + 40, 255))
                start += 40
                found = await withTaskGroup(of: String?.self) { group -> String? in
                    for n in batch {
                        let hp = "\(base)\(n):\(MainViewController.port)"
                        group.addTask { await MainViewController.isKNAS(hp, timeout: 1.5) ? hp : nil }
                    }
                    for await r in group { if let r = r { group.cancelAll(); return r } }
                    return nil
                }
            }
            finding = false
            findBtn.isEnabled = true
            spinner.stopAnimating()
            if let f = found { open(f) }
            else { showSetup("Couldn't find KNAS", "Type your NAS's address instead (it's in your NAS's network settings, like 192.168.1.50). If your iPhone asked about finding devices on your network, tap Allow.") }
        }
    }

    // ------------------------------------------------------------ web page

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loadFailed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loadFailed(error) }

    func loadFailed(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        if MainViewController.awayFrom(current.isEmpty ? saved : current) || MainViewController.isTailscale(current) { recover(); return }
        showSetup("Can't reach KNAS", "Couldn't open \(current). Check that KNAS is running and this phone is on your home Wi-Fi.")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    // links that open a new window (like a page opening in a new tab) open in the same view
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }

    // pages asking for the camera or microphone (Live Cam, voice remote) get asked through iOS
    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.prompt)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(a, animated: true)
    }

    @objc func cameBack() {
        // back from the background: make sure the page is still alive, and notice if you left home
        if !saved.isEmpty && MainViewController.awayFrom(saved) && !MainViewController.isTailscale(current) { recover(); return }
        if !web.isHidden && web.url == nil { open(current.isEmpty ? saved : current) }
    }

    // ------------------------------------------------------------ menu (hold two fingers)

    @objc func menuGesture(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, presentedViewController == nil else { return }
        let sheet = UIAlertController(title: appName, message: current.isEmpty ? nil : "Connected to \(current)", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Reload", style: .default) { [weak self] _ in
            guard let s = self else { return }
            if s.current.isEmpty { s.open(s.saved) } else { s.web.reload() }
        })
        if isTV {
            sheet.addAction(UIAlertAction(title: "AirPlay to a TV…", style: .default) { [weak self] _ in self?.showAirPlay() })
        }
        sheet.addAction(UIAlertAction(title: "Change address", style: .default) { [weak self] _ in
            self?.showSetup("Change address", "Type your NAS's address, or let the app look for it.")
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let pop = sheet.popoverPresentationController {           // iPad
            pop.sourceView = view
            pop.sourceRect = CGRect(origin: g.location(in: view), size: .zero)
        }
        present(sheet, animated: true)
    }

    /// AirPlay: pick a TV or speaker; the channel's video and sound go there.
    func showAirPlay() {
        let picker = AVRoutePickerView(frame: CGRect(x: -100, y: -100, width: 44, height: 44))
        picker.prioritizesVideoDevices = true
        view.addSubview(picker)
        // tap the picker's button for the person, then remove it
        if let button = picker.subviews.compactMap({ $0 as? UIButton }).first {
            button.sendActions(for: .touchUpInside)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { picker.removeFromSuperview() }
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        var traits = (fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]) ?? [:]
        traits[.weight] = weight
        let d = fontDescriptor.addingAttributes([.traits: traits])
        return UIFont(descriptor: d, size: pointSize)
    }
}

/// The cable box uses the whole screen, right up to the top edge (no gray strip for the notch or status bar).
final class FullScreenWebView: WKWebView {
    override var safeAreaInsets: UIEdgeInsets { .zero }
}
