import Foundation

/// Chinese for the fixed labels `mo` prints: cleanup categories, maintenance tasks, health ratings.
/// `mo` itself is English-only, so anything not listed here is shown the way `mo` wrote it.
func zh(_ name: String) -> String { names[name] ?? name }

/// "Excellent: Disk Almost Full, High CPU" → "状态很好：磁盘快满了、CPU 占用高"
func zhHealth(_ message: String) -> String {
    let parts = message.split(separator: ": ", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return zh(message) }
    return zh(parts[0]) + "：" + parts[1].split(separator: ", ").map { zh(String($0)) }.joined(separator: "、")
}

/// A size the way `mo` prints it ("3.2GB", "At least 3.2GB") in the app's own format ("3.2 GB", "至少 3.2 GB").
func zhSize(_ raw: String) -> String {
    let atLeast = raw.hasPrefix("At least ")
    let bytes = parseSize(atLeast ? String(raw.dropFirst("At least ".count)) : raw)
    guard bytes > 0 else { return zh(raw) }
    return (atLeast ? "至少 " : "") + Int64(bytes).formatted(byteFormat)
}

/// What `mo optimize` reports about a task or about the Mac's load, in Chinese. A message that is not
/// in the list below (a newer Mole, a rare case) is shown the way `mo` wrote it.
func zhResult(_ text: String) -> String {
    let whole = NSRange(text.startIndex..., in: text)
    for (rule, chinese) in resultRules {
        guard let match = rule.firstMatch(in: text, range: whole) else { continue }
        let varying = (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
        // The Chinese may leave a varying part out ("X skipped (admin…)" says the same for every X).
        let pieces = chinese.split(separator: "*", omittingEmptySubsequences: false)
        return zip(pieces, varying.prefix(pieces.count - 1) + [""]).map { $0 + $1 }.joined()
    }
    return text
}

private let resultRules: [(NSRegularExpression, String)] = results.map { english, chinese in
    (try! NSRegularExpression(pattern: "^" + NSRegularExpression.escapedPattern(for: english).replacingOccurrences(of: "\\*", with: "(.+?)") + "$"), chinese)
}

/// Mole's messages and what they say. `*` is the part that varies (a number, a size, a name) and is
/// carried over as it is. mo words a step the same way whether it did it or, in a preview, only would:
/// so the Chinese names the step and leaves the tense to the page.
private let results: [(String, String)] = [
    // What the tasks did
    ("DNS cache flushed", "刷新 DNS 缓存"),
    ("DNS cache refreshed", "刷新 DNS 缓存"),
    ("DNS cache already refreshed", "DNS 缓存刚刷新过，不用再刷"),
    ("DNS cache flush skipped, active VPN detected", "正连着 VPN，不刷新 DNS 缓存"),
    ("DNS cache refresh skipped, active VPN detected", "正连着 VPN，不刷新 DNS 缓存"),
    ("Spotlight index verified", "核对聚焦索引"),
    ("QuickLook thumbnails refreshed", "刷新快速查看的缩略图"),
    ("Icon services cache rebuilt", "重建图标缓存"),
    ("App saved states optimized", "整理应用的窗口状态记录"),
    ("Removed * old saved state(s)", "移除 * 份过期的窗口状态记录"),
    ("Repaired * corrupted preference files", "修复 * 个损坏的偏好设置文件"),
    ("All preference files valid", "偏好设置文件都完好"),
    ("Quarantine database already clean", "下载来源记录本来就是空的"),
    ("Quarantine history cleared (* entries)", "清除 * 条下载来源记录"),
    ("Optimized * databases for Mail, Safari, Messages", "压缩 * 个数据库（邮件、Safari、信息）"),
    ("No databases compacted", "没有压缩任何数据库"),
    ("All databases already optimized", "数据库都已经压缩过"),
    ("No databases found to optimize", "没有找到需要压缩的数据库"),
    ("Already optimal for * databases", "* 个数据库不需要压缩"),
    ("Skipped * databases over the 100 MB safety limit", "* 个数据库超过 100 MB 的安全上限，跳过"),
    ("Network stack refresh skipped, active VPN detected", "正连着 VPN，不动网络设置"),
    ("Network stack already optimal", "网络状态正常，不用处理"),
    ("Network routing table refreshed", "刷新路由表"),
    ("ARP cache cleared", "清空 ARP 缓存"),
    ("User directory permissions already optimal", "个人文件夹的权限没有问题"),
    ("User directory permissions repaired", "修复个人文件夹的权限"),
    ("File access issues resolved", "解决文件访问问题"),
    ("Spotlight index already optimal", "聚焦搜索速度正常，不用重建索引"),
    ("Spotlight index rebuild started", "开始重建聚焦索引"),
    ("Spotlight search is slow, rebuilding index, may take 1-2 hours", "聚焦搜索偏慢，重建索引，可能要 1 到 2 小时"),
    ("Spotlight search rules already clean", "聚焦搜索规则里没有失效的条目"),
    ("Would remove * orphan Spotlight rule(s)", "移除 * 条失效的聚焦搜索规则"),
    ("Removed * orphan Spotlight rule(s)", "移除 * 条失效的聚焦搜索规则"),
    (".DS_Store prevention already enabled on network & USB volumes", "早就设置成不往网络共享和 U 盘写 .DS_Store 了"),
    (".DS_Store prevention enabled on network & USB volumes", "设置成不往网络共享和 U 盘写 .DS_Store"),
    ("No legacy App Nap or disk-image overrides found", "没有发现旧优化工具留下的隐藏设置"),
    ("Skipped (whitelisted): *", "在跳过名单里：*"),
    ("Would remove override: *", "移除隐藏设置：*"),
    ("Removed override: *", "移除隐藏设置：*"),
    ("Launch Agents all healthy", "启动代理都正常"),
    ("Periodic maintenance skipped (not available on this macOS version)", "这个版本的 macOS 已经没有这些维护脚本"),
    ("Periodic maintenance already current (*d ago)", "维护脚本 * 天前跑过，不用补跑"),
    ("Periodic maintenance triggered", "补跑系统的维护脚本"),
    ("Shared file lists directory not found", "没有找到访达的个人收藏和最近使用记录"),
    ("Repaired * corrupted shared file list(s)", "修复 * 份损坏的记录"),
    ("Shared file lists all healthy", "访达的个人收藏和最近使用记录都完好"),
    ("Notification Center database is healthy (*)", "通知数据库大小正常（*）"),
    ("Notification Center database cleaned (was *)", "清理通知数据库（原来 *）"),
    ("Disk verify skipped (set MOLE_ENABLE_DISK_VERIFY=1 to enable)", "磁盘检查耗时长，默认不做"),
    ("Disk verify · skipped in dry-run", "预览时不做磁盘检查"),
    ("Disk filesystem verified OK", "文件系统完好"),
    ("Knowledge database not found", "没有找到使用习惯统计数据"),
    ("Knowledge database is healthy (*)", "使用习惯统计数据大小正常（*）"),
    ("Knowledge database cleaned (was *)", "清理使用习惯统计数据（原来 *）"),
    ("No login items found", "没有登录项"),
    ("Login items all healthy (* checked)", "登录项都有效（检查了 * 个）"),
    // Left out for want of administrator rights
    ("* skipped (admin access required)", "没有管理员权限，跳过"),
    ("Periodic maintenance skipped (requires sudo)", "没有管理员权限，跳过"),
    ("Skipping sudo-required optimizations: admin access not granted", "没有拿到管理员权限，需要它的任务会跳过"),
    // What went wrong or needs a look
    ("Failed to refresh DNS cache", "没能刷新 DNS 缓存"),
    ("Failed to inspect active VPN state", "没能确认是否连着 VPN"),
    ("Failed to verify Spotlight index", "没能核对聚焦索引"),
    ("Spotlight indexing disabled", "聚焦索引是关着的"),
    ("Spotlight indexing is disabled", "聚焦索引是关着的"),
    ("Failed to remove * Finder cache target(s)", "有 * 处访达缓存没能移除"),
    ("Failed to rebuild * Finder cache service(s)", "有 * 项访达缓存没能重建"),
    ("Failed to prepare saved state scan", "没能检查窗口状态记录"),
    ("Failed to scan old saved states", "没能检查窗口状态记录"),
    ("Failed to remove * old saved state(s)", "有 * 份过期的窗口状态记录没能移除"),
    ("Preference scan hit its time budget, repaired * so far", "偏好设置检查超时，到这时修复了 * 个"),
    ("Failed to inspect quarantine database", "没能读取下载来源记录"),
    ("Failed to clean quarantine database", "没能清除下载来源记录"),
    ("Failed to inspect active apps before database optimization", "没能确认相关应用是否在运行，数据库没有动"),
    ("Close these apps before database optimization: *", "要压缩数据库，请先退出：*"),
    ("Database optimization incomplete", "数据库没有全部压缩完"),
    ("Timed out on * databases", "* 个数据库压缩超时"),
    ("Failed on * databases", "* 个数据库压缩失败"),
    ("Network health check timed out", "网络状态检查超时"),
    ("Failed to inspect network health", "没能检查网络状态"),
    ("Network stack refresh incomplete (* operation(s) failed)", "网络设置没有全部刷新（* 步失败）"),
    ("Failed to repair permissions, may not be needed", "权限没能修复，也可能本来就不需要"),
    ("Failed to inspect Spotlight index (exit=*)", "没能检查聚焦索引（退出码 *）"),
    ("Spotlight speed check failed (* probe(s))", "聚焦搜索测速失败（* 次）"),
    ("Failed to rebuild Spotlight index", "没能重建聚焦索引"),
    ("Failed to inspect Spotlight search rules", "没能读取聚焦搜索规则"),
    ("Spotlight search rules changed or could not be read; kept", "聚焦搜索规则读不了或刚被改过，没有动"),
    ("Failed to remove orphan Spotlight rules", "没能移除失效的聚焦搜索规则"),
    ("Failed to enable .DS_Store prevention", "没能设置成不写 .DS_Store"),
    ("Failed to enable .DS_Store prevention for * volume type(s)", "有 * 类磁盘没能设置成不写 .DS_Store"),
    ("Could not remove override: *", "没能移除隐藏设置：*"),
    ("* Launch Agent(s) point at a missing program · left in ~/Library/LaunchAgents", "* 个启动代理指向已经不存在的程序，没有动它们，在 ~/Library/LaunchAgents 里"),
    ("Failed to run periodic maintenance (exit=*)", "系统的维护脚本没能跑完（退出码 *）"),
    ("Failed to prepare shared file list scan", "没能检查访达的个人收藏和最近使用记录"),
    ("Failed to scan shared file lists", "没能检查访达的个人收藏和最近使用记录"),
    ("Failed to repair * corrupted shared file list(s)", "有 * 份损坏的记录没能修复"),
    ("Shared file lists not readable (check directory permissions and Full Disk Access)", "读不了访达的个人收藏和最近使用记录，要先给 Kitty Clear 完全磁盘访问权限"),
    ("Failed to inspect Notification Center database size", "没能读取通知数据库的大小"),
    ("Notification Center cleanup skipped (database busy or locked)", "通知数据库正被使用，这次没有清理"),
    ("sqlite3 not available", "这台 Mac 上没有 sqlite3，做不了"),
    ("Disk verification timed out", "磁盘检查超时"),
    ("Disk verification failed (exit=*)", "磁盘检查失败（退出码 *）"),
    ("Disk issues detected · run: sudo diskutil repairVolume /", "磁盘有问题，请在终端里运行 sudo diskutil repairVolume /"),
    ("Disk verification result was not recognized", "看不懂磁盘检查的结果"),
    ("Failed to inspect Knowledge database size", "没能读取使用习惯统计数据的大小"),
    ("Knowledge database cleanup skipped (database busy or locked)", "使用习惯统计数据正被使用，这次没有清理"),
    ("Failed to inspect login items", "没能检查登录项"),
    ("Failed to inspect login items (*)", "没能检查登录项"),
    ("Login items audit incomplete (*)", "登录项没有检查完，不下结论"),
    ("Broken login item: * (app not found)", "失效的登录项：*（找不到对应的应用）"),
    ("* broken login item(s) · remove via System Settings > General > Login Items", "有 * 个失效的登录项，可以在“系统设置 › 通用 › 登录项”里移除"),
    // What it noticed about the Mac's load
    ("No sustained high-CPU bottleneck detected", "没有发现一直在占用 CPU 的进程"),
    ("Likely bottleneck: * (~*% CPU sustained)", "最可能拖慢这台 Mac 的是 *，它一直占着约 *% 的 CPU"),
    ("Desktop composition is busy. When another family is higher, treat this as a likely symptom rather than the root cause.",
     "它负责把所有窗口画到屏幕上，窗口多、动画多或接着高分辨率显示器时就会高。如果另有进程比它更忙，它多半是被带起来的，不是根源。"),
    ("External enterprise agent pressure detected. Mole will not terminate enterprise security processes; restart or policy checks must happen outside Mole.",
     "这是公司的安全软件。它不会被结束，要重启它或请管理员检查策略。"),
    ("Gatekeeper and code-signature assessment activity is elevated.", "系统正在大量校验应用的签名（Gatekeeper）。"),
    ("Metadata indexing or import work is consuming CPU.", "聚焦搜索正在建立索引或导入数据。"),
    ("Simulator runtime disk-image services are active.", "iOS 模拟器的磁盘映像服务正在运行。"),
    ("Additional sustained pressure:", "同样一直在占用 CPU 的还有："),
    // The closing count
    ("* cache cleaned", "清掉 * 缓存"),
    ("* databases optimized", "压缩 * 个数据库"),
    ("* configs repaired", "修复 * 个配置文件"),
]

/// What a maintenance task does, in Chinese; Mole's own English note when the task is new to the app.
func zhOptimizeNote(_ task: OptimizeTask) -> String { optimizeNotes[task.id] ?? task.note }

private let optimizeNotes = [
    "system_maintenance": "刷新 DNS 缓存，检查聚焦搜索的状态",
    "cache_refresh": "刷新快速查看的缩略图和图标缓存",
    "saved_state_cleanup": "移除 30 天以上的应用窗口状态记录",
    "fix_broken_configs": "修复损坏的偏好设置文件",
    "network_optimization": "刷新 DNS 缓存",
    "sqlite_vacuum": "压缩邮件、Safari 和信息的数据库，应用在运行时会跳过",
    "prevent_network_dsstore": "让访达不再往网络共享和 U 盘里写 .DS_Store，这是一项持续生效的设置",
    "legacy_overrides_audit": "移除旧优化工具留下的隐藏设置（App Nap、磁盘映像校验）",
    "network_stack_optimize": "清空路由表和 ARP 缓存，用来解决网络异常",
    "disk_permissions_repair": "修复个人文件夹的权限问题",
    "spotlight_index_optimize": "搜索变慢时重建聚焦索引，会自动判断是否需要",
    "spotlight_orphan_rules_cleanup": "移除已卸载应用留下的聚焦搜索规则",
    "periodic_maintenance": "系统的每日、每周、每月维护脚本过期没跑时补跑",
    "shared_file_list_repair": "修复损坏的访达个人收藏和最近使用记录",
    "disk_verify": "检查文件系统是否完好",
    "login_items_audit": "检查登录项里有没有已经失效的条目",
    "quarantine_cleanup": "清除 Gatekeeper 的下载来源记录",
    "launch_agents_cleanup": "找出指向已不存在程序的启动代理",
    "notification_cleanup": "清理旧的已送达通知，给通知数据库瘦身",
    "coreduet_cleanup": "清理旧的使用习惯统计数据",
]

private let names = [
    // mo clean: what a scan passed over, and why
    "Trash": "废纸篓",
    "Mail Downloads": "邮件下载的附件",
    "Project caches": "项目缓存",
    "grant Full Disk Access to your terminal": "要先给 Kitty Clear 完全磁盘访问权限",
    "process state unknown": "没法确认它是否在运行",
    "sizing unavailable": "量不出大小",
    "Current symlink broken": "它的版本链接坏了",
    // mo clean: what it points out and leaves to the user
    "Xcode DerivedData": "Xcode 的构建数据",
    "Xcode archives": "Xcode 归档",
    "Simulator data": "模拟器数据",
    "Docker Desktop data": "Docker Desktop 的数据",
    "Docker unused data": "Docker 没在用的数据",
    "Docker storage": "Docker 占用的空间",
    "OrbStack data": "OrbStack 的数据",
    "OrbStack container data": "OrbStack 的容器数据",
    "Lima data": "Lima 的数据",
    "pnpm store": "pnpm 仓库",
    "Gradle caches": "Gradle 缓存",
    "Hugging Face cache": "Hugging Face 的模型缓存",
    "LM Studio models": "LM Studio 的模型",
    "Maven local repository": "Maven 本地仓库",
    "Ivy local repository": "Ivy 本地仓库",
    "NuGet packages": "NuGet 包",
    "Conda packages": "Conda 包",
    "Anaconda packages": "Anaconda 包",
    "Deno module cache": "Deno 模块缓存",
    "FVM Flutter SDKs": "FVM 装的 Flutter SDK",
    "Android emulators": "Android 模拟器",
    "Android system images": "Android 系统镜像",
    "JetBrains old version data": "JetBrains 旧版本的数据",
    "Mail data": "邮件数据",
    "Mail downloads": "邮件下载的附件",
    "iOS backups": "iOS 设备备份",
    "macOS updates cache": "macOS 更新缓存",
    "Codex runtimes": "Codex 运行时",
    "Homebrew unused dependencies": "Homebrew 没在用的依赖",
    "Time Machine local snapshots": "时间机器的本地快照",
    "Build artifacts": "构建产物",
    "AI agent worktrees": "AI 代理的工作副本",
    "Orphaned simulator runtime": "没有设备在用的模拟器运行时",
    "review with docker system df": "可以用 docker system df 查看",
    "remove with brew autoremove": "可以用 brew autoremove 移除",
    "manual review": "要手动处理",
    // mo uninstall: what it notes under an app
    "Steam launcher only; game files managed by Steam are not included": "只卸载 Steam 启动器，Steam 管理的游戏文件不在其中",
    "Shared leftovers kept (some paths unreadable)": "和别的应用共用的文件没有动（有些位置读不了）",
    "Shared leftovers kept (other copies unchecked)": "和别的应用共用的文件没有动（没法确认别处还有没有这个应用）",
    "Leftovers kept (scan timed out)": "查找残留超时，残留文件没有动",
    // mo clean
    "User essentials": "用户缓存与日志",
    "App caches": "应用缓存",
    "Browsers": "浏览器",
    "Cloud & Office": "云盘与办公",
    "Developer tools": "开发工具",
    "Apps & utilities": "应用与工具",
    "Virtualization": "虚拟机",
    "Application Support": "应用支持文件",
    "App leftovers": "卸载残留",
    "Apple Silicon updates": "Apple 芯片更新缓存",
    "Device backups & firmware": "设备备份与固件",
    "Time Machine": "时间机器",
    "Large files": "大文件",
    "Project artifacts": "项目构建产物",
    "System": "系统",
    "External volume": "外接磁盘",
    // mo optimize
    "DNS & Spotlight Check": "DNS 与聚焦检查",
    "Finder Cache Refresh": "访达缓存刷新",
    "App State Cleanup": "应用状态清理",
    "Broken Config Repair": "损坏配置修复",
    "Network Cache Refresh": "网络缓存刷新",
    "Database Optimization": "数据库优化",
    "Prevent Finder .DS_Store": "禁止生成 .DS_Store",
    "Legacy Overrides": "旧版覆盖设置",
    "Network Stack Refresh": "网络栈刷新",
    "Permission Repair": "权限修复",
    "Spotlight Optimization": "聚焦优化",
    "Spotlight Orphan Rules": "聚焦失效规则",
    "Periodic Maintenance": "定期维护",
    "Shared File Lists": "共享文件列表",
    "Disk Health": "磁盘健康",
    "Login Items": "登录项",
    "Quarantine Database Cleanup": "隔离数据库清理",
    "Launch Agents Cleanup": "启动代理清理",
    "Notifications": "通知",
    "Usage Data": "使用数据",
    // mo status: overall rating, its reasons, battery condition
    "Excellent": "状态很好",
    "Good": "良好",
    "Fair": "一般",
    "Needs Attention": "需要留意",
    "Healthy": "健康",
    "Service Soon": "需要检修",
    "Battery Service Soon": "电池需要检修",
    "Critical Memory": "内存严重不足",
    "Disk Almost Full": "磁盘快满了",
    "Disk SMART Failing": "磁盘 SMART 异常",
    "Heavy Disk IO": "磁盘读写繁忙",
    "High CPU": "CPU 占用高",
    "High Memory": "内存占用高",
    "Memory Pressure": "内存压力大",
    "Overheating": "温度过高",
    "Restart Recommended": "建议重启",
    // mo status: what the battery is doing
    "charging": "正在充电",
    "discharging": "使用电池中",
    "charged": "已充满",
    "finishing": "快充满了",
    "Unknown": "状态未知",
    // mo clean summary
    "Partially measured": "部分已统计",
    "size unknown": "大小未知",
    "unknown": "大小未知",
    // mo history: the command a session belongs to
    "clean": "清理",
    "uninstall": "卸载",
    "optimize": "优化",
    "purge": "项目清理",
    "installer": "安装包清理",
    "analyze": "磁盘分析",
]
