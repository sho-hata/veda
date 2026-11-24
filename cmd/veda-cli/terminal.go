package main

import (
	"os"
	"sync"
)

type KeyEvent int

const (
	KeyNone KeyEvent = iota
	KeyUp
	KeyDown
	KeyLeft
	KeyRight
	KeySpace
	KeyToggleAuto
	KeyToggleSprite
	KeyIncreaseFade
	KeyDecreaseFade
	KeyQuit
)

type TerminalSize struct {
	Cols int
	Rows int
}

type TerminalController struct {
	mu             sync.Mutex
	isTTY          bool
	altScreen      bool
	restored       bool
	platformState  *platformTerminalState
	keyCh          chan KeyEvent
	stopReaderCh   chan struct{}
}

func NewTerminalController() *TerminalController {
	return &TerminalController{
		isTTY:        isTerminalFD(int(os.Stdin.Fd())) && isTerminalFD(int(os.Stdout.Fd())),
		keyCh:        make(chan KeyEvent, 64),
		stopReaderCh: make(chan struct{}),
	}
}

func (t *TerminalController) IsTTY() bool {
	return t.isTTY
}

func (t *TerminalController) Setup(useAltScreen bool) {
	t.mu.Lock()
	defer t.mu.Unlock()

	if t.isTTY {
		t.platformState = enableRawMode(int(os.Stdin.Fd()))
		go t.readInputLoop()
	}

	if useAltScreen && t.isTTY {
		t.altScreen = true
		t.WriteRaw("\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H")
	} else if t.isTTY {
		t.WriteRaw("\x1b[?25l")
	}
}

func (t *TerminalController) Restore() {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.restored {
		return
	}
	t.restored = true
	close(t.stopReaderCh)

	if t.platformState != nil {
		restoreRawMode(int(os.Stdin.Fd()), t.platformState)
		t.platformState = nil
	}

	if t.altScreen {
		t.altScreen = false
		t.WriteRaw("\x1b[0m\x1b[?25h\x1b[?1049l")
	} else if t.isTTY {
		t.WriteRaw("\x1b[0m\x1b[?25h")
	} else {
		t.WriteRaw("\x1b[0m")
	}
}

func (t *TerminalController) CurrentSize() TerminalSize {
	if cols, rows, ok := queryTerminalSize(int(os.Stdout.Fd())); ok && cols >= 40 && rows >= 18 {
		return TerminalSize{Cols: cols, Rows: rows}
	}
	return TerminalSize{Cols: 88, Rows: 28}
}

func (t *TerminalController) WriteRaw(s string) {
	_, _ = os.Stdout.WriteString(s)
}

func (t *TerminalController) PollKeys() []KeyEvent {
	var events []KeyEvent
	for {
		select {
		case ev := <-t.keyCh:
			events = append(events, ev)
		default:
			return events
		}
	}
}

func (t *TerminalController) readInputLoop() {
	buf := make([]byte, 32)
	for {
		select {
		case <-t.stopReaderCh:
			return
		default:
		}
		n, err := os.Stdin.Read(buf)
		if err != nil || n == 0 {
			return
		}
		for _, ev := range parseInputBytes(buf[:n]) {
			select {
			case t.keyCh <- ev:
			default:
			}
		}
	}
}

func parseInputBytes(buf []byte) []KeyEvent {
	var events []KeyEvent
	for i := 0; i < len(buf); {
		b := buf[i]
		if b == 0x1b {
			if i+2 < len(buf) && buf[i+1] == '[' {
				switch buf[i+2] {
				case 'A':
					events = append(events, KeyUp)
				case 'B':
					events = append(events, KeyDown)
				case 'C':
					events = append(events, KeyRight)
				case 'D':
					events = append(events, KeyLeft)
				}
				i += 3
				continue
			}
			events = append(events, KeyQuit)
			i++
			continue
		}

		switch b {
		case 0x03, 'q', 'Q':
			events = append(events, KeyQuit)
		case ' ':
			events = append(events, KeySpace)
		case 'w', 'W', 'k', 'K':
			events = append(events, KeyUp)
		case 's', 'S', 'j', 'J':
			events = append(events, KeyDown)
		case 'a', 'h', 'H':
			events = append(events, KeyLeft)
		case 'A', 'p', 'P':
			events = append(events, KeyToggleAuto)
		case 'd', 'D', 'l', 'L':
			events = append(events, KeyRight)
		case 'm', 'M':
			events = append(events, KeyToggleSprite)
		case '+', '=', ']':
			events = append(events, KeyIncreaseFade)
		case '-', '_', '[':
			events = append(events, KeyDecreaseFade)
		}
		i++
	}
	return events
}
