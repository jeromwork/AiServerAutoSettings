package forward

import (
	"bufio"
	"encoding/binary"
	"io"
	"net"
	"sync"
)

var (
	replyFail  = []byte{5, 5, 0, 1, 0, 0, 0, 0, 0, 0}
	replyNoCmd = []byte{5, 7, 0, 1, 0, 0, 0, 0, 0, 0}
	replyOK    = []byte{5, 0, 0, 1, 0, 0, 0, 0, 0, 0}
)

// pipe: пока идёт хоть одно направление; конец любого закрывает оба сокета (как v2).
func pipe(a, b net.Conn) {
	var wg sync.WaitGroup
	wg.Add(2)
	one := func(x, y net.Conn) {
		defer wg.Done()
		io.Copy(y, x)
		x.Close()
		y.Close()
	}
	go one(b, a)
	one(a, b)
	wg.Wait()
}

// bufConn читает через bufio (после PEEK первого байта), пишет напрямую.
type bufConn struct {
	net.Conn
	r *bufio.Reader
}

func (b *bufConn) Read(p []byte) (int, error) { return b.r.Read(p) }

// internalSocks: SOCKS5 поверх канала для sing-box LAN — всё идёт через канал.
func (f *fwd) internalSocks(c net.Conn, s *sess) error {
	return f.socks5(&bufConn{c, bufio.NewReader(c)}, s, func(h string, p int) (net.Conn, error) {
		up, err := f.dial(h, p)
		if err == nil {
			s.reg(up)
		}
		return up, err
	})
}

// socks5: без авторизации, только CONNECT.
func (f *fwd) socks5(c net.Conn, s *sess, open func(string, int) (net.Conn, error)) error {
	var b [4]byte
	if _, err := io.ReadFull(c, b[:2]); err != nil {
		return err
	}
	if _, err := io.CopyN(io.Discard, c, int64(b[1])); err != nil {
		return err
	}
	c.Write([]byte{5, 0})
	if _, err := io.ReadFull(c, b[:4]); err != nil {
		return err
	}
	if b[1] != 1 {
		c.Write(replyNoCmd)
		return nil
	}
	var host string
	switch b[3] {
	case 1, 4:
		ip := make([]byte, map[byte]int{1: 4, 4: 16}[b[3]])
		if _, err := io.ReadFull(c, ip); err != nil {
			return err
		}
		host = net.IP(ip).String()
	default:
		if _, err := io.ReadFull(c, b[:1]); err != nil {
			return err
		}
		name := make([]byte, b[0])
		if _, err := io.ReadFull(c, name); err != nil {
			return err
		}
		host = string(name)
	}
	if _, err := io.ReadFull(c, b[:2]); err != nil {
		return err
	}
	port := int(binary.BigEndian.Uint16(b[:2]))
	up, err := open(host, port)
	if err != nil {
		c.Write(replyFail)
		f.refuse(host, err)
		return nil
	}
	c.Write(replyOK)
	pipe(c, up)
	return nil
}
