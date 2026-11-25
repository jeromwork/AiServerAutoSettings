package cleanup

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"unicode/utf16"

	"golang.org/x/sys/windows/registry"
)

const (
	adapters = `Get-NetAdapter -IncludeHidden | Where-Object {
    ($_.Name -like 'RA2-LAN*' -or $_.Name -like 'RA2-VPN*' -or
     $_.Name -like 'RemoteAgents-Lab*' -or
     $_.Name -like 'ralab-tun*' -or $_.Name -like 'ralab-vpn*') -and
    $_.InterfaceDescription -in @('sing-tun Tunnel', 'Wintun Userspace Tunnel')
}`
	nrpt     = "Get-DnsClientNrptRule | Where-Object { $_.Comment -like 'RemoteAgents-Lab*' }"
	tasks    = "Get-ScheduledTask | Where-Object { $_.TaskName -like 'RemoteAgents-Lab*' }"
	internet = `Software\Microsoft\Windows\CurrentVersion\Internet Settings`
)

var (
	proxyNames = map[string]bool{"ProxyEnable": true, "ProxyServer": true, "ProxyOverride": true, "AutoConfigURL": true, "AutoDetect": true}
	hostsBegin = regexp.MustCompile(`(?m)^#[ \t]*(RemoteAgents-Lab[^\r\n]*?)[ \t]+begin[ \t]*(?:\r?\n|$)`)
)

func quote(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }

func (c *Cleaner) steps(mode string) []step {
	s := []step{{"Процессы", c.processes}, {"Откат изменений", c.undo}, {"Адаптеры", c.adapters},
		{"DNS", c.rules}, {"Имена компьютеров", c.hosts}, {"Прокси", c.proxy}, {"Задачи", c.tasks}}
	if c.reading || mode == "exit" {
		s = append(s, step{"Реестр", c.registry})
	}
	return append(s, step{"Файлы", c.files})
}

// command: одна команда в пределах общего времени уборки; по тайм-ауту дерево снимается целиком.
func (c *Cleaner) command(cmd *exec.Cmd, accepted ...int) (string, error) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
	cmd.Cancel = func() error {
		_ = exec.Command("taskkill.exe", "/F", "/T", "/PID", strconv.Itoa(cmd.Process.Pid)).Run()
		return cmd.Process.Kill()
	}
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	err := cmd.Run()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) && len(accepted) > 0 {
			for _, a := range accepted {
				if ee.ExitCode() == a {
					err = nil
				}
			}
		}
		if err != nil {
			if c.ctx.Err() != nil {
				return "", errors.New("время уборки истекло")
			}
			return "", fmt.Errorf("команда: %w", err)
		}
	}
	return strings.TrimSpace(strings.TrimPrefix(out.String(), "\ufeff")), nil
}

func (c *Cleaner) ps(script string) (string, error) {
	prefix := "$ErrorActionPreference='Stop'; [Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false); "
	return c.command(exec.CommandContext(c.ctx, "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", prefix+script))
}

func (c *Cleaner) query(script string) ([]map[string]any, error) {
	out, err := c.ps("ConvertTo-Json -InputObject @(" + script + ") -Compress -Depth 5")
	if err != nil || out == "" {
		return nil, err
	}
	var list []map[string]any
	if json.Unmarshal([]byte(out), &list) != nil {
		var one map[string]any
		if err := json.Unmarshal([]byte(out), &one); err != nil {
			return nil, err
		}
		list = []map[string]any{one}
	}
	return list, nil
}

func (c *Cleaner) ownedConditions() string {
	conds := []string{
		fmt.Sprintf("$_.ProcessId -ne %d", os.Getpid()), "$_.ProcessId -ne $PID", "$_.ExecutablePath",
		fmt.Sprintf("$_.ExecutablePath.StartsWith(%s, [StringComparison]::OrdinalIgnoreCase)", quote(strings.TrimRight(c.home, `\/`)+`\`)),
	}
	if p := os.Getppid(); p > 0 {
		conds = append(conds, fmt.Sprintf("$_.ProcessId -ne %d", p))
	}
	if exe := os.Getenv("RA_EXE"); exe != "" {
		conds = append(conds, fmt.Sprintf("(-not ($_.ExecutablePath -eq %s))", quote(exe)))
	}
	return strings.Join(conds, " -and ")
}

func (c *Cleaner) owned() string {
	return "Get-CimInstance Win32_Process | Where-Object { " + c.ownedConditions() + " }"
}

func (c *Cleaner) processes() error {
	const left = "Процессы: остались запущенные программы из папки данных"
	if c.reading {
		// Свои потомки (например, сама проверка) не считаются остатком.
		script := fmt.Sprintf("$all = @(Get-CimInstance Win32_Process); "+
			"$desc = [System.Collections.Generic.HashSet[int]]::new(); $q = [System.Collections.Generic.Queue[int]]::new(); $q.Enqueue(%d); "+
			"while ($q.Count -gt 0) { $cur = $q.Dequeue(); foreach ($p in $all) { "+
			"if ($p.ParentProcessId -eq $cur -and $desc.Add([int]$p.ProcessId)) { $q.Enqueue([int]$p.ProcessId) } } }; "+
			"@($all | Where-Object { %s -and (-not $desc.Contains([int]$_.ProcessId)) }) | Select-Object ProcessId", os.Getpid(), c.ownedConditions())
		if l, err := c.query(script); err != nil {
			return err
		} else if len(l) > 0 {
			c.note(left)
		}
		return nil
	}
	if _, err := c.ps(fmt.Sprintf("$failed=0; @(%s) | ForEach-Object { $id=$_.ProcessId; try { Stop-Process -Id $id -Force } "+
		"catch { if (Get-Process -Id $id -ErrorAction SilentlyContinue) { $failed++ } } }; if ($failed) { throw 'processes' }", c.owned())); err != nil {
		return err
	}
	if l, err := c.query(c.owned() + " | Select-Object ProcessId"); err != nil {
		return err
	} else if len(l) > 0 {
		c.note(left)
	}
	return nil
}

func (c *Cleaner) adapters() error {
	run, err := c.query(c.owned() + ` | Where-Object { $_.Name -match '^(sing-box.*|ralab-core|RA2-VPN)\.exe$' } | Select-Object ProcessId`)
	if err != nil {
		return err
	}
	if len(run) > 0 {
		if !c.reading {
			c.note("Адаптеры: удаление пропущено, сетевой процесс ещё работает")
		}
		return nil
	}
	list, err := c.query(adapters + " | Select-Object PnPDeviceID, Name, Status")
	if err != nil {
		return err
	}
	for _, a := range list {
		name, _ := a["Name"].(string)
		if strings.EqualFold(fmt.Sprint(a["Status"]), "up") {
			c.note("Адаптеры: " + name + " в состоянии Up, удаление пропущено")
		} else if c.reading {
			c.note("Адаптеры: осталось устройство программы")
		} else if _, err := c.command(exec.CommandContext(c.ctx, "pnputil.exe", "/remove-device", fmt.Sprint(a["PnPDeviceID"])), 0, 3010); err != nil {
			c.note("Адаптер: не удалось выполнить (" + err.Error() + ")")
		}
	}
	return nil
}

func (c *Cleaner) rules() error {
	if c.reading {
		if l, err := c.query(nrpt + " | Select-Object Name"); err != nil {
			return err
		} else if len(l) > 0 {
			c.note("DNS: остались правила программы")
		}
		return nil
	}
	_, err := c.ps("$failed=0; @(" + nrpt + ") | ForEach-Object { try { Remove-DnsClientNrptRule -Name $_.Name -Force } catch { $failed++ } }; if ($failed) { throw 'dns' }")
	return err
}

func (c *Cleaner) tasks() error {
	if c.reading {
		if l, err := c.query(tasks + " | Select-Object TaskName"); err != nil {
			return err
		} else if len(l) > 0 {
			c.note("Автозапуск: остались прежние задачи программы")
		}
		return nil
	}
	_, err := c.ps("$failed=0; @(" + tasks + ") | ForEach-Object { try { Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false } catch { $failed++ } }; if ($failed) { throw 'tasks' }")
	return err
}

func (c *Cleaner) registry() error {
	if c.reading {
		out, err := c.ps(`$run='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; if ((Test-Path -LiteralPath $run) -and ((Get-Item -LiteralPath $run).GetValueNames() -contains 'RemoteAgents-Lab')) { 'startup' }`)
		if out != "" {
			c.note("Реестр: осталась запись автозапуска")
		}
		return err
	}
	_, err := c.ps(`$base='HKCU:\Software\Classes\Directory\shell';
if (Test-Path -LiteralPath $base) { Get-ChildItem -LiteralPath $base | Where-Object { $_.PSChildName -like 'RemoteAgents.LabDisk.*' } | ForEach-Object { Remove-Item -LiteralPath $_.PSPath -Recurse -Force } }
$run='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';
if ((Test-Path -LiteralPath $run) -and ((Get-Item -LiteralPath $run).GetValueNames() -contains 'RemoteAgents-Lab')) { Remove-ItemProperty -LiteralPath $run -Name 'RemoteAgents-Lab' }`)
	return err
}

// hosts: блоки "# RemoteAgents-Lab… begin" … "# RemoteAgents-Lab… end"; кодировка и BOM сохраняются.
func (c *Cleaner) hosts() error {
	path := filepath.Join(envOr("SystemRoot", `C:\Windows`), `System32\drivers\etc\hosts`)
	raw, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var bom []byte
	var text string
	switch {
	case bytes.HasPrefix(raw, []byte{0xff, 0xfe}), bytes.HasPrefix(raw, []byte{0xfe, 0xff}):
		bom, raw = raw[:2], raw[2:]
		bo := binary.ByteOrder(binary.LittleEndian)
		ap := binary.AppendByteOrder(binary.LittleEndian)
		if bom[0] == 0xfe {
			bo, ap = binary.BigEndian, binary.BigEndian
		}
		u := make([]uint16, len(raw)/2)
		for i := range u {
			u[i] = bo.Uint16(raw[2*i:])
		}
		text = string(utf16.Decode(u))
		return c.hostsWrite(path, text, func(s string) []byte {
			b := make([]byte, 0, 2*len(s)+2)
			b = append(b, bom...)
			for _, v := range utf16.Encode([]rune(s)) {
				b = ap.AppendUint16(b, v)
			}
			return b
		})
	case bytes.HasPrefix(raw, []byte{0xef, 0xbb, 0xbf}):
		bom, raw = raw[:3], raw[3:]
	}
	// Latin-1 обратимо сопоставляет байты, в том числе UTF-8 без BOM и старые кодировки.
	rs := make([]rune, len(raw))
	for i, b := range raw {
		rs[i] = rune(b)
	}
	return c.hostsWrite(path, string(rs), func(s string) []byte {
		out := append([]byte{}, bom...)
		for _, r := range s {
			out = append(out, byte(r))
		}
		return out
	})
}

func (c *Cleaner) hostsWrite(path, text string, encode func(string) []byte) error {
	clean := removeBlocks(text)
	if c.reading {
		if hostsBegin.MatchString(text) {
			c.note("Имена компьютеров: остались записи программы")
		}
		return nil
	}
	if hostsBegin.MatchString(clean) {
		c.note("Имена компьютеров: найден незакрытый блок, требуется проверка")
	}
	if clean == text {
		return nil
	}
	tmp := filepath.Join(filepath.Dir(path), "RemoteAgents-Lab-"+strconv.Itoa(os.Getpid())+".tmp")
	if err := os.WriteFile(tmp, encode(clean), 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

// removeBlocks: RE2 без обратных ссылок, поэтому конец блока ищем отдельным выражением по имени из begin.
func removeBlocks(text string) string {
	var out strings.Builder
	pos := 0
	for {
		m := hostsBegin.FindStringSubmatchIndex(text[pos:])
		if m == nil {
			break
		}
		start, bodyFrom := pos+m[0], pos+m[1]
		name := text[pos+m[2] : pos+m[3]]
		end := regexp.MustCompile(`(?m)^#[ \t]*` + regexp.QuoteMeta(name) + `[ \t]+end[^\r\n]*(?:\r?\n|$)`).FindStringIndex(text[bodyFrom:])
		if end == nil {
			out.WriteString(text[pos:bodyFrom]) // незакрытый блок оставляем и сообщаем
			pos = bodyFrom
			continue
		}
		out.WriteString(text[pos:start])
		pos = bodyFrom + end[1]
	}
	out.WriteString(text[pos:])
	return out.String()
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// proxy: state/proxy-set.json — прежние значения ({"ProxyEnable": 0, "ProxyServer": null}; null = значения не было;
// допустим {"values": {...}} и {"value": ..., "type": "dword"|"sz"|"expand_sz"}). Метка удаляется после отката.
func (c *Cleaner) proxy() error {
	marker := filepath.Join(c.home, "state", "proxy-set.json")
	raw, err := os.ReadFile(marker)
	if os.IsNotExist(err) {
		return nil
	}
	if c.reading {
		c.note("Прокси: осталось сохранённое изменение настроек")
		return nil
	}
	if err != nil {
		return err
	}
	var data map[string]json.RawMessage
	if err := json.Unmarshal(bytes.TrimPrefix(raw, []byte("\xef\xbb\xbf")), &data); err != nil {
		return err
	}
	if v, ok := data["values"]; ok {
		data = nil
		if err := json.Unmarshal(v, &data); err != nil {
			return err
		}
	}
	if len(data) == 0 {
		return errors.New("неверная запись прежних настроек прокси")
	}
	key, err := registry.OpenKey(registry.CURRENT_USER, internet, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer key.Close()
	for name, rawv := range data {
		if !proxyNames[name] {
			return errors.New("неверная запись прежних настроек прокси")
		}
		var v any
		_ = json.Unmarshal(rawv, &v)
		kind := ""
		if obj, ok := v.(map[string]any); ok {
			kind, _ = obj["type"].(string)
			v = obj["value"]
		}
		switch x := v.(type) {
		case nil:
			if err := key.DeleteValue(name); err != nil && err != registry.ErrNotExist {
				return err
			}
		case float64:
			if x < 0 || x > 0xffffffff || x != float64(uint32(x)) || (kind != "" && kind != "dword") {
				return errors.New("неверный тип прежнего значения прокси")
			}
			err = key.SetDWordValue(name, uint32(x))
		case string:
			if kind == "expand_sz" {
				err = key.SetExpandStringValue(name, x)
			} else if kind == "" || kind == "sz" {
				err = key.SetStringValue(name, x)
			} else {
				return errors.New("неверный тип прежнего значения прокси")
			}
		default:
			return errors.New("неверный тип прежнего значения прокси")
		}
		if err != nil {
			return err
		}
	}
	// Уведомить WinINet: настройки изменились (39), перечитать (37).
	proc := syscall.NewLazyDLL("wininet.dll").NewProc("InternetSetOptionW")
	for _, opt := range []uintptr{39, 37} {
		if r, _, _ := proc.Call(0, opt, 0, 0); r == 0 {
			return errors.New("не удалось уведомить систему о смене прокси")
		}
	}
	return os.Remove(marker)
}

func linked(path string) bool {
	fi, err := os.Lstat(path)
	return err == nil && fi.Mode()&(os.ModeSymlink|os.ModeIrregular) != 0
}

// file: удалить временный файл/папку; ссылки и точки соединения снимаются без захода внутрь.
func (c *Cleaner) file(path string) {
	if c.reading {
		c.note("Файлы: остался временный файл или файл отката")
	} else if err := c.remove(path); err != nil {
		c.note("Временный файл: не удалось выполнить (" + err.Error() + ")")
	}
}

func (c *Cleaner) remove(path string) error {
	if err := c.ctx.Err(); err != nil {
		return errors.New("время уборки истекло")
	}
	if linked(path) {
		return os.Remove(path)
	}
	return os.RemoveAll(path)
}

func (c *Cleaner) files() error {
	filepath.WalkDir(c.home, func(p string, d os.DirEntry, err error) error {
		if err != nil || c.ctx.Err() != nil {
			return filepath.SkipDir
		}
		if d.IsDir() && linked(p) {
			return filepath.SkipDir
		}
		if n := strings.ToLower(d.Name()); !d.IsDir() && (strings.HasSuffix(n, ".ralab-part") || strings.HasSuffix(n, ".ralab-tmp")) {
			c.file(p)
		}
		return nil
	})
	type folder struct {
		path    string
		oldOnly bool
	}
	var folders []folder
	if t := envOr("TEMP", os.Getenv("TMP")); t != "" {
		folders = append(folders, folder{t, true})
	}
	folders = append(folders, folder{filepath.Join(c.home, "tmp"), false})
	for _, f := range folders {
		if linked(f.path) {
			if f.oldOnly {
				c.note("Временные файлы: папка является ссылкой, обход пропущен")
			} else {
				c.file(f.path)
			}
			continue
		}
		entries, err := os.ReadDir(f.path)
		if err != nil {
			continue
		}
		for _, e := range entries {
			p := filepath.Join(f.path, e.Name())
			if f.oldOnly && !strings.HasPrefix(strings.ToLower(e.Name()), "ralab") {
				continue
			}
			if p == c.home || strings.HasPrefix(c.home, p+string(filepath.Separator)) {
				continue
			}
			c.file(p)
		}
	}
	desktop, err := c.ps("[Environment]::GetFolderPath('DesktopDirectory')")
	if err != nil || desktop == "" {
		return errors.New("не удалось найти рабочий стол")
	}
	stop := filepath.Join(desktop, "RemoteAgents-Lab СТОП.cmd")
	if _, err := os.Stat(stop); err == nil {
		c.file(stop)
	}
	return nil
}

// undo: home/undo/*.cmd — отмена прежних изменений, от новых к старым; выполненный файл удаляется, неудачный остаётся.
func (c *Cleaner) undo() error {
	dir := filepath.Join(c.home, "undo")
	if linked(dir) {
		c.note("Откат изменений: папка является ссылкой, обход пропущен")
		return nil
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	type undoFile struct {
		mod  int64
		name string
		path string
	}
	var files []undoFile
	for _, e := range entries {
		p := filepath.Join(dir, e.Name())
		if !strings.HasSuffix(strings.ToLower(e.Name()), ".cmd") {
			continue
		}
		if linked(p) {
			c.note("Откат изменений: файл является ссылкой, запуск пропущен")
		} else if fi, err := e.Info(); err == nil && fi.Mode().IsRegular() {
			files = append(files, undoFile{fi.ModTime().UnixNano(), e.Name(), p})
		}
	}
	sort.Slice(files, func(i, j int) bool {
		return files[i].mod > files[j].mod || (files[i].mod == files[j].mod && files[i].name > files[j].name)
	})
	for _, f := range files {
		if c.reading {
			c.note("Файлы: остался файл отката")
			continue
		}
		// Путь через переменную: cmd не раскрывает % повторно; !-подстановки выключены.
		cmd := exec.CommandContext(c.ctx, "cmd.exe")
		cmd.SysProcAttr = &syscall.SysProcAttr{CmdLine: `cmd.exe /D /S /V:OFF /C ""%RA_UNDO_FILE%""`}
		cmd.Env = append(os.Environ(), "RA_UNDO_FILE="+f.path)
		if _, err := c.runUndo(cmd); err != nil {
			c.note("Откат изменения: не удалось выполнить (" + err.Error() + ")")
		} else {
			os.Remove(f.path)
		}
	}
	return nil
}

func (c *Cleaner) runUndo(cmd *exec.Cmd) (string, error) {
	cmd.Cancel = func() error {
		_ = exec.Command("taskkill.exe", "/F", "/T", "/PID", strconv.Itoa(cmd.Process.Pid)).Run()
		return cmd.Process.Kill()
	}
	cmd.SysProcAttr.HideWindow, cmd.SysProcAttr.CreationFlags = true, 0x08000000
	out, err := cmd.CombinedOutput()
	return string(out), err
}
