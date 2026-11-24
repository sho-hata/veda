package main

import (
	"fmt"
	"math"
)

type SpriteKind string

const (
	SpriteGundam SpriteKind = "GUNDAM-00"
	SpriteWindow SpriteKind = "VEDA-WIN"
)

type TransAmPhase int

const (
	PhaseStandby TransAmPhase = iota
	PhaseActivating
	PhaseActive
)

type AsciiAfterimage struct {
	X        float64
	Y        float64
	Sprite   SpriteKind
	Age      float64
	Duration float64
}

func (a AsciiAfterimage) Progress() float64 {
	d := a.Duration
	if d < 0.05 {
		d = 0.05
	}
	return clamp01(a.Age / d)
}

func (a AsciiAfterimage) IsExpired() bool {
	return a.Age >= a.Duration
}

type AsciiGNParticle struct {
	X, Y     float64
	VX, VY   float64
	Age      float64
	Lifetime float64
	Glyph    rune
}

const (
	activationDuration = 2.45
	lockInTimestamp    = 1.05
	maxAfterimages     = 48
	maxParticles       = 96
)

type TransAmSimulation struct {
	Phase             TransAmPhase
	ActivationElapsed float64
	SpriteKind        SpriteKind
	AutoPilot         bool
	FadeDuration      float64
	SpawnInterval     float64

	UnitX float64
	UnitY float64
	vx    float64
	vy    float64

	simTime       float64
	lastSpawnTime float64
	lastSpawnX    float64
	lastSpawnY    float64
	rngState      uint64

	Afterimages     []AsciiAfterimage
	Particles       []AsciiGNParticle
	shockwaveActive bool
	shockwaveAge    float64
}

func NewTransAmSimulation() *TransAmSimulation {
	return &TransAmSimulation{
		Phase:         PhaseStandby,
		SpriteKind:    SpriteGundam,
		AutoPilot:     true,
		FadeDuration:  0.55,
		SpawnInterval: 0.032,
		UnitX:         44,
		UnitY:         14,
		lastSpawnTime: -10,
		lastSpawnX:    -999,
		lastSpawnY:    -999,
		rngState:      0x5EED0001CAFEBEEF,
	}
}

func (s *TransAmSimulation) IsTransAmActive() bool {
	return s.Phase == PhaseActive
}

func (s *TransAmSimulation) StartActivation() {
	s.Phase = PhaseActivating
	s.ActivationElapsed = 0
	s.shockwaveActive = false
	s.shockwaveAge = 0
	s.Afterimages = s.Afterimages[:0]
}

func (s *TransAmSimulation) Deactivate() {
	s.Phase = PhaseStandby
}

func (s *TransAmSimulation) ToggleTransAm() {
	switch s.Phase {
	case PhaseStandby:
		s.StartActivation()
	case PhaseActivating:
		s.Phase = PhaseActive
	case PhaseActive:
		s.Deactivate()
	}
}

func (s *TransAmSimulation) ToggleSprite() {
	if s.SpriteKind == SpriteGundam {
		s.SpriteKind = SpriteWindow
	} else {
		s.SpriteKind = SpriteGundam
	}
}

func (s *TransAmSimulation) AdjustFadeDuration(delta float64) {
	v := math.Round((s.FadeDuration+delta)*100) / 100
	if v < 0.20 {
		v = 0.20
	} else if v > 1.20 {
		v = 1.20
	}
	s.FadeDuration = v
}

func (s *TransAmSimulation) HandleInput(key KeyEvent, width, height int) {
	const stepX = 5.0
	const stepY = 2.5

	switch key {
	case KeyUp:
		s.AutoPilot = false
		s.vy -= stepY * 3.5
		s.UnitY -= stepY
	case KeyDown:
		s.AutoPilot = false
		s.vy += stepY * 3.5
		s.UnitY += stepY
	case KeyLeft:
		s.AutoPilot = false
		s.vx -= stepX * 3.5
		s.UnitX -= stepX
	case KeyRight:
		s.AutoPilot = false
		s.vx += stepX * 3.5
		s.UnitX += stepX
	case KeySpace:
		s.ToggleTransAm()
	case KeyToggleAuto:
		s.AutoPilot = !s.AutoPilot
	case KeyToggleSprite:
		s.ToggleSprite()
	case KeyIncreaseFade:
		s.AdjustFadeDuration(0.10)
	case KeyDecreaseFade:
		s.AdjustFadeDuration(-0.10)
	}

	s.clampUnit(width, height)
}

func (s *TransAmSimulation) Step(dt float64, width, height int) {
	s.simTime += dt

	if s.shockwaveActive {
		s.shockwaveAge += dt
		if s.shockwaveAge > 0.75 {
			s.shockwaveActive = false
		}
	}

	switch s.Phase {
	case PhaseActivating:
		prev := s.ActivationElapsed
		next := prev + dt
		if prev < lockInTimestamp && next >= lockInTimestamp {
			s.shockwaveActive = true
			s.shockwaveAge = 0
			s.emitBurstParticles(float64(width)*0.5, float64(height)*0.5, 28)
		}
		if next >= activationDuration {
			s.Phase = PhaseActive
			s.ActivationElapsed = activationDuration
			s.UnitX = float64(width) * 0.5
			s.UnitY = float64(height) * 0.5
			s.lastSpawnX = s.UnitX
			s.lastSpawnY = s.UnitY
		} else {
			s.ActivationElapsed = next
		}

	case PhaseStandby, PhaseActive:
		speedScale := 0.75
		if s.IsTransAmActive() {
			speedScale = 1.85
		}
		if s.AutoPilot {
			cx := float64(width) * 0.5
			cy := float64(height) * 0.5
			rx := math.Max(10.0, float64(width)*0.34)
			ry := math.Max(4.0, float64(height)*0.28)
			angle := s.simTime * 1.9 * speedScale
			s.UnitX = cx + math.Cos(angle)*rx
			s.UnitY = cy + math.Sin(angle*2.0)*ry
		} else {
			s.UnitX += s.vx * dt
			s.UnitY += s.vy * dt
			damping := math.Pow(0.06, dt)
			s.vx *= damping
			s.vy *= damping
			s.clampUnit(width, height)
		}

		if s.IsTransAmActive() {
			s.maybeSpawnAfterimage()
		}
	}

	// 残像の年齢更新＆期限切れ破棄
	aliveAfter := s.Afterimages[:0]
	for _, ghost := range s.Afterimages {
		ghost.Age += dt
		if !ghost.IsExpired() {
			aliveAfter = append(aliveAfter, ghost)
		}
	}
	s.Afterimages = aliveAfter

	// GN パーティクル更新
	aliveParticles := s.Particles[:0]
	for _, p := range s.Particles {
		p.X += p.VX * dt
		p.Y += p.VY * dt
		p.Age += dt
		if p.Age < p.Lifetime {
			aliveParticles = append(aliveParticles, p)
		}
	}
	s.Particles = aliveParticles
}

func (s *TransAmSimulation) maybeSpawnAfterimage() {
	dist := math.Hypot(s.UnitX-s.lastSpawnX, (s.UnitY-s.lastSpawnY)*2.0)
	if dist < 1.6 {
		return
	}
	if (s.simTime - s.lastSpawnTime) < s.SpawnInterval {
		return
	}

	s.lastSpawnTime = s.simTime
	s.lastSpawnX = s.UnitX
	s.lastSpawnY = s.UnitY

	s.Afterimages = append(s.Afterimages, AsciiAfterimage{
		X:        s.UnitX,
		Y:        s.UnitY,
		Sprite:   s.SpriteKind,
		Age:      0,
		Duration: s.FadeDuration,
	})
	if len(s.Afterimages) > maxAfterimages {
		s.Afterimages = s.Afterimages[len(s.Afterimages)-maxAfterimages:]
	}

	s.emitBurstParticles(s.UnitX, s.UnitY, 2)
}

func (s *TransAmSimulation) emitBurstParticles(x, y float64, count int) {
	glyphs := []rune{'✦', '*', '·', '°', '+'}
	for i := 0; i < count; i++ {
		angle := s.nextRandom() * math.Pi * 2.0
		speed := 5.0 + s.nextRandom()*14.0
		gIdx := int(s.nextRandom()*float64(len(glyphs))) % len(glyphs)
		s.Particles = append(s.Particles, AsciiGNParticle{
			X:        x + (s.nextRandom()-0.5)*4.0,
			Y:        y + (s.nextRandom()-0.5)*2.0,
			VX:       math.Cos(angle) * speed,
			VY:       math.Sin(angle) * speed * 0.48,
			Age:      0,
			Lifetime: 0.35 + s.nextRandom()*0.45,
			Glyph:    glyphs[gIdx],
		})
	}
	if len(s.Particles) > maxParticles {
		s.Particles = s.Particles[len(s.Particles)-maxParticles:]
	}
}

func (s *TransAmSimulation) clampUnit(width, height int) {
	const marginX = 11.0
	const marginY = 5.0
	maxX := math.Max(marginX, float64(width)-marginX)
	maxY := math.Max(marginY, float64(height)-marginY)
	s.UnitX = math.Max(marginX, math.Min(maxX, s.UnitX))
	s.UnitY = math.Max(marginY, math.Min(maxY, s.UnitY))
}

func (s *TransAmSimulation) nextRandom() float64 {
	s.rngState = s.rngState*6364136223846793005 + 1442695040888963407
	shifted := (s.rngState >> 33) & 0x7FFFFFFF
	return float64(shifted) / float64(0x7FFFFFFF)
}

func (s *TransAmSimulation) Render(canvas *CanvasBuffer) {
	if s.Phase == PhaseActivating {
		s.renderActivationSequence(canvas, s.ActivationElapsed)
		return
	}
	s.renderFlightArena(canvas)
}

func (s *TransAmSimulation) renderActivationSequence(canvas *CanvasBuffer, t float64) {
	w := canvas.Width
	h := canvas.Height
	cx := w / 2
	cy := h / 2

	crimsonMix := clamp01((t - 0.18) / 0.24)
	primary := lerpColor(colorGNEmerald, colorTransAmRed, crimsonMix)
	flash1 := math.Exp(-math.Pow((t-0.28)/0.06, 2))
	flash2 := math.Exp(-math.Pow((t-1.05)/0.08, 2))
	flash := math.Min(1.0, flash1*0.7+flash2*0.85)

	bgTint := rgb(
		uint8(math.Min(120, (14.0+flash*85.0)*crimsonMix)),
		uint8(math.Min(40, 6.0+flash*16.0)),
		uint8(math.Min(55, (12.0+flash*30.0)*crimsonMix)),
	)
	canvas.Clear(bgTint)

	// 背景スキャングリッド
	gridColor := primary.Scaled(0.28)
	for y := 2; y < h-2; y += 3 {
		for x := 2; x < w-2; x++ {
			if (x+y)%8 == 0 {
				canvas.Set(x, y, '·', gridColor, colorNone, false)
			}
		}
	}

	// 回転する同心円 HUD リング
	ringExpand := easeOutCubic(clamp01((t - 0.08) / 0.55))
	rx := float64(minInt(w/2-4, 34)) * (0.45 + 0.55*ringExpand)
	ry := float64(minInt(h/2-2, 11)) * (0.45 + 0.55*ringExpand)
	const tickCount = 32
	ringCol := primary.Scaled(0.75 * ringExpand)
	for i := 0; i < tickCount; i++ {
		a := (float64(i)/float64(tickCount))*math.Pi*2.0 + t*1.1
		px := int(math.Round(float64(cx) + math.Cos(a)*rx))
		py := int(math.Round(float64(cy) + math.Sin(a)*ry))
		ch := '·'
		if i%4 == 0 {
			ch = '+'
		}
		canvas.Set(px, py, ch, ringCol, colorNone, false)
	}

	// GN パーティクル
	for _, p := range s.Particles {
		alpha := clamp01(1.0 - p.Age/p.Lifetime)
		col := lerpColor(colorTransAmDeep, colorTransAmHot, alpha)
		canvas.Set(int(math.Round(p.X)), int(math.Round(p.Y)), p.Glyph, col, colorNone, alpha > 0.6)
	}

	// ソレスタルビーイング エンブレム（中央から上下へ展開）
	if t >= 0.22 {
		reveal := easeOutCubic(clamp01((t - 0.22) / 0.68))
		emblem := celestialBeingEmblem
		startY := cy - len(emblem)/2
		startX := cx - len([]rune(emblem[0]))/2
		extraGlow := 0.0
		if t > 0.85 {
			extraGlow = 0.25
		}
		emblemColor := lerpColor(primary, colorWhite, math.Min(0.65, flash*0.7+extraGlow))
		coreColor := lerpColor(colorTransAmHot, colorWhite, 0.6)

		for row, line := range emblem {
			y := startY + row
			distFromMid := math.Abs(float64(row)-float64(len(emblem))*0.5) / (float64(len(emblem)) * 0.5)
			if distFromMid > reveal {
				continue
			}
			col := 0
			for _, ch := range line {
				x := startX + col
				col++
				if ch == ' ' {
					continue
				}
				fg := emblemColor
				if ch == '|' || ch == 'V' || ch == '_' || ch == '=' {
					fg = coreColor
				}
				canvas.Set(x, y, ch, fg, colorNone, true)
			}
		}
	}

	// 衝撃波リング（バナー背面）
	if s.shockwaveActive {
		s.drawShockwave(canvas, float64(cx), float64(cy), s.shockwaveAge/0.75)
	}

	// 赤色光学スキャンライン走査（1.02s 〜 1.65s）
	if t >= 1.02 && t <= 1.65 {
		beamP := clamp01((t - 1.02) / 0.58)
		beamY := 2 + int(float64(h-5)*beamP)
		canvas.DrawHorizontalLine(beamY, 2, w-3, '═', colorWhite, true)
		if beamY-1 >= 2 {
			canvas.DrawHorizontalLine(beamY-1, 2, w-3, '─', colorTransAmHot, false)
		}
		if beamY+1 < h-2 {
			canvas.DrawHorizontalLine(beamY+1, 2, w-3, '─', colorTransAmHot, false)
		}
	}

	// 「TRANS-AM」メインバナー（0.98s 〜 2.25s）
	if t >= 0.98 && t <= 2.25 {
		bannerP := easeOutCubic(clamp01((t - 0.98) / 0.25))
		banner := transAmBanner
		bannerStartY := cy - len(banner)/2
		bannerW := len([]rune(banner[0]))
		visibleHalf := int(float64(bannerW/2+1) * bannerP)
		boxBg := rgb(58, 4, 18)

		for idx, line := range banner {
			y := bannerStartY + idx
			lineStartX := cx - bannerW/2
			c := 0
			for _, ch := range line {
				x := lineStartX + c
				c++
				if absInt(x-cx) > visibleHalf {
					continue
				}
				isBorder := idx == 0 || idx == len(banner)-1
				fg := colorWhite
				if isBorder || idx == 3 {
					fg = colorTransAmHot
				}
				canvas.Set(x, y, ch, fg, boxBg, !isBorder)
			}
		}
	}

	// フレーム＆Vedaテレメトリ
	gnOutput := 100 + int(easeOutCubic(clamp01((t-0.35)/0.85))*200.0)
	title := "CELESTIAL BEING // TRANS-AM"
	if t < 0.35 {
		title = "VEDA // SYSTEM OVERRIDE"
	}
	canvas.DrawFrameBorder(primary, title)

	topRight := fmt.Sprintf(" GN OUTPUT: %d%% ", gnOutput)
	canvas.DrawText(topRight, w-len([]rune(topRight))-2, 1, colorWhite, primary.Scaled(0.45), true)

	bottomLeft := "PARTICLE DENSITY: 300% [MAX]"
	if t < 0.98 {
		bottomLeft = "LIMITER: RELEASING..."
	}
	canvas.DrawText(bottomLeft, 2, h-2, primary, colorNone, true)

	bottomRight := "AEOLIA BLACKBOX"
	canvas.DrawText(bottomRight, w-len([]rune(bottomRight))-2, h-2, colorDimGray, colorNone, false)
}

func (s *TransAmSimulation) renderFlightArena(canvas *CanvasBuffer) {
	w := canvas.Width
	h := canvas.Height
	active := s.IsTransAmActive()

	accent := colorGNEmerald
	bg := rgb(6, 12, 16)
	watermark := rgb(16, 42, 36)
	if active {
		accent = colorTransAmRed
		bg = rgb(18, 3, 9)
		watermark = rgb(58, 10, 24)
	}

	canvas.Clear(bg)

	// 背景ソレスタルビーイング透かし
	canvas.DrawSprite(celestialBeingEmblem, w/2, h/2, watermark, false, true, 1.0)

	// GN パーティクル
	for _, p := range s.Particles {
		lifeLeft := clamp01(1.0 - p.Age/p.Lifetime)
		col := lerpColor(colorGNDim, colorGNEmerald, lifeLeft)
		if active {
			col = lerpColor(colorTransAmEmber, colorTransAmHot, lifeLeft)
		}
		canvas.Set(int(math.Round(p.X)), int(math.Round(p.Y)), p.Glyph, col, colorNone, lifeLeft > 0.65)
	}

	// トランザム残像（古い順 → 新しい順）
	for _, ghost := range s.Afterimages {
		p := ghost.Progress()
		brightness := 1.0 - p
		var col RGBColor
		switch {
		case p < 0.25:
			col = lerpColor(colorTransAmHot, colorTransAmRed, p/0.25)
		case p < 0.65:
			col = lerpColor(colorTransAmRed, colorTransAmDeep, (p-0.25)/0.40)
		default:
			col = lerpColor(colorTransAmDeep, colorTransAmEmber, (p-0.65)/0.35)
		}

		lines := spriteLines(ghost.Sprite, true)
		canvas.DrawSprite(lines, int(math.Round(ghost.X)), int(math.Round(ghost.Y)), col, p < 0.35, true, brightness)
	}

	// 本体ユニット
	mainLines := spriteLines(s.SpriteKind, active)
	mainColor := colorGNEmerald
	if active {
		mainColor = colorWhite
	}
	canvas.DrawSprite(
		mainLines,
		int(math.Round(s.UnitX)),
		int(math.Round(s.UnitY)),
		mainColor,
		true,
		s.SpriteKind == SpriteGundam,
		1.0,
	)

	// 外枠・ステータス
	title := "VEDA CLI // GN-DRIVE STANDBY [GN 100%]"
	if active {
		title = "VEDA CLI // TRANS-AM ACTIVE [GN 300%]"
	}
	canvas.DrawFrameBorder(accent, title)

	modeStr := "MANUAL"
	if s.AutoPilot {
		modeStr = "AUTO"
	}
	stats := fmt.Sprintf(" UNIT:%s | MODE:%s | FADE:%.2fs | TRAILS:%02d ", s.SpriteKind, modeStr, s.FadeDuration, len(s.Afterimages))
	statColor := colorGNEmerald
	if active {
		statColor = colorTransAmHot
	}
	canvas.DrawText(stats, 2, 1, statColor, colorNone, true)

	controls := "[Space] Trans-Am  [Arrows/WASD] Move  [P] Auto  [M] Sprite  [+/-] Fade  [Q] Quit"
	ctrlRunes := []rune(controls)
	if len(ctrlRunes) > w-4 && w > 4 {
		controls = string(ctrlRunes[:w-4])
	}
	canvas.DrawText(controls, 2, h-2, colorDimGray, colorNone, false)
}

func (s *TransAmSimulation) drawShockwave(canvas *CanvasBuffer, cx, cy, progress float64) {
	p := clamp01(progress)
	rx := 8.0 + p*float64(canvas.Width)*0.45
	ry := 4.0 + p*float64(canvas.Height)*0.45
	const steps = 56
	col := lerpColor(colorWhite, colorTransAmRed, p).Scaled(1.0 - p*0.8)
	ch := '·'
	if p < 0.4 {
		ch = '○'
	}
	for i := 0; i < steps; i++ {
		a := (float64(i) / float64(steps)) * math.Pi * 2.0
		x := int(math.Round(cx + math.Cos(a)*rx))
		y := int(math.Round(cy + math.Sin(a)*ry))
		canvas.Set(x, y, ch, col, colorNone, p < 0.35)
	}
}

func spriteLines(kind SpriteKind, active bool) []string {
	if kind == SpriteWindow {
		if active {
			return windowSprite
		}
		return standbyWindowSprite
	}
	return gundamSprite
}

func clamp01(v float64) float64 {
	if v < 0 {
		return 0
	}
	if v > 1 {
		return 1
	}
	return v
}

func easeOutCubic(x float64) float64 {
	return 1.0 - math.Pow(1.0-x, 3)
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func absInt(x int) int {
	if x < 0 {
		return -x
	}
	return x
}
