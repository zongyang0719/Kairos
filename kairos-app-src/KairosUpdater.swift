#if os(macOS)
import AppKit
import Foundation
import SwiftUI

// MARK: - 软件更新（GitHub Release）
//
// app 是 ad-hoc 签名、未公证，Sparkle 那套 EdDSA/公证链走不通，所以自己做一条最窄的路：
//   查 releases/latest → 比版本 → 下 zip → ditto 解压 → **app 退出后**由派生的 sh 换包 → open 新 app。
//
// 铁律：绝不在 app 运行中覆盖自己。换包全部发生在进程退出之后（sh 用 kill -0 等 pid 消失）。
// 节制：启动 8 秒后静默查一次，24 小时最多一次（不论成败都记时间，失败不自动重试）；
// 「检查更新」按钮是手动的，不受 24h 限制。
//
// 状态文件放 `~/.kairos/updater.json`（`KairosFiles.configDirectory`，和 connection.json / rooms.json 同一个家）。
// 调试：环境变量 `KAIROS_UPDATE_API_URL` 可把 API 指向本地 mock JSON。

/// 语义化版本。`v` 前缀、缺省的 patch（"2.6" == "2.6.0"）、预发布段（2.6.0-beta.1 < 2.6.0）、
/// 构建元数据（+xxx，比较时忽略）都按 semver 2.0 处理。**不是字符串比较**：2.10.0 > 2.9.9。
struct KairosSemVer: Comparable, CustomStringConvertible {
    /// 去掉 `v` 前缀和 `+build` 之后的原文，用于展示和拼资产名。
    let normalized: String
    let core: [Int]
    let prerelease: [String]

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = text.first, first == "v" || first == "V" { text.removeFirst() }
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }
        guard !text.isEmpty else { return nil }
        normalized = text

        var coreText = Substring(text)
        var pre: [String] = []
        if let dash = text.firstIndex(of: "-") {
            coreText = text[..<dash]
            pre = text[text.index(after: dash)...]
                .split(separator: ".", omittingEmptySubsequences: false)
                .map(String.init)
            guard !pre.isEmpty, pre.allSatisfy({ !$0.isEmpty }) else { return nil }
        }
        let parts = coreText.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        while numbers.count < 3 { numbers.append(0) }
        core = numbers
        prerelease = pre
    }

    var description: String { normalized }

    static func compare(_ a: KairosSemVer, _ b: KairosSemVer) -> ComparisonResult {
        let width = max(a.core.count, b.core.count)
        for i in 0..<width {
            let x = i < a.core.count ? a.core[i] : 0
            let y = i < b.core.count ? b.core[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        // 正式版 > 同号预发布版
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, true): return .orderedSame
        case (true, false): return .orderedDescending
        case (false, true): return .orderedAscending
        case (false, false): break
        }
        for i in 0..<max(a.prerelease.count, b.prerelease.count) {
            guard i < a.prerelease.count else { return .orderedAscending }
            guard i < b.prerelease.count else { return .orderedDescending }
            let x = a.prerelease[i], y = b.prerelease[i]
            if x == y { continue }
            switch (Int(x), Int(y)) {
            case let (nx?, ny?): return nx < ny ? .orderedAscending : .orderedDescending
            case (_?, nil): return .orderedAscending   // 数字标识 < 字母标识
            case (nil, _?): return .orderedDescending
            case (nil, nil): return x < y ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }

    static func < (a: KairosSemVer, b: KairosSemVer) -> Bool { compare(a, b) == .orderedAscending }
    static func == (a: KairosSemVer, b: KairosSemVer) -> Bool { compare(a, b) == .orderedSame }
}

/// 一次检查的结论。纯值，不碰 UI，方便单测。
enum KairosUpdateCheckResult: Equatable {
    case upToDate(latest: String)
    case available(version: String, assetURL: URL)
    case failed(String)
}

enum KairosUpdateCheck {
    static let defaultAPI = URL(string: "https://api.github.com/repos/zongyang0719/Kairos/releases/latest")!
    static let minimumInterval: TimeInterval = 24 * 60 * 60

    static var apiURL: URL {
        if let override = ProcessInfo.processInfo.environment["KAIROS_UPDATE_API_URL"],
           let url = URL(string: override), url.scheme != nil {
            return url
        }
        return defaultAPI
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// 发布资产名。GitHub 上实际用的是 `-macOS.zip`；`make-zip.sh` 产出的是 `-mac.zip`，一并认。
    static func assetNames(for version: String) -> [String] {
        ["Kairos-v\(version)-macOS.zip", "Kairos-v\(version)-mac.zip"]
    }

    static func shouldAutoCheck(lastChecked: Date?, now: Date = Date()) -> Bool {
        guard let lastChecked else { return true }
        // 时钟被往回拨过（lastChecked 在未来）也放行，否则会卡死不查。
        return now.timeIntervalSince(lastChecked) >= minimumInterval || lastChecked > now
    }

    /// 解析 releases/latest 的 JSON 并与当前版本比较。坏 JSON、缺字段、版本号不合法都归 `.failed`。
    static func evaluate(data: Data, currentVersion: String) -> KairosUpdateCheckResult {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String else {
            return .failed("更新信息读不懂，稍后再试")
        }
        guard let latest = KairosSemVer(tag) else {
            return .failed("最新发布的版本号「\(tag)」不合规")
        }
        guard let current = KairosSemVer(currentVersion) else {
            return .failed("本机版本号「\(currentVersion)」不合规")
        }
        guard current < latest else { return .upToDate(latest: current.normalized) }

        let assets = object["assets"] as? [[String: Any]] ?? []
        for wanted in assetNames(for: latest.normalized) {
            if let asset = assets.first(where: { ($0["name"] as? String) == wanted }),
               let link = asset["browser_download_url"] as? String,
               let url = URL(string: link) {
                return .available(version: latest.normalized, assetURL: url)
            }
        }
        return .failed("发现 v\(latest.normalized)，但没找到 macOS 安装包")
    }

    static func fetch(apiURL: URL = apiURL, currentVersion: String = currentVersion) async -> KairosUpdateCheckResult {
        var request = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Kairos/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                switch http.statusCode {
                case 403, 429: return .failed("GitHub 暂时限流，稍后再试")
                case 404: return .failed("还没有可用的发布版本")
                default: return .failed("检查更新失败（HTTP \(http.statusCode)）")
                }
            }
            return evaluate(data: data, currentVersion: currentVersion)
        } catch {
            return .failed(networkMessage(error))
        }
    }

    static func networkMessage(_ error: Error) -> String {
        let code = (error as? URLError)?.code
        switch code {
        case .notConnectedToInternet?, .networkConnectionLost?, .dataNotAllowed?:
            return "没有网络，连上后再检查"
        case .timedOut?:
            return "连接超时，稍后再试"
        case .cannotFindHost?, .cannotConnectToHost?, .dnsLookupFailed?:
            return "连不上 GitHub，稍后再试"
        default:
            return "检查更新失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 安装：下载 → 解压 → 校验 → 退出后换包

enum KairosUpdateInstaller {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 换包脚本。参数：pid 新app 目标路径 备份路径 是否重新打开(1/0)。
    /// 只在 pid 消失之后动目标路径；新包放不进去就把备份挪回原位。
    static let swapScript = """
    #!/bin/sh
    PID="$1"; NEW_APP="$2"; TARGET="$3"; BACKUP="$4"; RELAUNCH="$5"
    echo "[$(date)] kairos updater: waiting for pid $PID"
    i=0
    while kill -0 "$PID" 2>/dev/null; do
      i=$((i+1))
      if [ "$i" -gt 600 ]; then echo "app did not quit in 120s, abort"; exit 1; fi
      sleep 0.2
    done
    mkdir -p "$(dirname "$BACKUP")"
    if [ -e "$TARGET" ]; then
      if ! mv "$TARGET" "$BACKUP"; then echo "backup failed, abort"; exit 1; fi
    fi
    if mv "$NEW_APP" "$TARGET"; then
      xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
      echo "installed $TARGET (old app kept at $BACKUP)"
    else
      echo "install failed, restoring backup"
      [ -e "$BACKUP" ] && mv "$BACKUP" "$TARGET"
      [ "$RELAUNCH" = "1" ] && open "$TARGET"
      exit 1
    fi
    [ "$RELAUNCH" = "1" ] && open "$TARGET"
    exit 0
    """

    /// 下载并解压，返回校验过的新 `Kairos.app` 路径。任何一步不对都抛 `Failure`（带中文提示）。
    static func prepare(version: String, assetURL: URL, bundleIdentifier: String?) async throws -> URL {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("kairos-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        var request = URLRequest(url: assetURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("Kairos/\(KairosUpdateCheck.currentVersion)", forHTTPHeaderField: "User-Agent")
        let downloaded: URL
        do {
            let (file, response) = try await URLSession.shared.download(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw Failure(message: "下载失败（HTTP \(http.statusCode)），稍后再试")
            }
            downloaded = work.appendingPathComponent("Kairos-v\(version)-macOS.zip")
            try FileManager.default.moveItem(at: file, to: downloaded)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(message: "下载失败：" + KairosUpdateCheck.networkMessage(error))
        }

        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        let status = run("/usr/bin/ditto", ["-x", "-k", downloaded.path, unpacked.path])
        guard status == 0 else { throw Failure(message: "解压失败，安装包可能不完整") }

        guard let app = findApp(in: unpacked) else {
            throw Failure(message: "安装包里没有 Kairos.app")
        }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        if let bundleIdentifier, (info?["CFBundleIdentifier"] as? String) != bundleIdentifier {
            throw Failure(message: "安装包不是 Kairos，已放弃")
        }
        if let packaged = (info?["CFBundleShortVersionString"] as? String).flatMap(KairosSemVer.init),
           let expected = KairosSemVer(version), packaged != expected {
            throw Failure(message: "安装包版本（\(packaged)）和发布说明（\(expected)）对不上，已放弃")
        }
        return app
    }

    static func findApp(in folder: URL) -> URL? {
        let direct = folder.appendingPathComponent("Kairos.app", isDirectory: true)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for child in children where child.lastPathComponent != "__MACOSX" {
            let nested = child.appendingPathComponent("Kairos.app", isDirectory: true)
            if FileManager.default.fileExists(atPath: nested.path) { return nested }
        }
        return nil
    }

    /// 目标位置能不能换。App Translocation（从下载目录直接双击、系统挪到只读随机路径）换了也没用。
    static func installBlocker(targetPath: String) -> String? {
        if targetPath.contains("/AppTranslocation/") {
            return "Kairos 正在从临时隔离位置运行，请先拖进「应用程序」再更新"
        }
        let parent = (targetPath as NSString).deletingLastPathComponent
        if !FileManager.default.isWritableFile(atPath: parent) {
            return "没有权限替换 \(parent) 里的 Kairos，请手动下载安装"
        }
        return nil
    }

    /// 派生换包 sh（它会等本进程退出才动手），返回后调用方负责退出 app。
    static func launchSwap(newApp: URL, targetPath: String, pid: Int32, relaunch: Bool) throws -> URL {
        let work = newApp.deletingLastPathComponent().deletingLastPathComponent()
        let script = work.appendingPathComponent("swap.sh")
        try swapScript.write(to: script, atomically: true, encoding: .utf8)
        let backup = work.appendingPathComponent("backup", isDirectory: true)
            .appendingPathComponent((targetPath as NSString).lastPathComponent)
        let log = work.appendingPathComponent("swap.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(pid), newApp.path, targetPath, backup.path, relaunch ? "1" : "0"]
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return log
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

// MARK: - 状态机（设置里那一行看的就是它）

@MainActor
final class KairosUpdater: ObservableObject {
    static let shared = KairosUpdater()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(version: String, assetURL: URL)
        case downloading(String)
        case installing(String)
        /// `retry` 非空：失败发生在下载/安装阶段，可以再点一次下载。
        case failed(message: String, retry: KairosUpdateCheckResult?)
    }

    private struct SavedState: Codable {
        var lastCheckedAt: Date?
        var latestVersion: String?
        var assetURL: String?
    }

    @Published private(set) var phase: Phase = .idle
    let currentVersion: String
    private let stateURL: URL
    private var launchCheckScheduled = false

    init(
        currentVersion: String = KairosUpdateCheck.currentVersion,
        stateURL: URL = KairosFiles.configDirectory.appendingPathComponent("updater.json")
    ) {
        self.currentVersion = currentVersion
        self.stateURL = stateURL
        restoreCachedResult()
    }

    /// 启动时调一次：8 秒后静默查（24h 内查过就不查）。
    func scheduleLaunchCheck(delay: TimeInterval = 8) {
        guard !launchCheckScheduled else { return }
        launchCheckScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, KairosUpdateCheck.shouldAutoCheck(lastChecked: self.loadState().lastCheckedAt) else { return }
            await self.check()
        }
    }

    /// 手动「检查更新」。
    func check() async {
        switch phase {
        case .checking, .downloading, .installing: return
        default: break
        }
        phase = .checking
        let result = await KairosUpdateCheck.fetch(currentVersion: currentVersion)
        var state = loadState()
        state.lastCheckedAt = Date()   // 成败都记，防止重试风暴
        apply(result, state: &state)
        saveState(state)
    }

    func downloadAndInstall() async {
        let version: String, assetURL: URL
        switch phase {
        case let .available(v, url), let .failed(_, .available(v, url)?):
            version = v; assetURL = url
        default: return
        }
        let target = Bundle.main.bundlePath
        if let blocker = KairosUpdateInstaller.installBlocker(targetPath: target) {
            phase = .failed(message: blocker, retry: .available(version: version, assetURL: assetURL))
            return
        }
        phase = .downloading(version)
        do {
            let app = try await KairosUpdateInstaller.prepare(
                version: version, assetURL: assetURL, bundleIdentifier: Bundle.main.bundleIdentifier
            )
            phase = .installing(version)
            _ = try KairosUpdateInstaller.launchSwap(
                newApp: app, targetPath: target,
                pid: ProcessInfo.processInfo.processIdentifier, relaunch: true
            )
            // 给界面一帧显示「正在重启」，然后退出；换包由 sh 在退出后完成。
            try? await Task.sleep(nanoseconds: 300_000_000)
            NSApp.terminate(nil)
        } catch {
            let message = (error as? KairosUpdateInstaller.Failure)?.message ?? "更新失败：\(error.localizedDescription)"
            phase = .failed(message: message, retry: .available(version: version, assetURL: assetURL))
        }
    }

    private func apply(_ result: KairosUpdateCheckResult, state: inout SavedState) {
        switch result {
        case let .upToDate(latest):
            phase = .upToDate(latest)
            state.latestVersion = latest
            state.assetURL = nil
        case let .available(version, url):
            phase = .available(version: version, assetURL: url)
            state.latestVersion = version
            state.assetURL = url.absoluteString
        case let .failed(message):
            phase = .failed(message: message, retry: nil)
        }
    }

    /// 24h 内不联网时，设置里仍能看到上次的结论（升级过之后缓存里的「新版」自然失效）。
    private func restoreCachedResult() {
        let state = loadState()
        guard let cached = state.latestVersion.flatMap(KairosSemVer.init),
              let current = KairosSemVer(currentVersion) else { return }
        if current < cached, let link = state.assetURL, let url = URL(string: link) {
            phase = .available(version: cached.normalized, assetURL: url)
        } else if state.lastCheckedAt != nil, !(current < cached) {
            phase = .upToDate(current.normalized)
        }
    }

    private func loadState() -> SavedState {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder.kairosUpdater.decode(SavedState.self, from: data) else {
            return SavedState()
        }
        return state
    }

    private func saveState(_ state: SavedState) {
        guard let data = try? JSONEncoder.kairosUpdater.encode(state) else { return }
        try? FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: stateURL, options: .atomic)
    }
}

private extension JSONDecoder {
    static var kairosUpdater: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var kairosUpdater: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

// MARK: - 设置里的「软件更新」小区块

struct KairosUpdateSection: View {
    @ObservedObject var updater: KairosUpdater = .shared

    private typealias T = KairosTokens

    var body: some View {
        Section("软件更新") {
            HStack(spacing: T.Spacing.s) {
                status
                Spacer(minLength: T.Spacing.s)
                trailing
            }
            // 版本号换档时（检查中 → 已是最新 → 发现新版本）数字等宽，这一行不跟着抖。
            .font(.system(size: T.TypeScale.body).monospacedDigit())
        }
    }

    @ViewBuilder
    private var status: some View {
        switch updater.phase {
        case .idle:
            Text("当前版本 v\(updater.currentVersion)")
        case .checking:
            Text("正在检查更新…").foregroundStyle(T.Ink.secondary)
        case let .upToDate(version):
            Text("已是最新 v\(version)")
        case let .available(version, _):
            Button("发现新版本 v\(version) — 下载并更新") {
                Task { await updater.downloadAndInstall() }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help("下载后 Kairos 会退出、替换并重新打开")
        case let .downloading(version):
            Text("正在下载 v\(version)…").foregroundStyle(T.Ink.secondary)
        case let .installing(version):
            Text("v\(version) 已就绪，Kairos 即将重启…").foregroundStyle(T.Ink.secondary)
        case let .failed(message, _):
            VStack(alignment: .leading, spacing: T.Spacing.xs) {
                Text("当前版本 v\(updater.currentVersion)")
                Text(message)
                    .font(.system(size: T.TypeScale.caption))
                    .foregroundStyle(T.Ink.secondary)
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch updater.phase {
        case .failed(_, .available?):
            Button("重试下载") { Task { await updater.downloadAndInstall() } }
                .controlSize(.small)
        case .available, .downloading, .installing:
            EmptyView()
        case .checking:
            Button("检查更新") {}.controlSize(.small).disabled(true)
        default:
            Button("检查更新") { Task { await updater.check() } }
                .controlSize(.small)
        }
    }
}
#endif
