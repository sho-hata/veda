import Foundation

struct RGBColor: Equatable {
    let r: UInt8
    let g: UInt8
    let b: UInt8

    static let black = RGBColor(r: 0, g: 0, b: 0)
    static let white = RGBColor(r: 255, g: 245, b: 248)
    static let gnEmerald = RGBColor(r: 48, g: 230, b: 174)
    static let gnDim = RGBColor(r: 24, g: 96, b: 78)
    static let transAmHot = RGBColor(r: 255, g: 135, b: 175)
    static let transAmCrimson = RGBColor(r: 255, g: 28, b: 78)
    static let transAmDeep = RGBColor(r: 175, g: 12, b: 48)
    static let transAmEmber = RGBColor(r: 92, g: 8, b: 28)
    static let amberWarn = RGBColor(r: 255, g: 132, b: 36)
    static let dimGray = RGBColor(r: 120, g: 125, b: 135)

    func scaled(by factor: Double) -> RGBColor {
        let f = max(0.0, min(1.5, factor))
        return RGBColor(
            r: UInt8(min(255, Int(Double(r) * f))),
            g: UInt8(min(255, Int(Double(g) * f))),
            b: UInt8(min(255, Int(Double(b) * f)))
        )
    }

    static func lerp(_ a: RGBColor, _ b: RGBColor, t: Double) -> RGBColor {
        let p = max(0.0, min(1.0, t))
        return RGBColor(
            r: UInt8(Double(a.r) + (Double(b.r) - Double(a.r)) * p),
            g: UInt8(Double(a.g) + (Double(b.g) - Double(a.g)) * p),
            b: UInt8(Double(a.b) + (Double(b.b) - Double(a.b)) * p)
        )
    }
}

struct Cell {
    var char: Character = " "
    var fg: RGBColor? = nil
    var bg: RGBColor? = nil
    var bold: Bool = false
}

/// フリッカー防止のダブルバッファ ANSI キャンバス
struct CanvasBuffer {
    let width: Int
    let height: Int
    private var cells: [Cell]

    init(width: Int, height: Int, defaultBg: RGBColor? = nil) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.cells = Array(repeating: Cell(char: " ", fg: nil, bg: defaultBg, bold: false), count: self.width * self.height)
    }

    mutating func clear(bg: RGBColor? = nil) {
        let empty = Cell(char: " ", fg: nil, bg: bg, bold: false)
        for i in cells.indices {
            cells[i] = empty
        }
    }

    mutating func set(x: Int, y: Int, char: Character, fg: RGBColor?, bg: RGBColor? = nil, bold: Bool = false) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        let idx = y * width + x
        let resolvedBg = bg ?? cells[idx].bg
        cells[idx] = Cell(char: char, fg: fg, bg: resolvedBg, bold: bold)
    }

    mutating func setBg(x: Int, y: Int, bg: RGBColor) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        cells[y * width + x].bg = bg
    }

    mutating func drawText(_ text: String, x: Int, y: Int, fg: RGBColor, bg: RGBColor? = nil, bold: Bool = false) {
        guard y >= 0, y < height else { return }
        var cx = x
        for ch in text {
            if cx >= 0 && cx < width {
                set(x: cx, y: y, char: ch, fg: fg, bg: bg, bold: bold)
            }
            cx += 1
        }
    }

    mutating func drawCenteredText(_ text: String, y: Int, fg: RGBColor, bg: RGBColor? = nil, bold: Bool = false) {
        let x = (width - text.count) / 2
        drawText(text, x: x, y: y, fg: fg, bg: bg, bold: bold)
    }

    mutating func drawSprite(
        _ lines: [String],
        centerX: Int,
        centerY: Int,
        fg: RGBColor,
        bold: Bool = false,
        skipSpaces: Bool = true,
        densityScale: Double = 1.0
    ) {
        let spriteH = lines.count
        let spriteW = lines.map(\.count).max() ?? 0
        let startX = centerX - spriteW / 2
        let startY = centerY - spriteH / 2

        for (rowIdx, line) in lines.enumerated() {
            let y = startY + rowIdx
            guard y >= 0, y < height else { continue }
            var colIdx = 0
            for ch in line {
                let x = startX + colIdx
                colIdx += 1
                guard x >= 0, x < width else { continue }
                if skipSpaces && ch == " " { continue }

                let mappedChar = degradeCharacter(ch, density: densityScale)
                if mappedChar != " " {
                    set(x: x, y: y, char: mappedChar, fg: fg, bold: bold)
                }
            }
        }
    }

    mutating func drawHorizontalLine(y: Int, from x0: Int, to x1: Int, char: Character, fg: RGBColor, bold: Bool = false) {
        guard y >= 0, y < height else { return }
        let lo = max(0, min(x0, x1))
        let hi = min(width - 1, max(x0, x1))
        guard lo <= hi else { return }
        for x in lo...hi {
            set(x: x, y: y, char: char, fg: fg, bold: bold)
        }
    }

    mutating func drawFrameBorder(fg: RGBColor, title: String? = nil) {
        guard width >= 4, height >= 4 else { return }
        set(x: 0, y: 0, char: "┌", fg: fg)
        set(x: width - 1, y: 0, char: "┐", fg: fg)
        set(x: 0, y: height - 1, char: "└", fg: fg)
        set(x: width - 1, y: height - 1, char: "┘", fg: fg)

        for x in 1..<(width - 1) {
            set(x: x, y: 0, char: "─", fg: fg)
            set(x: x, y: height - 1, char: "─", fg: fg)
        }
        for y in 1..<(height - 1) {
            set(x: 0, y: y, char: "│", fg: fg)
            set(x: width - 1, y: y, char: "│", fg: fg)
        }
        if let title, !title.isEmpty {
            drawText(" \(title) ", x: 2, y: 0, fg: fg, bold: true)
        }
    }

    /// 1 回の文字列バッファ構築で ANSI シーケンスを最小化して出力する
    func renderANSI(colorEnabled: Bool, moveCursorHome: Bool) -> String {
        var out = String()
        out.reserveCapacity(width * height * (colorEnabled ? 14 : 2))

        if moveCursorHome {
            out += "\u{1B}[H"
        }

        var lastFg: RGBColor? = nil
        var lastBg: RGBColor? = nil
        var lastBold = false

        for y in 0..<height {
            let rowStart = y * width
            for x in 0..<width {
                let cell = cells[rowStart + x]
                if colorEnabled {
                    if cell.bold != lastBold {
                        if cell.bold {
                            out += "\u{1B}[1m"
                        } else {
                            out += "\u{1B}[22m"
                        }
                        lastBold = cell.bold
                    }
                    if cell.fg != lastFg {
                        if let fg = cell.fg {
                            out += "\u{1B}[38;2;\(fg.r);\(fg.g);\(fg.b)m"
                        } else {
                            out += "\u{1B}[39m"
                        }
                        lastFg = cell.fg
                    }
                    if cell.bg != lastBg {
                        if let bg = cell.bg {
                            out += "\u{1B}[48;2;\(bg.r);\(bg.g);\(bg.b)m"
                        } else {
                            out += "\u{1B}[49m"
                        }
                        lastBg = cell.bg
                    }
                }
                out.append(cell.char)
            }
            if colorEnabled {
                out += "\u{1B}[0m"
                lastFg = nil
                lastBg = nil
                lastBold = false
            }
            if y < height - 1 {
                out.append("\n")
            }
        }
        return out
    }

    /// 残像の減衰率に応じて ASCII 密度を徐々に粒子化させる
    private func degradeCharacter(_ ch: Character, density: Double) -> Character {
        if density >= 0.65 { return ch }
        if density >= 0.42 {
            switch ch {
            case "█", "▓", "●", "◈", "#": return "▒"
            case "/", "\\", "|", "-", "_", "=", "[", "]", "╭", "╮", "╰", "╯", "─", "│", "├", "┤":
                return ch
            default:
                return ":"
            }
        }
        if density >= 0.22 {
            switch ch {
            case " ": return " "
            case "/", "\\", "|": return ":"
            default: return "·"
            }
        }
        return density >= 0.08 ? "." : " "
    }
}
