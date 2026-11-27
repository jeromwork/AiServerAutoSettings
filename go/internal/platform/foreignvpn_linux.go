//go:build linux

package platform

import (
	"encoding/binary"
	"net"
	"os"
	"syscall"
	"unsafe"
)

// ForeignVPN — маршрут к 1.1.1.1 через netlink RTM_GETROUTE; железный (есть /sys/class/net/<if>/device) и наш = "".
func ForeignVPN() string {
	idx := routeIfIndex(net.IPv4(1, 1, 1, 1).To4())
	if idx <= 0 {
		return ""
	}
	ni, err := net.InterfaceByIndex(idx)
	if err != nil || isOurIface(ni.Name) {
		return ""
	}
	if _, err := os.Stat("/sys/class/net/" + ni.Name + "/device"); err == nil {
		return ""
	}
	if ni.Flags&net.FlagLoopback != 0 {
		return ""
	}
	return ni.Name
}

func routeIfIndex(dst net.IP) int {
	fd, err := syscall.Socket(syscall.AF_NETLINK, syscall.SOCK_RAW|syscall.SOCK_CLOEXEC, syscall.NETLINK_ROUTE)
	if err != nil {
		return 0
	}
	defer syscall.Close(fd)
	tv := syscall.Timeval{Sec: 2}
	_ = syscall.SetsockoptTimeval(fd, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &tv)
	// nlmsghdr(16) + rtmsg(12) + rtattr(4)+dst(4)
	msg := make([]byte, 36)
	binary.LittleEndian.PutUint32(msg[0:], 36)
	binary.LittleEndian.PutUint16(msg[4:], syscall.RTM_GETROUTE)
	binary.LittleEndian.PutUint16(msg[6:], syscall.NLM_F_REQUEST)
	binary.LittleEndian.PutUint32(msg[8:], 1)
	msg[16] = syscall.AF_INET
	msg[17] = 32 // dst_len
	binary.LittleEndian.PutUint16(msg[28:], 8)
	binary.LittleEndian.PutUint16(msg[30:], syscall.RTA_DST)
	copy(msg[32:], dst)
	if err := syscall.Sendto(fd, msg, 0, &syscall.SockaddrNetlink{Family: syscall.AF_NETLINK}); err != nil {
		return 0
	}
	buf := make([]byte, 8192)
	n, _, err := syscall.Recvfrom(fd, buf, 0)
	if err != nil || n < syscall.NLMSG_HDRLEN {
		return 0
	}
	msgs, err := syscall.ParseNetlinkMessage(buf[:n])
	if err != nil {
		return 0
	}
	for _, m := range msgs {
		if m.Header.Type != syscall.RTM_NEWROUTE || len(m.Data) < syscall.SizeofRtMsg {
			continue
		}
		attrs, err := syscall.ParseNetlinkRouteAttr(&syscall.NetlinkMessage{Header: m.Header, Data: m.Data})
		if err != nil {
			continue
		}
		for _, a := range attrs {
			if a.Attr.Type == syscall.RTA_OIF && len(a.Value) >= 4 {
				return int(*(*uint32)(unsafe.Pointer(&a.Value[0])))
			}
		}
	}
	return 0
}
