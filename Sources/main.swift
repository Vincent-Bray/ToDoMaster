import AppKit
import AudioToolbox

// ==================== 数据模型 ====================
struct TodoItem: Codable {
    let id: UUID
    var title: String
    var date: Date?
    var isToday: Bool { date.map { Calendar.current.isDateInToday($0) } ?? false }
    var endDate: Date?
    var location: String?
    var notes: String
    var isCompleted: Bool
    var isStarred: Bool
    var reminderFired: Bool

    init(id: UUID = UUID(), title: String, date: Date? = nil, endDate: Date? = nil,
         location: String? = nil, notes: String = "", isCompleted: Bool = false, isStarred: Bool = false) {
        self.id = id; self.title = title; self.date = date; self.endDate = endDate
        self.location = location; self.notes = notes; self.isCompleted = isCompleted
        self.isStarred = isStarred; self.reminderFired = false
    }
}

// ==================== 数据存储 ====================
class TodoStore {
    static let shared = TodoStore()
    var items: [TodoItem] = []

    var todayItems: [TodoItem] {
        let today = items.filter { $0.isToday }
        return today.sorted { a, b in
            if a.isStarred != b.isStarred { return a.isStarred }
            let ad = a.date ?? .distantFuture
            let bd = b.date ?? .distantFuture
            return ad < bd
        }
    }
    var longTermItems: [TodoItem] {
        let lt = items.filter { !$0.isToday }
        return lt.sorted { a, b in
            let aExpired = a.date.map { $0.timeIntervalSinceNow < 0 } ?? false
            let bExpired = b.date.map { $0.timeIntervalSinceNow < 0 } ?? false
            if aExpired != bExpired { return !aExpired }
            if a.isStarred != b.isStarred { return a.isStarred }
            let ad = a.date ?? .distantFuture
            let bd = b.date ?? .distantFuture
            return ad < bd
        }
    }
    var showDetailedCountdown = false
    var todayCollapsed = false
    var longTermCollapsed = false
    var todayUncompleted: Set<UUID> = [] // 今日未完成标记
    private let fileURL: URL

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Vira/TodoApp")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("todos.json")
        load()
    }

    func add(_ item: TodoItem) { items.append(item); sortItems(); save() }
    func toggle(_ id: UUID) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].isCompleted.toggle(); save() }
    }
    func toggleStar(_ id: UUID) {
        if let i = items.firstIndex(where: { $0.id == id }) {
            items[i].isStarred.toggle(); sortItems(); save()
        }
    }
    func delete(_ ids: Set<UUID>) { items.removeAll { ids.contains($0.id) }; save() }
    func update(_ item: TodoItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item; sortItems(); save() }
    }

    func sortItems() {
        items.sort { a, b in
            // 过期项排最后
            let aExpired = a.date.map { $0.timeIntervalSinceNow < 0 } ?? false
            let bExpired = b.date.map { $0.timeIntervalSinceNow < 0 } ?? false
            if aExpired != bExpired { return !aExpired }
            if a.isStarred != b.isStarred { return a.isStarred }
            let ad = a.date ?? .distantFuture
            let bd = b.date ?? .distantFuture
            return ad < bd
        }
    }

    func daysUntil(_ date: Date) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)).day ?? 0
    }

    func countdownText(for item: TodoItem) -> String {
        guard let date = item.date else { return "—" }
        let days = daysUntil(date)
        if days < 0 { return "已过期" }
        if showDetailedCountdown {
            let interval = date.timeIntervalSince(Date())
            if interval < 0 { return "已过期" }
            let d = Int(interval) / 86400
            let h = (Int(interval) % 86400) / 3600
            let m = (Int(interval) % 3600) / 60
            if d > 0 { return "\(d)天\(h)时" }
            if h > 0 { return "\(h)时\(m)分" }
            return "\(m)分钟"
        }
        // 当天任务自动显示小时/分钟倒数
        if days == 0 {
            let interval = date.timeIntervalSince(Date())
            if interval < 0 { return "已过期" }
            let h = Int(interval) / 3600
            let m = (Int(interval) % 3600) / 60
            if h > 0 { return "\(h)时\(m)分" }
            return "\(m)分钟"
        }
        return "\(days)天"
    }

    func urgencyColor(for item: TodoItem) -> NSColor? {
        guard let date = item.date else { return nil }
        let days = daysUntil(date)
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let expiredBg = isDark ? NSColor(white: 0.22, alpha: 1.0) : NSColor(white: 0.88, alpha: 1.0)
        if days < 0 { return expiredBg }
        if date.timeIntervalSinceNow < 0 { return expiredBg }
        if item.isStarred { return NSColor.systemPurple.withAlphaComponent(0.15) }
        switch days {
        case 0: return NSColor.systemPurple.withAlphaComponent(0.12)
        case 1...3: return NSColor.systemRed.withAlphaComponent(0.10)
        case 4...7: return NSColor.systemYellow.withAlphaComponent(0.12)
        case 8...15: return NSColor.systemBlue.withAlphaComponent(0.08)
        default: return NSColor.systemGreen.withAlphaComponent(0.08)
        }
    }

    func exportMarkdown(ids: Set<UUID>) -> String {
        let sel = items.filter { ids.contains($0.id) }
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
        let dfmt = DateFormatter(); dfmt.dateFormat = "MM-dd"
        var md = "# 待办事项导出\n\n导出时间: \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short))\n\n"
        md += "| 状态 | 星标 | 任务 | 时间 | 倒数 | 地点 | 备注 |\n|------|------|------|------|------|------|------|\n"
        for item in sel {
            let s = item.isCompleted ? "✅" : "⬜"
            let star = item.isStarred ? "⭐" : ""
            var timeStr = "—"
            if let d = item.date {
                timeStr = dfmt.string(from: d) + " " + fmt.string(from: d)
                if let e = item.endDate { timeStr += "-" + fmt.string(from: e) }
            }
            md += "| \(s) | \(star) | \(item.title) | \(timeStr) | \(countdownText(for: item)) | \(item.location ?? "—") | \(item.notes.isEmpty ? "—" : item.notes) |\n"
        }
        md += "\n共 \(sel.count) 项。\n"
        return md
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: fileURL) }
    }
    func reload() { load() }
    private func load() {
        if let d = try? Data(contentsOf: fileURL),
           let dec = try? JSONDecoder().decode([TodoItem].self, from: d) {
            items = dec; sortItems()
        }
    }
}

// ==================== 智能解析（v2） ====================
func parseSmartInput(_ input: String) -> TodoItem {
    var text = input
    var date: Date?; var endDate: Date?
    var location: String?
    let now = Date(); let cal = Calendar.current

    func removeMatch(_ m: NSTextCheckingResult) {
        if let r = Range(m.range, in: text) {
            text = text.replacingOccurrences(of: String(text[r]), with: " ")
        }
    }

    // 时间区间
    if let re = try? NSRegularExpression(pattern: "(上午|下午|晚上|中午|早上)?\\s*(\\d{1,2})[:：点时](\\d{1,2}|半)?[分]?\\s*[-~～—–—到至]+\\s*(上午|下午|晚上|中午|早上)?\\s*(\\d{1,2})[:：点时]?(\\d{1,2}|半)?[分]?"),
       let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
        let g = { (i: Int) -> String in
            m.range(at: i).location != NSNotFound ? (text as NSString).substring(with: m.range(at: i)) : ""
        }
        let p1 = g(1); var h1 = Int(g(2)) ?? 0
        let ms1 = g(3); let m1 = ms1 == "半" ? 30 : (Int(ms1) ?? 0)
        let p2 = g(4); var h2 = Int(g(5)) ?? 0
        let ms2 = g(6); let m2 = ms2 == "半" ? 30 : (Int(ms2) ?? 0)
        func adj(_ per: String, _ h: inout Int) {
            switch per { case "下午","晚上": if h < 12 { h += 12 }; case "中午": if h < 11 { h = 12 }; default: break }
        }
        adj(p1, &h1); adj(p2, &h2)
        var c = cal.dateComponents([.year,.month,.day], from: now)
        c.hour = h1; c.minute = m1; date = cal.date(from: c)
        c.hour = h2; c.minute = m2; endDate = cal.date(from: c)
        removeMatch(m)
    }

    // 日期
    if let re = try? NSRegularExpression(pattern: "(\\d{1,2})月(\\d{1,2})[日号]"),
       let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
        let gD = { (i: Int) -> String in
            m.range(at: i).location != NSNotFound ? (text as NSString).substring(with: m.range(at: i)) : ""
        }
        let mo = Int(gD(1)) ?? 1; let da = Int(gD(2)) ?? 1
        var c = cal.dateComponents([.year], from: now); c.month = mo; c.day = da
        if let d = cal.date(from: c), cal.startOfDay(for: d) < cal.startOfDay(for: now) { c.year! += 1; date = cal.date(from: c) }
        else { date = cal.date(from: c) }
        removeMatch(m)
    }

    if let re = try? NSRegularExpression(pattern: "(今天|明天|后天|大后天)"),
       let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
        let s = (text as NSString).substring(with: m.range(at: 1))
        let off = ["今天":0,"明天":1,"后天":2,"大后天":3][s] ?? 0
        let base = cal.date(byAdding: .day, value: off, to: now)!
        if let d = date {
            var c = cal.dateComponents([.hour,.minute], from: d)
            c.year = cal.component(.year, from: base); c.month = cal.component(.month, from: base); c.day = cal.component(.day, from: base)
            date = cal.date(from: c)
        } else { date = base }
        if let e = endDate {
            var c = cal.dateComponents([.hour,.minute], from: e)
            c.year = cal.component(.year, from: base); c.month = cal.component(.month, from: base); c.day = cal.component(.day, from: base)
            endDate = cal.date(from: c)
        }
        removeMatch(m)
    }

    // 星期（含"下/上/这/本"前缀）
    if let re = try? NSRegularExpression(pattern: "(下|上|这|本)?\\s*(?:周|星期)([一二三四五六日天])"),
       let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
        let gW = { (i: Int) -> String in
            m.range(at: i).location != NSNotFound ? (text as NSString).substring(with: m.range(at: i)) : ""
        }
        let prefix = gW(1)
        let dm = ["一":2,"二":3,"三":4,"四":5,"五":6,"六":7,"日":1,"天":1]
        if let t = dm[gW(2)] {
            var diff = t - cal.component(.weekday, from: now); if diff <= 0 { diff += 7 }
            switch prefix { case "下": diff += 7; case "上": diff -= 7; default: break }
            let base = cal.date(byAdding: .day, value: diff, to: now)!
            if let d = date {
                var c = cal.dateComponents([.hour,.minute], from: d)
                c.year = cal.component(.year, from: base); c.month = cal.component(.month, from: base); c.day = cal.component(.day, from: base)
                date = cal.date(from: c)
            } else { date = base }
        }
        removeMatch(m)
    }

    // 单个时间
    if endDate == nil {
        if let re = try? NSRegularExpression(pattern: "(上午|下午|晚上|中午|早上|凌晨)?\\s*(\\d{1,2})[:：点时](\\d{1,2}|半)?[分]?"),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            let gS = { (i: Int) -> String in
                m.range(at: i).location != NSNotFound ? (text as NSString).substring(with: m.range(at: i)) : ""
            }
            let per = gS(1); var h = Int(gS(2)) ?? 0
            let ms = gS(3); let mi = ms == "半" ? 30 : (Int(ms) ?? 0)
            switch per { case "下午","晚上": if h < 12 { h += 12 }; case "中午": if h < 11 { h = 12 }; default: break }
            var c = cal.dateComponents([.year,.month,.day], from: date ?? now)
            c.hour = h; c.minute = mi; date = cal.date(from: c)
            removeMatch(m)
        }
    }

    // 地点
    let locPatterns = [
        "(?:地点[:：]?在?|地址[:：]?在?|在|到)\\s*([^，。！？、；;\\s]{2,}(?:教室|会议室|实验室|图书馆|办公室|自习室|机房|报告厅|活动中心|体育馆|操场|大楼))",
        "(?:地点[:：]?在?|地址[:：]?在?|在|到)\\s*([^，。！？、；;]{2,15})",
        "([^，。！？、；;\\s]{2,}(?:教室|会议室|实验室|图书馆|办公室|自习室|机房|报告厅))"
    ]
    for p in locPatterns {
        if let re = try? NSRegularExpression(pattern: p),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            let locRaw = m.range(at: 1).location != NSNotFound ? (text as NSString).substring(with: m.range(at: 1)) : ""
            location = locRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            removeMatch(m)
            break
        }
    }

    text = text.replacingOccurrences(of: "[，。、；;：:.,!?！？（）()【】\\[\\]「」『』]", with: " ", options: .regularExpression)
    text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in ["任务是", "任务:", "任务：", "要做", "需要", "记得"] {
        if text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)) }
    }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { text = input.trimmingCharacters(in: .whitespacesAndNewlines) }

    return TodoItem(title: text, date: date, endDate: endDate, location: location)
}

// ==================== 自定义行视图（整行背景色） ====================
class ColoredRowView: NSTableRowView {
    var bgColor: NSColor?
    override func draw(_ dirtyRect: NSRect) {
        if let color = bgColor {
            color.setFill()
            dirtyRect.fill()
        }
        super.draw(dirtyRect)
    }
}

// ==================== 虚线分隔表格 ====================
class DashedTableView: NSTableView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1.0)
        context.setLineDash(phase: 0, lengths: [3, 3])
        for i in 1..<numberOfColumns {
            let colRect = rect(ofColumn: i)
            let x = colRect.minX
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: bounds.height))
            context.strokePath()
        }
        context.restoreGState()
    }
}

// ==================== 主视图 ====================
class ViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let store = TodoStore.shared
    var selectedIDs = Set<UUID>()
    var tableView = DashedTableView()
    var scrollView = NSScrollView()
    var inputField = NSTextField()
    var statusLabel = NSTextField(labelWithString: "")
    var trashButton = NSButton(title: "删除", target: nil, action: nil)
    var dateLabel = NSTextField(labelWithString: "")
    let timeFmt = DateFormatter()
    let dayFmt = DateFormatter()

    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 540)) }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 监听便笺勾选 → 同步表格
        NotificationCenter.default.addObserver(forName: NSNotification.Name("taskToggledFromNote"), object: nil, queue: .main) { [weak self] _ in
            self?.tableView.reloadData()
            self?.updateStatus()
        }
        // 监听便笺悬停 → 刷新内容
        NotificationCenter.default.addObserver(forName: NSNotification.Name("noteHoverRefresh"), object: nil, queue: .main) { [weak self] notif in
            let isToday = notif.object as? Bool ?? true
            if isToday { self?.generateTodayNote() }
            else { self?.refreshVisibleNotes() }
        }
        super.viewDidLoad()
        timeFmt.dateFormat = "HH:mm"; dayFmt.dateFormat = "MM-dd"
        setupUI()
        updateDateLabel()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.updateDateLabel()
        }
        startReminderTimer()
    }

    func updateDateLabel() {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy年M月d日 "
        let weekday = DateFormatter(); weekday.dateFormat = "EEEE"
        weekday.locale = Locale(identifier: "zh_CN")
        dateLabel.stringValue = fmt.string(from: Date()) + weekday.string(from: Date())
    }

    func setupUI() {
        // 智能输入行 + 日期
        let icon = NSTextField(labelWithString: "⚡"); icon.font = NSFont.systemFont(ofSize: 14)
        inputField = NSTextField()
        inputField.placeholderString = "粘贴通知文本…  例: 8:30考试, 地点在数字化大楼317机房"
        inputField.font = NSFont.systemFont(ofSize: 13)
        inputField.target = self; inputField.action = #selector(parseAction)

        let parseBtn = NSButton(title: "解析", target: self, action: #selector(parseAction))
        parseBtn.bezelStyle = NSButton.BezelStyle.rounded
        parseBtn.keyEquivalent = "\r"

        dateLabel.font = NSFont.systemFont(ofSize: 12)
        dateLabel.textColor = NSColor.secondaryLabelColor
        dateLabel.alignment = NSTextAlignment.right

        let inputRow = NSStackView(views: [icon, inputField, parseBtn, dateLabel])
        inputRow.orientation = NSUserInterfaceLayoutOrientation.horizontal
        inputRow.spacing = 8
        inputRow.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        // 表格列: ★ | ☐ | 任务 | 时间 | 倒数 | 地点 | 备注
        let colDefs: [(String, String, CGFloat, Bool)] = [
            ("star", "★", 30, false), ("check", "", 32, false),
            ("title", "任务", 180, true), ("date", "时间", 110, true),
            ("countdown", "倒数", 75, false), ("loc", "地点", 120, true),
            ("notes", "备注", 110, true)
        ]
        for (id, title, w, editable) in colDefs {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title; c.width = w; c.isEditable = editable
            tableView.addTableColumn(c)
        }
        tableView.dataSource = self; tableView.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnSelection = false
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = 38
        
        tableView.intercellSpacing = NSSize(width: 0, height: 0)

        scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = NSBorderType.bezelBorder

        // 底部
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = NSColor.secondaryLabelColor

        let selBtn = NSButton(title: "全选", target: self, action: #selector(selectAllAction))

        selBtn.bezelStyle = NSButton.BezelStyle.smallSquare; selBtn.font = NSFont.systemFont(ofSize: 11)
        let clrBtn = NSButton(title: "清除已完成", target: self, action: #selector(clearDone))
        clrBtn.bezelStyle = NSButton.BezelStyle.smallSquare; clrBtn.font = NSFont.systemFont(ofSize: 11)
        let expBtn = NSButton(title: "导出 Markdown", target: self, action: #selector(exportAction))
        expBtn.bezelStyle = NSButton.BezelStyle.rounded; expBtn.font = NSFont.systemFont(ofSize: 11)
        let refreshBtn = NSButton(title: "⟳ 刷新", target: self, action: #selector(refreshAction))
        refreshBtn.bezelStyle = NSButton.BezelStyle.rounded; refreshBtn.font = NSFont.systemFont(ofSize: 11)
        let settingsBtn = NSButton(title: "⚙ 设置", target: self, action: #selector(openSettings))
        settingsBtn.bezelStyle = NSButton.BezelStyle.rounded; settingsBtn.font = NSFont.systemFont(ofSize: 11)
        let addBtn = NSButton(title: "+ 添加", target: self, action: #selector(addAction))
        addBtn.bezelStyle = NSButton.BezelStyle.rounded; addBtn.font = NSFont.systemFont(ofSize: 11)
        addBtn.keyEquivalent = "n"

        // 便笺按钮已移至各分区表头
        trashButton.bezelStyle = NSButton.BezelStyle.rounded
        trashButton.font = NSFont.systemFont(ofSize: 11)
        trashButton.target = self; trashButton.action = #selector(trashClicked)
        let toolbar = NSStackView(views: [trashButton, statusLabel, NSView(), selBtn, clrBtn, expBtn, refreshBtn, settingsBtn, addBtn])
        toolbar.orientation = NSUserInterfaceLayoutOrientation.horizontal
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        let sep1 = NSBox(); sep1.boxType = NSBox.BoxType.separator
        let sep2 = NSBox(); sep2.boxType = NSBox.BoxType.separator

        let main = NSStackView(views: [inputRow, sep1, scrollView, sep2, toolbar])
        main.orientation = NSUserInterfaceLayoutOrientation.vertical
        main.spacing = 0; main.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(main)
        NSLayoutConstraint.activate([
            main.topAnchor.constraint(equalTo: view.topAnchor),
            main.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            main.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            main.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            dateLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])
        setupContextMenu()
        updateStatus()
    }

    // MARK: - 整行背景色
    func tableView(_ tv: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        // 分区表头：全宽行视图
        guard row < displayRows.count else { return nil }
        if case .sectionHeader(let title, let isToday) = displayRows[row] {
            let rv = NSTableRowView()
            rv.wantsLayer = true
            rv.layer?.backgroundColor = NSColor(white: 0.92, alpha: 1.0).cgColor

            let header = SectionHeaderView(title: title, showProgress: isToday)
            header.frame = rv.bounds
            header.autoresizingMask = [.width, .height]
            header.setExpanded(isToday ? !store.todayCollapsed : !store.longTermCollapsed)
            if isToday {
                header.setNoteButtonTitle("📅 今日便笺")
                header.onToggle = { [weak self] in
                    self?.store.todayCollapsed.toggle()
                    self?.tableView.reloadData()
                }
                header.onNoteClick = { [weak self] in
                    self?.generateTodayNote()
                }
                header.onRollClick = { [weak self] in
                    self?.rollRandomTask()
                }
            } else {
                header.setNoteButtonTitle("📝 长期便笺")
                header.hideRollButton()
                header.onToggle = { [weak self] in
                    self?.store.longTermCollapsed.toggle()
                    self?.tableView.reloadData()
                }
                header.onNoteClick = { [weak self] in
                    self?.generateMemoNote()
                }
            }
            rv.addSubview(header)
            return rv
        }
        let rv = ColoredRowView()
        if row < displayRows.count {
            rv.bgColor = store.urgencyColor(for: taskForRow(row) ?? TodoItem(title: ""))
        }
        return rv
    }

    // MARK: - 垂直居中单元格
    func centeredCell(_ tf: NSTextField, bg: NSColor? = nil) -> NSView {
        let container = NSView()
        tf.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tf)
        NSLayoutConstraint.activate([
            tf.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            tf.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -4)
        ])
        return container
    }

    func centeredView(_ v: NSView, bg: NSColor? = nil) -> NSView {
        let container = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)
        NSLayoutConstraint.activate([
            v.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            v.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    // MARK: - 随机任务池
    let randomTasks = [
        "喝一杯水", "做10个俯卧撑", "站起来伸展一下", "闭眼休息1分钟",
        "整理桌面", "回复一条消息", "背5个单词", "做一页题目",
        "复习一个知识点", "写一行笔记", "喝杯茶或咖啡", "看看窗外远处",
        "做一次深呼吸", "整理书架", "清理电脑桌面文件", "给手机充上电",
        "倒一杯水", "洗个苹果吃", "做20个深蹲", "拉伸一下肩膀",
        "检查一下待办清单", "整理一下笔记", "给TDM提一个新想法", "记录一个灵感",
        "听一首歌放松", "做一道数学题", "看一段教学视频", "预习明天的内容",
        "复习昨天的笔记", "写今日小结", "规划一下明天", "清空回收站",
        "整理下载文件夹", "给植物浇浇水", "做一次眼保健操", "按摩一下太阳穴",
        "写下三件感恩的事", "整理书桌抽屉", "检查一下邮箱", "更新一下日历",
        "给电脑清理灰尘", "整理一下耳机线", "准备明天的文具", "看一页闲书",
        "写一段日记", "整理一下照片", "查看一下日程", "把水杯加满",
        "做一次简单的冥想", "站起来走动一下", "给自己一个微笑", "整理一下书签",
        "检查一下闹钟设置", "给朋友发一句问候", "做一道英语阅读", "练一行字",
        "整理一下快捷键记忆", "查看一下内存使用", "看看有什么新邮件", "给电池充充电",
        "看看天空是什么颜色", "想一个有趣的点子", "把椅子调到舒适高度", "检查一下屏幕亮度",
        "换一个舒服的姿势", "打开一扇窗通风", "擦一下屏幕", "整理一下充电线",
        "检查一下软件更新", "做一次肩部环绕", "活动一下手腕", "转一转脖子",
        "揉一揉眼睛", "踮脚30次", "原地踏步1分钟", "写下今天的关键词",
        "想一想周末计划", "看看冰箱里有什么", "把要洗的衣服分类", "整理一下书签栏",
        "清一下浏览器缓存", "给TDM写一个好评", "想想晚饭吃什么", "检查一下饮水量",
        "把手机调成静音", "查看一下步数", "规划一下下午的安排", "想一个新目标",
        "回忆一下昨天学了什么", "把桌面图标排列整齐", "看看日历上有什么安排", "给未来的自己写一句话",
        "尝试一个新姿势学习", "换个背景壁纸", "检查一下云盘同步", "给屏幕截图存档",
        "把重要的事标记一下", "看一段励志视频", "写下本周目标完成度", "给自己一个奖励计划",
        "把窗户关上或者打开", "检查一下夜间模式", "记录一下当前心情", "把闹钟提前5分钟"
    ]

    @objc func rollRandomTask() {
        guard !randomTasks.isEmpty else { return }
        let title = randomTasks.randomElement()!
        let now = Date()
        let cal = Calendar.current
        // 随机时间：当前时间之后，分钟为15的整数倍
        let currentMinute = cal.component(.minute, from: now)
        let nextQuarter = ((currentMinute / 15) + 1) * 15
        let maxMinutes = 24 * 60 - cal.component(.hour, from: now) * 60 - currentMinute
        let quarters = max(1, maxMinutes / 15)
        let randomQuarter = Int.random(in: 0..<quarters)
        let totalMinutes = nextQuarter + randomQuarter * 15
        var c = cal.dateComponents([.year, .month, .day], from: now)
        c.hour = cal.component(.hour, from: now) + totalMinutes / 60
        c.minute = totalMinutes % 60
        let taskDate = cal.date(from: c) ?? now
        let item = TodoItem(title: title, date: taskDate, endDate: nil, location: nil, notes: "")
        store.add(item)
        SoundFX.shared.rollTask()
        tableView.reloadData(); updateStatus()
    }

    // MARK: - 分区显示模型
    enum DisplayRow {
        case sectionHeader(title: String, isToday: Bool)
        case task(TodoItem)
    }

    var displayRows: [DisplayRow] {
        var rows: [DisplayRow] = []
        rows.append(.sectionHeader(title: "📋 今日待办", isToday: true))
        if !store.todayCollapsed {
            for item in store.todayItems { rows.append(.task(item)) }
        }
        rows.append(.sectionHeader(title: "📁 长期待办", isToday: false))
        if !store.longTermCollapsed {
            for item in store.longTermItems { rows.append(.task(item)) }
        }
        return rows
    }

    func itemFor(_ row: Int) -> TodoItem {
        if case .task(let item) = displayRows[row] { return item }
        return TodoItem(title: "")
    }

    func taskForRow(_ row: Int) -> TodoItem? {
        guard row < displayRows.count else { return nil }
        if case .task(let item) = displayRows[row] { return item }
        return nil
    }

    // MARK: - 数据源
    func numberOfRows(in tv: NSTableView) -> Int { displayRows.count }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        guard row < displayRows.count else { return nil }
        let displayRow = displayRows[row]

        // 分区表头：由 rowViewForRow 处理，返回 nil 隐藏单元格
        if case .sectionHeader = displayRow {
            return nil
        }

        // 任务行
        guard case .task(let item) = displayRow else { return nil }
        let cid = col?.identifier.rawValue ?? ""
        let bg = store.urgencyColor(for: item)
        let isPast = item.date.map { $0.timeIntervalSinceNow < 0 } ?? false

        func strikethrough(_ s: String, fontSize: CGFloat = 11) -> NSAttributedString {
            return NSAttributedString(string: s, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: NSColor(white: 0.55, alpha: 1.0),
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: NSColor(white: 0.55, alpha: 1.0)
            ])
        }

        switch cid {
        case "star":
            let btn = NSButton(title: item.isStarred ? "★" : "☆", target: self, action: #selector(starToggled(_:)))
            btn.tag = row; btn.bezelStyle = NSButton.BezelStyle.circular
            btn.font = NSFont.systemFont(ofSize: 14)
            btn.isBordered = false
            if item.isStarred { btn.contentTintColor = NSColor.systemPurple }
            return centeredView(btn, bg: bg)

        case "check":
            let btn = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkToggled(_:)))
            btn.tag = row; btn.state = item.isCompleted ? .on : .off
            return centeredView(btn, bg: bg)

        case "title":
            let cell = NSTextField()
            cell.isBezeled = false; cell.isBordered = false; cell.drawsBackground = false
            cell.isEditable = true; cell.focusRingType = NSFocusRingType.none
            if item.isCompleted || isPast {
                cell.attributedStringValue = strikethrough(item.title, fontSize: 13)
            } else {
                cell.stringValue = item.title
                cell.font = NSFont.systemFont(ofSize: 13, weight: item.isStarred ? .semibold : .regular)
            }
            return centeredCell(cell, bg: bg)

        case "date":
            let cell = NSTextField()
            cell.isBezeled = false; cell.isBordered = false; cell.drawsBackground = false
            cell.isEditable = true; cell.focusRingType = NSFocusRingType.none
            var s = ""
            if let d = item.date {
                s = dayFmt.string(from: d) + " " + timeFmt.string(from: d)
                if let e = item.endDate { s += "-" + timeFmt.string(from: e) }
            }
            if isPast { cell.attributedStringValue = strikethrough(s) }
            else {
                cell.stringValue = s; cell.font = NSFont.systemFont(ofSize: 11)
                cell.textColor = NSColor.systemOrange
            }
            return centeredCell(cell, bg: bg)

        case "countdown":
            let cell = NSTextField(labelWithString: store.countdownText(for: item))
            cell.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            cell.alignment = NSTextAlignment.center
            if isPast {
                cell.attributedStringValue = strikethrough(store.countdownText(for: item))
            } else if let d = item.date {
                let days = store.daysUntil(d)
                if days == 0 { cell.textColor = NSColor.systemPurple }
                else if days <= 3 { cell.textColor = NSColor.systemRed }
                else if days <= 7 { cell.textColor = NSColor.systemOrange }
                else { cell.textColor = NSColor.systemBlue }
            }
            return centeredCell(cell, bg: bg)

        case "loc":
            let cell = NSTextField()
            cell.isBezeled = false; cell.isBordered = false; cell.drawsBackground = false
            cell.isEditable = true; cell.focusRingType = NSFocusRingType.none
            if isPast { cell.attributedStringValue = strikethrough(item.location ?? "") }
            else {
                cell.stringValue = item.location ?? ""
                cell.font = NSFont.systemFont(ofSize: 11); cell.textColor = NSColor.systemBlue
            }
            return centeredCell(cell, bg: bg)

        case "notes":
            let cell = NSTextField()
            cell.isBezeled = false; cell.isBordered = false; cell.drawsBackground = false
            cell.isEditable = true; cell.focusRingType = NSFocusRingType.none
            if isPast { cell.attributedStringValue = strikethrough(item.notes) }
            else {
                cell.stringValue = item.notes
                cell.font = NSFont.systemFont(ofSize: 11); cell.textColor = NSColor.systemGray
            }
            return centeredCell(cell, bg: bg)

        default: return nil
        }
    }

    func tableView(_ tv: NSTableView, shouldEdit col: NSTableColumn?, row: Int) -> Bool {
        return col?.identifier.rawValue != "check" && col?.identifier.rawValue != "star" && col?.identifier.rawValue != "countdown"
    }

    func tableView(_ tv: NSTableView, setObjectValue obj: Any?, for col: NSTableColumn?, row: Int) {
        guard row < displayRows.count, let cid = col?.identifier.rawValue, let val = obj as? String else { return }
        var item = itemFor(row)
        switch cid {
        case "title": item.title = val
        case "loc": item.location = val.isEmpty ? nil : val
        case "notes": item.notes = val
        case "date":
            let p = DateFormatter(); p.dateFormat = "HH:mm"
            if let d = p.date(from: val) {
                var c = Calendar.current.dateComponents([.year,.month,.day], from: item.date ?? Date())
                c.hour = Calendar.current.component(.hour, from: d)
                c.minute = Calendar.current.component(.minute, from: d)
                item.date = Calendar.current.date(from: c)
            }
        default: break
        }
        store.update(item)
    }

    // MARK: - 右键菜单（NSMenuDelegate 动态构建）
    func setupContextMenu() {
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        let col = tableView.clickedColumn
        guard row >= 0, row < displayRows.count, col >= 0, col < tableView.tableColumns.count else { return }
        tableView.selectRowIndexes(IndexSet([row]), byExtendingSelection: false)
        let cid = tableView.tableColumns[col].identifier.rawValue

        func addItem(_ title: String, _ sel: Selector) {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }

        switch cid {
        case "star":
            addItem(itemFor(row).isStarred ? "取消星标" : "标星", #selector(starToggledFromMenu))
        case "check":
            addItem(itemFor(row).isCompleted ? "标记未完成" : "标记完成", #selector(checkToggledFromMenu))
        case "title": addItem("编辑任务", #selector(editTitle))
        case "date": addItem("编辑时间", #selector(editDate))
        case "countdown":
            addItem(store.showDetailedCountdown ? "显示天数" : "显示精确时间", #selector(toggleCountdownMode))
        case "loc": addItem("编辑地点", #selector(editLocation))
        case "notes": addItem("编辑备注", #selector(editNotes))
        default: break
        }

        menu.addItem(.separator())
        addItem("删除此项", #selector(deleteClickedRow))
    }

    func tableView(_ tv: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        guard row < displayRows.count else { return }
        let item = itemFor(row)
        rowView.wantsLayer = true
        if let bg = store.urgencyColor(for: item) {
            rowView.layer?.backgroundColor = bg.cgColor
        } else {
            rowView.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        selectedIDs = Set(tableView.selectedRowIndexes.compactMap {
            $0 < displayRows.count ? itemFor($0).id : nil
        })
        updateStatus()
    }

    // MARK: - 编辑
    @objc func editTitle() { editField("任务", .title) }
    @objc func editDate() { editField("时间", .date) }
    @objc func editLocation() { editField("地点", .loc) }
    @objc func editNotes() { editField("备注", .notes) }

    enum EditCol { case title, date, loc, notes }

    func editField(_ label: String, _ col: EditCol) {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0 && row < displayRows.count else { return }
        let item = itemFor(row)
        var current = ""
        switch col {
        case .title: current = item.title
        case .loc: current = item.location ?? ""
        case .notes: current = item.notes
        case .date:
            if let d = item.date {
                current = timeFmt.string(from: d)
                if let e = item.endDate { current += "-" + timeFmt.string(from: e) }
            }
        }
        let alert = NSAlert(); alert.messageText = "编辑\(label)"
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        f.stringValue = current; alert.accessoryView = f
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == NSApplication.ModalResponse.alertFirstButtonReturn {
            let val = f.stringValue
            var item = itemFor(row)
            switch col {
            case .title: item.title = val
            case .loc: item.location = val.isEmpty ? nil : val
            case .notes: item.notes = val
            case .date:
                let p = DateFormatter(); p.dateFormat = "HH:mm"
                if let d = p.date(from: val) {
                    var c = Calendar.current.dateComponents([.year,.month,.day], from: item.date ?? Date())
                    c.hour = Calendar.current.component(.hour, from: d)
                    c.minute = Calendar.current.component(.minute, from: d)
                    item.date = Calendar.current.date(from: c)
                }
            }
            store.update(item); tableView.reloadData()
        }
    }

    // MARK: - 动作
    @objc func starToggled(_ sender: NSButton) {
        SoundFX.shared.starToggle()
        let row = sender.tag
        if row < displayRows.count { store.toggleStar(itemFor(row).id); tableView.reloadData() }
    }

    @objc func starToggledFromMenu() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0 && row < displayRows.count else { return }
        store.toggleStar(itemFor(row).id); tableView.reloadData()
    }

    @objc func checkToggled(_ sender: NSButton) {
        let row = sender.tag
        if row < displayRows.count { store.toggle(itemFor(row).id); tableView.reloadData(); refreshVisibleNotes(); SoundFX.shared.taskComplete() }
    }

    @objc func checkToggledFromMenu() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0 && row < displayRows.count else { return }
        store.toggle(itemFor(row).id); tableView.reloadData(); refreshVisibleNotes()
    }

    @objc func toggleCountdownMode() {
SoundFX.shared.buttonTap()
        store.showDetailedCountdown.toggle(); tableView.reloadData()
    }

    @objc func deleteClickedRow() {
        SoundFX.shared.taskDelete()
        let row = tableView.clickedRow
        if row >= 0 && row < displayRows.count {
            store.delete([itemFor(row).id]); refreshVisibleNotes()
        } else {
            store.delete(selectedIDs)
        }
        tableView.reloadData(); updateStatus()
    }

    @objc func parseAction() {
SoundFX.shared.buttonTap()
        let text = inputField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        store.add(parseSmartInput(text))
        inputField.stringValue = ""
        tableView.reloadData(); updateStatus()
    }

    @objc func addAction() {
        SoundFX.shared.noteCreate()
        let alert = NSAlert(); alert.messageText = "添加待办事项"
        alert.addButton(withTitle: "添加"); alert.addButton(withTitle: "取消")

        let formView = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 260))

        func makeLabel(_ text: String, _ y: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.frame = NSRect(x: 0, y: y, width: 80, height: 20)
            l.font = NSFont.systemFont(ofSize: 11)
            l.textColor = NSColor.secondaryLabelColor
            return l
        }

        let titleLabel = makeLabel("任务名称:", 230)
        let titleField = NSTextField(frame: NSRect(x: 85, y: 228, width: 255, height: 24))
        titleField.placeholderString = "必填"

        let startLabel = makeLabel("开始时间:", 198)
        let datePicker = NSDatePicker(frame: NSRect(x: 85, y: 195, width: 255, height: 24))
        datePicker.datePickerStyle = NSDatePicker.Style.textFieldAndStepper
        datePicker.datePickerElements = [.yearMonthDay, .hourMinute]
        datePicker.dateValue = Date()

        let endLabel = makeLabel("结束时间:", 166)
        let endPicker = NSDatePicker(frame: NSRect(x: 85, y: 163, width: 255, height: 24))
        endPicker.datePickerStyle = NSDatePicker.Style.textFieldAndStepper
        endPicker.datePickerElements = [.hourMinute]

        let locLabel = makeLabel("地点:", 131)
        let locField = NSTextField(frame: NSRect(x: 85, y: 128, width: 255, height: 24))
        locField.placeholderString = "选填"

        let notesLabel = makeLabel("备注:", 96)
        let notesField = NSTextField(frame: NSRect(x: 85, y: 93, width: 255, height: 24))
        notesField.placeholderString = "选填"

        let starCheck = NSButton(checkboxWithTitle: "⭐ 星标", target: nil, action: nil)
        starCheck.frame = NSRect(x: 85, y: 60, width: 120, height: 24)

        let todayCheck = NSButton(checkboxWithTitle: "📅 加入今日待办", target: nil, action: nil)
        todayCheck.frame = NSRect(x: 85, y: 30, width: 160, height: 24)

        for v in [titleLabel, titleField, startLabel, datePicker, endLabel, endPicker,
                  locLabel, locField, notesLabel, notesField, starCheck, todayCheck] {
            formView.addSubview(v)
        }
        alert.accessoryView = formView

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == NSApplication.ModalResponse.alertFirstButtonReturn {
            let t = titleField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return }
            let l = locField.stringValue.trimmingCharacters(in: .whitespaces)
            let n = notesField.stringValue.trimmingCharacters(in: .whitespaces)
            var date = datePicker.dateValue
            if todayCheck.state == .on {
                let cal = Calendar.current
                var c = cal.dateComponents([.year, .month, .day], from: Date())
                let timeC = cal.dateComponents([.hour, .minute], from: date)
                c.hour = timeC.hour; c.minute = timeC.minute
                if let d = cal.date(from: c) { date = d }
            }
            let endComps = Calendar.current.dateComponents([.hour, .minute], from: endPicker.dateValue)
            var end: Date? = nil
            if endComps.hour != 0 || endComps.minute != 0 {
                var c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                c.hour = endComps.hour; c.minute = endComps.minute
                end = Calendar.current.date(from: c)
            }
            let starred = starCheck.state == .on
            let item = TodoItem(title: t, date: date, endDate: end,
                                location: l.isEmpty ? nil : l, notes: n, isStarred: starred)
            store.add(item)
            tableView.reloadData(); updateStatus()
        }
    }

    @objc func selectAllAction() {
SoundFX.shared.buttonTap()
        if selectedIDs.count >= store.items.count { tableView.deselectAll(nil) }
        else { tableView.selectAll(nil) }
    }

    @objc func clearDone() {
        SoundFX.shared.taskDelete()
        let done = Set(store.items.filter { $0.isCompleted }.map { $0.id })
        store.delete(done); tableView.reloadData(); updateStatus(); refreshVisibleNotes()
    }

    @objc func trashClicked() {
        guard !selectedIDs.isEmpty else {
            SoundFX.shared.alertShow(); let a = NSAlert(); a.messageText = "请先选中要删除的表项"; a.runModal(); return
        }
        SoundFX.shared.alertShow(); let a = NSAlert(); a.messageText = "确认删除"
        a.informativeText = "将删除选中的 \(selectedIDs.count) 个表项，此操作不可撤销。"
        a.addButton(withTitle: "删除"); a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn {
            store.delete(selectedIDs)
            selectedIDs.removeAll()
            tableView.reloadData(); updateStatus()
            refreshVisibleNotes()
            SoundFX.shared.taskDelete()
        }
    }

    func refreshVisibleNotes() {
        let sm = StickyNoteManager.shared
        // 只刷新展开中的便笺，折叠的不动
        if let tp = sm.todayPanel,
           let nv = tp.contentView?.subviews.first(where: { $0 is StickyNoteView }) as? StickyNoteView,
           !nv.isCollapsedState {
            generateTodayNote()
        }
        if let mp = sm.memoPanel,
           let mnv = mp.contentView?.subviews.first(where: { $0 is StickyNoteView }) as? StickyNoteView,
           !mnv.isCollapsedState {
            // 用便笺中已有的 ID 刷新，不依赖表格选中
            let memoIDs = sm.taskIDs
            if !memoIDs.isEmpty {
                let items = store.longTermItems.filter { memoIDs.contains($0.id) }
                if !items.isEmpty {
                    var blocks: [(String, String, String, String, String, NSColor, Int, Bool, UUID?)] = []
                    for item in items {
                        var timeStr = ""
                        if let d = item.date {
                            timeStr = dayFmt.string(from: d) + " " + timeFmt.string(from: d)
                            if let e = item.endDate { timeStr += "-" + timeFmt.string(from: e) }
                        }
                        var countdownStr = ""
                        if let d = item.date {
                            let cal = Calendar.current
                            let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: d)).day ?? 0
                            if days < 0 { countdownStr = "已过期" }
                            else if days == 0 { countdownStr = "今天" }
                            else if days == 1 { countdownStr = "明天" }
                            else { countdownStr = "\(days)天后" }
                        }
                        let color = store.urgencyColor(for: item) ?? NSColor.systemGray
                        let pri = colorPriority(for: item)
                        blocks.append((item.title, timeStr, countdownStr, item.location ?? "", item.notes, color, pri, item.isCompleted, item.id))
                    }
                    sm.updateMemoNote(tasks: blocks, ids: memoIDs)
                }
            }
        }
    }

    @objc func refreshAction() {
        SoundFX.shared.refreshDone()
        store.reload()
        tableView.reloadData()
        updateStatus()
        // 刷新便笺：重新生成内容
        let sm = StickyNoteManager.shared
        for panel in [sm.memoPanel, sm.todayPanel].compactMap({ $0 }) {
            guard let noteView = panel.contentView?.subviews.first(where: { $0 is StickyNoteView }) as? StickyNoteView else { continue }
            let ids = sm.taskIDs
            let items = store.items.filter { ids.contains($0.id) }
            var blocks: [(String, String, String, String, String, NSColor, Int, Bool, UUID?)] = []
            for item in items {
                var timeStr = ""
                if let d = item.date {
                    timeStr = dayFmt.string(from: d) + " " + timeFmt.string(from: d)
                    if let e = item.endDate { timeStr += "-" + timeFmt.string(from: e) }
                }
                var countdownStr = ""
                if let d = item.date {
                    let cal = Calendar.current
                    let a = cal.startOfDay(for: Date())
                    let b = cal.startOfDay(for: d)
                    let days = cal.dateComponents([.day], from: a, to: b).day ?? 0
                    if days == 0 {
                        let interval = d.timeIntervalSince(Date())
                        if interval < 0 { countdownStr = "已过期" }
                        else {
                            let h = Int(interval) / 3600
                            let m = (Int(interval) % 3600) / 60
                            countdownStr = h > 0 ? "今天·\(h)时\(m)分" : "今天·\(m)分"
                        }
                    } else if days == 1 { countdownStr = "明天" }
                    else if days > 0 { countdownStr = "\(days)天后" }
                    else { countdownStr = "已过\(-days)天" }
                }
                let color = store.urgencyColor(for: item) ?? NSColor.systemGray
                let pri = colorPriority(for: item)
                blocks.append((item.title, timeStr, countdownStr, item.location ?? "", item.notes, color, pri, item.isCompleted, item.id))
            }
            noteView.taskBlocks = blocks.sorted { $0.6 < $1.6 }
            noteView.needsDisplay = true
        }
    }

    @objc func openSettings() {
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.showNoteSettings()
        }
    }

    // MARK: - 今日便笺（自动读取所有今日待办）
    func generateTodayNote() {
        let sm = StickyNoteManager.shared
        // 只有当用户选中的项包含今日任务时才按选中过滤
        let todayIDs = Set(store.todayItems.map { $0.id })
        let selectedTodayIDs = selectedIDs.intersection(todayIDs)
        let items: [TodoItem]
        if !selectedTodayIDs.isEmpty {
            items = store.todayItems.filter { selectedTodayIDs.contains($0.id) }
        } else {
            items = store.todayItems
        }
        guard !items.isEmpty else {
            // 今日无任务时关闭便笺，不弹窗
            StickyNoteManager.shared.todayPanel?.close()
            StickyNoteManager.shared.todayPanel = nil
            return
        }
        var blocks: [(String, String, String, String, String, NSColor, Int, Bool, UUID?)] = []
        for item in items {
            let timeStr = item.date.map { timeFmt.string(from: $0) } ?? ""
            let countdownStr: String = {
                guard let d = item.date else { return "" }
                let interval = d.timeIntervalSinceNow
                if interval < 0 { return "未完成" }
                let h = Int(interval) / 3600
                let m = (Int(interval) % 3600) / 60
                return h > 0 ? "\(h)时\(m)分" : "\(m)分钟"
            }()
            let color = item.isCompleted ? NSColor.systemGray :
                (store.urgencyColor(for: item) ?? NSColor.systemGray)
            let pri = item.isCompleted ? 5 : (item.isStarred ? -1 : 0)
            blocks.append((item.title, timeStr, countdownStr, item.location ?? "", item.notes, color, pri, item.isCompleted, item.id))
        }
        sm.updateTodayNote(tasks: blocks)
    }

    // MARK: - 长期便笺（选中项）
    func generateMemoNote() {
        guard !selectedIDs.isEmpty else {
            SoundFX.shared.alertShow(); let a = NSAlert(); a.messageText = "请先选中要加入便笺的待办任务"; a.runModal(); return
        }
        let items = store.longTermItems.filter { selectedIDs.contains($0.id) }
        guard !items.isEmpty else {
            SoundFX.shared.alertShow(); let a = NSAlert(); a.messageText = "所选任务均为今日待办，请用今日便笺"; a.runModal(); return
        }
        // 强制刷新便笺数据
        var blocks: [(String, String, String, String, String, NSColor, Int, Bool, UUID?)] = []
        for item in items {
            var timeStr = ""
            if let d = item.date {
                timeStr = dayFmt.string(from: d) + " " + timeFmt.string(from: d)
                if let e = item.endDate { timeStr += "-" + timeFmt.string(from: e) }
            }
            var countdownStr = ""
            if let d = item.date {
                let cal = Calendar.current
                let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: d)).day ?? 0
                if days < 0 { countdownStr = "已过期" }
                else if days == 0 { countdownStr = "今天" }
                else if days == 1 { countdownStr = "明天" }
                else { countdownStr = "\(days)天后" }
            }
            let color = store.urgencyColor(for: item) ?? NSColor.systemGray
            let pri = colorPriority(for: item)
            blocks.append((item.title, timeStr, countdownStr, item.location ?? "", item.notes, color, pri, item.isCompleted, item.id))
        }
        StickyNoteManager.shared.updateMemoNote(tasks: blocks, ids: Set(items.map { $0.id }))
    }

    // MARK: - 行高（区分表头和任务行）
    func tableView(_ tv: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < displayRows.count else { return 32 }
        if case .sectionHeader = displayRows[row] { return 36 }
        return 32
    }

    // 旧 createStickyNote 已移除，使用 generateTodayNote / generateMemoNote

    func colorPriority(for item: TodoItem) -> Int {
        guard let date = item.date else { return 5 }
        let days = store.daysUntil(date)
        if days < 0 { return 5 }
        if date.timeIntervalSinceNow < 0 { return 5 } // 过期项排最后
        if days == 0 { return 0 }
        if days <= 3 { return 1 }
        if days <= 7 { return 2 }
        if days <= 15 { return 3 }
        return 4
    }

    @objc func exportAction() {
        SoundFX.shared.exportDone()
        guard !selectedIDs.isEmpty else { return }
        let md = store.exportMarkdown(ids: selectedIDs)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "待办事项导出.md"
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == NSApplication.ModalResponse.OK, let url = panel.url {
            try? md.write(to: url, atomically: true, encoding: .utf8)
            let a = NSAlert(); a.messageText = "已导出"; a.runModal()
        }
    }

    // MARK: - 复制粘贴
    func copy(_ sender: Any?) {
        guard !selectedIDs.isEmpty else { return }
        let items = store.items.filter { selectedIDs.contains($0.id) }
        let lines = items.map { item -> String in
            var parts = [item.isStarred ? "⭐" : "", item.title]
            if let d = item.date {
                var t = timeFmt.string(from: d)
                if let e = item.endDate { t += "-" + timeFmt.string(from: e) }
                parts.append(t)
            }
            if let l = item.location { parts.append(l) }
            if !item.notes.isEmpty { parts.append(item.notes) }
            return parts.filter { !$0.isEmpty }.joined(separator: " | ")
        }
        let pb = NSPasteboard.general; pb.clearContents()
        pb.setString(lines.joined(separator: "\n"), forType: .string)
    }

    func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { store.add(parseSmartInput(trimmed)) }
        }
        tableView.reloadData(); updateStatus()
    }

    func updateStatus() {
        statusLabel.stringValue = "已选 \(selectedIDs.count) / 共 \(store.items.count)"
    }

    // MARK: - 提醒
    func startReminderTimer() {
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.checkReminders() }
    }

    func checkReminders() {
        let now = Date()
        for i in store.items.indices {
            guard let d = store.items[i].date, !store.items[i].reminderFired, !store.items[i].isCompleted else { continue }
            if d.timeIntervalSince(now) <= 60 && d.timeIntervalSince(now) > -60 {
                store.items[i].reminderFired = true
                DispatchQueue.main.async {
                    let a = NSAlert(); a.messageText = "⏰ 待办提醒"
                    a.informativeText = self.store.items[i].title
                    if let l = self.store.items[i].location { a.informativeText += "\n📍 \(l)" }
                    a.alertStyle = NSAlert.Style.informational
                    a.addButton(withTitle: "知道了")
                    NSApp.activate(ignoringOtherApps: true); a.runModal()
                }
            }
        }
    }
}

// ==================== 便笺系统 ====================
class ColorPickerHelper: NSObject {
    let sm: StickyNoteManager
    var paletteView: NSView
    var colorWell: NSColorWell
    var swatchButtons: [NSButton] = []

    init(sm: StickyNoteManager, paletteView: NSView, colorWell: NSColorWell) {
        self.sm = sm; self.paletteView = paletteView; self.colorWell = colorWell
        super.init()
    }

    @objc func togglePalette(_ sender: NSButton) {
        paletteView.isHidden = !paletteView.isHidden
        if !paletteView.isHidden {
            // 弹出到 🎨 按钮正右侧
            paletteView.superview?.addSubview(paletteView, positioned: .above, relativeTo: nil)
        }
    }

    @objc func resetDefault(_ sender: NSButton) {
        sm.customNoteColor = nil
        colorWell.color = sm.effectiveNoteBg
        previewBox?.layer?.backgroundColor = sm.effectiveNoteBg.cgColor
        sm.applySettings()
    }

    @objc func showMore(_ sender: NSButton) {
        // 将系统调色盘定位到 📝 按钮正右侧
        let panel = NSColorPanel.shared
        if let win = sender.window {
            let btnFrame = win.frame
            // sender 在屏幕上的位置
            let btnRect = sender.convert(sender.bounds, to: nil)
            let screenRect = win.convertToScreen(btnRect)
            panel.setFrameTopLeftPoint(NSPoint(x: screenRect.maxX + 8, y: screenRect.maxY))
        }
        panel.orderFront(nil)
        colorWell.performClick(nil)
    }

    weak var previewBox: NSButton?

    @objc func swatchClicked(_ sender: NSButton) {
SoundFX.shared.buttonTap()
        let colors = sm.currentPalette
        guard sender.tag < colors.count else { return }
        sm.customNoteColor = colors[sender.tag]
        colorWell.color = colors[sender.tag]
        previewBox?.layer?.backgroundColor = colors[sender.tag].cgColor
        sm.applySettings()
        paletteView.isHidden = true
    }
}

class SoundFX {
    static let shared = SoundFX()
    // 预加载音效池，每个音效 4 个实例轮换，支持快速连续播放
    private var pools: [String: [NSSound]] = [:]
    private var indices: [String: Int] = [:]
    private let poolSize = 4

    init() {
        for name in ["Glass", "Blow", "Pop", "Tink", "Funk", "Purr", "Ping", "Hero", "Bottle", "Frog", "Sosumi", "Submarine"] {
            var instances: [NSSound] = []
            for _ in 0..<poolSize {
                if let s = NSSound(named: NSSound.Name(name)) {
                    s.volume = 0.7
                    instances.append(s)
                }
            }
            pools[name] = instances
            indices[name] = 0
        }
    }

    // 展开音效防抖：冷却时间 = 折叠延时设置
    private var lastExpandTime: TimeInterval = 0
    func noteExpand() {
        let now = Date().timeIntervalSince1970
        let cooldown = StickyNoteManager.shared.collapseDelay
        guard now - lastExpandTime >= cooldown else { return }
        lastExpandTime = now
        play("Purr")
    }

    func play(_ name: String) {
        guard let pool = pools[name], !pool.isEmpty else { return }
        let idx = indices[name] ?? 0
        let sound = pool[idx % pool.count]
        sound.currentTime = 0
        sound.play()
        indices[name] = (idx + 1) % poolSize
    }

    func taskComplete() { play("Glass") }
    func taskDelete() { play("Blow") }
    func noteCreate() { play("Pop") }
    func noteToggle() { play("Ping") }
    func rollTask() { play("Funk") }
    func buttonTap() { play("Bottle") }
    func noteCollapse() { play("Purr") }
    func exportDone() { play("Hero") }
    func refreshDone() { play("Ping") }
    func alertShow() { play("Sosumi") }
    func starToggle() { play("Frog") }
    func headerToggle() { play("Submarine") }
}

class SliderTracker: NSObject {
    let slider: NSSlider
    let label: NSTextField
    let suffix: String
    init(slider: NSSlider, label: NSTextField, suffix: String = "%") {
        self.slider = slider; self.label = label; self.suffix = suffix
        super.init()
        slider.target = self
        slider.action = #selector(changed(_:))
    }
    @objc func changed(_ sender: NSSlider) {
        label.stringValue = String(format: "%.0f\(suffix)", sender.doubleValue * 100)
    }
}

class SectionHeaderView: NSView {
    var onToggle: (() -> Void)?
    var onNoteClick: (() -> Void)?
    private let titleLabel = NSTextField(labelWithString: "")
    private let arrowLabel = NSTextField(labelWithString: "▼")
    private let noteButton = NSButton(title: "📝 便笺", target: nil, action: nil)
    private let rollButton = NSButton(title: "🎲 Roll", target: nil, action: nil)
    private let progressLabel = NSTextField(labelWithString: "")

    init(title: String, showProgress: Bool = false) {
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 36))
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.92, alpha: 1.0).cgColor

        arrowLabel.font = NSFont.systemFont(ofSize: 11)
        arrowLabel.frame = NSRect(x: 8, y: 10, width: 16, height: 16)
        addSubview(arrowLabel)

        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        titleLabel.frame = NSRect(x: 28, y: 10, width: 200, height: 16)
        addSubview(titleLabel)

        if showProgress {
            progressLabel.isHidden = true
        }

        rollButton.bezelStyle = NSButton.BezelStyle.rounded
        rollButton.font = NSFont.systemFont(ofSize: 11)
        rollButton.target = self
        rollButton.action = #selector(rollClicked)
        rollButton.frame = NSRect(x: 370, y: 5, width: 90, height: 26)
        addSubview(rollButton)

        noteButton.bezelStyle = NSButton.BezelStyle.rounded
        noteButton.font = NSFont.systemFont(ofSize: 11)
        noteButton.target = self
        noteButton.action = #selector(noteClicked)
        noteButton.frame = NSRect(x: 465, y: 5, width: 115, height: 26)
        addSubview(noteButton)

        let clickArea = NSButton(frame: NSRect(x: 0, y: 0, width: 510, height: 36))
        clickArea.title = ""
        clickArea.isBordered = false
        clickArea.target = self
        clickArea.action = #selector(headerClicked)
        addSubview(clickArea)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setExpanded(_ expanded: Bool) {
        arrowLabel.stringValue = expanded ? "▼" : "▶"
    }

    func setProgress(_ text: String) {
        progressLabel.stringValue = text
    }

    func hideRollButton() { rollButton.isHidden = true }
    func setNoteButtonTitle(_ title: String) {
        noteButton.title = title
    }

    var onRollClick: (() -> Void)?
    @objc func rollClicked() { onRollClick?() }
    @objc func headerClicked() { SoundFX.shared.headerToggle(); onToggle?() }
    @objc func noteClicked() { SoundFX.shared.noteCreate(); onNoteClick?() }

    override func layout() {
        super.layout()
        let w = bounds.width
        noteButton.frame = NSRect(x: w - 125, y: 5, width: 115, height: 26)
        rollButton.frame = NSRect(x: w - 225, y: 5, width: 90, height: 26)
    }
}

class StickyNoteView: NSView {
    var taskBlocks: [(title: String, time: String, countdown: String, location: String, notes: String, color: NSColor, priority: Int, isCompleted: Bool, itemId: UUID?)] = []
    var fontAlpha: CGFloat = 1.0
    var isCollapsedState: Bool = false
    var isTodayNote: Bool = false
    var onCollapse: (() -> Void)?
    var onExpand: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(t)
    }
    var onTaskToggle: ((UUID?) -> Void)?
    private var checkboxButtons: [NSButton] = []

    override var mouseDownCanMoveWindow: Bool { false }

    private var dragStart: NSPoint = .zero
    private var dragWindowOrigin: NSPoint = .zero

    override func mouseDown(with event: NSEvent) {
        guard let win = window else { return }
        // 开始拖拽（勾选框按钮自行处理点击）
        dragStart = NSEvent.mouseLocation
        dragWindowOrigin = win.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let win = window, let screen = NSScreen.main else { return }
        let cur = NSEvent.mouseLocation
        let dx = cur.x - dragStart.x
        let dy = cur.y - dragStart.y
        var newX = dragWindowOrigin.x + dx
        var newY = dragWindowOrigin.y + dy
        // 约束在屏幕范围内，不允许飞出
        let vis = screen.visibleFrame
        let w = win.frame.width
        let h = win.frame.height
        newX = max(vis.minX, min(newX, vis.maxX - w))
        newY = max(vis.minY, min(newY, vis.maxY - h))
        // 保持原始大小，只移动位置
        win.setFrame(NSRect(x: newX, y: newY, width: w, height: h), display: true)
    }

    func rebuildCheckboxes() {
        checkboxButtons.forEach { $0.removeFromSuperview() }
        checkboxButtons.removeAll()
        var y: CGFloat = bounds.height - 36
        for task in taskBlocks {
            let blockHeight: CGFloat = 22 + (task.time.isEmpty ? 0 : 18) + (task.location.isEmpty ? 0 : 18) + (task.notes.isEmpty ? 0 : 18) + 22
            let btn = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxToggled(_:)))
            btn.frame = NSRect(x: 12, y: y - 17, width: 18, height: 18)
            btn.state = task.isCompleted ? .on : .off
            btn.tag = checkboxButtons.count
            btn.wantsLayer = true
            addSubview(btn)
            checkboxButtons.append(btn)
            y -= blockHeight
        }
    }

    @objc func checkboxToggled(_ sender: NSButton) {
        let idx = sender.tag
        guard idx < taskBlocks.count else { return }
        onTaskToggle?(taskBlocks[idx].itemId)
    }

    override func mouseEntered(with event: NSEvent) {
        // 先刷新内容，再展开
        NotificationCenter.default.post(name: NSNotification.Name("noteHoverRefresh"), object: isTodayNote)
        StickyNoteManager.shared.expandNotePanel(self)
    }
    override func mouseExited(with event: NSEvent) {
        StickyNoteManager.shared.scheduleCollapsePanel(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let sm = StickyNoteManager.shared
        let bgColor = sm.effectiveNoteBg
        // 安全获取亮度：灰度色需先转 sRGB
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        (bgColor.usingColorSpace(.sRGB) ?? bgColor).getRed(&r, green: &g, blue: &b, alpha: &a)
        let bgBrightness = (r + g + b) / 3.0
        let isDarkBg = bgBrightness < 0.5
        let autoTitleColor = isDarkBg ? NSColor.white : NSColor.black
        let autoBodyColor = isDarkBg ? NSColor(white: 0.85, alpha: 1.0) : NSColor(white: 0.25, alpha: 1.0)
        let titleColor = autoTitleColor
        let bodyColor = autoBodyColor
        let noteColor = isDarkBg ? NSColor(white: 0.70, alpha: 1.0) : NSColor(white: 0.35, alpha: 1.0)
        let sepColor = sm.isNightMode ? NSColor(white: 0.35, alpha: 1.0) : NSColor.separatorColor

        bgColor.setFill()
        dirtyRect.fill()

        let noteTitle = isTodayNote ? "📅 ToDo Master Today" : "📋 ToDo Master Memo"

        // 折叠状态：只显示标题
        if isCollapsedState {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: titleColor.withAlphaComponent(fontAlpha)
            ]
            let s = NSAttributedString(string: noteTitle, attributes: attrs)
            s.draw(at: NSPoint(x: 14, y: (bounds.height - 16) / 2))
            return
        }

        // 展开状态：顶部显示标题
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: titleColor.withAlphaComponent(fontAlpha * 0.8)
        ]
        let titleStr = NSAttributedString(string: noteTitle, attributes: titleAttrs)
        titleStr.draw(at: NSPoint(x: 14, y: bounds.height - 24))

        let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 11)
        var y: CGFloat = bounds.height - 36

        for (i, task) in taskBlocks.enumerated() {
            // 勾选框
            let boxRect = NSRect(x: 14, y: y - 15, width: 14, height: 14)
            let boxPath = NSBezierPath(roundedRect: boxRect, xRadius: 3, yRadius: 3)
            boxPath.lineWidth = 1.2
            if task.isCompleted {
                NSColor.systemBlue.withAlphaComponent(0.7).setFill()
                boxPath.fill()
                let checkAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: NSColor.white
                ]
                NSAttributedString(string: "✓", attributes: checkAttrs).draw(at: NSPoint(x: 16, y: y - 15))
            } else {
                titleColor.withAlphaComponent(fontAlpha * 0.5).setStroke()
                boxPath.stroke()
            }

            // 标题
            let titleStr: NSAttributedString
            if task.isCompleted {
                let grayAttrs: [NSAttributedString.Key: Any] = [
                    .font: titleFont,
                    .foregroundColor: NSColor(white: 0.55, alpha: 1.0).withAlphaComponent(fontAlpha),
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: NSColor(white: 0.55, alpha: 1.0)
                ]
                titleStr = NSAttributedString(string: "  " + task.title, attributes: grayAttrs)
            } else {
                let titleAttrs: [NSAttributedString.Key: Any] = [
                    .font: titleFont, .foregroundColor: titleColor.withAlphaComponent(fontAlpha)
                ]
                titleStr = NSAttributedString(string: "  " + task.title, attributes: titleAttrs)
            }
            titleStr.draw(at: NSPoint(x: 32, y: y - 16))
            y -= 22

            // 时间 + 倒数日
            if !task.time.isEmpty {
                var timeStr = "🕐 " + task.time
                if !task.countdown.isEmpty { timeStr += "  ·  " + task.countdown }
                let timeAttrs: [NSAttributedString.Key: Any] = task.isCompleted ? [
                    .font: bodyFont, .foregroundColor: NSColor(white: 0.55, alpha: 1.0).withAlphaComponent(fontAlpha),
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue
                ] : [
                    .font: bodyFont, .foregroundColor: bodyColor.withAlphaComponent(fontAlpha)
                ]
                (NSAttributedString(string: timeStr, attributes: timeAttrs)).draw(at: NSPoint(x: 32, y: y - 14))
                y -= 18
            }

            // 地点
            if !task.location.isEmpty {
                let locAttrs: [NSAttributedString.Key: Any] = [
                    .font: bodyFont, .foregroundColor: bodyColor.withAlphaComponent(fontAlpha)
                ]
                (NSAttributedString(string: "📍 " + task.location, attributes: locAttrs)).draw(at: NSPoint(x: 14, y: y - 14))
                y -= 18
            }

            // 备注
            if !task.notes.isEmpty {
                let noteAttrs: [NSAttributedString.Key: Any] = [
                    .font: bodyFont, .foregroundColor: noteColor.withAlphaComponent(fontAlpha)
                ]
                (NSAttributedString(string: "📝 " + task.notes, attributes: noteAttrs)).draw(at: NSPoint(x: 14, y: y - 14))
                y -= 18
            }

            y -= 8

            // 虚线分隔（最后一项不画）
            if i < taskBlocks.count - 1 {
                let path = NSBezierPath()
                path.lineWidth = 1.0
                let pattern: [CGFloat] = [3, 3]
                path.setLineDash(pattern, count: 2, phase: 0)
                sepColor.setStroke()
                path.move(to: NSPoint(x: 14, y: y))
                path.line(to: NSPoint(x: bounds.width - 14, y: y))
                path.stroke()
                y -= 14
            }
        }
    }
}

class StickyNotePanel: NSPanel {
    // isDockedToNotch 已移除（刘海停靠功能不再使用）

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            // 双击恢复
            self.alphaValue = 1.0
            // isDockedToNotch 已移除
            NotificationCenter.default.post(name: NSNotification.Name("StickyNoteRestored"), object: nil)
            return
        }
        super.mouseDown(with: event)
    }
}

class StickyNoteManager {
    static let shared = StickyNoteManager()
    // 旧 panel/mouseMonitor 属性已移除
    var noteAlpha: CGFloat = 1.0
    var fontAlpha: CGFloat = 1.0
    var showBorder: Bool = true
    var collapseOnMouseLeave: Bool = true
    var collapseDelay: TimeInterval = 1.5
    var collapsedAlpha: CGFloat = 0.5
    var isNightMode: Bool = false
    var noteBgColor: NSColor?
    enum NotePosition: String, CaseIterable {
        case belowIcon = "图标正下方"
        case topLeft = "左上角"
        case topRight = "右上角"
        case bottomLeft = "左下角"
        case bottomRight = "右下角"
        case centerTop = "顶部居中"
    }
    var notePosition: NotePosition = .belowIcon
    var followTheme: Bool = true // 便笺颜色跟随主题
    var followSpaces: Bool = false // 便笺跟随桌面切换（默认不跟随）
    var customNoteColor: NSColor? = nil // 用户自定义色块

    static let lightPalette: [NSColor] = [
        NSColor(red: 0.88, green: 0.88, blue: 0.88, alpha: 1.0), // 浅灰（默认）
        NSColor(red: 0.75, green: 0.85, blue: 0.98, alpha: 1.0), // 浅蓝
        NSColor(red: 0.98, green: 0.95, blue: 0.72, alpha: 1.0), // 浅黄
        NSColor(red: 0.75, green: 0.93, blue: 0.78, alpha: 1.0), // 浅绿
        NSColor(red: 0.97, green: 0.78, blue: 0.78, alpha: 1.0), // 浅红
        NSColor(red: 0.88, green: 0.78, blue: 0.95, alpha: 1.0), // 浅紫
        NSColor(red: 0.98, green: 0.86, blue: 0.72, alpha: 1.0), // 浅橙
        NSColor(red: 0.72, green: 0.93, blue: 0.93, alpha: 1.0)  // 浅青
    ]
    static let darkPalette: [NSColor] = [
        NSColor(red: 0.22, green: 0.22, blue: 0.22, alpha: 1.0), // 深灰（默认）
        NSColor(red: 0.15, green: 0.22, blue: 0.35, alpha: 1.0), // 深蓝
        NSColor(red: 0.32, green: 0.30, blue: 0.12, alpha: 1.0), // 深黄
        NSColor(red: 0.13, green: 0.28, blue: 0.15, alpha: 1.0), // 深绿
        NSColor(red: 0.32, green: 0.15, blue: 0.15, alpha: 1.0), // 深红
        NSColor(red: 0.25, green: 0.15, blue: 0.32, alpha: 1.0), // 深紫
        NSColor(red: 0.32, green: 0.22, blue: 0.10, alpha: 1.0), // 深橙
        NSColor(red: 0.10, green: 0.28, blue: 0.28, alpha: 1.0)  // 深青
    ]

    var currentPalette: [NSColor] {
        (followTheme && isNightMode) ? Self.darkPalette : Self.lightPalette
    }

    var effectiveNoteBg: NSColor {
        customNoteColor ?? noteBgColor ?? currentPalette[0]
    }
    var taskIDs: Set<UUID> = []
    var memoPanel: StickyNotePanel?
    var todayPanel: StickyNotePanel?
    var todayNoteIDs: Set<UUID> = []
    // 旧 collapseTimer 已移除（使用 panelCollapseTimers）
    // 旧 isCollapsed 已移除（使用 StickyNoteView.isCollapsedState）
    // 旧 expandedSize 已移除

    // MARK: - 双便笺系统
    func updateTodayNote(tasks: [(String, String, String, String, String, NSColor, Int, Bool, UUID?)]) {
        if let p = todayPanel,
           let v = p.contentView?.subviews.first(where: { $0 is StickyNoteView }) as? StickyNoteView {
            v.taskBlocks = tasks.sorted { $0.6 < $1.6 }
            v.isCollapsedState = false // 强制展开
            p.alphaValue = noteAlpha
            v.rebuildCheckboxes()
            v.needsDisplay = true
            // 自动调整高度
            var h: CGFloat = 32
            for t in v.taskBlocks {
                h += 22; if !t.1.isEmpty { h += 18 }; if !t.3.isEmpty { h += 18 }; if !t.4.isEmpty { h += 18 }; h += 22
            }
            h = max(h, 80)
            var frame = p.frame; frame.origin.y += frame.height - h; frame.size.height = h
            p.setFrame(frame, display: true)
            v.frame = p.contentView?.bounds ?? v.frame; v.needsDisplay = true
            p.orderFrontRegardless()
        } else {
            createNotePanel(tasks: tasks, isToday: true)
        }
        stackNotes()
    }

    func updateMemoNote(tasks: [(String, String, String, String, String, NSColor, Int, Bool, UUID?)], ids: Set<UUID>) {
        taskIDs = ids
        if let p = memoPanel,
           let v = p.contentView?.subviews.first(where: { $0 is StickyNoteView }) as? StickyNoteView {
            v.taskBlocks = tasks.sorted { $0.6 < $1.6 }
            v.isCollapsedState = false // 强制展开
            p.alphaValue = noteAlpha
            v.rebuildCheckboxes()
            v.needsDisplay = true
            var h: CGFloat = 32
            for t in v.taskBlocks {
                h += 22; if !t.1.isEmpty { h += 18 }; if !t.3.isEmpty { h += 18 }; if !t.4.isEmpty { h += 18 }; h += 22
            }
            h = max(h, 80)
            var frame = p.frame; frame.origin.y += frame.height - h; frame.size.height = h
            p.setFrame(frame, display: true)
            v.frame = p.contentView?.bounds ?? v.frame; v.needsDisplay = true
            p.orderFrontRegardless()
        } else {
            createNotePanel(tasks: tasks, isToday: false)
        }
        stackNotes()
    }

    func createNotePanel(tasks: [(String, String, String, String, String, NSColor, Int, Bool, UUID?)], isToday: Bool) {
        let sorted = tasks.sorted { $0.6 < $1.6 }
        var height: CGFloat = 32
        for t in sorted {
            height += 22; if !t.1.isEmpty { height += 18 }; if !t.3.isEmpty { height += 18 }; if !t.4.isEmpty { height += 18 }; height += 22
        }
        height = max(height, 80)
        let width: CGFloat = 280
        let screen = NSScreen.main ?? NSScreen.screens[0]
        var startX = screen.frame.midX - width / 2
        var startY = screen.frame.maxY - height - 28
        // 按用户设置的位置摆放
        let margin: CGFloat = 20
        let topY = screen.frame.maxY - height - 28
        switch notePosition {
        case .belowIcon:
            if let delegate = NSApp.delegate as? AppDelegate,
               let btn = delegate.statusItem?.button, let btnWin = btn.window {
                startX = btnWin.frame.midX - width / 2
            }
            startY = topY
        case .topLeft:
            startX = margin; startY = topY
        case .topRight:
            startX = screen.frame.maxX - width - margin; startY = topY
        case .bottomLeft:
            startX = margin; startY = margin
        case .bottomRight:
            startX = screen.frame.maxX - width - margin; startY = margin
        case .centerTop:
            startX = screen.frame.midX - width / 2; startY = topY
        }
        // 今日便笺在上，长期便笺在下
        if !isToday, let tp = todayPanel {
            startY = tp.frame.origin.y - height - 4
        }
        let p = StickyNotePanel(
            contentRect: NSRect(x: startX, y: startY, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false
        )
        p.level = NSWindow.Level.floating
        p.isOpaque = false; p.backgroundColor = NSColor.clear
        p.hasShadow = true; p.isMovableByWindowBackground = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = followSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle] : [.fullScreenAuxiliary, .ignoresCycle]

        let noteView = StickyNoteView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        noteView.taskBlocks = sorted
        noteView.fontAlpha = fontAlpha
        noteView.isTodayNote = isToday
        DispatchQueue.main.async { noteView.rebuildCheckboxes() }
        noteView.onTaskToggle = { [weak self] itemId in
            guard let id = itemId else { return }
            TodoStore.shared.toggle(id)
            // 通知主界面刷新
            NotificationCenter.default.post(name: NSNotification.Name("taskToggledFromNote"), object: id)
        }

        let cv = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        cv.wantsLayer = true
        cv.layer?.cornerRadius = 12
        cv.layer?.backgroundColor = effectiveNoteBg.cgColor
        cv.layer?.borderWidth = showBorder ? 1 : 0
        cv.layer?.borderColor = NSColor.separatorColor.cgColor
        noteView.frame = cv.bounds
        noteView.autoresizingMask = [.width, .height]
        cv.addSubview(noteView)

        // ❌ 关闭按钮 + 📌 锁定按钮
        let closeBtn = NSButton(title: "❌", target: self, action: #selector(closeNoteBtnClicked(_:)))
        closeBtn.isBordered = false; closeBtn.font = NSFont.systemFont(ofSize: 10)
        closeBtn.frame = NSRect(x: width - 48, y: height - 22, width: 20, height: 18)
        closeBtn.tag = isToday ? 1 : 0
        closeBtn.wantsLayer = true
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(closeBtn, positioned: .above, relativeTo: noteView)
        NSLayoutConstraint.activate([
            closeBtn.topAnchor.constraint(equalTo: cv.topAnchor, constant: 9),
            closeBtn.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -28),
            closeBtn.widthAnchor.constraint(equalToConstant: 20),
            closeBtn.heightAnchor.constraint(equalToConstant: 18)
        ])

        let pinBtn = NSButton(title: "📌", target: self, action: #selector(pinNoteBtnClicked(_:)))
        pinBtn.isBordered = false; pinBtn.font = NSFont.systemFont(ofSize: 10)
        pinBtn.tag = isToday ? 1 : 0
        pinBtn.wantsLayer = true
        pinBtn.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(pinBtn, positioned: .above, relativeTo: closeBtn)
        NSLayoutConstraint.activate([
            pinBtn.topAnchor.constraint(equalTo: cv.topAnchor, constant: 9),
            pinBtn.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -4),
            pinBtn.widthAnchor.constraint(equalToConstant: 20),
            pinBtn.heightAnchor.constraint(equalToConstant: 18)
        ])

        p.contentView = cv

        if isToday { todayPanel = p } else { memoPanel = p }
        p.orderFrontRegardless()
        SoundFX.shared.noteCreate()
        stackNotes()
        // 立即开始计时折叠（不需要等鼠标经过）
        if let nv = p.contentView?.subviews.first(where: { $0 is StickyNoteView }) as? StickyNoteView {
            let sm = StickyNoteManager.shared
            DispatchQueue.main.async {
                sm.scheduleCollapsePanel(nv)
            }
        }
    }

    @objc func closeNoteBtnClicked(_ sender: NSButton) {
        if sender.tag == 1 { todayPanel?.orderOut(nil) } else { memoPanel?.orderOut(nil) }
        stackNotes()
    }

    var pinnedPanels: Set<ObjectIdentifier> = []

    @objc func pinNoteBtnClicked(_ sender: NSButton) {
        let p: StickyNotePanel? = sender.tag == 1 ? todayPanel : memoPanel
        guard let panel = p else { return }
        let key = ObjectIdentifier(panel)
        if pinnedPanels.contains(key) {
            pinnedPanels.remove(key)
            panel.styleMask.insert(.resizable)
            panel.isMovableByWindowBackground = true
            sender.title = "📌"
        } else {
            pinnedPanels.insert(key)
            panel.styleMask.remove(.resizable)
            panel.isMovableByWindowBackground = false
            sender.title = "📍"
        }
    }

    func repositionNotes() {
        guard let screen = NSScreen.main else { return }
        let margin: CGFloat = 20
        let width: CGFloat = 280
        for (i, p) in [todayPanel, memoPanel].compactMap({ $0 }).enumerated() {
            let h = p.frame.height
            let topY = screen.frame.maxY - h - 28
            var x: CGFloat = screen.frame.midX - width / 2
            var y: CGFloat = topY
            switch notePosition {
            case .belowIcon:
                if let delegate = NSApp.delegate as? AppDelegate,
                   let btn = delegate.statusItem?.button, let btnWin = btn.window {
                    x = btnWin.frame.midX - width / 2
                }
                y = topY
            case .topLeft: x = margin; y = topY
            case .topRight: x = screen.frame.maxX - width - margin; y = topY
            case .bottomLeft: x = margin; y = margin
            case .bottomRight: x = screen.frame.maxX - width - margin; y = margin
            case .centerTop: x = screen.frame.midX - width / 2; y = topY
            }
            // 第二个便笺叠放在第一个下方
            if i > 0, let first = todayPanel {
                y = first.frame.origin.y - h - 4
            }
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }
        stackNotes()
    }

    // MARK: - 智能叠放
    func stackNotes() {
        guard let screen = NSScreen.main else { return }
        let topY = screen.frame.maxY - 28
        var currentY = topY

        // Today 在上，Memo 在下
        if let tp = todayPanel, tp.isVisible {
            var f = tp.frame
            f.origin.y = currentY - f.height
            tp.setFrame(f, display: true)
            currentY = f.origin.y - 4
        }
        if let mp = memoPanel, mp.isVisible {
            var f = mp.frame
            f.origin.y = currentY - f.height
            mp.setFrame(f, display: true)
        }
    }

    func applySettings() {
        // 立即移动现有便笺到设置的位置
        repositionNotes()
        // 应用整体深夜模式
        // 更新双面板
        for p in [memoPanel, todayPanel].compactMap({ $0 }) {
            p.collectionBehavior = followSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle] : [.fullScreenAuxiliary, .ignoresCycle]
            p.alphaValue = noteAlpha
            if let cv = p.contentView {
                cv.wantsLayer = true
                cv.layer?.borderWidth = showBorder ? 1 : 0
                cv.layer?.backgroundColor = effectiveNoteBg.cgColor
                cv.layer?.borderColor = (isNightMode ? NSColor(white: 0.35, alpha: 1.0) : NSColor.separatorColor).cgColor
            }
            if let nv = p.contentView?.subviews.first(where: { $0 is StickyNoteView }) as? StickyNoteView {
                nv.fontAlpha = fontAlpha
                nv.needsDisplay = true
            }
        }
        if isNightMode {
            NSApp.appearance = NSAppearance(named: NSAppearance.Name.darkAqua)
        } else {
            NSApp.appearance = NSAppearance(named: NSAppearance.Name.aqua)
        }
    }

    // 旧全局折叠/展开已移除，使用 per-panel 版本（expandNotePanel/collapseNotePanel）

    var panelCollapseTimers: [ObjectIdentifier: Timer] = [:]

    func expandNotePanel(_ view: StickyNoteView) {
        SoundFX.shared.noteExpand()
        panelCollapseTimers[ObjectIdentifier(view)]?.invalidate()
        panelCollapseTimers[ObjectIdentifier(view)] = nil
        // 找到包含此view的panel
        for p in [memoPanel, todayPanel].compactMap({ $0 }) {
            if let nv = p.contentView?.subviews.first(where: { $0 === view }) as? StickyNoteView,
               nv.isCollapsedState {
                nv.isCollapsedState = false
                nv.needsDisplay = true
                p.alphaValue = noteAlpha
                // 恢复展开大小
                var h: CGFloat = 32
                for t in nv.taskBlocks {
                    h += 22; if !t.1.isEmpty { h += 18 }; if !t.3.isEmpty { h += 18 }; if !t.4.isEmpty { h += 18 }; h += 22
                }
                h = max(h, 80)
                var f = p.frame
                f.origin.y += f.height - h
                f.size.height = h
                p.setFrame(f, display: true, animate: true)
                stackNotes()
            }
        }
    }

    func scheduleCollapsePanel(_ view: StickyNoteView) {
        guard collapseOnMouseLeave else { return }
        panelCollapseTimers[ObjectIdentifier(view)]?.invalidate()
        panelCollapseTimers[ObjectIdentifier(view)] = Timer.scheduledTimer(withTimeInterval: collapseDelay, repeats: false) { [weak self] _ in
            self?.collapseNotePanel(view)
        }
    }

    func collapseNotePanel(_ view: StickyNoteView) {
        for p in [memoPanel, todayPanel].compactMap({ $0 }) {
            if let nv = p.contentView?.subviews.first(where: { $0 === view }) as? StickyNoteView,
               !nv.isCollapsedState {
                nv.isCollapsedState = true
                nv.needsDisplay = true
                p.alphaValue = collapsedAlpha
                let collapsedHeight: CGFloat = 32
                var f = p.frame
                f.origin.y += f.height - collapsedHeight
                f.size.height = collapsedHeight
                p.setFrame(f, display: true, animate: true)
                stackNotes()
            }
        }
    }

    // 旧 scheduleCollapse() 已移除，使用 scheduleCollapsePanel(_:)

    func closeNote() {
        taskIDs = []; todayNoteIDs = []
        memoPanel?.close(); memoPanel = nil
        todayPanel?.close(); todayPanel = nil

    }
}

// ==================== 应用代理 ====================
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        let vc = ViewController()
        window = NSWindow(contentViewController: vc)
        window.title = "ToDoMaster"
        window.setContentSize(NSSize(width: 780, height: 540))
        window.center(); window.tabbingMode = NSWindow.TabbingMode.disallowed
        window.makeKeyAndOrderFront(nil)
        window.delegate = self

        // 状态栏图标
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "ToDoMaster")
            btn.action = #selector(statusItemClicked)
            btn.target = self
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "关于", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu; mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editItem.submenu = editMenu; mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    @objc func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showStatusMenu()
        } else {
            toggleNoteVisibility()
        }
    }

    func toggleNoteVisibility() {
        let sm = StickyNoteManager.shared
        let panels = [sm.memoPanel, sm.todayPanel].compactMap { $0 }
        guard !panels.isEmpty else {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let anyVisible = panels.contains { $0.isVisible }
        if anyVisible {
            panels.forEach { $0.orderOut(nil) }
        } else {
            panels.forEach { $0.orderFrontRegardless() }
            sm.stackNotes()
        }
    }

    func positionNoteBelowStatusItem() {
        let sm = StickyNoteManager.shared
        guard let btn = statusItem.button, let btnWindow = btn.window else { return }
        guard NSScreen.main != nil else { return }
        let btnFrame = btnWindow.frame
        for p in [sm.memoPanel, sm.todayPanel].compactMap({ $0 }) where p.isVisible {
            let x = btnFrame.midX - p.frame.width / 2
            p.setFrameOrigin(NSPoint(x: x, y: p.frame.origin.y))
            p.alphaValue = 1.0
        }
        sm.stackNotes()
    }

    func showStatusMenu() {
        let menu = NSMenu()
        let show = NSMenuItem(title: "显示 TDM", action: #selector(showMainFromStatus), keyEquivalent: "")
        show.target = self; menu.addItem(show)
        let add = NSMenuItem(title: "新增任务", action: #selector(addFromStatus), keyEquivalent: "")
        add.target = self; menu.addItem(add)
        let settings = NSMenuItem(title: "便笺设置", action: #selector(showNoteSettings), keyEquivalent: "")
        settings.target = self; menu.addItem(settings)
        menu.addItem(.separator())
        let del = NSMenuItem(title: "删除便笺", action: #selector(deleteNoteFromStatus), keyEquivalent: "")
        del.target = self; menu.addItem(del)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc func showHelpGuide() {
        let alert = NSAlert()
        alert.messageText = "ToDoMaster 使用说明"
        alert.informativeText = [
            "━━━━━━━━━ 快速入门 ━━━━━━━━━",
            "",
            "【添加任务】",
            "1. 智能解析：顶部输入框粘贴文本，点击\"解析\"自动提取时间、地点、任务",
            "2. 手动添加：点击\"+ 添加\"填写表单，可选加入今日待办",
            "3. 随机任务：今日表头点\"🎲 Roll\"随机生成轻松小任务",
            "",
            "【任务管理】",
            "• 星标：点 ☆ 置顶加粗  · 多选：Cmd+点击  · 编辑：双击或右键",
            "• 删除：选中后点\"删除\"按钮  · 完成：点勾选框，便笺实时同步",
            "• 刷新：点\"⟳ 刷新\"同步表格和便笺数据",
            "",
            "━━━━━━━━━ 今日/长期待办 ━━━━━━━━━",
            "",
            "• 日期为今天的任务自动归入\"今日待办\"，其余在\"长期待办\"",
            "• 过期任务灰色置底，一眼区分",
            "• 点击表头折叠/展开，今日表头显示随机任务按钮",
            "",
            "━━━━━━━━━ 便笺系统 ━━━━━━━━━",
            "",
            "【创建】今日表头\"📅 今日便笺\"自动读取今日任务",
            "     长期表头\"📝 长期便笺\"读取选中任务",
            "",
            "【操作】鼠标移开自动折叠，悬停展开，拖拽移动",
            "     ❌ 关闭  ·  📌 锁定位置和大小",
            "     便笺内勾选框直接标记完成，双向同步",
            "",
            "【双便笺】上下叠放不遮挡，折叠显示",
            "     \"📅 ToDo Master Today\" / \"📋 ToDo Master Memo\"",
            "",
            "【便笺设置】右键状态栏 ☑ → 便笺设置",
            "     · 三个透明度独立调节（便笺/字体/折叠）",
            "     · 🎨 颜色选择：8 种预设 + 自定义调色盘",
            "     · 深夜模式 + 跟随主题变色",
            "     · 便笺位置：图标下方/四角/居中",
            "     · 折叠延时自定义（1~30秒）",
            "",
            "━━━━━━━━━ 其他 ━━━━━━━━━",
            "",
            "• 状态栏 ☑：左键隐藏/显示便笺，右键弹出菜单",
            "• 后台运行：红叉隐藏窗口，Dock 右键退出",
            "• 导出 Markdown：选中任务后点击导出按钮"
        ].joined(separator: "\n")
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc func showNoteSettings() {
        let sm = StickyNoteManager.shared
        let alert = NSAlert(); alert.messageText = "便笺设置"
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")

        let v = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 530))

        // 分组标题和分隔线辅助函数
        func makeSectionHeader(_ text: String, _ y: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.frame = NSRect(x: 0, y: y, width: 300, height: 20)
            l.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            l.textColor = NSColor.secondaryLabelColor
            return l
        }
        func makeSeparator(_ y: CGFloat) -> NSView {
            let s = NSView(frame: NSRect(x: 0, y: y, width: 300, height: 1))
            s.wantsLayer = true
            s.layer?.backgroundColor = NSColor.separatorColor.cgColor
            return s
        }

        // 便笺透明度
        let bgLabel = NSTextField(labelWithString: "便笺透明度:")
        bgLabel.frame = NSRect(x: 0, y: 472, width: 85, height: 22)
        let bgSlider = NSSlider(value: sm.noteAlpha, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)
        bgSlider.frame = NSRect(x: 90, y: 470, width: 160, height: 22)
        let bgVal = NSTextField(labelWithString: String(format: "%.0f%%", sm.noteAlpha * 100))
        bgVal.frame = NSRect(x: 255, y: 472, width: 45, height: 22)
        bgVal.font = NSFont.systemFont(ofSize: 10)
        let bgTracker = SliderTracker(slider: bgSlider, label: bgVal)

        // 字体透明度
        let fontLabel = NSTextField(labelWithString: "字体透明度:")
        fontLabel.frame = NSRect(x: 0, y: 440, width: 85, height: 22)
        let fontSlider = NSSlider(value: sm.fontAlpha, minValue: 0.2, maxValue: 1.0, target: nil, action: nil)
        fontSlider.frame = NSRect(x: 90, y: 438, width: 160, height: 22)
        let fontVal = NSTextField(labelWithString: String(format: "%.0f%%", sm.fontAlpha * 100))
        fontVal.frame = NSRect(x: 255, y: 440, width: 45, height: 22)
        fontVal.font = NSFont.systemFont(ofSize: 10)
        let fontTracker = SliderTracker(slider: fontSlider, label: fontVal)

        // 显示边框
        let borderCheck = NSButton(checkboxWithTitle: "显示便笺边框", target: nil, action: nil)
        borderCheck.frame = NSRect(x: 0, y: 340, width: 200, height: 24)
        borderCheck.state = sm.showBorder ? .on : .off

        // 鼠标移开时折叠
        let collapseCheck = NSButton(checkboxWithTitle: "鼠标移开时折叠", target: nil, action: nil)
        collapseCheck.frame = NSRect(x: 0, y: 308, width: 140, height: 24)
        collapseCheck.state = sm.collapseOnMouseLeave ? .on : .off

        // 折叠延时（可输入数字）
        let delayLabel = NSTextField(labelWithString: "延时(秒):")
        delayLabel.frame = NSRect(x: 145, y: 308, width: 65, height: 22)
        let delayField = NSTextField(frame: NSRect(x: 210, y: 73, width: 55, height: 22))
        delayField.frame = NSRect(x: 210, y: 306, width: 55, height: 22)
        delayField.stringValue = String(format: "%.0f", sm.collapseDelay)
        delayField.font = NSFont.systemFont(ofSize: 11)

        // 折叠后透明度
        let cAlphaLabel = NSTextField(labelWithString: "折叠透明度:")
        cAlphaLabel.frame = NSRect(x: 0, y: 408, width: 85, height: 22)
        let cAlphaSlider = NSSlider(value: sm.collapsedAlpha, minValue: 0.1, maxValue: 1.0, target: nil, action: nil)
        cAlphaSlider.frame = NSRect(x: 90, y: 406, width: 160, height: 22)
        let cAlphaVal = NSTextField(labelWithString: String(format: "%.0f%%", sm.collapsedAlpha * 100))
        cAlphaVal.frame = NSRect(x: 255, y: 408, width: 45, height: 22)
        cAlphaVal.font = NSFont.systemFont(ofSize: 10)
        let cAlphaTracker = SliderTracker(slider: cAlphaSlider, label: cAlphaVal)

        // 便笺颜色（预览框 + 🎨按钮 + 3×3弹出色块）
        let colorLabel = NSTextField(labelWithString: "便笺颜色:")
        colorLabel.frame = NSRect(x: 0, y: 208, width: 85, height: 22)

        // 预览框（展示当前选中颜色，纯展示无功能）
        let clearColor = NSButton(title: "", target: nil, action: nil)
        clearColor.bezelStyle = NSButton.BezelStyle.rounded
        clearColor.wantsLayer = true
        clearColor.layer?.backgroundColor = sm.effectiveNoteBg.cgColor
        clearColor.layer?.cornerRadius = 4
        clearColor.layer?.borderWidth = 1
        clearColor.layer?.borderColor = NSColor.separatorColor.cgColor
        clearColor.frame = NSRect(x: 90, y: 205, width: 26, height: 26)

        // 🎨 弹出按钮
        let swatchBtn = NSButton(title: "🎨", target: nil, action: nil)
        swatchBtn.bezelStyle = NSButton.BezelStyle.rounded
        swatchBtn.font = NSFont.systemFont(ofSize: 14)
        swatchBtn.frame = NSRect(x: 122, y: 205, width: 36, height: 26)

        // 3×3 弹出色块面板（🎨按钮右侧弹出）
        let paletteView = NSView(frame: NSRect(x: 160, y: 210, width: 118, height: 102))
        paletteView.wantsLayer = true
        paletteView.layer?.backgroundColor = NSColor(white: 0.95, alpha: 0.98).cgColor
        paletteView.layer?.cornerRadius = 8
        paletteView.layer?.borderWidth = 1
        paletteView.layer?.borderColor = NSColor.separatorColor.cgColor
        paletteView.isHidden = true
        var swatchButtons: [NSButton] = []
        for i in 0..<8 {
            let row = i / 3
            let col = i % 3
            let b = NSButton(frame: NSRect(x: 8 + CGFloat(col) * 36, y: 68 - CGFloat(row) * 32, width: 30, height: 26))
            b.wantsLayer = true
            b.layer?.backgroundColor = sm.currentPalette[i].cgColor
            b.layer?.cornerRadius = 4
            b.layer?.borderWidth = 1
            b.layer?.borderColor = NSColor.separatorColor.cgColor
            b.bezelStyle = NSButton.BezelStyle.rounded
            b.tag = i
            b.title = ""
            paletteView.addSubview(b)
            swatchButtons.append(b)
        }
        // 第九格：更多颜色
        let moreBtn = NSButton(title: "📝", target: nil, action: nil)
        moreBtn.bezelStyle = NSButton.BezelStyle.rounded
        moreBtn.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        moreBtn.frame = NSRect(x: 80, y: 8, width: 30, height: 26)
        paletteView.addSubview(moreBtn)

        let colorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        colorWell.isHidden = true
        colorWell.color = sm.effectiveNoteBg

        // 跟随桌面开关
        let spacesCheck = NSButton(checkboxWithTitle: "便笺跟随桌面切换", target: nil, action: nil)
        spacesCheck.frame = NSRect(x: 0, y: 144, width: 155, height: 22)
        spacesCheck.state = sm.followSpaces ? .on : .off

        // 跟随主题开关
        let themeCheck = NSButton(checkboxWithTitle: "跟随主题变色", target: nil, action: nil)
        themeCheck.frame = NSRect(x: 0, y: 176, width: 150, height: 22)
        themeCheck.state = sm.followTheme ? .on : .off

        // 深夜模式
        let nightCheck = NSButton(checkboxWithTitle: "深夜模式（应用+便笺全局暗色）", target: nil, action: nil)
        nightCheck.frame = NSRect(x: 0, y: 276, width: 280, height: 24)
        nightCheck.state = sm.isNightMode ? .on : .off

        // 便笺贴边位置
        let posLabel = NSTextField(labelWithString: "便笺位置:")
        posLabel.frame = NSRect(x: 0, y: 76, width: 85, height: 22)
        posLabel.font = NSFont.systemFont(ofSize: 11)
        posLabel.textColor = NSColor.secondaryLabelColor
        let posPopup = NSPopUpButton(frame: NSRect(x: 90, y: 73, width: 150, height: 24))
        for pos in StickyNoteManager.NotePosition.allCases {
            posPopup.addItem(withTitle: pos.rawValue)
        }
        posPopup.selectItem(withTitle: sm.notePosition.rawValue)

        let helpButton = NSButton(title: "📖 使用说明", target: self, action: #selector(showHelpGuide))
        helpButton.bezelStyle = NSButton.BezelStyle.rounded
        helpButton.font = NSFont.systemFont(ofSize: 12)
        helpButton.frame = NSRect(x: 0, y: 30, width: 120, height: 28)

        // 分组标题和分隔线
        let hAppearance = makeSectionHeader("外观透明度", 502)
        let sep1 = makeSeparator(447)
        let hCollapse = makeSectionHeader("显示与折叠", 370)
        let sep2 = makeSeparator(306)
        let hColor = makeSectionHeader("颜色与主题", 238)
        let sep3 = makeSeparator(172)
        let hPosition = makeSectionHeader("位置与帮助", 106)
        let sep4 = makeSeparator(70)

        _ = bgTracker; _ = fontTracker; _ = cAlphaTracker // 防止被释放
        // 连接调色盘按钮
        let colorHelper = ColorPickerHelper(sm: sm, paletteView: paletteView, colorWell: colorWell)
        colorHelper.swatchButtons = swatchButtons
        colorHelper.previewBox = clearColor
        moreBtn.target = colorHelper; moreBtn.action = #selector(ColorPickerHelper.showMore(_:))
        clearColor.target = colorHelper; clearColor.action = #selector(ColorPickerHelper.resetDefault(_:))
        swatchBtn.target = colorHelper; swatchBtn.action = #selector(ColorPickerHelper.togglePalette(_:))
        for (i, sb) in swatchButtons.enumerated() {
            sb.target = colorHelper; sb.action = #selector(ColorPickerHelper.swatchClicked(_:))
            sb.tag = i
        }
        _ = colorHelper
        for vv in [hAppearance, bgLabel, bgSlider, bgVal, fontLabel, fontSlider, fontVal, cAlphaLabel, cAlphaSlider, cAlphaVal, hCollapse, borderCheck, collapseCheck, delayLabel, delayField, nightCheck, hColor, colorLabel, clearColor, swatchBtn, colorWell, paletteView, themeCheck, spacesCheck, hPosition, posLabel, posPopup, helpButton] { v.addSubview(vv) }
        alert.accessoryView = v

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == NSApplication.ModalResponse.alertFirstButtonReturn {
            sm.noteAlpha = CGFloat(bgSlider.doubleValue)
            sm.fontAlpha = CGFloat(fontSlider.doubleValue)
            sm.showBorder = borderCheck.state == .on
            sm.collapseOnMouseLeave = collapseCheck.state == .on
            sm.collapseDelay = max(1.0, TimeInterval(delayField.stringValue) ?? 3.0)
            sm.collapsedAlpha = CGFloat(cAlphaSlider.doubleValue)
            sm.isNightMode = nightCheck.state == .on
            sm.customNoteColor = colorWell.color
            sm.followTheme = themeCheck.state == .on
            sm.followSpaces = spacesCheck.state == .on
            colorWell.deactivate()
            if let posTitle = posPopup.titleOfSelectedItem,
               let pos = StickyNoteManager.NotePosition(rawValue: posTitle) {
                sm.notePosition = pos
            }
            sm.applySettings()
        }
    }

    @objc func deleteNoteFromStatus() {
        let sm = StickyNoteManager.shared
        let panels = [("📅 今日便笺", sm.todayPanel), ("📝 长期便笺", sm.memoPanel)].compactMap { $0.1 != nil ? $0 : nil }
        if panels.count >= 2 {
            let alert = NSAlert(); alert.messageText = "选择要删除的便笺"
            for (title, _) in panels { alert.addButton(withTitle: title) }
            alert.addButton(withTitle: "取消")
            let resp = alert.runModal()
            switch resp {
            case .alertFirstButtonReturn: sm.todayPanel?.close(); sm.todayPanel = nil
            case .alertSecondButtonReturn: sm.memoPanel?.close(); sm.memoPanel = nil
            default: break
            }
        } else {
            sm.closeNote()
        }
    }

    @objc func showMainFromStatus() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func addFromStatus() {
        showMainFromStatus()
        // 触发添加对话框
        if let vc = window.contentViewController as? ViewController {
            vc.addAction()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { sender.windows.first?.makeKeyAndOrderFront(nil) }
        return true
    }
}

// ==================== 启动 ====================
let app = NSApplication.shared
app.setActivationPolicy(NSApplication.ActivationPolicy.regular)
app.appearance = NSAppearance(named: NSAppearance.Name.aqua)
let delegate = AppDelegate()
app.delegate = delegate
app.activate(ignoringOtherApps: true)
app.run()
