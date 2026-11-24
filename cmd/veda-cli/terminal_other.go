//go:build !darwin && !linux

package main

type platformTerminalState struct{}

func isTerminalFD(_ int) bool                                { return false }
func enableRawMode(_ int) *platformTerminalState             { return nil }
func restoreRawMode(_ int, _ *platformTerminalState)         {}
func queryTerminalSize(_ int) (cols int, rows int, ok bool)  { return 88, 28, false }
