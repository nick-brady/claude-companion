import SwiftUI

// MARK: - Block model

/// A reply split into blocks. Inline markdown (bold, code, links…) inside each block is
/// already resolved to an AttributedString by Foundation's inline-only parser, so rendering
/// never parses anything.
enum MDBlock: Equatable {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case list(ordered: Bool, items: [MDListItem])
    case code(language: String, text: String)
    case table(header: [AttributedString], rows: [[AttributedString]])
    case rule
}

struct MDListItem: Equatable {
    var number: Int          // the number written in the source for ordered lists
    var text: AttributedString
    var children: [MDBlock]  // nested lists
}

/// Inline markdown (bold, italic, code, links). Falls back to the plain string, never throws.
func inlineMarkdown(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(s)
}

/// A parsed reply. Parsing is line-based and linear; it never throws and always produces
/// something sensible for half-streamed text (an unclosed ``` fence is a code block, a table
/// whose separator row is still being typed is a table, and so on).
struct MarkdownDocument: Equatable {
    var blocks: [MDBlock]

    // Memo: streaming replies re-render on every chunk, and the transcript re-evaluates its
    // rows often, so parse each distinct string once. The cache is tiny and just clears when
    // it fills up.
    @MainActor private static var cache: [String: MarkdownDocument] = [:]

    @MainActor static func cached(_ text: String) -> MarkdownDocument {
        if let d = cache[text] { return d }
        let d = parse(text)
        if cache.count >= 96 { cache.removeAll(keepingCapacity: true) }
        cache[text] = d
        return d
    }

    static func parse(_ text: String) -> MarkdownDocument {
        var p = Parser(lines: text.split(separator: "\n", omittingEmptySubsequences: false).map { Substring($0) })
        return MarkdownDocument(blocks: p.parseBlocks())
    }
}

// MARK: - Parser

private struct Line {
    let raw: Substring
    let indent: Int          // leading spaces (tab = 4)
    let body: Substring      // raw without leading whitespace or trailing whitespace
    var isBlank: Bool { body.isEmpty }

    init(_ s: Substring) {
        raw = s
        var n = 0
        var i = s.startIndex
        while i < s.endIndex, s[i] == " " || s[i] == "\t" { n += s[i] == "\t" ? 4 : 1; i = s.index(after: i) }
        indent = n
        var trimmed = s[i...]
        while let last = trimmed.last, last == " " || last == "\t" || last == "\r" { trimmed = trimmed.dropLast() }
        body = trimmed
    }

    var isFence: Bool { body.hasPrefix("```") || body.hasPrefix("~~~") }

    /// `#`…`######` followed by a space (or nothing).
    var heading: (level: Int, text: String)? {
        guard body.first == "#" else { return nil }
        let hashes = body.prefix { $0 == "#" }
        guard hashes.count <= 6 else { return nil }
        let rest = body[hashes.endIndex...]
        guard rest.isEmpty || rest.first == " " else { return nil }
        var t = rest.trimmingCharacters(in: .whitespaces)
        // Optional closing hashes: "## Title ##"
        while t.last == "#" { t.removeLast() }
        return (hashes.count, t.trimmingCharacters(in: .whitespaces))
    }

    /// `---`, `***`, `___` (3+), optionally with spaces between.
    var isRule: Bool {
        guard let c = body.first, c == "-" || c == "*" || c == "_" else { return false }
        var count = 0
        for ch in body {
            if ch == c { count += 1 } else if ch != " " { return false }
        }
        return count >= 3
    }

    /// `- `, `* `, `+ `, `1. `, `1) ` → (ordered, number, text after the marker)
    var listMarker: (ordered: Bool, number: Int, text: String)? {
        guard let c = body.first else { return nil }
        if c == "-" || c == "*" || c == "+" {
            let rest = body.dropFirst()
            guard rest.isEmpty || rest.first == " " else { return nil }
            return (false, 0, String(rest.drop { $0 == " " }))
        }
        if c.isNumber {
            let digits = body.prefix { $0.isNumber }
            guard digits.count <= 9, let n = Int(digits) else { return nil }
            let afterDigits = body[digits.endIndex...]
            guard let p = afterDigits.first, p == "." || p == ")" else { return nil }
            let rest = afterDigits.dropFirst()
            guard rest.isEmpty || rest.first == " " else { return nil }
            return (true, n, String(rest.drop { $0 == " " }))
        }
        return nil
    }

    var hasPipe: Bool { body.contains("|") }

    /// `|---|:--:|` and friends; also accepts a partially streamed one like `|---|-`.
    var isTableSeparator: Bool {
        guard body.contains("-") else { return false }
        for ch in body where !(ch == "|" || ch == "-" || ch == ":" || ch == " ") { return false }
        let cells = splitTableCells(body)
        guard !cells.isEmpty else { return false }
        for cell in cells {
            var c = Substring(cell)
            if c.first == ":" { c = c.dropFirst() }
            if c.last == ":" { c = c.dropLast() }
            if c.isEmpty || c.contains { $0 != "-" } { return false }
        }
        return true
    }
}

/// Split a table row on unescaped pipes that sit outside backtick code spans. Leading and
/// trailing pipes are dropped; cells are trimmed.
private func splitTableCells(_ s: Substring) -> [String] {
    var cells: [String] = []
    var cur = ""
    var inCode = false
    var i = s.startIndex
    while i < s.endIndex {
        let ch = s[i]
        if ch == "\\", s.index(after: i) < s.endIndex, s[s.index(after: i)] == "|" {
            cur.append("|"); i = s.index(i, offsetBy: 2); continue
        }
        if ch == "`" { inCode.toggle() }
        if ch == "|", !inCode { cells.append(cur); cur = "" } else { cur.append(ch) }
        i = s.index(after: i)
    }
    cells.append(cur)
    var out = cells.map { $0.trimmingCharacters(in: .whitespaces) }
    // Drop the empty cell before a leading pipe and after a trailing pipe.
    if out.count > 1, out.first == "" { out.removeFirst() }
    if out.count > 1, out.last == "" { out.removeLast() }
    return out
}

private struct Parser {
    let lines: [Line]
    var i = 0

    init(lines: [Substring]) { self.lines = lines.map(Line.init) }

    private var cur: Line? { i < lines.count ? lines[i] : nil }
    private func line(_ k: Int) -> Line? { k < lines.count ? lines[k] : nil }

    mutating func parseBlocks() -> [MDBlock] {
        var blocks: [MDBlock] = []
        while let l = cur {
            if l.isBlank { i += 1; continue }
            if l.isFence { blocks.append(parseFence()); continue }
            if let h = l.heading { blocks.append(.heading(level: h.level, text: inlineMarkdown(h.text))); i += 1; continue }
            if l.isRule { blocks.append(.rule); i += 1; continue }
            if l.hasPipe, let next = line(i + 1), next.isTableSeparator { blocks.append(parseTable()); continue }
            if l.listMarker != nil { blocks.append(parseList()); continue }
            blocks.append(parseParagraph())
        }
        return blocks
    }

    /// Does this line start a new block (so a paragraph should end before it)?
    private func startsBlock(_ l: Line) -> Bool {
        l.isFence || l.heading != nil || l.isRule || l.listMarker != nil
    }

    private mutating func parseParagraph() -> MDBlock {
        var parts: [String] = []
        while let l = cur, !l.isBlank, parts.isEmpty || !startsBlock(l) {
            // A table starting mid-paragraph begins a new block.
            if !parts.isEmpty, l.hasPipe, let next = line(i + 1), next.isTableSeparator { break }
            parts.append(String(l.body))
            i += 1
        }
        return .paragraph(inlineMarkdown(parts.joined(separator: "\n")))
    }

    private mutating func parseFence() -> MDBlock {
        let open = lines[i]
        let marker = open.body.prefix { $0 == "`" || $0 == "~" }
        let language = open.body[marker.endIndex...].trimmingCharacters(in: .whitespaces)
        i += 1
        var code: [String] = []
        while let l = cur {
            if l.body.hasPrefix(marker), l.body.allSatisfy({ $0 == marker.first! }) { i += 1; break }
            // Keep the code's own indentation relative to the fence.
            var raw = String(l.raw)
            if raw.last == "\r" { raw.removeLast() }
            code.append(String(raw.dropFirst(min(open.indent, raw.prefix { $0 == " " }.count))))
            i += 1
        }
        // An unclosed fence (still streaming) just runs to the end of the text.
        return .code(language: language, text: code.joined(separator: "\n"))
    }

    private mutating func parseTable() -> MDBlock {
        let header = splitTableCells(lines[i].body)
        i += 2 // header + separator
        var rows: [[String]] = []
        while let l = cur, !l.isBlank, l.hasPipe, !l.isFence, l.heading == nil {
            var cells = splitTableCells(l.body)
            if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
            if cells.count > header.count { cells = Array(cells.prefix(header.count)) }
            rows.append(cells)
            i += 1
        }
        func cell(_ s: String) -> AttributedString {
            inlineMarkdown(s.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "<br/>", with: "\n"))
        }
        return .table(header: header.map(cell), rows: rows.map { $0.map(cell) })
    }

    private struct Entry { var indent: Int; var ordered: Bool; var number: Int; var text: String }

    private mutating func parseList() -> MDBlock {
        var entries: [Entry] = []
        let base = lines[i].indent
        let ordered = lines[i].listMarker?.ordered ?? false
        while let l = cur {
            if l.isBlank {
                // A blank line only ends the list if what follows isn't another item.
                guard let next = line(i + 1), !next.isBlank, next.listMarker != nil else { break }
                i += 1; continue
            }
            if let m = l.listMarker {
                // Switching between "1." and "-" at the top level starts a new list.
                if l.indent <= base, m.ordered != ordered { break }
                entries.append(Entry(indent: l.indent, ordered: m.ordered, number: m.number, text: m.text))
            } else if l.indent >= 2, !entries.isEmpty, !l.isFence, l.heading == nil {
                // Indented continuation of the previous item.
                entries[entries.count - 1].text += "\n" + l.body
            } else { break }
            i += 1
        }
        return buildList(entries[...])
    }

    private func buildList(_ entries: ArraySlice<Entry>) -> MDBlock {
        guard let first = entries.first else { return .list(ordered: false, items: []) }
        let base = first.indent
        var items: [MDListItem] = []
        var k = entries.startIndex
        while k < entries.endIndex {
            let e = entries[k]
            var item = MDListItem(number: e.number, text: inlineMarkdown(e.text), children: [])
            var j = k + 1
            while j < entries.endIndex, entries[j].indent > base { j += 1 }
            if j > k + 1 { item.children = [buildList(entries[(k + 1)..<j])] }
            items.append(item)
            k = j
        }
        return .list(ordered: first.ordered, items: items)
    }
}

// MARK: - Style

struct MarkdownStyle {
    var fontSize: CGFloat
    var lineSpacing: CGFloat
    var text: Color
    var muted: Color          // list markers, table header text stays `text`
    var divider: Color        // rules and table lines
    var codeBackground: Color
    var maxCellWidth: CGFloat  // a table cell wraps past this; wider tables scroll sideways

    /// Main window: paper theme, text colour per turn role.
    static func window(size: CGFloat, text: Color) -> MarkdownStyle {
        MarkdownStyle(fontSize: size, lineSpacing: 3, text: text, muted: Theme.muted,
                      divider: Theme.hairline, codeBackground: Theme.ink.opacity(0.06), maxCellWidth: 260)
    }

    /// Floating pill: white on dark, matching the plain-text opacity it had before.
    static let pill = MarkdownStyle(fontSize: 14, lineSpacing: 2, text: .white.opacity(0.94),
                                    muted: .white.opacity(0.5), divider: .white.opacity(0.18),
                                    codeBackground: .white.opacity(0.08), maxCellWidth: 200)

    var monoFont: Font { .system(size: fontSize - 1.5, design: .monospaced) }
    var bodyFont: Font { .system(size: fontSize) }
}

// MARK: - View

/// Block-level Markdown: headings, paragraphs, lists, fenced code, pipe tables and rules,
/// with inline markdown inside each. Pure layout — no GeometryReader, preferences, timers
/// or animations — so it is safe inside the self-sizing pill.
struct MarkdownView: View {
    let doc: MarkdownDocument
    let style: MarkdownStyle

    @MainActor init(text: String, style: MarkdownStyle) {
        self.doc = MarkdownDocument.cached(text)
        self.style = style
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(doc.blocks.enumerated()), id: \.offset) { _, block in
                MDBlockView(block: block, style: style, depth: 0)
            }
        }
        .font(style.bodyFont)
        .foregroundStyle(style.text)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MDBlockView: View {
    let block: MDBlock
    let style: MarkdownStyle
    let depth: Int

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(.system(size: headingSize(level), weight: level <= 2 ? .semibold : .medium))
                .padding(.top, level <= 2 ? 6 : 3)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            Text(text)
                .lineSpacing(style.lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let ordered, let items):
            MDListView(ordered: ordered, items: items, style: style, depth: depth)
        case .code(_, let text):
            MDCodeView(text: text, style: style)
        case .table(let header, let rows):
            MDTableView(header: header, rows: rows, style: style)
        case .rule:
            Rectangle().fill(style.divider).frame(height: 1).padding(.vertical, 2)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return style.fontSize * 1.35
        case 2: return style.fontSize * 1.2
        case 3: return style.fontSize * 1.08
        default: return style.fontSize
        }
    }
}

private struct MDListView: View {
    let ordered: Bool
    let items: [MDListItem]
    let style: MarkdownStyle
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(marker(item))
                        .foregroundStyle(style.muted)
                        .frame(minWidth: ordered ? 18 : 10, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.text)
                            .lineSpacing(style.lineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                            MDBlockView(block: child, style: style, depth: depth + 1)
                        }
                    }
                }
            }
        }
        .padding(.leading, depth == 0 ? 2 : 0)
    }

    private func marker(_ item: MDListItem) -> String {
        if ordered { return "\(item.number)." }
        return ["•", "◦", "▪"][min(depth, 2)]
    }
}

private struct MDCodeView: View {
    let text: String
    let style: MarkdownStyle

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(style.monoFont)
                .lineSpacing(2)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .fixedSize(horizontal: true, vertical: true)
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(style.codeBackground))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(style.divider, lineWidth: 0.6))
    }
}

private struct MDTableView: View {
    let header: [AttributedString]
    let rows: [[AttributedString]]
    let style: MarkdownStyle

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, h in
                        cell(h).fontWeight(.semibold)
                    }
                }
                divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { k, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, c in cell(c) }
                    }
                    if k < rows.count - 1 { divider(opacity: 0.55) }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(style.divider, lineWidth: 0.6))
        }
    }

    private func cell(_ s: AttributedString) -> some View {
        ClampWidth(max: style.maxCellWidth) {
            Text(s)
                .font(.system(size: style.fontSize - 0.5))
                .lineSpacing(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
    }

    /// A table cell inside a horizontal ScrollView is offered unlimited width, so a plain
    /// `frame(maxWidth:)` would clamp the width but keep the single-line height. This measures
    /// the text at its ideal width, or at `max` if that's narrower, so the row grows to fit
    /// the wrapped text. Stateless: it measures its child, never itself.
    private struct ClampWidth: Layout {
        let max: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let s = subviews.first else { return .zero }
            let ideal = s.sizeThatFits(.unspecified)
            let limit = Swift.min(proposal.width ?? max, max)
            if ideal.width <= limit { return ideal }
            return s.sizeThatFits(ProposedViewSize(width: limit, height: nil))
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                                  proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }

    private func divider(opacity: Double = 1) -> some View {
        Rectangle().fill(style.divider.opacity(opacity)).frame(height: 1)
            .gridCellColumns(max(header.count, 1))
            .gridCellUnsizedAxes(.horizontal)
    }
}
