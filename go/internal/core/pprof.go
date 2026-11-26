package core

import (
	"net"
	"net/http"
	"net/http/pprof"
)

// startPprof — только 127.0.0.1 (отладка, --pprof).
func (c *core) startPprof(addr string) {
	host, _, err := net.SplitHostPort(addr)
	if err != nil || (host != "127.0.0.1" && host != "localhost") {
		c.log.Warn("core: pprof-refused", "addr", addr)
		return
	}
	l, err := net.Listen("tcp", addr)
	if err != nil {
		c.log.Warn("core: pprof", "err", err.Error())
		return
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/debug/pprof/", pprof.Index)
	mux.HandleFunc("/debug/pprof/profile", pprof.Profile)
	mux.HandleFunc("/debug/pprof/trace", pprof.Trace)
	srv := &http.Server{Handler: mux}
	go func() { _ = srv.Serve(l) }()
	c.log.Info("core: pprof", "addr", l.Addr().String())
	c.onStop = append(c.onStop, func() { _ = srv.Close() })
}
