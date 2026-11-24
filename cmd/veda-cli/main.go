package main

import (
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

const helpText = `veda-cli — ガンダム00 トランザム ASCII Art CLI (Go)

USAGE:
  veda-cli [OPTIONS]
  go run ./cmd/veda-cli [OPTIONS]

OPTIONS:
  -demo                   発動モーション後、自動で高速トランザム残像デモを再生して終了
  -activation-only        ソレスタルビーイングのコックピット発動モーションのみ再生
  -duration <秒>          デモ実行時間（秒、デフォルト: 7.0）
  -gundam                 ガンダム00 シルエットで表示（デフォルト）
  -window                 Veda ウィンドウフレームの ASCII 版で表示
  -snapshot <phase>       静止ASCIIアートを1フレーム出力 (emblem | climax | trails)
  -no-color               ANSI カラーを無効化してモノクロ出力
  -h, -help               このヘルプを表示

INTERACTIVE KEYS:
  Space                   トランザム起動（コックピット演出） / 停止
  Arrow / WASD / HJKL     手動操作で機体を移動（赤いASCII残像が発生）
  P                       オートパイロット（高速8の字軌道）切替
  M                       スプライト切替（GUNDAM-00 ⇄ VEDA-WIN）
  + / -                   残像の持続時間調整（0.20s 〜 1.20s）
  Q / Esc / Ctrl+C        終了
`

func main() {
	demoMode := flag.Bool("demo", false, "発動モーション後に自動で高速トランザム残像デモを再生して終了")
	activationOnly := flag.Bool("activation-only", false, "コックピット発動モーションのみ再生")
	durationSec := flag.Float64("duration", 0, "実行時間（秒）")
	useWindow := flag.Bool("window", false, "Veda ウィンドウフレームの ASCII 版で表示")
	useGundam := flag.Bool("gundam", false, "ガンダム00 シルエットで表示")
	snapshotPhase := flag.String("snapshot", "", "静止ASCIIアートを1フレーム出力 (emblem|climax|trails)")
	noColor := flag.Bool("no-color", false, "ANSIカラー無効化")

	flag.Usage = func() {
		fmt.Fprint(os.Stderr, helpText)
	}
	flag.Parse()

	colorEnabled := !*noColor

	sim := NewTransAmSimulation()
	if *useWindow && !*useGundam {
		sim.SpriteKind = SpriteWindow
	} else {
		sim.SpriteKind = SpriteGundam
	}

	if *snapshotPhase != "" {
		renderSnapshot(sim, *snapshotPhase, colorEnabled)
		return
	}

	term := NewTerminalController()
	isDemo := *demoMode || *activationOnly || !term.IsTTY()
	maxDuration := *durationSec
	if *activationOnly {
		maxDuration = activationDuration + 0.1
	} else if isDemo && maxDuration <= 0 {
		maxDuration = 7.0
	}

	sigCh := make(chan os.Signal, 2)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(sigCh)

	sim.StartActivation()
	sim.AutoPilot = true

	term.Setup(term.IsTTY())
	defer term.Restore()

	const targetFPS = 30.0
	ticker := time.NewTicker(time.Duration(float64(time.Second) / targetFPS))
	defer ticker.Stop()

	lastTick := time.Now()
	totalElapsed := 0.0

	for {
		select {
		case <-sigCh:
			return
		case now := <-ticker.C:
			dt := now.Sub(lastTick).Seconds()
			if dt < 0.001 {
				dt = 0.001
			} else if dt > 0.1 {
				dt = 0.1
			}
			lastTick = now
			totalElapsed += dt

			size := term.CurrentSize()
			for _, key := range term.PollKeys() {
				if key == KeyQuit {
					return
				}
				sim.HandleInput(key, size.Cols, size.Rows)
			}

			sim.Step(dt, size.Cols, size.Rows)

			canvas := NewCanvasBuffer(size.Cols, size.Rows)
			sim.Render(canvas)
			frame := canvas.RenderANSI(colorEnabled, term.IsTTY())
			term.WriteRaw(frame)
			if !term.IsTTY() {
				term.WriteRaw("\n")
			}

			if maxDuration > 0 && totalElapsed >= maxDuration {
				return
			}
		}
	}
}

func renderSnapshot(sim *TransAmSimulation, phaseName string, colorEnabled bool) {
	const width = 84
	const height = 26
	canvas := NewCanvasBuffer(width, height)

	switch strings.ToLower(strings.TrimSpace(phaseName)) {
	case "emblem":
		sim.StartActivation()
		sim.Step(0.78, width, height)
	case "trails":
		sim.Phase = PhaseActive
		sim.AutoPilot = true
		for i := 0; i < 45; i++ {
			sim.Step(0.035, width, height)
		}
	default:
		sim.StartActivation()
		for elapsed := 0.0; elapsed < 1.22; elapsed += 0.04 {
			sim.Step(0.04, width, height)
		}
	}

	sim.Render(canvas)
	fmt.Println(canvas.RenderANSI(colorEnabled, false))
}
