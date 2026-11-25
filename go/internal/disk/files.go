package disk

import (
	"bytes"
	"encoding/json"
	"encoding/xml"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var errSettings = errors.New("Не удалось подготовить настройки Диска.")

func readJSON(path string, dst any) bool {
	b, err := os.ReadFile(path)
	return err == nil && json.Unmarshal(bytes.TrimPrefix(b, []byte{239, 187, 191}), dst) == nil
}
func writeFile(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(data); err == nil {
		err = f.Sync()
	}
	if e := f.Close(); err == nil {
		err = e
	}
	if err != nil {
		return err
	}
	return os.Rename(f.Name(), path)
}
func writeJSON(path string, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return writeFile(path, b)
}
func exists(path string) bool { st, err := os.Stat(path); return err == nil && !st.IsDir() }
func expand(s string) string {
	s = regexp.MustCompile(`%([^%]+)%`).ReplaceAllStringFunc(s, func(v string) string {
		if e, ok := os.LookupEnv(v[1 : len(v)-1]); ok {
			return e
		}
		return v
	})
	s = os.ExpandEnv(s)
	if s == "~" || strings.HasPrefix(s, "~/") || strings.HasPrefix(s, `~\`) {
		h, _ := os.UserHomeDir()
		s = filepath.Join(h, strings.TrimLeft(s[1:], `/\`))
	}
	return s
}
func defaultHome() string { return filepath.Join(os.Getenv("LOCALAPPDATA"), "RemoteDisk") }
func defaultBase() string {
	h := os.Getenv("USERPROFILE")
	if h == "" {
		h, _ = os.UserHomeDir()
	}
	return filepath.Join(h, "Disk")
}

// A small XML tree preserves generated Syncthing settings, including unknown elements.
type element struct {
	XMLName  xml.Name
	Attr     []xml.Attr `xml:",any,attr"`
	Text     string     `xml:",chardata"`
	Children []*element `xml:",any"`
}

func (n *element) child(name string) *element {
	for _, c := range n.Children {
		if c.XMLName.Local == name {
			return c
		}
	}
	return nil
}
func (n *element) text(name string) string {
	if c := n.child(name); c != nil {
		return strings.TrimSpace(c.Text)
	}
	return ""
}
func (n *element) remove(name string) {
	out := n.Children[:0]
	for _, c := range n.Children {
		if c.XMLName.Local != name {
			out = append(out, c)
		}
	}
	n.Children = out
}
func (n *element) put(name, value string) {
	n.remove(name)
	n.Children = append(n.Children, &element{XMLName: xml.Name{Local: name}, Text: value})
}
func loadXML(state string) (*element, error) {
	b, e := os.ReadFile(filepath.Join(state, "config.xml"))
	if e != nil {
		return nil, e
	}
	var root element
	e = xml.Unmarshal(b, &root)
	return &root, e
}
func prepare(state string, guiPort, listenPort string) error {
	root, e := loadXML(state)
	if e != nil {
		return errSettings
	}
	gui, options := root.child("gui"), root.child("options")
	if gui == nil || options == nil {
		return errSettings
	}
	root.remove("folder")
	found := false
	for i, a := range gui.Attr {
		if a.Name.Local == "tls" {
			gui.Attr[i].Value = "false"
			found = true
		}
	}
	if !found {
		gui.Attr = append(gui.Attr, xml.Attr{Name: xml.Name{Local: "tls"}, Value: "false"})
	}
	gui.put("address", "127.0.0.1:"+guiPort)
	for _, name := range []string{"globalAnnounceEnabled", "localAnnounceEnabled", "relaysEnabled", "natEnabled", "crashReportingEnabled", "startBrowser"} {
		options.put(name, "false")
	}
	for name, value := range map[string]string{"listenAddress": "tcp://127.0.0.1:" + listenPort, "autoUpgradeIntervalH": "0", "reconnectionIntervalS": "10", "urAccepted": "-1"} {
		options.put(name, value)
	}
	b, e := xml.Marshal(root)
	if e != nil {
		return errSettings
	}
	return writeFile(filepath.Join(state, "config.xml"), append([]byte(xml.Header), b...))
}
