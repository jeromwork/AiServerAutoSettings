package agent

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"syscall"
	"time"

	"remoteagents/internal/api"
)

const (
	execMax  = 64
	chunkMax = 4 << 20
	listMax  = 2000
)

func (a *Agent) dispatch(r *http.Request, route string, body []byte) response {
	switch route {
	case "status":
		return a.handleStatus()
	case "log":
		return a.handleLog(r)
	case "exec":
		return a.handleExec(r, body)
	case "proc":
		return a.handleProc(r)
	case "procs":
		return a.handleProcs()
	case "kill":
		return a.handleKill(body)
	case "read":
		return a.handleRead(r)
	case "write":
		return a.handleWrite(body)
	case "files":
		return a.handleFiles(r)
	case "code":
		return a.handleCode()
	case "restart":
		return a.handleRestart()
	case "switch":
		return a.handleSwitch(body)
	case "vpn":
		return a.handleVPN(body)
	case "update":
		return a.handleUpdate(r, body)
	case "rollback":
		return a.handleRollback(body)
	case "expose":
		return a.handleExpose(body)
	case "unexpose":
		return a.handleUnexpose(body)
	case "exposed":
		return a.handleExposed()
	default:
		return failure(404, "нет такой ручки")
	}
}

func (a *Agent) handleStatus() response {
	var st map[string]any
	if a.d.Status != nil {
		st = a.d.Status()
	} else if a.d.Act != nil {
		st = a.d.Act.Status()
	}
	out := map[string]any{
		"exe_version": "", "rollback": "", "computer": "", "uptime_s": int(time.Since(a.started).Seconds()),
		"rss_mb": 0, "events": 0, "agent_port": 0, "color": "", "state": "",
		"settings": nil, "singbox": map[string]any{}, "uplink": map[string]any{},
		"rounds": map[string]any{}, "lan": []any{}, "forward": map[string]any{},
		"tun": map[string]any{}, "vpn": map[string]any{}, "disk": "", "procs": []string{},
	}
	if host, err := os.Hostname(); err == nil {
		out["computer"] = host
	}
	for k, v := range st {
		out[k] = v
	}
	out["platform"] = runtime.GOOS
	out["arch"] = runtime.GOARCH
	out["home"] = a.d.Paths.Home
	if _, has := out["version"]; !has {
		out["version"] = ""
	}
	if _, has := out["instance"]; !has {
		out["instance"] = a.instance
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.port != 0 {
		out["agent_port"] = a.port
	}
	return ok(out)
}

func (a *Agent) handleLog(r *http.Request) response {
	n := 200
	if nStr := r.URL.Query().Get("n"); nStr != "" {
		if v, err := strconv.Atoi(nStr); err == nil && v >= 0 {
			n = v
		}
	}
	records := a.d.Act.LogTail(n)
	if records == nil {
		records = []string{}
	}
	return ok(map[string]any{"records": records})
}

func (a *Agent) handleExec(r *http.Request, body []byte) response {
	var req struct {
		Cmd   string `json:"cmd"`
		Shell string `json:"shell"`
		Cwd   string `json:"cwd"`
		Wait  bool   `json:"wait"`
	}
	if err := json.Unmarshal(body, &req); err != nil || req.Cmd == "" {
		return failure(400, "нет cmd")
	}
	if req.Shell == "" {
		if runtime.GOOS == "windows" {
			req.Shell = "powershell"
		} else {
			req.Shell = "sh"
		}
	}
	if req.Cwd == "" {
		if home, err := os.UserHomeDir(); err == nil && home != "" {
			req.Cwd = home
		} else {
			req.Cwd = a.d.Paths.Home
		}
	}

	a.execMu.Lock()
	if len(a.execs) >= execMax {
		var exitedID string
		for id, ex := range a.execs {
			if ex.proc.Exited() {
				exitedID = id
				break
			}
		}
		if exitedID == "" {
			a.execMu.Unlock()
			return failure(429, "слишком много запущенных процессов")
		}
		a.execs[exitedID].release()
		delete(a.execs, exitedID)
	}

	// Detached commands live until Agent.Close, not until the HTTP response.
	// BaseContext is a.ctx, so removing request cancellation retains agent values.
	execCtx, cancelExec := context.WithCancel(context.WithoutCancel(r.Context()))
	stopExec := context.AfterFunc(a.ctx, cancelExec) //nolint:contextcheck // Agent shutdown must cancel commands independently of the HTTP request.
	proc, err := a.d.Shell.Start(execCtx, api.ExecReq{
		Cmd:   req.Cmd,
		Shell: req.Shell,
		Cwd:   req.Cwd,
		Wait:  req.Wait,
	})
	if err != nil {
		stopExec()
		cancelExec()
		a.execMu.Unlock()
		return response{
			code: http.StatusInternalServerError,
			value: map[string]any{
				"error": fmt.Sprintf("не запустить: %v", err),
				"id":    "",
			},
		}
	}
	eid := proc.ID()
	a.execs[eid] = execution{id: eid, cmd: req.Cmd, proc: proc, release: func() { stopExec(); cancelExec() }}
	a.execMu.Unlock()

	a.d.Log.Info("exec", "id", eid)

	if !req.Wait {
		return ok(map[string]any{"id": eid})
	}

	for !proc.Exited() {
		out := proc.Read("out", 0)
		err := proc.Read("err", 0)
		proc.WaitNew(r.Context(), out.NextOff, err.NextOff, 100*time.Millisecond)
		if r.Context().Err() != nil || a.ctx.Err() != nil {
			return failure(504, "agent: canceled: execution wait interrupted")
		}
	}
	outChunk := proc.Read("out", 0)
	errChunk := proc.Read("err", 0)

	return ok(map[string]any{
		"id":        eid,
		"exited":    true,
		"code":      proc.Code(),
		"out":       string(outChunk.Data),
		"err":       string(errChunk.Data),
		"truncated": proc.Truncated(),
	})
}

func (a *Agent) handleProc(r *http.Request) response {
	id := r.URL.Query().Get("id")
	if id == "" {
		return failure(404, "нет такого процесса")
	}
	a.execMu.Lock()
	ex, found := a.execs[id]
	a.execMu.Unlock()
	if !found {
		return failure(404, "нет такого процесса")
	}

	outOff, _ := strconv.Atoi(r.URL.Query().Get("out"))
	errOff, _ := strconv.Atoi(r.URL.Query().Get("err"))
	wait := r.URL.Query().Get("wait") == "1"

	if wait {
		ex.proc.WaitNew(r.Context(), outOff, errOff, 25*time.Second)
	}

	chunkOut := ex.proc.Read("out", outOff)
	chunkErr := ex.proc.Read("err", errOff)

	outB64 := base64.StdEncoding.EncodeToString(chunkOut.Data)
	errB64 := base64.StdEncoding.EncodeToString(chunkErr.Data)
	drained := ex.proc.Drained(chunkOut.NextOff, chunkErr.NextOff)

	return ok(map[string]any{
		"id":        id,
		"out_b64":   outB64,
		"err_b64":   errB64,
		"out_off":   chunkOut.NextOff,
		"err_off":   chunkErr.NextOff,
		"exited":    drained,
		"code":      processCode(ex.proc),
		"truncated": ex.proc.Truncated(),
	})
}

func (a *Agent) handleProcs() response {
	a.execMu.Lock()
	list := make([]map[string]any, 0, len(a.execs))
	for _, ex := range a.execs {
		cmd := ex.cmd
		if len(cmd) > 80 {
			cmd = cmd[:80]
		}
		list = append(list, map[string]any{
			"id":     ex.id,
			"cmd":    cmd,
			"exited": ex.proc.Exited(),
			"code":   processCode(ex.proc),
		})
	}
	a.execMu.Unlock()
	return ok(map[string]any{"procs": list})
}

func (a *Agent) handleKill(body []byte) response {
	var req struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(body, &req)
	if req.ID == "" {
		return failure(404, "нет такого процесса")
	}
	a.execMu.Lock()
	ex, found := a.execs[req.ID]
	a.execMu.Unlock()
	if !found {
		return failure(404, "нет такого процесса")
	}
	if err := ex.proc.Kill(); err != nil {
		return failure(500, err.Error())
	}
	return ok(map[string]any{"ok": true})
}

func (a *Agent) handleRead(r *http.Request) response {
	path := r.URL.Query().Get("path")
	if path == "" {
		return failure(404, "нет path")
	}
	offset, _ := strconv.ParseInt(r.URL.Query().Get("offset"), 10, 64)
	length, _ := strconv.ParseInt(r.URL.Query().Get("length"), 10, 64)
	if length <= 0 || length > chunkMax {
		length = chunkMax
	}
	if offset < 0 {
		offset = 0
	}

	f, err := openRegular(path)
	if err != nil {
		return failure(404, fmt.Sprintf("%T: %s", err, truncate(err.Error(), 100)))
	}
	defer func() { _ = f.Close() }()

	st, err := f.Stat()
	if err != nil {
		return failure(404, fmt.Sprintf("%T: %s", err, truncate(err.Error(), 100)))
	}
	if !st.Mode().IsRegular() {
		return failure(400, "agent: file: regular file required")
	}
	size := st.Size()

	if _, err := f.Seek(offset, io.SeekStart); err != nil {
		return failure(404, fmt.Sprintf("%T: %s", err, truncate(err.Error(), 100)))
	}
	buf := make([]byte, length)
	n, err := io.ReadFull(f, buf)
	if err != nil && err != io.EOF && err != io.ErrUnexpectedEOF {
		return failure(404, fmt.Sprintf("%T: %s", err, truncate(err.Error(), 100)))
	}
	data := buf[:n]
	b64 := base64.StdEncoding.EncodeToString(data)
	eof := offset+int64(n) >= size

	return ok(map[string]any{
		"size":   size,
		"offset": offset,
		"b64":    b64,
		"eof":    eof,
	})
}

func (a *Agent) handleWrite(body []byte) response {
	var req struct {
		Path   string `json:"path"`
		B64    string `json:"b64"`
		Offset int64  `json:"offset"`
		Done   *bool  `json:"done"`
	}
	if err := json.Unmarshal(body, &req); err != nil || req.Path == "" {
		return failure(400, "нужны path, b64 (offset, done необязательно)")
	}
	data, err := base64.StdEncoding.DecodeString(req.B64)
	if err != nil {
		return failure(400, "нужны path, b64 (offset, done необязательно)")
	}
	done := true
	if req.Done != nil {
		done = *req.Done
	}

	if req.Offset < 0 {
		return failure(400, "agent: offset: must be nonnegative")
	}
	req.Path, err = filepath.Abs(req.Path)
	if err != nil {
		return failure(400, "agent: path: invalid path")
	}
	a.writeMu.Lock()
	defer a.writeMu.Unlock()
	part := req.Path + ".ralab-part"
	if _, owned := a.parts[part]; !owned && req.Offset > 0 {
		return failure(409, "нет начала файла (offset > 0 без предыдущих кусков)")
	}
	if req.Offset > 0 {
		if _, err := os.Stat(part); err != nil {
			return failure(409, "нет начала файла (offset > 0 без предыдущих кусков)")
		}
	}
	if err := os.MkdirAll(filepath.Dir(req.Path), 0700); err != nil {
		return failure(500, err.Error())
	}

	var f *os.File
	if req.Offset == 0 {
		if _, owned := a.parts[part]; owned {
			if err := os.Remove(part); err != nil {
				return failure(500, err.Error())
			}
		}
		if _, err := os.Lstat(part); err == nil || !os.IsNotExist(err) {
			return failure(409, "agent: upload: part already exists or is inaccessible")
		}
		a.parts[part] = struct{}{}
		if err := a.saveParts(); err != nil {
			delete(a.parts, part)
			return failure(500, err.Error())
		}
		f, err = os.OpenFile(part, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if err != nil {
			delete(a.parts, part)
			err = errors.Join(err, a.saveParts())
		}
	} else {
		f, err = os.OpenFile(part, os.O_WRONLY, 0600)
		if err == nil {
			_, err = f.Seek(req.Offset, io.SeekStart)
		}
	}
	if err != nil {
		if f != nil {
			_ = f.Close()
		}
		return failure(500, err.Error())
	}
	a.parts[part] = struct{}{}
	_, writeErr := f.Write(data)
	closeErr := f.Close()
	if writeErr == nil {
		writeErr = closeErr
	}
	if writeErr != nil {
		return failure(500, writeErr.Error())
	}

	if done {
		if err := os.Rename(part, req.Path); err != nil {
			return failure(500, err.Error())
		}
		delete(a.parts, part)
		if err := a.saveParts(); err != nil {
			return failure(500, err.Error())
		}
	}

	return ok(map[string]any{
		"ok":      true,
		"written": len(data),
		"done":    done,
	})
}

func (a *Agent) handleFiles(r *http.Request) response {
	path := r.URL.Query().Get("path")
	if path == "" {
		if home, err := os.UserHomeDir(); err == nil && home != "" {
			path = home
		} else {
			path = a.d.Paths.Home
		}
	}
	entries, err := os.ReadDir(path)
	if err != nil {
		return failure(404, fmt.Sprintf("%T: %s", err, truncate(err.Error(), 100)))
	}
	out := make([]map[string]any, 0, min(len(entries), listMax))
	for _, e := range entries {
		if len(out) >= listMax {
			break
		}
		name := e.Name()
		isDir := e.IsDir()
		var size any
		var mtime any
		if info, err := e.Info(); err == nil {
			size = info.Size()
			mtime = info.ModTime().Unix()
		}
		out = append(out, map[string]any{
			"name":  name,
			"dir":   isDir,
			"size":  size,
			"mtime": mtime,
		})
	}
	return ok(map[string]any{
		"path":    path,
		"entries": out,
	})
}

func (a *Agent) handleCode() response {
	return failure(http.StatusNotImplemented, "v3: /code replaced by /update")
}

func (a *Agent) handleRestart() response {
	err := a.d.Act.Restart(a.ctx)
	return actionError(err)
}

func (a *Agent) handleSwitch(body []byte) response {
	var req struct {
		Path string `json:"path"`
	}
	_ = json.Unmarshal(body, &req)
	if req.Path == "" {
		return failure(400, "нужен path")
	}
	err := a.d.Act.SwitchPath(req.Path)
	return actionError(err)
}

func (a *Agent) handleVPN(body []byte) response {
	var req struct {
		Mode string `json:"mode"`
	}
	_ = json.Unmarshal(body, &req)
	if req.Mode != "off" && req.Mode != "auto" && req.Mode != "only" {
		return failure(400, "режим: off, auto или only")
	}
	err := a.d.Act.VPN(req.Mode)
	if err != nil {
		return actionError(err)
	}
	st := a.d.Act.Status()
	if vpnSt, exists := st["vpn"]; exists {
		return ok(vpnSt)
	}
	return ok(map[string]any{"mode": req.Mode})
}

func (a *Agent) handleUpdate(r *http.Request, body []byte) response {
	sha := r.Header.Get("X-Sha256")
	ver := r.Header.Get("X-Version")
	err := a.d.Act.InstallDev(a.ctx, bytes.NewReader(body), sha, ver)
	return actionError(err)
}

func (a *Agent) handleRollback(body []byte) response {
	var req struct {
		Reason string `json:"reason"`
	}
	_ = json.Unmarshal(body, &req)
	if req.Reason == "" {
		req.Reason = "agent"
	}
	err := a.d.Act.Rollback(a.ctx, req.Reason)
	return actionError(err)
}

func (a *Agent) handleExpose(body []byte) response {
	if a.d.Fwd == nil || a.d.Fwd() == nil {
		return failure(http.StatusServiceUnavailable, "forward-not-ready")
	}
	var req struct {
		Name       string `json:"name"`
		ServerPort int    `json:"serverPort"`
		PCPort     int    `json:"pcPort"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		return failure(400, "invalid json")
	}
	exp, err := a.d.Fwd().Expose(req.Name, req.ServerPort, req.PCPort)
	if err != nil {
		// Match wrapped OS errors as well; validation errors retain HTTP 400.
		var pathErr *os.PathError
		var linkErr *os.LinkError
		var syscallErr *os.SyscallError
		var netErr *net.OpError
		var errno syscall.Errno
		if errors.As(err, &pathErr) || errors.As(err, &linkErr) ||
			errors.As(err, &syscallErr) || errors.As(err, &netErr) ||
			errors.As(err, &errno) || os.IsPermission(err) ||
			os.IsExist(err) || os.IsNotExist(err) {
			return failure(http.StatusConflict, err.Error())
		}
		return failure(400, err.Error())
	}
	if exp.Err != "" {
		return failure(409, exp.Err)
	}
	return ok(map[string]any{
		"ok":         true,
		"name":       exp.Name,
		"serverPort": exp.ServerPort,
		"pcPort":     exp.PCPort,
		"url":        fmt.Sprintf("http://localhost:%d", exp.PCPort),
	})
}

func (a *Agent) handleUnexpose(body []byte) response {
	if a.d.Fwd == nil || a.d.Fwd() == nil {
		return failure(http.StatusServiceUnavailable, "forward-not-ready")
	}
	var req struct {
		Name string `json:"name"`
	}
	_ = json.Unmarshal(body, &req)
	if req.Name == "" {
		return failure(400, "нужен name")
	}
	if err := a.d.Fwd().Unexpose(req.Name); err != nil {
		return failure(400, err.Error())
	}
	return ok(map[string]any{
		"ok":   true,
		"name": req.Name,
	})
}

func (a *Agent) handleExposed() response {
	if a.d.Fwd == nil || a.d.Fwd() == nil {
		return ok(map[string]any{
			"exposed": []map[string]any{},
			"channel": false,
		})
	}
	fwd := a.d.Fwd()
	items := fwd.List()
	out := make([]map[string]any, 0, len(items))
	for _, e := range items {
		out = append(out, map[string]any{
			"name":       e.Name,
			"serverPort": e.ServerPort,
			"pcPort":     e.PCPort,
			"listening":  e.Err == "",
			"url":        fmt.Sprintf("http://localhost:%d", e.PCPort),
		})
	}
	return ok(map[string]any{
		"exposed": out,
		"channel": fwd.InternalSocks() != "",
	})
}

func truncate(s string, max int) string {
	if len(s) > max {
		return s[:max]
	}
	return s
}

func processCode(p api.ExecProc) any {
	if !p.Exited() {
		return nil
	}
	return p.Code()
}
