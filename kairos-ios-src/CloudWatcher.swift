import Foundation

/// 手机怎么知道 iCloud 上的账本变了。
///
/// Mac 上是 fs-watch 盯着本机文件；手机上那个文件夹是 iCloud Drive 的，进程外的东西
/// 改它（Mac、being）手机是听不见的。三条腿：
///   1. 回到前台重读一次——人一打开就是最新的（RootView 里挂在 scenePhase 上）；
///   2. NSMetadataQuery 盯着「用户通过文件选择器授权过的 iCloud 文档」，云上有新版本就重读；
///   3. 前台每 30 秒重读一次兜底——读的是本机 80KB 的文件，零网络、零 token，
///      只防第 2 条在某些系统版本上不吭声。
/// 读到的和内存里一样时 `apply` 不动 UI，所以重读再勤也不闪。退到后台全部停掉。
@MainActor
final class CloudLedgerWatcher {
    private let reload: () -> Void
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var ticker: Task<Void, Never>?
    private var pending: Task<Void, Never>?

    init(reload: @escaping () -> Void) {
        self.reload = reload
    }

    func start() {
        startQuery()
        startTicker()
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        pending?.cancel()
        pending = nil
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers = []
        query?.stop()
        query = nil
    }

    private func startQuery() {
        guard query == nil else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryAccessibleUbiquitousExternalDocumentsScope]
        query.predicate = NSPredicate(
            format: "%K IN %@",
            NSMetadataItemFSNameKey,
            ["projection-snapshot.json", KairosMailFiles.mailboxName]
        )
        query.notificationBatchingInterval = 1
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: query, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleReload() }
            })
        }
        query.start()
        self.query = query
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.reload()
            }
        }
    }

    /// 元数据通知会一阵一阵地来（发现新版本一次、下载完成又一次），合并成一次重读。
    private func scheduleReload() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }
}
