package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/api/fake"
	"remoteagents/internal/forward"
)

func init() {
	for _, name := range []string{"forward", "p12"} {
		api.RegisterDev(api.DevCmd{
			Name: name,
			Help: "verify forward package with fake.Channel and python3 http server",
			Run:  devForward,
		})
	}
}

type devChannel struct {
	fake.Channel
	pyPort int
}

func (c *devChannel) State() api.ChannelState {
	return api.ChannelState{State: "up", Since: time.Now()}
}
func (c *devChannel) Subscribe() (<-chan api.ChannelState, func()) {
	ch := make(chan api.ChannelState, 1)
	ch <- api.ChannelState{State: "up", Since: time.Now()}
	var once sync.Once
	return ch, func() { once.Do(func() { close(ch) }) }
}
func (c *devChannel) DialContext(ctx context.Context, network, addr string) (net.Conn, error) {
	var d net.Dialer
	// Route all traffic through the channel to the local python HTTP server
	return d.DialContext(ctx, "tcp", fmt.Sprintf("127.0.0.1:%d", c.pyPort))
}
func devForward(ctx context.Context, args []string) int {
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	if len(args) >= 1 && (args[0] == "-h" || args[0] == "--help" || args[0] == "help") {
		fmt.Println("usage: remoteagents dev forward")
		return 0
	}

	var lc net.ListenConfig
	dialer := &net.Dialer{Timeout: 2 * time.Second}

	// 1. Temporary home directory
	tmpHome, err := os.MkdirTemp("", "ra3-dev-forward-home-*")
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to create tmp home: %v\n", err)
		return 1
	}
	defer func() { _ = os.RemoveAll(tmpHome) }()

	// 2. Temporary web directory for python3 server
	tmpWeb, err := os.MkdirTemp("", "ra3-dev-forward-web-*")
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to create tmp web: %v\n", err)
		return 1
	}
	defer func() { _ = os.RemoveAll(tmpWeb) }()

	testContent := "DEV_FORWARD_TEST_OK\n"
	if err := os.WriteFile(filepath.Join(tmpWeb, "index.html"), []byte(testContent), 0600); err != nil {
		fmt.Fprintf(os.Stderr, "failed to write test index.html: %v\n", err)
		return 1
	}

	// Find free port for python3 server
	pyLn, err := lc.Listen(ctx, "tcp", "127.0.0.1:0")
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to allocate free port for python: %v\n", err)
		return 1
	}
	pyPort := pyLn.Addr().(*net.TCPAddr).Port
	_ = pyLn.Close()

	// Start python3 -m http.server
	pyCmd := exec.CommandContext(ctx, "python3", "-m", "http.server", strconv.Itoa(pyPort), "--bind", "127.0.0.1", "--directory", tmpWeb)
	if err := pyCmd.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "failed to start python3 http.server: %v\n", err)
		return 1
	}
	defer func() {
		if pyCmd.Process != nil {
			_ = pyCmd.Process.Kill()
			_ = pyCmd.Wait()
		}
	}()

	// Wait for python server to accept connections
	pyReady := false
	pollDialer := &net.Dialer{Timeout: 100 * time.Millisecond}
	for i := 0; i < 400; i++ {
		conn, err := pollDialer.DialContext(ctx, "tcp", fmt.Sprintf("127.0.0.1:%d", pyPort))
		if err == nil {
			_ = conn.Close()
			pyReady = true
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !pyReady {
		fmt.Fprintf(os.Stderr, "python3 http server did not become ready on port %d\n", pyPort)
		return 1
	}

	// Find free ports for static forward and lanProxy
	staticLn, err := lc.Listen(ctx, "tcp", "127.0.0.1:0")
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to allocate port for static forward: %v\n", err)
		return 1
	}
	staticPort := staticLn.Addr().(*net.TCPAddr).Port
	_ = staticLn.Close()

	proxyLn, err := lc.Listen(ctx, "tcp", "127.0.0.1:0")
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to allocate port for proxy: %v\n", err)
		return 1
	}
	proxyPort := proxyLn.Addr().(*net.TCPAddr).Port
	_ = proxyLn.Close()

	cfg := &api.Config{
		Forwards: []api.ForwardCfg{
			{Listen: staticPort, ToHost: "127.0.0.1", ToPort: pyPort},
		},
		LanProxy: &api.LanProxyCfg{Port: proxyPort},
		LAN: []api.LANCfg{
			{
				Name: "test-lan",
				Share: api.LANShare{
					Enabled: true,
					Domains: []string{"test.lan", "*.test.lan"},
					Subnets: []string{"10.0.0.0/8"},
				},
			},
		},
	}

	paths := api.NewPaths(tmpHome)
	devCh := &devChannel{pyPort: pyPort}
	logger := &fake.Logger{}
	traces := fake.NewTraces("dev-inst-12345678")
	mode := api.Mode{}

	fwd, err := forward.New(cfg, devCh, paths, logger, traces, mode)
	if err != nil {
		fmt.Fprintf(os.Stderr, "forward.New failed: %v\n", err)
		return 1
	}

	if err := fwd.Start(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "fwd.Start failed: %v\n", err)
		return 1
	}
	defer func() { _ = fwd.Stop(ctx) }()

	// Verification 1: Static forward
	staticURL := fmt.Sprintf("http://127.0.0.1:%d/", staticPort)
	client := &http.Client{Timeout: 3 * time.Second}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, staticURL, nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to create request: %v\n", err)
		return 1
	}
	resp, err := client.Do(req)
	if err != nil {
		fmt.Fprintf(os.Stderr, "static forward request failed: %v\n", err)
		return 1
	}
	body, err := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if err != nil || !bytes.Contains(body, []byte("DEV_FORWARD_TEST_OK")) {
		fmt.Fprintf(os.Stderr, "unexpected static forward response: %s (err: %v)\n", string(body), err)
		return 1
	}
	fmt.Printf("static forward: ok (port %d -> python %d)\n", staticPort, pyPort)

	// Verification 2: Expose
	exposed, err := fwd.Expose("py-expose", pyPort, 0)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Expose failed: %v\n", err)
		return 1
	}
	if exposed.PCPort <= 0 {
		fmt.Fprintf(os.Stderr, "invalid exposed PCPort: %d\n", exposed.PCPort)
		return 1
	}

	expURL := fmt.Sprintf("http://127.0.0.1:%d/", exposed.PCPort)
	expReq, err := http.NewRequestWithContext(ctx, http.MethodGet, expURL, nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to create request: %v\n", err)
		return 1
	}
	expResp, err := client.Do(expReq)
	if err != nil {
		fmt.Fprintf(os.Stderr, "exposed request failed: %v\n", err)
		return 1
	}
	expBody, err := io.ReadAll(expResp.Body)
	_ = expResp.Body.Close()
	if err != nil || !bytes.Contains(expBody, []byte("DEV_FORWARD_TEST_OK")) {
		fmt.Fprintf(os.Stderr, "unexpected exposed response: %s (err: %v)\n", string(expBody), err)
		return 1
	}
	fmt.Printf("expose: ok (allocated PCPort %d, answered with python server content)\n", exposed.PCPort)

	// Verify state/exposed.json exists
	expJSONPath := filepath.Join(paths.State, "exposed.json")
	if _, err := os.Stat(expJSONPath); err != nil {
		fmt.Fprintf(os.Stderr, "state/exposed.json not found: %v\n", err)
		return 1
	}

	// Verification 3: Unexpose
	if err := fwd.Unexpose("py-expose"); err != nil {
		fmt.Fprintf(os.Stderr, "Unexpose failed: %v\n", err)
		return 1
	}

	// Ensure port is closed
	time.Sleep(50 * time.Millisecond)
	shortDialer := &net.Dialer{Timeout: 200 * time.Millisecond}
	conn, err := shortDialer.DialContext(ctx, "tcp", fmt.Sprintf("127.0.0.1:%d", exposed.PCPort))
	if err == nil {
		_ = conn.Close()
		fmt.Fprintf(os.Stderr, "unexposed port %d is still open!\n", exposed.PCPort)
		return 1
	}
	fmt.Printf("unexpose: ok (port %d is closed)\n", exposed.PCPort)

	// Verification 4: lanProxy /lan.pac
	pacURL := fmt.Sprintf("http://127.0.0.1:%d/lan.pac", proxyPort)
	pacReq, err := http.NewRequestWithContext(ctx, http.MethodGet, pacURL, nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to create request: %v\n", err)
		return 1
	}
	pacResp, err := client.Do(pacReq)
	if err != nil {
		fmt.Fprintf(os.Stderr, "lanProxy /lan.pac request failed: %v\n", err)
		return 1
	}
	pacBody, err := io.ReadAll(pacResp.Body)
	_ = pacResp.Body.Close()
	if err != nil || pacResp.StatusCode != 200 || !bytes.Contains(pacBody, []byte("FindProxyForURL")) {
		fmt.Fprintf(os.Stderr, "unexpected /lan.pac response: %s (err: %v)\n", string(pacBody), err)
		return 1
	}
	fmt.Println("lanProxy /lan.pac: ok")

	// Verification 5: lanProxy HTTP CONNECT
	proxyConn, err := dialer.DialContext(ctx, "tcp", fmt.Sprintf("127.0.0.1:%d", proxyPort))
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to dial lanProxy: %v\n", err)
		return 1
	}
	defer func() { _ = proxyConn.Close() }()
	_ = proxyConn.SetDeadline(time.Now().Add(5 * time.Second))

	connectReq := fmt.Sprintf("CONNECT test.lan:%d HTTP/1.1\r\nHost: test.lan:%d\r\n\r\n", pyPort, pyPort)
	if _, err := proxyConn.Write([]byte(connectReq)); err != nil {
		fmt.Fprintf(os.Stderr, "failed to write CONNECT to lanProxy: %v\n", err)
		return 1
	}

	br := bufio.NewReader(proxyConn)
	statusLine, err := br.ReadString('\n')
	if err != nil || !strings.Contains(statusLine, "200") {
		fmt.Fprintf(os.Stderr, "CONNECT failed, status: %s (err: %v)\n", statusLine, err)
		return 1
	}
	// Consume headers until \r\n
	for {
		line, err := br.ReadString('\n')
		if err != nil || line == "\r\n" || line == "\n" {
			break
		}
	}

	// Send HTTP GET over CONNECT tunnel
	httpReq := "GET / HTTP/1.1\r\nHost: test.lan\r\nConnection: close\r\n\r\n"
	if _, err := proxyConn.Write([]byte(httpReq)); err != nil {
		fmt.Fprintf(os.Stderr, "failed to write HTTP GET over tunnel: %v\n", err)
		return 1
	}
	tunnelResp, err := io.ReadAll(br)
	if err != nil || !bytes.Contains(tunnelResp, []byte("DEV_FORWARD_TEST_OK")) {
		fmt.Fprintf(os.Stderr, "unexpected response over CONNECT tunnel: %s (err: %v)\n", string(tunnelResp), err)
		return 1
	}
	fmt.Println("lanProxy HTTP CONNECT: ok")

	// Verification 6: lanProxy SOCKS5 CONNECT
	sConn, err := dialer.DialContext(ctx, "tcp", fmt.Sprintf("127.0.0.1:%d", proxyPort))
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to dial lanProxy for SOCKS5: %v\n", err)
		return 1
	}
	defer func() { _ = sConn.Close() }()
	_ = sConn.SetDeadline(time.Now().Add(5 * time.Second))

	// SOCKS5 handshake: VER=5, NMETHODS=1, METHOD=0
	if _, err := sConn.Write([]byte{0x05, 0x01, 0x00}); err != nil {
		fmt.Fprintf(os.Stderr, "failed to write SOCKS5 greeting: %v\n", err)
		return 1
	}
	sResp := make([]byte, 2)
	if _, err := io.ReadFull(sConn, sResp); err != nil || sResp[0] != 0x05 || sResp[1] != 0x00 {
		fmt.Fprintf(os.Stderr, "invalid SOCKS5 handshake reply: %v (err: %v)\n", sResp, err)
		return 1
	}

	// SOCKS5 CONNECT to domain test.lan:pyPort
	domain := "test.lan"
	reqBuf := bytes.NewBuffer([]byte{0x05, 0x01, 0x00, 0x03, byte(len(domain))})
	reqBuf.WriteString(domain)
	portBytes := make([]byte, 2)
	binary.BigEndian.PutUint16(portBytes, uint16(pyPort))
	reqBuf.Write(portBytes)

	if _, err := sConn.Write(reqBuf.Bytes()); err != nil {
		fmt.Fprintf(os.Stderr, "failed to write SOCKS5 CONNECT: %v\n", err)
		return 1
	}

	// SOCKS5 reply: 4 bytes header + BND.ADDR + BND.PORT
	replyHead := make([]byte, 4)
	if _, err := io.ReadFull(sConn, replyHead); err != nil || replyHead[1] != 0x00 {
		fmt.Fprintf(os.Stderr, "SOCKS5 CONNECT failed with rep code %d (err: %v)\n", replyHead[1], err)
		return 1
	}
	// Consume remaining BND.ADDR and BND.PORT
	switch replyHead[3] {
	case 0x01: // IPv4
		discard := make([]byte, 6)
		_, _ = io.ReadFull(sConn, discard)
	case 0x03: // Domain
		lenB := make([]byte, 1)
		_, _ = io.ReadFull(sConn, lenB)
		discard := make([]byte, int(lenB[0])+2)
		_, _ = io.ReadFull(sConn, discard)
	case 0x04: // IPv6
		discard := make([]byte, 18)
		_, _ = io.ReadFull(sConn, discard)
	}

	// Write HTTP request over SOCKS5 tunnel
	if _, err := sConn.Write([]byte("GET / HTTP/1.1\r\nHost: test.lan\r\nConnection: close\r\n\r\n")); err != nil {
		fmt.Fprintf(os.Stderr, "failed to write over SOCKS5 tunnel: %v\n", err)
		return 1
	}
	socksResp, err := io.ReadAll(sConn)
	if err != nil || !bytes.Contains(socksResp, []byte("DEV_FORWARD_TEST_OK")) {
		fmt.Fprintf(os.Stderr, "unexpected response over SOCKS5: %s (err: %v)\n", string(socksResp), err)
		return 1
	}
	fmt.Println("lanProxy SOCKS5 CONNECT: ok")

	// Verification 7: InternalSocks
	internalSocks := fwd.InternalSocks()
	if internalSocks == "" {
		fmt.Fprintln(os.Stderr, "InternalSocks is empty")
		return 1
	}
	inConn, err := dialer.DialContext(ctx, "tcp", internalSocks)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to dial InternalSocks: %v\n", err)
		return 1
	}
	defer func() { _ = inConn.Close() }()
	_ = inConn.SetDeadline(time.Now().Add(5 * time.Second))

	// Handshake
	if _, err := inConn.Write([]byte{0x05, 0x01, 0x00}); err != nil {
		fmt.Fprintf(os.Stderr, "failed to write InternalSocks greeting: %v\n", err)
		return 1
	}
	inResp := make([]byte, 2)
	if _, err := io.ReadFull(inConn, inResp); err != nil || inResp[1] != 0x00 {
		fmt.Fprintf(os.Stderr, "InternalSocks handshake failed: %v\n", inResp)
		return 1
	}
	// CONNECT IPv4 127.0.0.1:pyPort
	reqIPv4 := []byte{0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, portBytes[0], portBytes[1]}
	if _, err := inConn.Write(reqIPv4); err != nil {
		fmt.Fprintf(os.Stderr, "failed to write InternalSocks CONNECT: %v\n", err)
		return 1
	}
	inReply := make([]byte, 4)
	if _, err := io.ReadFull(inConn, inReply); err != nil || inReply[1] != 0x00 {
		fmt.Fprintf(os.Stderr, "InternalSocks CONNECT returned code %d\n", inReply[1])
		return 1
	}
	discard := make([]byte, 6)
	_, _ = io.ReadFull(inConn, discard)

	if _, err := inConn.Write([]byte("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")); err != nil {
		fmt.Fprintf(os.Stderr, "failed to write over InternalSocks tunnel: %v\n", err)
		return 1
	}
	inBody, err := io.ReadAll(inConn)
	if err != nil || !bytes.Contains(inBody, []byte("DEV_FORWARD_TEST_OK")) {
		fmt.Fprintf(os.Stderr, "unexpected response over InternalSocks: %s\n", string(inBody))
		return 1
	}
	fmt.Printf("InternalSocks: ok (%s)\n", internalSocks)

	fmt.Println("dev forward: ok")
	return 0
}
