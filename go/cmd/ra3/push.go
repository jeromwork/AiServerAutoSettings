package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"debug/buildinfo"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"remoteagents/internal/api"
)

func cmdPush(ctx context.Context, stateDir, pc, binaryFile, customVersion string, deadlineSec int) error {
	st, err := readState(stateDir, pc)
	if err != nil {
		return err
	}

	if deadlineSec <= 0 || deadlineSec > 150 {
		return fmt.Errorf("ra3: deadline должен быть от 1 до 150 секунд")
	}

	if binaryFile == "" {
		// Detect target os and arch from /status
		var statusResp struct {
			Platform string `json:"platform"`
			OS       string `json:"os"`
			Arch     string `json:"arch"`
		}
		if err := callAgentJSON(ctx, st, "GET", "/status", nil, &statusResp, 10*time.Second); err != nil {
			return fmt.Errorf("ra3: не удалось получить /status для определения ОС/архитектуры: %w", err)
		}

		osName := statusResp.Platform
		if osName == "" {
			osName = statusResp.OS
		}
		if osName == "" {
			return fmt.Errorf("ra3: /status не содержит ОС")
		}
		archName := statusResp.Arch
		if archName == "" {
			return fmt.Errorf("ra3: /status не содержит архитектуру")
		}
		target := osName + "/" + archName

		buildScript, err := findBuildScript(ctx)
		if err != nil {
			return fmt.Errorf("ra3: скрипт сборки build.sh не найден; укажите файл бинарника явно: ra3 push <ПК> <файл> (%w)", err)
		}

		_, _ = fmt.Fprintf(os.Stderr, "ra3: сборка под цель %s через %s...\n", target, buildScript)
		cmd := exec.CommandContext(ctx, "bash", buildScript, "--target", target)
		cmd.Dir = filepath.Dir(buildScript)
		cmd.Stdout = os.Stderr
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("ra3: ошибка сборки (%s): %w", target, err)
		}

		located, err := findBuiltBinary(filepath.Dir(buildScript), osName, archName)
		if err != nil {
			return fmt.Errorf("ra3: бинарник после сборки не найден в dist/: %w", err)
		}
		binaryFile = located
	}

	info, err := os.Stat(binaryFile)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Size() == 0 || info.Size() > 100<<20 {
		return fmt.Errorf("ra3: бинарник должен иметь размер 1..100 МиБ")
	}
	data, err := os.ReadFile(binaryFile)
	if err != nil {
		return fmt.Errorf("ra3: не удалось прочитать бинарник %s: %w", binaryFile, err)
	}

	sha := fmt.Sprintf("%x", sha256.Sum256(data))

	version := customVersion
	if version == "" {
		version, err = binaryVersion(binaryFile)
		if err != nil {
			return err
		}
	}

	verRe := regexp.MustCompile(api.VersionRe)
	if !verRe.MatchString(version) {
		return fmt.Errorf("ra3: недопустимая версия %q (должна соответствовать %s)", version, api.VersionRe)
	}

	// 1. Слушатель <ПК>.events создаётся ДО POST запроса
	eventsPath := filepath.Join(stateDir, st.PC+".events")

	var lc net.ListenConfig
	l, err := lc.Listen(ctx, "unix", eventsPath)
	if err != nil {
		return fmt.Errorf("ra3: не удалось открыть сокет событий %s: %w", eventsPath, err)
	}

	defer func() { _ = l.Close() }()
	if err := os.Chmod(eventsPath, 0600); err != nil {
		return err
	}
	waitCtx, cancel := context.WithTimeout(ctx, time.Duration(deadlineSec)*time.Second)
	defer cancel()
	stopClose := context.AfterFunc(waitCtx, func() { _ = l.Close() })
	defer stopClose()

	// 2. Отправка POST /update с X-Sha256 и X-Version
	headers := map[string]string{
		"Content-Type": "application/octet-stream",
		"X-Sha256":     sha,
		"X-Version":    version,
	}

	code, respData, err := callAgent(waitCtx, st, "POST", "/update", bytes.NewReader(data), headers, 30*time.Second)
	if err != nil {
		return fmt.Errorf("ra3: ошибка отправки /update: %w", err)
	}

	if code != http.StatusOK {
		var errObj struct {
			Error  string   `json:"error"`
			Errors []string `json:"errors"`
		}
		if json.Unmarshal(respData, &errObj) == nil {
			if len(errObj.Errors) > 0 {
				return fmt.Errorf("ra3: код отклонён агентом (%d):\n  %s", code, strings.Join(errObj.Errors, "\n  "))
			}
			if errObj.Error != "" {
				return fmt.Errorf("ra3: код отклонён агентом (%d): %s", code, errObj.Error)
			}
		}
		return fmt.Errorf("ra3: код отклонён агентом (%d): %s", code, strings.TrimSpace(string(respData)))
	}

	fmt.Printf("код отправлен: %s (%d байт, sha256 %s...)\n", version, len(data), sha[:12])
	fmt.Printf("ожидание переподключения новой версии (до %d с)...\n", deadlineSec)

	// 3. Ждём UP новой версии ≤ deadlineSec (150 с)
	start := time.Now()
	deadline := time.Duration(deadlineSec) * time.Second
	if ul, ok := l.(*net.UnixListener); ok {
		_ = ul.SetDeadline(time.Now().Add(deadline))
	}

	for {
		conn, err := l.Accept()
		if err != nil {
			return fmt.Errorf("ra3: за %d с новая версия не подняла канал", deadlineSec)
		}

		stopConnClose := context.AfterFunc(waitCtx, func() { _ = conn.Close() })
		end, _ := waitCtx.Deadline()
		if err := conn.SetReadDeadline(end); err != nil {
			stopConnClose()
			_ = conn.Close()
			return err
		}
		lineBytes, readErr := bufio.NewReaderSize(conn, 1024).ReadSlice('\n')
		stopConnClose()
		_ = conn.Close()
		if readErr != nil {
			continue
		}

		line := strings.TrimSpace(string(lineBytes))
		parts := strings.Split(line, "\t")
		if len(parts) >= 2 && parts[0] == "UP" {
			upVer := parts[1]
			rollback := ""
			if len(parts) > 2 && parts[2] != "-" && parts[2] != "" {
				rollback = parts[2]
			}

			elapsed := time.Since(start)
			if rollback != "" {
				return fmt.Errorf("ra3: откат: %s (версия %s)", rollback, upVer)
			} else if upVer != version {
				continue
			} else {
				fmt.Printf("подключён, версия %s за %.1f с\n", upVer, elapsed.Seconds())
			}
			return nil
		}
	}
}

func findBuildScript(ctx context.Context) (string, error) {
	candidates := []string{
		"go/build.sh",
		"build.sh",
	}

	for _, c := range candidates {
		if fi, err := os.Stat(c); err == nil && !fi.IsDir() {
			abs, err := filepath.Abs(c)
			if err == nil {
				return abs, nil
			}
			return c, nil
		}
	}

	// Try git rev-parse --show-toplevel
	out, err := exec.CommandContext(ctx, "git", "rev-parse", "--show-toplevel").Output()
	if err == nil {
		gitRoot := strings.TrimSpace(string(out))
		gitCandidates := []string{
			filepath.Join(gitRoot, "go", "build.sh"),
			filepath.Join(gitRoot, "build.sh"),
		}
		for _, c := range gitCandidates {
			if fi, err := os.Stat(c); err == nil && !fi.IsDir() {
				return c, nil
			}
		}
	}

	return "", fmt.Errorf("файл build.sh не найден")
}

func findBuiltBinary(baseDir, osName, archName string) (string, error) {
	distDirs := []string{
		filepath.Join(baseDir, "dist"),
		filepath.Join(baseDir, "go", "dist"),
		"dist",
		"go/dist",
	}

	var checkedDirs []string
	for _, dist := range distDirs {
		checkedDirs = append(checkedDirs, dist)
		if fi, err := os.Stat(dist); err != nil || !fi.IsDir() {
			continue
		}

		targetExt := ""
		if osName == "windows" {
			targetExt = ".exe"
		}

		exactNames := []string{
			fmt.Sprintf("remoteagents-%s-%s%s", osName, archName, targetExt),
		}

		for _, name := range exactNames {
			p := filepath.Join(dist, name)
			if s, err := os.Stat(p); err == nil && !s.IsDir() {
				return p, nil
			}
		}

	}

	return "", fmt.Errorf("директории проверены: %s", strings.Join(checkedDirs, ", "))
}

// Read build metadata without executing a binary for a different OS/architecture.
func binaryVersion(path string) (string, error) {
	info, err := buildinfo.ReadFile(path)
	if err == nil {
		re := regexp.MustCompile(`(?:^|\s)-X(?:=|\s+)["']?main\.version=([A-Za-z0-9._-]+)`)
		for _, setting := range info.Settings {
			if setting.Key == "-ldflags" {
				if match := re.FindStringSubmatch(setting.Value); len(match) == 2 {
					return match[1], nil
				}
			}
		}
	}
	return "", fmt.Errorf("ra3: версия бинарника не найдена в build metadata; укажите --version перед именем ПК")
}
