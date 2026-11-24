package main

import (
	"strings"
	"testing"
)

func TestTransAmBannerAlignment(t *testing.T) {
	expected := len([]rune(transAmBanner[0]))
	for i, line := range transAmBanner {
		if got := len([]rune(line)); got != expected {
			t.Fatalf("transAmBanner[%d] rune length = %d, want %d", i, got, expected)
		}
	}
}

func TestActivationAndAfterimageLifecycle(t *testing.T) {
	sim := NewTransAmSimulation()
	sim.StartActivation()
	if sim.Phase != PhaseActivating {
		t.Fatalf("expected PhaseActivating, got %v", sim.Phase)
	}

	// 発動シークエンス完了まで進行
	for i := 0; i < 80; i++ {
		sim.Step(0.035, 84, 26)
	}
	if !sim.IsTransAmActive() {
		t.Fatalf("expected PhaseActive after activation sequence, got %v", sim.Phase)
	}

	// 自動移動で残像が生成されること
	for i := 0; i < 30; i++ {
		sim.Step(0.035, 84, 26)
	}
	if len(sim.Afterimages) == 0 {
		t.Fatalf("expected active afterimages during Trans-Am motion")
	}

	// トランザム停止後、持続時間経過で残像がすべて破棄されること
	sim.Deactivate()
	for i := 0; i < 40; i++ {
		sim.Step(0.035, 84, 26)
	}
	if len(sim.Afterimages) != 0 {
		t.Fatalf("expected 0 afterimages after fade out, got %d", len(sim.Afterimages))
	}
}

func TestSnapshotRender(t *testing.T) {
	sim := NewTransAmSimulation()
	sim.StartActivation()
	for elapsed := 0.0; elapsed < 1.22; elapsed += 0.04 {
		sim.Step(0.04, 84, 26)
	}
	canvas := NewCanvasBuffer(84, 26)
	sim.Render(canvas)
	out := canvas.RenderANSI(false, false)
	if !strings.Contains(out, "SYSTEM ACTIVATED // MODE ACT MAX") {
		t.Fatalf("expected TRANS-AM banner in climax snapshot")
	}
}
