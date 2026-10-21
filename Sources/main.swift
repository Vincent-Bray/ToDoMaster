import AppKit

// ==================== 数据模型 ====================
struct TodoItem: Codable {
    let id: UUID
    var title: String
    var date: Date?
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
    var showDetailedCountdown = false
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
        if days == 0 { return "今天" }
        return "\(days)天"
    }

    func urgencyColor(for item: TodoItem) -> NSColor? {
        guard let date = item.date else { return nil }
        let days = daysUntil(date)
        if days < 0 { return nil }
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
    if let re = try? NSRegularExpression(pattern: "(上午|下午|晚上|中午|早上)?\\s*(\\d{1,2})[:：点时](\\d{1,2}|半)?[分]?\\s*[-~～—到至]\\s*(上午|下午|晚上|中午|早上)?\\s*(\\d{1,2})[:：点时]?(\\d{1,2}|半)?[分]?"),
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
        if let d = cal.date(from: c), d < now { c.year! += 1; date = cal.date(from: c) }
        else { date = cal.date(from: c) }
        removeMatch(m)
    }

    if let re = try? NSRegularExpression(pattern: "(今天|明天|后天|大后天)"),
       let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
        let s = (text as NSString).substring(with: m.range(at: 1))
        let off = ["今天":0,"明天":1,"后天":2,"大后天":3][s] ?? 0
        let base = cal.date(byAdding: .day, value: off, to: now)!
        if var d = date {
            var c = cal.dateComponents([.hour,.minute], from: d)
            c.year = cal.component(.year, from: base); c.month = cal.component(.month, from: base); c.day = cal.component(.day, from: base)
            date = cal.date(from: c)
        } else { date = base }
        if var e = endDate {
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
            if var d = date {
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
    var dateLabel = NSTextField(labelWithString: "")
    let timeFmt = DateFormatter()
    let dayFmt = DateFormatter()

    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 540)) }

    override func viewDidLoad() {
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
        let settingsBtn = NSButton(title: "⚙ 设置", target: self, action: #selector(openSettings))
        settingsBtn.bezelStyle = NSButton.BezelStyle.rounded; settingsBtn.font = NSFont.systemFont(ofSize: 11)
        let addBtn = NSButton(title: "+ 添加", target: self, action: #selector(addAction))
        addBtn.bezelStyle = NSButton.BezelStyle.rounded; addBtn.font = NSFont.systemFont(ofSize: 11)
        addBtn.keyEquivalent = "n"

        let noteBtn = NSButton(title: "便笺", target: self, action: #selector(createStickyNote))
        noteBtn.bezelStyle = NSButton.BezelStyle.rounded; noteBtn.font = NSFont.systemFont(ofSize: 11)
        let toolbar = NSStackView(views: [statusLabel, NSView(), selBtn, clrBtn, expBtn, noteBtn, settingsBtn, addBtn])
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
        let rv = ColoredRowView()
        if row < store.items.count {
            rv.bgColor = store.urgencyColor(for: store.items[row])
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

    // MARK: - 数据源
    func numberOfRows(in tv: NSTableView) -> Int { store.items.count }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        guard row < store.items.count else { return nil }
        let item = store.items[row]
        let cid = col?.identifier.rawValue ?? ""
        let bg = store.urgencyColor(for: item)
        let isPast = item.date.map { store.daysUntil($0) < 0 } ?? false

        func strikethrough(_ s: String) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.secondaryLabelColor
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
                cell.attributedStringValue = strikethrough(item.title)
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
        guard row < store.items.count, let cid = col?.identifier.rawValue, let val = obj as? String else { return }
        switch cid {
        case "title": store.items[row].title = val
        case "loc": store.items[row].location = val.isEmpty ? nil : val
        case "notes": store.items[row].notes = val
        case "date":
            let p = DateFormatter(); p.dateFormat = "HH:mm"
            if let d = p.date(from: val) {
                var c = Calendar.current.dateComponents([.year,.month,.day], from: store.items[row].date ?? Date())
                c.hour = Calendar.current.component(.hour, from: d)
                c.minute = Calendar.current.component(.minute, from: d)
                store.items[row].date = Calendar.current.date(from: c)
            }
        default: break
        }
        store.update(store.items[row])
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
        guard row >= 0, row < store.items.count, col >= 0, col < tableView.tableColumns.count else { return }
        tableView.selectRowIndexes(IndexSet([row]), byExtendingSelection: false)
        let cid = tableView.tableColumns[col].identifier.rawValue

        func addItem(_ title: String, _ sel: Selector) {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }

        switch cid {
        case "star":
            addItem(store.items[row].isStarred ? "取消星标" : "标星", #selector(starToggledFromMenu))
        case "check":
            addItem(store.items[row].isCompleted ? "标记未完成" : "标记完成", #selector(checkToggledFromMenu))
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
        guard row < store.items.count else { return }
        let item = store.items[row]
        rowView.wantsLayer = true
        if let bg = store.urgencyColor(for: item) {
            rowView.layer?.backgroundColor = bg.cgColor
        } else {
            rowView.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        selectedIDs = Set(tableView.selectedRowIndexes.compactMap {
            $0 < store.items.count ? store.items[$0].id : nil
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
        guard row >= 0 && row < store.items.count else { return }
        let item = store.items[row]
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
            switch col {
            case .title: store.items[row].title = val
            case .loc: store.items[row].location = val.isEmpty ? nil : val
            case .notes: store.items[row].notes = val
            case .date:
                let p = DateFormatter(); p.dateFormat = "HH:mm"
                if let d = p.date(from: val) {
                    var c = Calendar.current.dateComponents([.year,.month,.day], from: item.date ?? Date())
                    c.hour = Calendar.current.component(.hour, from: d)
                    c.minute = Calendar.current.component(.minute, from: d)
                    store.items[row].date = Calendar.current.date(from: c)
                }
            }
            store.update(store.items[row]); tableView.reloadData()
        }
    }

    // MARK: - 动作
    @objc func starToggled(_ sender: NSButton) {
        let row = sender.tag
        if row < store.items.count { store.toggleStar(store.items[row].id); tableView.reloadData() }
    }

    @objc func starToggledFromMenu() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0 && row < store.items.count else { return }
        store.toggleStar(store.items[row].id); tableView.reloadData()
    }

    @objc func checkToggled(_ sender: NSButton) {
        let row = sender.tag
        if row < store.items.count { store.toggle(store.items[row].id); tableView.reloadData() }
    }

    @objc func checkToggledFromMenu() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0 && row < store.items.count else { return }
        store.toggle(store.items[row].id); tableView.reloadData()
    }

    @objc func toggleCountdownMode() {
        store.showDetailedCountdown.toggle(); tableView.reloadData()
    }

    @objc func deleteClickedRow() {
        let row = tableView.clickedRow
        if row >= 0 && row < store.items.count {
            store.delete([store.items[row].id])
        } else {
            store.delete(selectedIDs)
        }
        tableView.reloadData(); updateStatus()
    }

    @objc func parseAction() {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        store.add(parseSmartInput(text))
        inputField.stringValue = ""
        tableView.reloadData(); updateStatus()
    }

    @objc func addAction() {
        let alert = NSAlert(); alert.messageText = "添加待办事项"
        alert.addButton(withTitle: "添加"); alert.addButton(withTitle: "取消")

        let formView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))

        let titleField = NSTextField(frame: NSRect(x: 0, y: 170, width: 320, height: 24))
        titleField.placeholderString = "任务名称 *"

        let datePicker = NSDatePicker(frame: NSRect(x: 0, y: 135, width: 220, height: 24))
        datePicker.datePickerStyle = NSDatePicker.Style.textFieldAndStepper
        datePicker.datePickerElements = [.yearMonthDay, .hourMinute]

        let endPicker = NSDatePicker(frame: NSRect(x: 0, y: 100, width: 220, height: 24))
        endPicker.datePickerStyle = NSDatePicker.Style.textFieldAndStepper
        endPicker.datePickerElements = [.hourMinute]

        let locField = NSTextField(frame: NSRect(x: 0, y: 65, width: 320, height: 24))
        locField.placeholderString = "地点"

        let notesField = NSTextField(frame: NSRect(x: 0, y: 30, width: 320, height: 24))
        notesField.placeholderString = "备注"

        let starCheck = NSButton(checkboxWithTitle: "⭐ 星标", target: nil, action: nil)
        starCheck.frame = NSRect(x: 0, y: 2, width: 120, height: 24)

        for v in [titleField, datePicker, endPicker, locField, notesField, starCheck] {
            formView.addSubview(v)
        }
        alert.accessoryView = formView

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == NSApplication.ModalResponse.alertFirstButtonReturn {
            let t = titleField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return }
            let l = locField.stringValue.trimmingCharacters(in: .whitespaces)
            let n = notesField.stringValue.trimmingCharacters(in: .whitespaces)
            let date = datePicker.dateValue
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
        if selectedIDs.count == store.items.count { tableView.deselectAll(nil) }
        else { tableView.selectAll(nil) }
    }

    @objc func clearDone() {
        let done = Set(store.items.filter { $0.isCompleted }.map { $0.id })
        store.delete(done); tableView.reloadData(); updateStatus()
    }

    @objc func openSettings() {
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.showNoteSettings()
        }
    }

    @objc func createStickyNote() {
        guard !selectedIDs.isEmpty else {
            let a = NSAlert(); a.messageText = "请先选中任务"; a.runModal(); return
        }
        let sm = StickyNoteManager.shared
        // 去重：过滤已在便笺中的任务
        let items = store.items.filter { selectedIDs.contains($0.id) && !sm.taskIDs.contains($0.id) }
        guard !items.isEmpty else {
            let a = NSAlert(); a.messageText = "所选任务已在便笺中"; a.runModal(); return
        }
        var blocks: [(String, String, String, String, String, NSColor, Int)] = []
        for item in items {
            var timeStr = ""
            if let d = item.date {
                timeStr = dayFmt.string(from: d) + " " + timeFmt.string(from: d)
                if let e = item.endDate { timeStr += "-" + timeFmt.string(from: e) }
            }
            let color = store.urgencyColor(for: item) ?? NSColor.systemGray
            let pri = colorPriority(for: item)
            // 倒数日
            var countdownStr = ""
            if let d = item.date {
                let cal = Calendar.current
                let a = cal.startOfDay(for: Date())
                let b = cal.startOfDay(for: d)
                let days = cal.dateComponents([.day], from: a, to: b).day ?? 0
                if days == 0 { countdownStr = "今天" }
                else if days == 1 { countdownStr = "明天" }
                else if days > 0 { countdownStr = "\(days)天后" }
                else { countdownStr = "已过\(-days)天" }
            }
            blocks.append((item.title, timeStr, countdownStr, item.location ?? "", item.notes, color, pri))
        }

        // 追加模式：已有便笺则追加
        if let existingPanel = StickyNoteManager.shared.panel,
           let existingView = existingPanel.contentView?.subviews.first(where: { $0 is StickyNoteView }) as? StickyNoteView {
            existingView.taskBlocks.append(contentsOf: blocks)
            existingView.taskBlocks.sort { $0.6 < $1.6 }
            existingView.needsDisplay = true
            // 调整面板大小
            var h: CGFloat = 32
            for t in existingView.taskBlocks {
                h += 22
                if !t.time.isEmpty { h += 18 }
                if !t.location.isEmpty { h += 18 }
                if !t.notes.isEmpty { h += 18 }
                h += 22
            }
            h = max(h, 80)
            var frame = existingPanel.frame
            frame.origin.y += frame.height - h
            frame.size.height = h
            existingPanel.setFrame(frame, display: true)
            existingView.frame = existingPanel.contentView!.bounds
            existingView.needsDisplay = true
            existingPanel.orderFrontRegardless()
        } else {
            StickyNoteManager.shared.createNote(tasks: blocks, from: view.window)
        }
        for item in items { sm.taskIDs.insert(item.id) }
        tableView.reloadData()
    }

    func colorPriority(for item: TodoItem) -> Int {
        guard let date = item.date else { return 5 }
        let days = store.daysUntil(date)
        if days < 0 { return 5 }
        if days == 0 { return 0 }
        if days <= 3 { return 1 }
        if days <= 7 { return 2 }
        if days <= 15 { return 3 }
        return 4
    }

    @objc func exportAction() {
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
class StickyNoteView: NSView {
    var taskBlocks: [(title: String, time: String, countdown: String, location: String, notes: String, color: NSColor, priority: Int)] = []
    var fontAlpha: CGFloat = 1.0
    var onCollapse: (() -> Void)?
    var onExpand: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(t)
    }
    override func mouseEntered(with event: NSEvent) {
        StickyNoteManager.shared.expandNote()
        StickyNoteManager.shared.collapseTimer?.invalidate()
    }
    override func mouseExited(with event: NSEvent) {
        StickyNoteManager.shared.scheduleCollapse()
    }

    override func draw(_ dirtyRect: NSRect) {
        let sm = StickyNoteManager.shared
        let bgColor = sm.noteBgColor ?? (sm.isNightMode ? NSColor(white: 0.12, alpha: 1.0) : NSColor(white: 0.98, alpha: 1.0))
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

        // 折叠状态：只显示标题
        if StickyNoteManager.shared.isCollapsed {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: titleColor.withAlphaComponent(fontAlpha)
            ]
            let s = NSAttributedString(string: "📋 ToDo Master Memo", attributes: attrs)
            s.draw(at: NSPoint(x: 14, y: (bounds.height - 16) / 2))
            return
        }

        let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 11)
        var y: CGFloat = bounds.height - 16

        for (i, task) in taskBlocks.enumerated() {
            // 标题（彩色）
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: titleFont, .foregroundColor: titleColor.withAlphaComponent(fontAlpha)
            ]
            let dot = NSBezierPath(ovalIn: NSRect(x: 14, y: y - 13, width: 8, height: 8))
            task.color.setFill()
            dot.fill()
            let titleStr = NSAttributedString(string: "  " + task.title, attributes: titleAttrs)
            titleStr.draw(at: NSPoint(x: 14, y: y - 16))
            y -= 22

            // 时间 + 倒数日
            if !task.time.isEmpty {
                var timeStr = "🕐 " + task.time
                if !task.countdown.isEmpty { timeStr += "  ·  " + task.countdown }
                let timeAttrs: [NSAttributedString.Key: Any] = [
                    .font: bodyFont, .foregroundColor: bodyColor.withAlphaComponent(fontAlpha)
                ]
                (NSAttributedString(string: timeStr, attributes: timeAttrs)).draw(at: NSPoint(x: 14, y: y - 14))
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
    var isDockedToNotch = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            // 双击恢复
            self.alphaValue = 1.0
            self.isDockedToNotch = false
            NotificationCenter.default.post(name: NSNotification.Name("StickyNoteRestored"), object: nil)
            return
        }
        super.mouseDown(with: event)
    }
}

class StickyNoteManager {
    static let shared = StickyNoteManager()
    var panel: StickyNotePanel?
    var mouseMonitor: Any?
    var noteAlpha: CGFloat = 1.0
    var fontAlpha: CGFloat = 1.0
    var showBorder: Bool = true
    var collapseOnMouseLeave: Bool = false
    var collapseDelay: TimeInterval = 1.5
    var collapsedAlpha: CGFloat = 0.5
    var isNightMode: Bool = false
    var noteBgColor: NSColor?
    var taskIDs: Set<UUID> = []
    var collapseTimer: Timer?
    var isCollapsed: Bool = false
    var expandedSize: NSSize = NSSize(width: 280, height: 200)

    func createNote(tasks: [(String, String, String, String, String, NSColor, Int)], from window: NSWindow?) {
        closeNote()

        let sorted = tasks.sorted { $0.6 < $1.6 }

        // 计算高度
        var height: CGFloat = 32
        for task in sorted {
            height += 22 // 标题
            if !task.1.isEmpty { height += 18 } // 时间
            if !task.3.isEmpty { height += 18 } // 地点
            if !task.4.isEmpty { height += 18 } // 备注
            height += 22 // 分隔+间距
        }
        height = max(height, 80)

        let width: CGFloat = 280
        let screen = NSScreen.main ?? NSScreen.screens[0]
        var startX = screen.frame.midX - width / 2
        var startY = screen.frame.maxY - height - 28
        // 优先定位到状态栏图标正下方
        if let delegate = NSApp.delegate as? AppDelegate,
           let btn = delegate.statusItem?.button, let btnWin = btn.window {
            let btnFrame = btnWin.frame
            startX = btnFrame.midX - width / 2
            startY = screen.frame.maxY - height - 28
        }

        let p = StickyNotePanel(
            contentRect: NSRect(x: startX, y: startY, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        p.level = NSWindow.Level.floating
        p.isOpaque = false
        p.backgroundColor = NSColor.clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let noteView = StickyNoteView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        noteView.taskBlocks = sorted.map {
            (title: $0.0, time: $0.1, countdown: $0.2, location: $0.3, notes: $0.4, color: $0.5, priority: $0.6)
        }

        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 12
        containerView.layer?.backgroundColor = NSColor(white: 0.98, alpha: 1.0).cgColor
        containerView.layer?.borderWidth = 1
        containerView.layer?.borderColor = NSColor.separatorColor.cgColor

        noteView.frame = containerView.bounds
        noteView.autoresizingMask = [.width, .height]
        containerView.addSubview(noteView)

        p.contentView = containerView
        p.orderFrontRegardless()
        panel = p
    }

    func startNotchMonitor() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            guard let self = self, let panel = self.panel else { return }
            let mouseLoc = NSEvent.mouseLocation

            guard let screen = panel.screen ?? NSScreen.main else { return }
            let notchCenterX = screen.frame.midX
            let notchTopY = screen.frame.maxY
            let nearNotch = abs(mouseLoc.x - notchCenterX) < 130 && (notchTopY - mouseLoc.y) < 70

            if panel.isDockedToNotch {
                if nearNotch {
                    panel.alphaValue = 0.45
                } else {
                    panel.alphaValue = 0.12
                }
            }
        }
    }

    func checkDocking() {
        guard let panel = panel, let screen = panel.screen ?? NSScreen.main else { return }
        let frame = panel.frame
        let notchCenterX = screen.frame.midX
        let notchTopY = screen.frame.maxY
        let nearNotch = abs(frame.midX - notchCenterX) < 130 && (notchTopY - frame.maxY) < 70

        if nearNotch && !panel.isDockedToNotch {
            panel.isDockedToNotch = true
            panel.alphaValue = 0.12
        } else if !nearNotch && panel.isDockedToNotch {
            panel.isDockedToNotch = false
            panel.alphaValue = 1.0
        }
    }

    func applySettings() {
        // 应用整体深夜模式
        if isNightMode {
            NSApp.appearance = NSAppearance(named: NSAppearance.Name.darkAqua)
        } else {
            NSApp.appearance = NSAppearance(named: NSAppearance.Name.aqua)
        }
        guard let panel = panel else { return }
        panel.alphaValue = noteAlpha
        if let cv = panel.contentView {
            cv.wantsLayer = true
            cv.layer?.borderWidth = showBorder ? 1 : 0
            cv.layer?.backgroundColor = (noteBgColor ?? (isNightMode ? NSColor(white: 0.12, alpha: 1.0) : NSColor(white: 0.98, alpha: 1.0))).cgColor
            cv.layer?.borderColor = (isNightMode ? NSColor(white: 0.35, alpha: 1.0) : NSColor.separatorColor).cgColor
        }
        if let noteView = panel.contentView?.subviews.first(where: { $0 is StickyNoteView }) as? StickyNoteView {
            noteView.fontAlpha = fontAlpha
            noteView.needsDisplay = true
        }
    }

    func collapseNote() {
        guard let panel = panel, !isCollapsed else { return }
        isCollapsed = true
        panel.alphaValue = collapsedAlpha
        expandedSize = panel.frame.size
        let collapsedHeight: CGFloat = 32
        var frame = panel.frame
        frame.origin.y += frame.height - collapsedHeight
        frame.size.height = collapsedHeight
        panel.setFrame(frame, display: true, animate: true)
    }

    func expandNote() {
        guard let panel = panel, isCollapsed else { return }
        isCollapsed = false
        collapseTimer?.invalidate()
        panel.alphaValue = noteAlpha
        var frame = panel.frame
        frame.origin.y += frame.height - expandedSize.height
        frame.size = expandedSize
        panel.setFrame(frame, display: true, animate: true)
    }

    func scheduleCollapse() {
        guard collapseOnMouseLeave else { return }
        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: collapseDelay, repeats: false) { [weak self] _ in
            self?.collapseNote()
        }
    }

    func closeNote() {
        taskIDs = []
        panel?.close()
        panel = nil
        if let mon = mouseMonitor {
            NSEvent.removeMonitor(mon)
            mouseMonitor = nil
        }
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
        guard let note = StickyNoteManager.shared.panel else {
            // 没有便笺，显示主窗口
            window.makeKeyAndOrderFront(nil)
            return
        }
        if note.isVisible {
            note.orderOut(nil)
        } else {
            positionNoteBelowStatusItem()
            note.orderFrontRegardless()
        }
    }

    func positionNoteBelowStatusItem() {
        guard let note = StickyNoteManager.shared.panel,
              let btn = statusItem.button, let btnWindow = btn.window else { return }
        let btnFrame = btnWindow.frame
        guard let screen = NSScreen.main else { return }
        let noteWidth = note.frame.width
        let x = btnFrame.midX - noteWidth / 2
        let y = screen.frame.maxY - note.frame.height - 28
        note.setFrameOrigin(NSPoint(x: x, y: y))
        note.alphaValue = 1.0
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

    @objc func showNoteSettings() {
        let sm = StickyNoteManager.shared
        let alert = NSAlert(); alert.messageText = "便笺设置"
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")

        let v = NSView(frame: NSRect(x: 0, y: 0, width: 310, height: 310))

        // 便笺透明度
        let bgLabel = NSTextField(labelWithString: "便笺透明度:")
        bgLabel.frame = NSRect(x: 0, y: 278, width: 85, height: 22)
        let bgSlider = NSSlider(value: sm.noteAlpha, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)
        bgSlider.frame = NSRect(x: 90, y: 276, width: 160, height: 22)
        let bgVal = NSTextField(labelWithString: String(format: "%.0f%%", sm.noteAlpha * 100))
        bgVal.frame = NSRect(x: 255, y: 278, width: 45, height: 22)
        bgVal.font = NSFont.systemFont(ofSize: 10)

        // 字体透明度
        let fontLabel = NSTextField(labelWithString: "字体透明度:")
        fontLabel.frame = NSRect(x: 0, y: 246, width: 85, height: 22)
        let fontSlider = NSSlider(value: sm.fontAlpha, minValue: 0.2, maxValue: 1.0, target: nil, action: nil)
        fontSlider.frame = NSRect(x: 90, y: 244, width: 160, height: 22)
        let fontVal = NSTextField(labelWithString: String(format: "%.0f%%", sm.fontAlpha * 100))
        fontVal.frame = NSRect(x: 255, y: 246, width: 45, height: 22)
        fontVal.font = NSFont.systemFont(ofSize: 10)

        // 显示边框
        let borderCheck = NSButton(checkboxWithTitle: "显示便笺边框", target: nil, action: nil)
        borderCheck.frame = NSRect(x: 0, y: 212, width: 200, height: 24)
        borderCheck.state = sm.showBorder ? .on : .off

        // 鼠标移开时折叠
        let collapseCheck = NSButton(checkboxWithTitle: "鼠标移开时折叠", target: nil, action: nil)
        collapseCheck.frame = NSRect(x: 0, y: 178, width: 140, height: 24)
        collapseCheck.state = sm.collapseOnMouseLeave ? .on : .off

        // 折叠延时（可输入数字）
        let delayLabel = NSTextField(labelWithString: "延时(秒):")
        delayLabel.frame = NSRect(x: 145, y: 178, width: 65, height: 22)
        let delayField = NSTextField(frame: NSRect(x: 210, y: 73, width: 55, height: 22))
        delayField.frame = NSRect(x: 210, y: 176, width: 55, height: 22)
        delayField.stringValue = String(format: "%.0f", sm.collapseDelay)
        delayField.font = NSFont.systemFont(ofSize: 11)

        // 折叠后透明度
        let cAlphaLabel = NSTextField(labelWithString: "折叠透明度:")
        cAlphaLabel.frame = NSRect(x: 0, y: 145, width: 85, height: 22)
        let cAlphaSlider = NSSlider(value: sm.collapsedAlpha, minValue: 0.1, maxValue: 1.0, target: nil, action: nil)
        cAlphaSlider.frame = NSRect(x: 90, y: 143, width: 160, height: 22)
        let cAlphaVal = NSTextField(labelWithString: String(format: "%.0f%%", sm.collapsedAlpha * 100))
        cAlphaVal.frame = NSRect(x: 255, y: 145, width: 45, height: 22)
        cAlphaVal.font = NSFont.systemFont(ofSize: 10)

        // 便笺颜色
        let colorLabel = NSTextField(labelWithString: "便笺颜色:")
        colorLabel.frame = NSRect(x: 0, y: 78, width: 85, height: 22)
        let colorWell = NSColorWell(frame: NSRect(x: 90, y: 75, width: 60, height: 26))
        colorWell.color = sm.noteBgColor ?? NSColor(white: 0.98, alpha: 1.0)
        let clearColor = NSButton(title: "默认", target: nil, action: nil)
        clearColor.bezelStyle = NSButton.BezelStyle.rounded
        clearColor.font = NSFont.systemFont(ofSize: 10)
        clearColor.frame = NSRect(x: 160, y: 76, width: 55, height: 24)
        clearColor.tag = 100

        // 深夜模式
        let nightCheck = NSButton(checkboxWithTitle: "深夜模式（应用+便笺全局暗色）", target: nil, action: nil)
        nightCheck.frame = NSRect(x: 0, y: 112, width: 280, height: 24)
        nightCheck.state = sm.isNightMode ? .on : .off

        for vv in [bgLabel, bgSlider, bgVal, fontLabel, fontSlider, fontVal, borderCheck, collapseCheck, delayLabel, delayField, cAlphaLabel, cAlphaSlider, cAlphaVal, nightCheck, colorLabel, colorWell, clearColor] { v.addSubview(vv) }
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
            sm.noteBgColor = colorWell.color
            colorWell.deactivate()
            sm.applySettings()
        }
    }

    @objc func deleteNoteFromStatus() {
        StickyNoteManager.shared.closeNote()
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
