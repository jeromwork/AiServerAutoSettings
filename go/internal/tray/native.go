//go:build windows || linux

package tray

import (
	"bytes"
	"context"
	"image"
	"image/color"
	"image/png"
	"runtime"
	"strings"
	"time"

	"github.com/gogpu/systray"
	"remoteagents/internal/bus"
)

// LabTray.cs menu, driven only by launcher messages and process events.
func (t *Tray) Run(ctx context.Context) error {
	if runtime.GOOS == "linux" && !desktopAvailable() {
		if t.o.Ready != nil {
			t.o.Ready()
		}
		<-ctx.Done()
		return nil
	}
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	icon := systray.New().SetAppName("RemoteAgents")
	icons := map[string][]byte{}
	for name, c := range map[string]color.RGBA{"grey": {128, 128, 128, 255}, "yellow": {218, 165, 32, 255}, "green": {34, 139, 34, 255}, "red": {178, 34, 34, 255}} {
		img := image.NewRGBA(image.Rect(0, 0, 32, 32))
		for y := 2; y < 30; y++ {
			for x := 2; x < 30; x++ {
				if (x-16)*(x-16)+(y-16)*(y-16) < 196 {
					img.SetRGBA(x, y, c)
				}
			}
		}
		var b bytes.Buffer
		_ = png.Encode(&b, img)
		icons[name] = b.Bytes()
	}
	icon.SetIcon(icons["grey"]).SetTooltip("Запуск")
	open := func() {
		t.mu.Lock()
		url := t.url
		t.mu.Unlock()
		if url != "" {
			t.open(url)
		} else {
			icon.ShowNotification("Состояние", "Запуск")
		}
	}
	menu := systray.NewMenu()
	menu.Add("Открыть окно", open)
	control := menu.AddCheckbox("Управление компьютером", false, func() {
		t.mu.Lock()
		on := !t.control
		t.mu.Unlock()
		t.command("control", map[string]any{"enabled": on})
	})
	menu.AddSeparator()
	menu.Add("Открыть Happier", func() { t.open("http://127.0.0.1:47831") })
	disk := menu.Add("Диск", func() {
		t.mu.Lock()
		home := t.home
		t.mu.Unlock()
		if home != "" {
			t.open(home)
		}
	})
	disk.SetDisabled(true)
	menu.AddSeparator()
	menu.Add("Состояние", func() {
		t.mu.Lock()
		text := t.tip + "\n" + strings.Join(t.lines, "\n")
		t.mu.Unlock()
		icon.ShowNotification("Состояние", text)
	})
	menu.Add("Скопировать отчёт", func() { t.command("report", nil) })
	menu.AddSeparator()
	update := menu.Add("Обновить", func() { t.command("update", nil) })
	update.SetDisabled(true)
	rollback := menu.Add("Вернуть предыдущую версию", func() { t.command("rollback", nil) })
	rollback.SetDisabled(true)
	menu.AddSeparator()
	menu.Add("Выход", func() { t.command("exit", map[string]any{"final": true}) })
	icon.SetMenu(menu).OnClick(open).OnDoubleClick(open).Show()
	unsub := t.o.Bus.Subscribe("supervisor.message", func(ev bus.Event) {
		t.mu.Lock()
		switch ev.Data["t"] {
		case "ui":
			t.url, _ = ev.Data["url"].(string)
		case "state":
			t.control, _ = ev.Data["control"].(bool)
			t.disk, _ = ev.Data["disk"].(bool)
			t.home, _ = ev.Data["diskHome"].(string)
			t.tip, _ = ev.Data["tip"].(string)
			t.lines = nil
			if rows, ok := ev.Data["lines"].([]any); ok {
				for _, row := range rows {
					if s, ok := row.(string); ok {
						t.lines = append(t.lines, s)
					}
				}
			}
			if c, ok := ev.Data["color"].(string); ok {
				icon.SetIcon(icons[c])
			}
		case "core":
			t.running, _ = ev.Data["running"].(bool)
			t.rollback, _ = ev.Data["rollback"].(bool)
			if !t.running {
				t.disk = false
				icon.SetIcon(icons["red"])
				t.tip = "Остановлено"
			}
		case "update-progress":
			t.locked, _ = ev.Data["locked"].(bool)
			if s, ok := ev.Data["text"].(string); ok && s != "" {
				update.SetLabel(s)
			} else {
				update.SetLabel("Обновить")
			}
		case "notice":
			if s, ok := ev.Data["text"].(string); ok {
				icon.ShowNotification("RemoteAgents", s)
			}
		case "report":
			if s, ok := ev.Data["text"].(string); ok {
				go func() {
					if runtime.GOOS != "windows" {
						t.copy(ctx, s)
						return
					}
					c, cancel := context.WithTimeout(ctx, 5*time.Second)
					defer cancel()
					t.copy(c, s)
				}()
			}
		case "open-ui":
			go open()
		}
		control.SetChecked(t.control)
		disk.SetDisabled(!t.disk || t.home == "")
		update.SetDisabled(!t.running || t.locked)
		rollback.SetDisabled(!t.rollback || t.locked)
		icon.SetTooltip(t.tip)
		t.mu.Unlock()
	})
	defer unsub()
	if t.o.Ready != nil {
		t.o.Ready()
	}
	go func() { <-ctx.Done(); icon.Remove() }()
	return icon.Run()
}
