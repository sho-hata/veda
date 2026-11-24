import Darwin
import Foundation

/// シグナル受信フラグ（POSIX シグナルハンドラから安全に書き込むため sig_atomic_t を使用）
nonisolated(unsafe) private var gSignalInterrupted: sig_atomic_t = 0

private func handleInterruptSignal(_ signal: Int32) {
    gSignalInterrupted = 1
}

enum KeyEvent: Equatable {
    case up
    case down
    case left
    case right
    case space
    case toggleAuto
    case toggleSprite
    case increaseFade
    case decreaseFade
    case quit
}

struct TerminalSize {
    let cols: Int
    let rows: Int
}

final class TerminalController {
    private var originalTermios: termios?
    private let isInteractiveTTY: Bool
    private var alternateScreenActive = false

    init() {
        self.isInteractiveTTY = (isatty(STDIN_FILENO) != 0) && (isatty(STDOUT_FILENO) != 0)
    }

    var isTTY: Bool {
        isInteractiveTTY
    }

    var wasInterrupted: Bool {
        gSignalInterrupted != 0
    }

    func setup(useAlternateScreen: Bool) {
        gSignalInterrupted = 0
        signal(SIGINT, handleInterruptSignal)
        signal(SIGTERM, handleInterruptSignal)

        if isInteractiveTTY {
            var raw = termios()
            if tcgetattr(STDIN_FILENO, &raw) == 0 {
                originalTermios = raw
                raw.c_lflag &= ~UInt(ICANON | ECHO)
                // 非ブロッキング読み取り (VMIN=0, VTIME=0)
                withUnsafeMutablePointer(to: &raw.c_cc) { ptr in
                    ptr.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                        cc[Int(VMIN)] = 0
                        cc[Int(VTIME)] = 0
                    }
                }
                tcsetattr(STDIN_FILENO, TCSANOW, &raw)
            }
        }

        if useAlternateScreen && isInteractiveTTY {
            alternateScreenActive = true
            writeRaw("\u{1B}[?1049h\u{1B}[?25l\u{1B}[2J\u{1B}[H")
        } else if isInteractiveTTY {
            writeRaw("\u{1B}[?25l")
        }
    }

    func restore() {
        if var orig = originalTermios {
            tcsetattr(STDIN_FILENO, TCSANOW, &orig)
            originalTermios = nil
        }

        if alternateScreenActive {
            alternateScreenActive = false
            writeRaw("\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l")
        } else if isInteractiveTTY {
            writeRaw("\u{1B}[0m\u{1B}[?25h")
        } else {
            writeRaw("\u{1B}[0m")
        }
    }

    func currentSize() -> TerminalSize {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col >= 40, ws.ws_row >= 18 {
            return TerminalSize(cols: Int(ws.ws_col), rows: Int(ws.ws_row))
        }
        return TerminalSize(cols: 88, rows: 28)
    }

    func writeRaw(_ text: String) {
        text.withCString { cstr in
            let total = strlen(cstr)
            var written = 0
            while written < total {
                let n = Darwin.write(STDOUT_FILENO, cstr.advanced(by: written), total - written)
                if n <= 0 { break }
                written += n
            }
        }
    }

    func pollKeys() -> [KeyEvent] {
        guard isInteractiveTTY else { return [] }
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
        guard count > 0 else { return [] }

        var events: [KeyEvent] = []
        var i = 0
        while i < count {
            let b = buffer[i]
            if b == 0x1B {
                // ESC シーケンス（矢印キー: ESC [ A/B/C/D）
                if i + 2 < count && buffer[i + 1] == 0x5B {
                    switch buffer[i + 2] {
                    case 0x41: events.append(.up)
                    case 0x42: events.append(.down)
                    case 0x43: events.append(.right)
                    case 0x44: events.append(.left)
                    default: break
                    }
                    i += 3
                    continue
                } else {
                    events.append(.quit)
                    i += 1
                    continue
                }
            }

            switch b {
            case 0x03, UInt8(ascii: "q"), UInt8(ascii: "Q"):
                events.append(.quit)
            case UInt8(ascii: " "):
                events.append(.space)
            case UInt8(ascii: "w"), UInt8(ascii: "W"), UInt8(ascii: "k"), UInt8(ascii: "K"):
                events.append(.up)
            case UInt8(ascii: "s"), UInt8(ascii: "S"), UInt8(ascii: "j"), UInt8(ascii: "J"):
                events.append(.down)
            case UInt8(ascii: "a"), UInt8(ascii: "A"), UInt8(ascii: "h"), UInt8(ascii: "H"):
                if b == UInt8(ascii: "A") {
                    events.append(.toggleAuto)
                } else {
                    events.append(.left)
                }
            case UInt8(ascii: "d"), UInt8(ascii: "D"), UInt8(ascii: "l"), UInt8(ascii: "L"):
                events.append(.right)
            case UInt8(ascii: "p"), UInt8(ascii: "P"):
                events.append(.toggleAuto)
            case UInt8(ascii: "m"), UInt8(ascii: "M"):
                events.append(.toggleSprite)
            case UInt8(ascii: "+"), UInt8(ascii: "="), UInt8(ascii: "]"):
                events.append(.increaseFade)
            case UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "["):
                events.append(.decreaseFade)
            default:
                break
            }
            i += 1
        }
        return events
    }
}
