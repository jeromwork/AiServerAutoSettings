package core

import (
	"archive/zip"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"remoteagents/internal/agent"
	"remoteagents/internal/api"
	"remoteagents/internal/autostart"
	"remoteagents/internal/config"
)

func (a *App) UpdateCheck(ctx context.Context) (*api.Release, error) { return a.updater.Check(ctx) }
func (a *App) UpdateNow(ctx context.Context) error {
	if !a.op.TryLock() {
		return api.ErrBusy
	}
	defer a.op.Unlock()
	r, err := a.updater.Check(ctx)
	if err != nil {
		return err
	}
	if r.Version == a.f.Version {
		return nil
	}
	candidate, err := a.updater.Fetch(ctx, *r)
	if err != nil {
		return err
	}
	if err = a.updater.Stage(ctx, candidate, r.Version); err != nil {
		return err
	}
	return a.Restart(ctx)
}

// The HTTP agent restarts after sending the /code response; staging never restarts.
func (a *App) InstallDev(ctx context.Context, body io.Reader, sha, version string) error {
	if !a.op.TryLock() {
		return api.ErrBusy
	}
	defer a.op.Unlock()
	candidate, err := a.updater.ReceiveDev(ctx, body, sha, version)
	if err != nil {
		return err
	}
	return a.updater.Stage(ctx, candidate, version)
}
func (a *App) ConfigCheck(data []byte, password string) error {
	_, _, err := config.Open(data, password)
	return err
}
func (a *App) ConfigApply(ctx context.Context, data []byte, password string) error {
	if !a.op.TryLock() {
		return api.ErrBusy
	}
	defer a.op.Unlock()
	if _, err := config.Apply(a.p, data, password, a.log); err != nil {
		return err
	}
	if a.f.Mode.AllowsSystemChanges() {
		on := true
		var root map[string]json.RawMessage
		_ = json.Unmarshal(data, &root)
		if value, ok := root["autostart"]; ok {
			_ = json.Unmarshal(value, &on)
		}
		var err error
		if on {
			err = autostart.Enable(a.launcher())
		} else {
			err = autostart.Disable()
		}
		if err != nil {
			a.log.Warn("autostart.failed", "err", err)
		}
	}
	return nil // webui restarts after its reply, as with /code.
}
func (a *App) ConfigRevert(context.Context) error {
	if !a.op.TryLock() {
		return api.ErrBusy
	}
	defer a.op.Unlock()
	return config.Revert(a.p, a.log)
}
func (a *App) SetControl(on bool) error {
	if err := agent.SetEnabled(a.p, on); err != nil {
		return err
	}
	a.bus.Publish("control.changed", map[string]any{"enabled": on})
	a.link.Refresh()
	return nil
}
func (a *App) SwitchPath(name string) error {
	if a.rounds == nil {
		return errors.New("канал не настроен")
	}
	return a.rounds.ForcePath(name)
}
func (a *App) HappierURL() (string, error) {
	port := 47831
	if h := a.cfg.Happier.LocalWeb; h != nil && h.Enabled && h.Port != 0 {
		port = h.Port
	}
	return fmt.Sprintf("http://127.0.0.1:%d", port), nil
}
func (a *App) LogTail(n int) []string { return a.log.Tail(n) }
func (a *App) LogZip(w io.Writer) error {
	z := zip.NewWriter(w)
	f, err := z.Create("report.txt")
	if err == nil {
		_, err = io.WriteString(f, a.report())
	}
	closeErr := z.Close()
	return errors.Join(err, closeErr)
}
func (a *App) LogSend(ctx context.Context) error               { return api.ErrNotSupported } // v2 has no Actions endpoint for this.
func (a *App) Leftovers(ctx context.Context) ([]string, error) { return a.cleaner.Check(ctx), nil }
func (a *App) Restart(context.Context) error                   { a.bus.Publish("app.restart", nil); return nil }
func (a *App) Exit(context.Context) error {
	a.link.Send(map[string]any{"t": api.MsgExit})
	a.bus.Publish("app.stop", nil)
	return nil
}
func (a *App) Rollback(ctx context.Context, reason string) error {
	if !a.op.TryLock() {
		return api.ErrBusy
	}
	defer a.op.Unlock()
	var st struct {
		Current  string `json:"current"`
		LastGood string `json:"lastGood"`
		Previous string `json:"previous"`
	}
	data, err := os.ReadFile(filepath.Join(a.p.Versions, "state.json"))
	if err != nil {
		return err
	}
	if err = json.Unmarshal(data, &st); err != nil {
		return err
	}
	if st.Previous != "" && st.LastGood == st.Current {
		st.LastGood = st.Previous
	}
	if st.LastGood == "" || st.LastGood == st.Current {
		return errors.New("нет предыдущей рабочей версии")
	}
	data, _ = json.Marshal(map[string]string{"dir": st.LastGood})
	path := filepath.Join(a.p.Versions, "pending.json")
	if err = os.WriteFile(path+".tmp", data, 0600); err != nil {
		return err
	}
	if err = os.Rename(path+".tmp", path); err != nil {
		return err
	}
	a.log.Info("rollback", "why", reason)
	return a.Restart(ctx)
}
func (a *App) updateRequest(ctx context.Context, send func(map[string]any), rollback bool) {
	send(map[string]any{"t": "update-progress", "locked": true, "text": "Обновляю…"})
	var err error
	if rollback {
		err = a.Rollback(ctx, "tray")
	} else {
		err = a.UpdateNow(ctx)
	}
	send(map[string]any{"t": "update-progress", "locked": false, "text": ""})
	if err != nil {
		a.log.Warn("update.failed", "err", err)
		send(map[string]any{"t": "notice", "text": err.Error()})
	}
}
func (a *App) autoUpdate(ctx context.Context) {
	a.onceAuto.Do(func() {
		if err := a.UpdateNow(ctx); err != nil {
			a.log.Warn("update.auto", "err", err)
		}
	})
}
func (a *App) VPN(mode string) error {
	if !a.f.Mode.AllowsTun() {
		return api.ErrSafe
	}
	if a.vpn == nil || !a.cfg.Enabled("vpn") {
		return errors.New("VPN не настроен")
	}
	if mode != "off" && mode != "auto" && mode != "only" {
		return errors.New("неверный режим VPN")
	}
	a.vpnMu.Lock()
	defer a.vpnMu.Unlock()
	copyCfg := *a.vpnCfg
	a.vpnCfg = &copyCfg
	// RenderVPN reads Raw to distinguish a missing section; preserve every other field.
	var raw map[string]json.RawMessage
	_ = json.Unmarshal(a.vpnCfg.Raw, &raw)
	var v map[string]any
	_ = json.Unmarshal(raw["vpn"], &v)
	if v == nil {
		v = map[string]any{}
	}
	v["mode"] = mode
	raw["vpn"], _ = json.Marshal(v)
	a.vpnCfg.Raw, _ = json.Marshal(raw)
	a.vpnCfg.VPN.Mode = mode
	data, _ := json.Marshal(map[string]string{"mode": mode})
	path := filepath.Join(a.p.State, "vpn.json")
	if err := os.WriteFile(path+".tmp", data, 0600); err != nil {
		return err
	}
	if err := os.Rename(path+".tmp", path); err != nil {
		return err
	}
	a.bus.Publish("vpn.request", nil)
	return nil
}
