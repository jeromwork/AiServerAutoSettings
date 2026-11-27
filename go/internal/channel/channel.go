// Package channel keeps the ssh session to the server alive (plan 5.1): reverse
// port to the local agent, probe/claim protocol of "ra-lab session", reconnect on drop.
package channel

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/crypto/ssh"

	"remoteagents/internal/api"
)

const (
	rportFirst = 13340
	rportCount = 60
	probeSize  = 65536
	sbWait     = 15 * time.Second // wait for sing-box before ssh-direct
	upTimeout  = 40 * time.Second // from ssh up to RALAB-CHANNEL-UP
	pinFor     = 600 * time.Second
)

// Возврат на предпочтительный путь: первая попытка через returnBase, при неудачах задержка удваивается до returnMax.
var (
	returnBase = 60 * time.Second
	returnMax  = 15 * time.Minute
)

const reasonNetChanged = "сеть сменилась, перестраиваю"

// retryDelay — пауза после круга неудач: 0.5 с … 30 с, удваивается, сбрасывается успехом (fails=0).
func retryDelay(fails int) time.Duration {
	d := 500 * time.Millisecond
	for ; fails > 1 && d < 30*time.Second; fails-- {
		d *= 2
	}
	return min(d, 30*time.Second)
}

var pcName = regexp.MustCompile(`^[A-Za-z0-9._-]{1,64}$`)

type Options struct {
	PC, Version, Rollback  string
	Mode                   api.Mode
	DialTimeout, Keepalive time.Duration
}

type chn struct {
	cfg   *api.Config
	sb    api.Singbox
	agent api.AgentHost
	log   api.Logger
	tr    api.Traces
	o     Options
	sv    api.Server
	signr ssh.Signer
	hkey  ssh.PublicKey

	mu      sync.Mutex
	st      api.ChannelState
	client  *ssh.Client // current connection (nil unless connected)
	subs    map[int]chan api.ChannelState
	subSeq  int
	pinned  time.Time
	cancel  context.CancelFunc
	done    chan struct{}
	started bool
	kick    chan struct{} // ForcePath: drop the current ssh
	rcur    int
	cleaned bool

	sessCancel context.CancelFunc // отмена текущей попытки/сессии (смена сети)
	underlayAt time.Time          // последняя смена сети под живой сессией (для этапа B)
	netPending bool               // смена сети: следующий круг — с начала списка путей
	retPref    chan struct{}      // сработал таймер возврата на предпочтительный путь
	retFails   int                // подряд неудачных возвратов (растит задержку)
	retTimer   *time.Timer
}

// New validates the configuration (strict hostKey is mandatory) and builds the channel.
func New(cfg *api.Config, sb api.Singbox, agent api.AgentHost, log api.Logger, tr api.Traces, o Options) (api.Channel, error) {
	if cfg == nil || len(cfg.Servers) == 0 {
		return nil, errors.New("channel: no-server")
	}
	if agent == nil || log == nil {
		return nil, errors.New("channel: missing-dependency")
	}
	if !pcName.MatchString(o.PC) {
		return nil, errors.New("channel: bad-pc-name")
	}
	if o.DialTimeout <= 0 {
		o.DialTimeout = 15 * time.Second
	}
	if o.Keepalive <= 0 {
		o.Keepalive = 3 * time.Second
	}
	if o.Version == "" {
		o.Version = "go-dev"
	}
	sv := cfg.Servers[0]
	signer, err := ssh.ParsePrivateKey(sv.Key)
	if err != nil {
		return nil, errors.New("channel: bad-key")
	}
	hk, err := parseHostKey(sv.HostKey)
	if err != nil {
		return nil, err
	}
	c := &chn{cfg: cfg, sb: sb, agent: agent, log: log.With("channel"), tr: tr, o: o, sv: sv, signr: signer, hkey: hk,
		subs: map[int]chan api.ChannelState{}, kick: make(chan struct{}, 1), retPref: make(chan struct{}, 1)}
	c.st = api.ChannelState{State: "waiting", Since: time.Now()}
	c.log.Secret(agent.Token())
	return c, nil
}

func parseHostKey(s string) (ssh.PublicKey, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil, errors.New("channel: hostkey-missing")
	}
	if k, _, _, _, err := ssh.ParseAuthorizedKey([]byte(s)); err == nil {
		return k, nil
	}
	f := strings.Fields(s) // known_hosts form: "<host> <type> <base64>"
	if len(f) >= 3 {
		if k, _, _, _, err := ssh.ParseAuthorizedKey([]byte(f[1] + " " + f[2])); err == nil {
			return k, nil
		}
	}
	return nil, errors.New("channel: hostkey-invalid")
}

func (c *chn) Name() string { return "channel" }

func (c *chn) Status() map[string]any {
	s := c.State()
	return map[string]any{"state": s.State, "path": s.Path, "reason": s.Reason, "since": s.Since, "session": s.Session}
}

func (c *chn) State() api.ChannelState {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.st
}

func (c *chn) Subscribe() (<-chan api.ChannelState, func()) {
	c.mu.Lock()
	defer c.mu.Unlock()
	ch := make(chan api.ChannelState, 8)
	id := c.subSeq
	c.subSeq++
	c.subs[id] = ch
	ch <- c.st
	return ch, func() {
		c.mu.Lock()
		defer c.mu.Unlock()
		if _, ok := c.subs[id]; ok {
			delete(c.subs, id)
			close(ch)
		}
	}
}

// set publishes a new state; a slow subscriber loses its oldest item, never blocks the channel.
func (c *chn) set(state, path, reason string, up bool) {
	c.mu.Lock()
	if state == c.st.State && reason == c.st.Reason && path == c.st.Path && !up {
		c.mu.Unlock()
		return
	}
	n := c.st.Session
	if up {
		n++
	}
	c.st = api.ChannelState{State: state, Path: path, Reason: reason, Since: time.Now(), Session: n}
	st := c.st
	for _, ch := range c.subs {
		for {
			select {
			case ch <- st:
			default:
				select {
				case <-ch:
					continue
				default:
				}
			}
			break
		}
	}
	c.mu.Unlock()
	c.log.Info("state", "state", state, "via", path, "reason", reason, "session", st.Session)
}

func (c *chn) Start(ctx context.Context) error {
	c.mu.Lock()
	if c.started {
		c.mu.Unlock()
		return errors.New("channel: already-started")
	}
	c.started = true
	if c.o.Mode.NoChannel {
		c.mu.Unlock()
		c.set("waiting", "", "no-channel", false)
		return nil
	}
	rc, cancel := context.WithCancel(context.WithoutCancel(ctx))
	c.cancel, c.done = cancel, make(chan struct{})
	c.mu.Unlock()
	go c.loop(rc)
	return nil
}

func (c *chn) Stop(ctx context.Context) error {
	c.mu.Lock()
	cancel, done, cl := c.cancel, c.done, c.client
	c.mu.Unlock()
	if cancel == nil {
		return nil
	}
	cancel()
	if cl != nil {
		_ = cl.Close()
	}
	select {
	case <-done:
	case <-ctx.Done():
		return ctx.Err()
	}
	c.set("waiting", "", "stopped", false)
	return nil
}

func (c *chn) loop(ctx context.Context) {
	defer close(c.done)
	fails := 0
	first := true
	sw := &sweep{failed: map[string]string{}, mismatch: map[string]bool{}}
	for ctx.Err() == nil {
		c.set("connecting", "", c.takeNetReason(), false)
		sctx, scancel := context.WithCancel(ctx)
		c.mu.Lock()
		c.sessCancel = scancel
		c.mu.Unlock()
		path, err := c.session(sctx, first)
		scancel()
		first = false
		if ctx.Err() != nil {
			return
		}
		if c.consumeNetPending() { // сеть сменилась: старые отказы не в счёт, идём с начала списка без паузы
			fails = 0
			sw.reset()
			select {
			case <-c.kick:
			default:
			}
			c.selectFirst()
			c.set("connecting", "", reasonNetChanged, false)
			continue
		}
		reason := "closed"
		if err != nil {
			reason = err.Error()
		}
		wasUp := path != "" && errors.Is(err, errWasUp)
		if wasUp {
			fails = 0
			sw.reset()
			if c.consumeReturn() {
				c.selectFirst()
				continue
			}
		} else {
			fails++
		}
		mism := !wasUp && isHostKeyMismatch(err)
		if mism {
			reason = reasonIntercepted
			if d := mismatchDetail(err); d != "" {
				reason += ": " + d
			}
		}
		if !wasUp && path != "" {
			sw.failed[path], sw.mismatch[path] = reason, mism
		}
		// Следующий путь по рангу, если ошибка случилась до связи и пути ещё есть.
		if next, all := c.nextPath(ctx, sw); !wasUp && path != "" && next != "" {
			c.set("down", path, reason, false)
			c.log.Info("path-next", "from", path, "to", next)
			if c.selectPath(next) == nil {
				continue // без паузы: идём дальше по рангу
			}
		} else if !wasUp && mism && all {
			// Отпечаток не совпал на ВСЕХ путях: подмена/устаревший конфиг, ожиданием не пройдёт.
			reason = "host key mismatch: на всех путях отпечаток сервера не совпал с конфигом (" + strings.TrimPrefix(mismatchDetail(err), "") + ")"
		}
		if !wasUp {
			sw.reset() // круг по путям закончен — новый круг после паузы
		}
		c.set("down", path, reason, false)
		pause := retryDelay(fails) // связь была (fails=0) — минимальная пауза 0.5 с, чтобы не крутиться
		t := time.NewTimer(pause)
		select {
		case <-ctx.Done():
			t.Stop()
			return
		case <-c.kick:
		case <-t.C:
		}
		t.Stop()
	}
}

// NetChanged: сеть сменилась (вызывается после перенастройки sing-box). Текущая попытка/сессия обрывается,
// круг путей начинается с первого по рангу, без паузы. Закреплённый путь (ForcePath) не сбрасывается.
func (c *chn) NetChanged() {
	c.mu.Lock()
	cancel := c.sessCancel
	if !c.started || c.cancel == nil {
		c.mu.Unlock()
		return
	}
	c.netPending = true
	st := c.st
	c.mu.Unlock()
	c.log.Info("net-changed", "session", st.Session, "state", st.State)
	c.set("connecting", st.Path, reasonNetChanged, false)
	if cancel != nil {
		cancel()
	}
	select { // разбудить паузу между кругами
	case c.kick <- struct{}{}:
	default:
	}
}

// Underlay: сеть под каналом изменилась (физическая сеть, чужой VPN, старт/стоп нашего VPN). Канал — слой поверх сети,
// поэтому живая сессия НЕ рвётся (проверка и переключение — следующий этап). Если сессия не up — как NetChanged:
// сразу новый круг путей.
func (c *chn) Underlay() {
	c.mu.Lock()
	st := c.st
	started := c.started && c.cancel != nil
	if started && st.State == "up" {
		c.underlayAt = time.Now()
		c.mu.Unlock()
		c.log.Info("underlay-changed", "session", st.Session, "state", st.State)
		return
	}
	c.mu.Unlock()
	c.NetChanged()
}

func (c *chn) takeNetReason() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.netPending {
		return reasonNetChanged
	}
	return ""
}

func (c *chn) consumeNetPending() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	p := c.netPending
	c.netPending = false
	return p
}

// consumeReturn — сессию закрыли ради возврата на предпочтительный путь.
func (c *chn) consumeReturn() bool {
	select {
	case <-c.retPref:
		return true
	default:
		return false
	}
}

// selectFirst — выбрать первый по рангу путь селектора (если не закреплён другой).
func (c *chn) selectFirst() {
	if c.sb == nil || c.o.Mode.NoSingbox {
		return
	}
	c.mu.Lock()
	pinned := time.Now().Before(c.pinned)
	c.mu.Unlock()
	if names := c.sb.PathNames(); !pinned && len(names) > 0 {
		_ = c.selectPath(names[0])
	}
}

// armReturn: сессия поднялась на пути не первого ранга — один раз через задержку вернуться на предпочтительный.
// Таймер одноразовый и ставится по событию «up», не опрос; на первом пути/закреплённом — не ставится.
func (c *chn) armReturn(path string) {
	select { // сигнал прошлой сессии не относится к этой
	case <-c.retPref:
	default:
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.retTimer != nil {
		c.retTimer.Stop()
		c.retTimer = nil
	}
	if c.sb == nil || c.o.Mode.NoSingbox || time.Now().Before(c.pinned) {
		return
	}
	names := c.sb.PathNames()
	if len(names) == 0 || path == names[0] {
		c.retFails = 0
		return
	}
	d := returnBase
	for i := 0; i < c.retFails && d < returnMax; i++ {
		d *= 2
	}
	c.retFails++
	c.retTimer = time.AfterFunc(min(d, returnMax), func() {
		select {
		case c.retPref <- struct{}{}:
		default:
		}
	})
}

func (c *chn) disarmReturnKeep() {
	c.mu.Lock()
	if c.retTimer != nil {
		c.retTimer.Stop()
		c.retTimer = nil
	}
	c.mu.Unlock()
}

const reasonIntercepted = "отпечаток не совпал — путь перехвачен"

// sweep — пройденные в этом круге пути: имя → причина отказа; mismatch — отказ из-за отпечатка.
type sweep struct {
	failed   map[string]string
	mismatch map[string]bool
}

func (s *sweep) reset() {
	clear(s.failed)
	clear(s.mismatch)
}

func isHostKeyMismatch(err error) bool {
	return err != nil && strings.Contains(err.Error(), "host key mismatch")
}

// nextPath — первый ещё не пробованный путь селектора по рангу; all — все пути круга пробованы и все с чужим отпечатком.
func (c *chn) nextPath(ctx context.Context, sw *sweep) (next string, all bool) {
	if c.sb == nil || c.o.Mode.NoSingbox {
		return "", len(sw.failed) > 0 && len(sw.mismatch) == len(sw.failed) && allTrue(sw.mismatch)
	}
	c.mu.Lock()
	pinned := time.Now().Before(c.pinned)
	c.mu.Unlock()
	names := c.sb.PathNames()
	if pinned || len(names) == 0 {
		return "", false
	}
	for _, n := range names {
		if _, tried := sw.failed[n]; !tried {
			return n, false
		}
	}
	return "", allTrue(sw.mismatch)
}

func allTrue(m map[string]bool) bool {
	for _, v := range m {
		if !v {
			return false
		}
	}
	return len(m) > 0
}

// selectPath переключает селектор chan на путь name (без закрепления).
func (c *chn) selectPath(name string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return c.sb.Clash(ctx, "PUT", "/proxies/chan", map[string]string{"name": name}, nil)
}

// pathLabel — имя пути для событий: у sing-box это текущий выбор селектора chan, иначе ssh-direct.
func (c *chn) pathLabel(base string) string {
	if base != "chan" || c.sb == nil {
		return base
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	var g struct {
		Now string `json:"now"`
	}
	if err := c.sb.Clash(ctx, "GET", "/proxies/chan", nil, &g); err != nil || g.Now == "" {
		return base
	}
	return g.Now
}

var errWasUp = errors.New("connection lost")

func (c *chn) pickPath(ctx context.Context, first bool) (string, string) {
	direct := net.JoinHostPort(c.sv.Host, strconv.Itoa(c.sv.Port))
	if c.o.Mode.NoSingbox || c.sb == nil {
		return "ssh-direct", direct
	}
	select {
	case <-c.sb.Ready():
		return "chan", c.sb.ChanAddr()
	default:
	}
	select { // sing-box перезапускается (смена сети/падение): ждём его событие Ready, не опрашиваем
	case <-c.sb.Ready():
		return "chan", c.sb.ChanAddr()
	case <-time.After(sbWait):
		return "ssh-direct", direct
	case <-ctx.Done():
		return "", ""
	}
}

func (c *chn) dial(ctx context.Context, addr string) (*ssh.Client, *activityConn, error) {
	d := net.Dialer{Timeout: c.o.DialTimeout}
	raw, err := d.DialContext(ctx, "tcp", addr)
	if err != nil {
		return nil, nil, fmt.Errorf("dial: %w", err)
	}
	ac := &activityConn{Conn: raw}
	ac.touch()
	conf := &ssh.ClientConfig{
		User:            c.sv.User,
		Auth:            []ssh.AuthMethod{ssh.PublicKeys(c.signr)},
		HostKeyCallback: c.checkHostKey,
		// Сервер держит ключи нескольких типов (ed25519, ecdsa, rsa); без этого клиент Go сначала просит ecdsa/rsa и
		// получает «чужой» ключ, хотя в конфиге закреплён другой тип. Просим тот тип, что закреплён: строгость не слабеет.
		HostKeyAlgorithms: hostKeyAlgos(c.hkey),
		Timeout:           c.o.DialTimeout,
	}
	_ = raw.SetDeadline(time.Now().Add(c.o.DialTimeout))
	cc, chans, reqs, err := ssh.NewClientConn(ac, c.sv.Host, conf)
	if err != nil {
		_ = raw.Close()
		return nil, nil, fmt.Errorf("ssh: %w", err)
	}
	_ = raw.SetDeadline(time.Time{})
	return ssh.NewClient(cc, chans, reqs), ac, nil
}

func (c *chn) checkHostKey(_ string, _ net.Addr, key ssh.PublicKey) error {
	if !bytes.Equal(key.Marshal(), c.hkey.Marshal()) {
		return &hostKeyError{want: ssh.FingerprintSHA256(c.hkey), got: ssh.FingerprintSHA256(key), gotType: key.Type()}
	}
	return nil
}

// hostKeyError — отпечатки публичные (не секрет): их видно в журнале и на странице.
type hostKeyError struct{ want, got, gotType string }

func (e *hostKeyError) Error() string {
	return fmt.Sprintf("host key mismatch: ожидался %s, получен %s (%s)", e.want, e.got, e.gotType)
}

func hostKeyAlgos(k ssh.PublicKey) []string {
	switch k.Type() {
	case ssh.KeyAlgoRSA:
		return []string{ssh.KeyAlgoRSASHA512, ssh.KeyAlgoRSASHA256, ssh.KeyAlgoRSA}
	default:
		return []string{k.Type()}
	}
}

// mismatchDetail — «ожидался …, получен …» из ошибки подключения ("" — если это не mismatch).
func mismatchDetail(err error) string {
	var he *hostKeyError
	if errors.As(err, &he) {
		return fmt.Sprintf("ожидался %s, получен %s (%s)", he.want, he.got, he.gotType)
	}
	return ""
}

type activityConn struct {
	net.Conn
	last atomic.Int64
}

func (a *activityConn) touch() { a.last.Store(time.Now().UnixNano()) }
func (a *activityConn) Read(p []byte) (int, error) {
	n, err := a.Conn.Read(p)
	if n > 0 {
		a.touch()
	}
	return n, err
}
func (a *activityConn) idle() time.Duration { return time.Since(time.Unix(0, a.last.Load())) }

// keepalive: ServerAliveInterval x CountMax. A probe is sent only when the link is silent;
// this is a liveness protocol of the ssh link, not state polling.
func (c *chn) keepalive(ctx context.Context, cl *ssh.Client, ac *activityConn, dead chan<- struct{}) {
	t := time.NewTicker(c.o.Keepalive)
	defer t.Stop()
	miss := 0
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		if ac.idle() < c.o.Keepalive {
			miss = 0
			continue
		}
		res := make(chan error, 1)
		go func() { _, _, err := cl.SendRequest("keepalive@openssh.com", true, nil); res <- err }()
		select {
		case err := <-res:
			if err != nil {
				close(dead)
				return
			}
			miss = 0
		case <-time.After(c.o.Keepalive):
			if miss++; miss >= 3 {
				close(dead)
				return
			}
		case <-ctx.Done():
			return
		}
	}
}

func (c *chn) listen(cl *ssh.Client) (net.Listener, int, error) {
	var last error
	for i := 0; i < rportCount; i++ {
		port := rportFirst + c.rcur%rportCount
		c.rcur++
		l, err := cl.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err == nil {
			return l, port, nil
		}
		last = err
	}
	return nil, 0, fmt.Errorf("rport: no free port in %d-%d: %w", rportFirst, rportFirst+rportCount-1, last)
}

func nonce() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// session runs one connection until it is lost. Returns the path and the reason.
func (c *chn) session(ctx context.Context, first bool) (string, error) {
	path, addr := c.pickPath(ctx, first)
	if path == "" {
		return "", ctx.Err()
	}
	path = c.pathLabel(path)
	c.set("connecting", path, "", false)
	cl, ac, err := c.dial(ctx, addr)
	if err != nil {
		return path, err
	}
	sctx, stop := context.WithCancel(ctx)
	defer stop()
	c.mu.Lock()
	c.client = cl
	c.mu.Unlock()
	defer func() {
		c.mu.Lock()
		c.client = nil
		c.mu.Unlock()
		_ = cl.Close()
	}()
	dead := make(chan struct{})
	go c.keepalive(sctx, cl, ac, dead)
	connLost := make(chan struct{})
	go func() { _ = cl.Wait(); close(connLost) }()
	go func() { // external close (Stop) or keepalive death drops the connection
		select {
		case <-dead:
		case <-ctx.Done():
		case <-sctx.Done():
			return
		}
		_ = cl.Close()
	}()

	if !c.cleaned { // previous runs: stale server-side "ra-lab session" of this PC
		c.cleaned = true
		c.cleanStale(cl)
	}
	l, rport, err := c.listen(cl)
	if err != nil {
		return path, err
	}
	defer l.Close()
	c.agent.Serve(l) // the agent already serves before the server connects

	sess, err := cl.NewSession()
	if err != nil {
		return path, fmt.Errorf("session: %w", err)
	}
	defer sess.Close()
	stdin, err := sess.StdinPipe()
	if err != nil {
		return path, err
	}
	stdout, err := sess.StdoutPipe()
	if err != nil {
		return path, err
	}
	errw := c.log.Writer(api.StreamCore, "ra-lab")
	defer errw.Close()
	sess.Stderr = errw
	n := nonce()
	cmd := fmt.Sprintf("~/.local/bin/ra-lab session --pc %s --nonce %s --port %d --version go-%s", c.o.PC, n, rport, shq(strings.TrimPrefix(c.o.Version, "go-")))
	if c.o.Rollback != "" {
		cmd += " --rollback " + shq(c.o.Rollback)
	}
	if err = sess.Start(cmd); err != nil {
		return path, fmt.Errorf("exec: %w", err)
	}
	upCh := make(chan error, 1)
	go func() { upCh <- c.handshake(bufio.NewReaderSize(stdout, 1<<16), stdin, n, rport) }()
	select {
	case err = <-upCh:
		if err != nil {
			return path, err
		}
	case <-time.After(upTimeout):
		return path, errors.New("handshake: timeout")
	case <-connLost:
		return path, errors.New("handshake: connection lost")
	case <-ctx.Done():
		return path, ctx.Err()
	}
	c.set("up", path, "", true)
	c.log.Info("up", "rport", rport, "via", path)
	c.armReturn(path)
	defer c.disarmReturnKeep()
	waitSess := make(chan error, 1)
	go func() { waitSess <- sess.Wait() }()
	select { // block on events: connection lost, session end, forced switch, stop
	case <-connLost:
		select {
		case <-dead:
			return path, fmt.Errorf("%w: keepalive", errWasUp)
		default:
			return path, fmt.Errorf("%w: closed", errWasUp)
		}
	case <-waitSess:
		return path, fmt.Errorf("%w: server session ended", errWasUp)
	case <-c.kick:
		return path, fmt.Errorf("%w: path switch", errWasUp)
	case <-c.retPref:
		c.retPref <- struct{}{} // consumeReturn в цикле увидит признак
		return path, fmt.Errorf("%w: возврат на предпочтительный путь", errWasUp)
	case <-ctx.Done():
		return path, ctx.Err()
	}
}

func shq(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// handshake: RALAB-PROBE1 -> RALAB-UP1 -> CLAIM + token -> RALAB-CHANNEL-UP.
func (c *chn) handshake(r *bufio.Reader, w io.Writer, n string, rport int) error {
	line, err := r.ReadString('\n')
	if err != nil {
		return fmt.Errorf("probe: %w", err)
	}
	if strings.TrimRight(line, "\r\n") != fmt.Sprintf("RALAB-PROBE1 %s %d", n, probeSize) {
		return errors.New("probe: bad header or nonce")
	}
	h := sha256.New()
	if _, err = io.CopyN(h, r, probeSize); err != nil {
		return fmt.Errorf("probe: %w", err)
	}
	if line, err = r.ReadString('\n'); err != nil || strings.TrimRight(line, "\r\n") != "" {
		return errors.New("probe: no separator")
	}
	if line, err = r.ReadString('\n'); err != nil || strings.TrimRight(line, "\r\n") != "SHA256 "+hex.EncodeToString(h.Sum(nil)) {
		return errors.New("probe: sha mismatch down")
	}
	data := make([]byte, probeSize)
	_, _ = rand.Read(data)
	sum := sha256.Sum256(data)
	if _, err = w.Write(data); err != nil {
		return fmt.Errorf("probe: %w", err)
	}
	if line, err = r.ReadString('\n'); err != nil {
		return fmt.Errorf("probe: %w", err)
	}
	if strings.TrimRight(line, "\r\n") != fmt.Sprintf("RALAB-UP1 %s %s", n, hex.EncodeToString(sum[:])) {
		return errors.New("probe: sha mismatch up")
	}
	if _, err = io.WriteString(w, "CLAIM\n"+c.agent.Token()+"\n"); err != nil {
		return fmt.Errorf("claim: %w", err)
	}
	for {
		if line, err = r.ReadString('\n'); err != nil {
			return fmt.Errorf("claim: %w", err)
		}
		switch {
		case strings.HasPrefix(line, "RALAB-CHANNEL-UP"):
			return nil
		case strings.HasPrefix(line, "RALAB-AGENT-FAIL"):
			return fmt.Errorf("agent-fail: %s", strings.TrimSpace(line))
		}
	}
}

// cleanStale kills leftover "ra-lab session" processes of this PC (a crashed previous run).
// Best effort; the new session never matches because it starts afterwards.
func (c *chn) cleanStale(cl *ssh.Client) {
	// Только для имён v3 (-v3): pkill по имени без суффикса мог бы убить живую сессию Лаборатории v2 того же ПК.
	if !strings.HasSuffix(c.o.PC, "-v3") {
		return
	}
	s, err := cl.NewSession()
	if err != nil {
		return
	}
	defer s.Close()
	pat := "[r]a-lab session --pc " + c.o.PC + " "
	_ = s.Run("pkill -f -- " + shq(pat) + " || true")
	c.log.Info("stale-clean", "pc", c.o.PC)
}

func (c *chn) current() *ssh.Client {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.client
}

func (c *chn) DialContext(ctx context.Context, network, addr string) (net.Conn, error) {
	cl := c.current()
	if cl == nil || c.State().State != "up" {
		return nil, errors.New("channel: not-up")
	}
	type res struct {
		conn net.Conn
		err  error
	}
	ch := make(chan res, 1)
	go func() { conn, err := cl.Dial(network, addr); ch <- res{conn, err} }()
	select {
	case r := <-ch:
		return r.conn, r.err
	case <-ctx.Done():
		go func() {
			if r := <-ch; r.conn != nil {
				_ = r.conn.Close()
			}
		}()
		return nil, ctx.Err()
	}
}

func (c *chn) Exec(ctx context.Context, cmd string, stdin io.Reader, stdout, stderr io.Writer) (int, error) {
	cl := c.current()
	if cl == nil || c.State().State != "up" {
		return -1, errors.New("channel: not-up")
	}
	s, err := cl.NewSession()
	if err != nil {
		return -1, err
	}
	defer s.Close()
	s.Stdin, s.Stdout, s.Stderr = stdin, stdout, stderr
	if err = s.Start(cmd); err != nil {
		return -1, err
	}
	done := make(chan error, 1)
	go func() { done <- s.Wait() }()
	select {
	case err = <-done:
	case <-ctx.Done():
		_ = s.Close()
		return -1, ctx.Err()
	}
	var ee *ssh.ExitError
	switch {
	case err == nil:
		return 0, nil
	case errors.As(err, &ee):
		return ee.ExitStatus(), nil
	}
	return -1, err
}

// ForcePath selects the path in the sing-box selector "chan", pins it and drops ssh to reconnect.
func (c *chn) ForcePath(name string) error {
	if c.sb == nil || c.o.Mode.NoSingbox {
		return errors.New("channel: no-singbox")
	}
	known := false
	for _, n := range c.sb.PathNames() {
		if n == name {
			known = true
		}
	}
	if !known {
		return errors.New("channel: unknown-path")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := c.sb.Clash(ctx, "PUT", "/proxies/chan", map[string]string{"name": name}, nil); err != nil {
		return fmt.Errorf("channel: select: %w", err)
	}
	c.mu.Lock()
	c.pinned = time.Now().Add(pinFor)
	c.mu.Unlock()
	c.log.Info("force", "via", name, "pin_s", int(pinFor.Seconds()))
	select {
	case c.kick <- struct{}{}:
	default:
	}
	return nil
}
