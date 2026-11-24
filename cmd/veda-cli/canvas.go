package main

import (
	"fmt"
	"strings"
)

type RGBColor struct {
	R, G, B uint8
	Valid   bool
}

func rgb(r, g, b uint8) RGBColor {
	return RGBColor{R: r, G: g, B: b, Valid: true}
}

var (
	colorNone         = RGBColor{}
	colorWhite        = rgb(255, 245, 248)
	colorGNEmerald    = rgb(48, 230, 174)
	colorGNDim        = rgb(24, 96, 78)
	colorTransAmHot   = rgb(255, 135, 175)
	colorTransAmRed   = rgb(255, 28, 78)
	colorTransAmDeep  = rgb(175, 12, 48)
	colorTransAmEmber = rgb(92, 8, 28)
	colorDimGray      = rgb(120, 125, 135)
)

func (c RGBColor) Scaled(factor float64) RGBColor {
	if !c.Valid {
		return c
	}
	if factor < 0 {
		factor = 0
	} else if factor > 1.5 {
		factor = 1.5
	}
	clampByte := func(v float64) uint8 {
		if v > 255 {
			return 255
		}
		if v < 0 {
			return 0
		}
		return uint8(v)
	}
	return rgb(
		clampByte(float64(c.R)*factor),
		clampByte(float64(c.G)*factor),
		clampByte(float64(c.B)*factor),
	)
}

func lerpColor(a, b RGBColor, t float64) RGBColor {
	p := clamp01(t)
	return rgb(
		uint8(float64(a.R)+(float64(b.R)-float64(a.R))*p),
		uint8(float64(a.G)+(float64(b.G)-float64(a.G))*p),
		uint8(float64(a.B)+(float64(b.B)-float64(a.B))*p),
	)
}

type Cell struct {
	Ch   rune
	Fg   RGBColor
	Bg   RGBColor
	Bold bool
}

// CanvasBuffer はフリッカー防止のダブルバッファ ANSI キャンバス。
type CanvasBuffer struct {
	Width  int
	Height int
	cells  []Cell
}

func NewCanvasBuffer(width, height int) *CanvasBuffer {
	if width < 1 {
		width = 1
	}
	if height < 1 {
		height = 1
	}
	cb := &CanvasBuffer{
		Width:  width,
		Height: height,
		cells:  make([]Cell, width*height),
	}
	cb.Clear(colorNone)
	return cb
}

func (c *CanvasBuffer) Clear(bg RGBColor) {
	empty := Cell{Ch: ' ', Fg: colorNone, Bg: bg, Bold: false}
	for i := range c.cells {
		c.cells[i] = empty
	}
}

func (c *CanvasBuffer) Set(x, y int, ch rune, fg, bg RGBColor, bold bool) {
	if x < 0 || x >= c.Width || y < 0 || y >= c.Height {
		return
	}
	idx := y*c.Width + x
	resolvedBg := bg
	if !resolvedBg.Valid {
		resolvedBg = c.cells[idx].Bg
	}
	c.cells[idx] = Cell{Ch: ch, Fg: fg, Bg: resolvedBg, Bold: bold}
}

func (c *CanvasBuffer) DrawText(text string, x, y int, fg, bg RGBColor, bold bool) {
	if y < 0 || y >= c.Height {
		return
	}
	cx := x
	for _, r := range text {
		if cx >= 0 && cx < c.Width {
			c.Set(cx, y, r, fg, bg, bold)
		}
		cx++
	}
}

func (c *CanvasBuffer) DrawHorizontalLine(y, x0, x1 int, ch rune, fg RGBColor, bold bool) {
	if y < 0 || y >= c.Height {
		return
	}
	if x0 > x1 {
		x0, x1 = x1, x0
	}
	if x0 < 0 {
		x0 = 0
	}
	if x1 >= c.Width {
		x1 = c.Width - 1
	}
	for x := x0; x <= x1; x++ {
		c.Set(x, y, ch, fg, colorNone, bold)
	}
}

func (c *CanvasBuffer) DrawFrameBorder(fg RGBColor, title string) {
	if c.Width < 4 || c.Height < 4 {
		return
	}
	c.Set(0, 0, '┌', fg, colorNone, false)
	c.Set(c.Width-1, 0, '┐', fg, colorNone, false)
	c.Set(0, c.Height-1, '└', fg, colorNone, false)
	c.Set(c.Width-1, c.Height-1, '┘', fg, colorNone, false)

	for x := 1; x < c.Width-1; x++ {
		c.Set(x, 0, '─', fg, colorNone, false)
		c.Set(x, c.Height-1, '─', fg, colorNone, false)
	}
	for y := 1; y < c.Height-1; y++ {
		c.Set(0, y, '│', fg, colorNone, false)
		c.Set(c.Width-1, y, '│', fg, colorNone, false)
	}
	if title != "" {
		c.DrawText(" "+title+" ", 2, 0, fg, colorNone, true)
	}
}

func (c *CanvasBuffer) DrawSprite(lines []string, centerX, centerY int, fg RGBColor, bold, skipSpaces bool, densityScale float64) {
	spriteH := len(lines)
	spriteW := 0
	for _, line := range lines {
		if n := len([]rune(line)); n > spriteW {
			spriteW = n
		}
	}
	startX := centerX - spriteW/2
	startY := centerY - spriteH/2

	for rowIdx, line := range lines {
		y := startY + rowIdx
		if y < 0 || y >= c.Height {
			continue
		}
		colIdx := 0
		for _, ch := range line {
			x := startX + colIdx
			colIdx++
			if x < 0 || x >= c.Width {
				continue
			}
			if skipSpaces && ch == ' ' {
				continue
			}
			mapped := degradeRune(ch, densityScale)
			if mapped != ' ' {
				c.Set(x, y, mapped, fg, colorNone, bold)
			}
		}
	}
}

// RenderANSI は 1 フレームを単一文字列へ組み立てて ANSI 出力を最小化する。
func (c *CanvasBuffer) RenderANSI(colorEnabled, moveCursorHome bool) string {
	var b strings.Builder
	est := c.Width * c.Height * 2
	if colorEnabled {
		est = c.Width * c.Height * 14
	}
	b.Grow(est)

	if moveCursorHome {
		b.WriteString("\x1b[H")
	}

	var lastFg, lastBg RGBColor
	lastBold := false

	for y := 0; y < c.Height; y++ {
		rowStart := y * c.Width
		for x := 0; x < c.Width; x++ {
			cell := c.cells[rowStart+x]
			if colorEnabled {
				if cell.Bold != lastBold {
					if cell.Bold {
						b.WriteString("\x1b[1m")
					} else {
						b.WriteString("\x1b[22m")
					}
					lastBold = cell.Bold
				}
				if cell.Fg != lastFg {
					if cell.Fg.Valid {
						fmt.Fprintf(&b, "\x1b[38;2;%d;%d;%dm", cell.Fg.R, cell.Fg.G, cell.Fg.B)
					} else {
						b.WriteString("\x1b[39m")
					}
					lastFg = cell.Fg
				}
				if cell.Bg != lastBg {
					if cell.Bg.Valid {
						fmt.Fprintf(&b, "\x1b[48;2;%d;%d;%dm", cell.Bg.R, cell.Bg.G, cell.Bg.B)
					} else {
						b.WriteString("\x1b[49m")
					}
					lastBg = cell.Bg
				}
			}
			b.WriteRune(cell.Ch)
		}
		if colorEnabled {
			b.WriteString("\x1b[0m")
			lastFg = colorNone
			lastBg = colorNone
			lastBold = false
		}
		if y < c.Height-1 {
			b.WriteByte('\n')
		}
	}

	return b.String()
}

func degradeRune(ch rune, density float64) rune {
	if density >= 0.65 {
		return ch
	}
	if density >= 0.42 {
		switch ch {
		case '█', '▓', '●', '◈', '#':
			return '▒'
		case '/', '\\', '|', '-', '_', '=', '[', ']', '╭', '╮', '╰', '╯', '─', '│', '├', '┤':
			return ch
		default:
			return ':'
		}
	}
	if density >= 0.22 {
		switch ch {
		case ' ':
			return ' '
		case '/', '\\', '|':
			return ':'
		default:
			return '·'
		}
	}
	if density >= 0.08 {
		return '.'
	}
	return ' '
}
