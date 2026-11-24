import Darwin
import Foundation

struct CliOptions {
    var demoMode: Bool = false
    var activationOnly: Bool = false
    var snapshotMode: Bool = false
    var snapshotPhase: String = "climax"
    var durationSeconds: Double? = nil
    var colorEnabled: Bool = true
    var sprite: CliSpriteKind = .gundam
    var showHelp: Bool = false

    static func parse(_ args: [String]) -> CliOptions {
        var opts = CliOptions()
        var i = 1
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-h", "--help":
                opts.showHelp = true
            case "--demo":
                opts.demoMode = true
            case "--activation-only":
                opts.activationOnly = true
            case "--snapshot":
                opts.snapshotMode = true
                if i + 1 < args.count && !args[i + 1].hasPrefix("-") {
                    opts.snapshotPhase = args[i + 1]
                    i += 1
                }
            case "--duration":
                if i + 1 < args.count, let val = Double(args[i + 1]) {
                    opts.durationSeconds = max(1.0, val)
                    i += 1
                }
            case "--window":
                opts.sprite = .window
            case "--gundam":
                opts.sprite = .gundam
            case "--no-color":
                opts.colorEnabled = false
            default:
                break
            }
            i += 1
        }
        return opts
    }

    static let helpText = """
    veda-cli — ガンダム00 トランザム ASCII Art CLI

    USAGE:
      swift run veda-cli [OPTIONS]

    OPTIONS:
      --demo                  発動モーション後、自動で高速トランザム残像デモを再生して終了
      --activation-only       ソレスタルビーイングのコックピット発動モーションのみ再生
      --duration <秒>         デモ実行時間（秒、デフォルト: 7.0）
      --gundam                ガンダム00 シルエットで表示（デフォルト）
      --window                Veda ウィンドウフレームの ASCII 版で表示
      --snapshot [climax|trails|emblem]
                              1フレームの静止ASCIIアートを標準出力へ描画
      --no-color              ANSI カラーを無効化してモノクロ出力
      -h, --help              このヘルプを表示

    INTERACTIVE KEYS:
      Space                   トランザム起動（コックピット演出） / 停止
      Arrow / WASD / HJKL     手動操作で機体を移動（赤いASCII残像が発生）
      P                       オートパイロット（高速8の字軌道）切替
      M                       スプライト切替（GUNDAM-00 ⇄ VEDA-WIN）
      + / -                   残像の持続時間調整（0.20s 〜 1.20s）
      Q / Esc / Ctrl+C        終了
    """
}

@main
struct VedaCLIMain {
    static func main() {
        let opts = CliOptions.parse(CommandLine.arguments)
        if opts.showHelp {
            print(CliOptions.helpText)
            return
        }

        let sim = TransAmSimulation()
        sim.spriteKind = opts.sprite

        // 静止スナップショットモード（非TTYやプレビュー確認用）
        if opts.snapshotMode {
            renderSnapshot(sim: sim, phaseName: opts.snapshotPhase, colorEnabled: opts.colorEnabled)
            return
        }

        let terminal = TerminalController()
        let isDemo = opts.demoMode || opts.activationOnly || !terminal.isTTY
        let maxDuration: Double? = {
            if opts.activationOnly {
                return TransAmSimulation.activationDuration + 0.1
            }
            if isDemo {
                return opts.durationSeconds ?? 7.0
            }
            return opts.durationSeconds
        }()

        // 起動直後からコックピット発動演出に入る（インタラクティブでも即トランザム体験可能）
        sim.startActivation()
        sim.autoPilot = true

        terminal.setup(useAlternateScreen: terminal.isTTY)
        defer { terminal.restore() }

        let targetFPS: Double = 30.0
        let frameInterval: Double = 1.0 / targetFPS
        var totalElapsed: Double = 0.0
        var lastTick = Date()

        while !terminal.wasInterrupted {
            let now = Date()
            let dt = min(0.1, max(0.001, now.timeIntervalSince(lastTick)))
            lastTick = now
            totalElapsed += dt

            let size = terminal.currentSize()
            let keys = terminal.pollKeys()
            var shouldQuit = false
            for key in keys {
                if key == .quit {
                    shouldQuit = true
                    break
                }
                sim.handleInput(key, canvasWidth: size.cols, canvasHeight: size.rows)
            }
            if shouldQuit { break }

            sim.step(dt: dt, width: size.cols, height: size.rows)

            var canvas = CanvasBuffer(width: size.cols, height: size.rows)
            sim.render(into: &canvas)
            let frameText = canvas.renderANSI(
                colorEnabled: opts.colorEnabled,
                moveCursorHome: terminal.isTTY
            )
            terminal.writeRaw(frameText)
            if !terminal.isTTY {
                terminal.writeRaw("\n")
            }

            if let limit = maxDuration, totalElapsed >= limit {
                break
            }

            let sleepUs = UInt32(max(1_000, Int(frameInterval * 1_000_000)))
            usleep(sleepUs)
        }
    }

    private static func renderSnapshot(sim: TransAmSimulation, phaseName: String, colorEnabled: Bool) {
        let width = 84
        let height = 26
        var canvas = CanvasBuffer(width: width, height: height)

        switch phaseName.lowercased() {
        case "emblem":
            sim.startActivation()
            sim.step(dt: 0.78, width: width, height: height)
        case "trails":
            sim.phase = .active
            sim.autoPilot = true
            for _ in 0..<45 {
                sim.step(dt: 0.035, width: width, height: height)
            }
        default: // "climax"
            sim.startActivation()
            var elapsed = 0.0
            while elapsed < 1.22 {
                sim.step(dt: 0.04, width: width, height: height)
                elapsed += 0.04
            }
        }

        sim.render(into: &canvas)
        print(canvas.renderANSI(colorEnabled: colorEnabled, moveCursorHome: false))
    }
}
