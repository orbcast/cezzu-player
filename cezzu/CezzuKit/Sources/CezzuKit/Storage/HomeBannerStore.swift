import Foundation

/// 首页沉浸式 Banner 的磁盘缓存：固定取「热门剧集」前 N 条。
///
/// 仅当前 N 条的 **subject id 序列** 变化时才写盘；元数据微调不触发更新。
public final class HomeBannerStore: @unchecked Sendable {
    public static let maxCount: Int = 5

    private let fileURL: URL
    /// 没有选中 ref 时为 true：不读也不写，首页不该有任何来源之外的 Banner。
    private let isDisabled: Bool
    private let lock = NSLock()
    private var memory: [CatalogItem]?

    public init(fileURL: URL? = nil) {
        self.isDisabled = false
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = Self.defaultFileURL()
        }
    }

    /// 按 ref 隔离的缓存：每个 ref 一份文件，换 ref 不会看到别家的榜单。
    /// `refID` 为 nil（还没选 ref）时是一个永远为空的存储。
    public init(refID: String?) {
        guard let refID, !refID.isEmpty else {
            self.fileURL = Self.defaultFileURL()
            self.isDisabled = true
            return
        }
        let safe = String(refID.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
        self.fileURL = Self.defaultFileURL().deletingLastPathComponent()
            .appendingPathComponent("home-banner-\(safe).json", isDirectory: false)
        self.isDisabled = false
    }

    public static func defaultFileURL() -> URL {
        let fm = FileManager.default
        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport.appendingPathComponent("Cezzu", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("home-banner.json", isDirectory: false)
    }

    /// 从热门列表截取前 `maxCount` 条（不足则全取）。
    public static func pickTop(_ items: [CatalogItem], count: Int = HomeBannerStore.maxCount) -> [CatalogItem] {
        Array(items.prefix(count))
    }

    /// 比较两份列表的 subject id 序列是否完全一致。
    public static func idsMatch(_ lhs: [CatalogItem], _ rhs: [CatalogItem]) -> Bool {
        lhs.map(\.id) == rhs.map(\.id)
    }

    /// 旧版本写的缓存缺 info / metaTags / heat 这些后加的字段。
    /// id 序列没变时本不会写盘，缓存就会一直缺字段，所以这里单独放行一次覆盖。
    public static func needsFieldBackfill(cached: [CatalogItem], fresh: [CatalogItem]) -> Bool {
        zip(cached, fresh).contains { cached, fresh in
            (cached.info.isEmpty && !fresh.info.isEmpty)
                || (cached.metaTags.isEmpty && !fresh.metaTags.isEmpty)
                || (cached.heat == 0 && fresh.heat > 0)
        }
    }

    /// 读缓存（内存命中优先）。文件缺失或损坏时返回空数组。
    public func load() -> [CatalogItem] {
        if isDisabled { return [] }
        lock.lock()
        defer { lock.unlock() }
        if let memory { return memory }
        let items = readFromDisk()
        memory = items
        return items
    }

    /// 用最新热门列表同步缓存。
    ///
    /// - 前 N 条 id 未变且字段齐全：保留原缓存，返回 `false`
    /// - id 变了，或老缓存缺新加的字段：写入新前 N 条，返回 `true`
    /// - 热门为空：不动缓存，返回 `false`
    @discardableResult
    public func updateIfNeeded(from trending: [CatalogItem]) -> Bool {
        if isDisabled { return false }
        let top = Self.pickTop(trending)
        guard !top.isEmpty else { return false }

        lock.lock()
        defer { lock.unlock() }

        let current = memory ?? readFromDisk()
        if Self.idsMatch(current, top), !Self.needsFieldBackfill(cached: current, fresh: top) {
            memory = current
            return false
        }

        memory = top
        writeToDisk(top)
        return true
    }

    // MARK: - private

    private func readFromDisk() -> [CatalogItem] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([CatalogItem].self, from: data)) ?? []
    }

    private func writeToDisk(_ items: [CatalogItem]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(items) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
