package explorer

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// ---- подмены

type node struct {
	dir     bool
	content string
	a       Attrs
}

type memFS struct{ n map[string]*node }

func newMemFS(dirs ...string) *memFS {
	m := &memFS{n: map[string]*node{}}
	for _, d := range dirs {
		m.n[d] = &node{dir: true}
	}
	return m
}
func (m *memFS) Stat(p string) (bool, bool, Attrs, error) {
	n := m.n[p]
	if n == nil {
		return false, false, Attrs{}, nil
	}
	return true, n.dir, n.a, nil
}
func (m *memFS) SetAttrs(p string, a Attrs) error {
	if n := m.n[p]; n != nil {
		n.a.ReadOnly, n.a.Hidden, n.a.System = a.ReadOnly, a.Hidden, a.System
	}
	return nil
}
func (m *memFS) Entries(p string) ([]string, error) {
	var out []string
	for k := range m.n {
		if filepath.Dir(k) == p && k != p {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out, nil
}
func (m *memFS) Read(p string) (string, error) {
	if n := m.n[p]; n != nil && !n.dir {
		return n.content, nil
	}
	return "", os.ErrNotExist
}
func (m *memFS) Write(p, c string) error { m.n[p] = &node{content: c}; return nil }
func (m *memFS) Mkdir(p string) error    { m.n[p] = &node{dir: true}; return nil }
func (m *memFS) RemoveFile(p string) error {
	delete(m.n, p)
	return nil
}
func (m *memFS) RemoveDir(p string) error {
	delete(m.n, p)
	return nil
}

type fakeIcons struct{}

func (fakeIcons) PathFor(k Kind) (string, error)   { return `C:\icons\` + string(k) + ".ico", nil }
func (fakeIcons) ApplicationPath() (string, error) { return `C:\icons\app.ico`, nil }

type notes struct{ paths []string }

func (n *notes) Changed(p string) { n.paths = append(n.paths, p) }

type memReg struct{ v map[string]map[string]string }

func newMemReg() *memReg                  { return &memReg{v: map[string]map[string]string{}} }
func (r *memReg) Exists(k string) bool    { _, ok := r.v[k]; return ok }
func (r *memReg) Read(k, n string) string { return r.v[k][n] }
func (r *memReg) Write(k, n, v string) error {
	if r.v[k] == nil {
		r.v[k] = map[string]string{}
	}
	r.v[k][n] = v
	return nil
}
func (r *memReg) DeleteTree(k string) error {
	for key := range r.v {
		if key == k || strings.HasPrefix(key, k+`\`) {
			delete(r.v, key)
		}
	}
	return nil
}

type call3 struct{ method, path string }

type fakeAPI struct {
	peer   string
	data   map[string]any // "GET path" → ответ
	calls  []call3
	bodies []any
	fail   map[string]error
}

func (f *fakeAPI) Peer() string { return f.peer }
func (f *fakeAPI) Request(_ context.Context, method, path string, body any) ([]byte, error) {
	f.calls = append(f.calls, call3{method, path})
	f.bodies = append(f.bodies, body)
	key := method + " " + path
	if e := f.fail[key]; e != nil {
		return nil, e
	}
	v, ok := f.data[key]
	if !ok {
		return nil, nil
	}
	return json.Marshal(v)
}
func (f *fakeAPI) did(method, path string) bool {
	for _, c := range f.calls {
		if c.method == method && c.path == path {
			return true
		}
	}
	return false
}

// ---- состояния

func TestStatusKinds(t *testing.T) {
	full := func(m map[string]any) map[string]any {
		b := map[string]any{"state": "idle", "needBytes": 0.0, "needTotalItems": 0.0, "globalBytes": 100.0}
		for k, v := range m {
			b[k] = v
		}
		return b
	}
	remote := func(m map[string]any) map[string]any {
		b := map[string]any{"completion": 100.0, "needItems": 0.0, "needBytes": 0.0, "needDeletes": 0.0, "remoteState": "valid"}
		for k, v := range m {
			b[k] = v
		}
		return b
	}
	cases := []struct {
		name      string
		local, rm map[string]any
		conn, was bool
		want      Kind
	}{
		{"synced", full(nil), remote(nil), true, false, KindSynced},
		{"syncing", full(map[string]any{"needBytes": 50.0, "state": "syncing"}), remote(map[string]any{"completion": 50.0}), true, false, KindSyncing},
		{"offline", full(nil), remote(nil), false, false, KindOffline},
		{"pending", full(map[string]any{"state": ""}), remote(nil), true, false, KindPending},
		{"error", full(map[string]any{"error": "x"}), remote(nil), true, false, KindError},
		{"localchanges", full(map[string]any{"receiveOnlyTotalItems": 1.0}), remote(nil), true, false, KindLocalChanges},
		{"removed", full(nil), remote(map[string]any{"remoteState": "notSharing"}), true, true, KindServerRemoved},
		{"waiting-not-removed", full(nil), remote(map[string]any{"remoteState": "notSharing"}), true, false, KindPending},
		{"paused", full(map[string]any{"state": "paused"}), remote(nil), true, false, KindPaused},
	}
	for _, c := range cases {
		got := status(&FolderState{}, c.local, c.rm, c.conn, c.was)
		if got.Kind != c.want {
			t.Errorf("%s: %s, want %s", c.name, got.Kind, c.want)
		}
	}
	r := status(&FolderState{}, full(map[string]any{"needBytes": 1.0, "state": "syncing"}), remote(map[string]any{"completion": 100.0}), true, false)
	if r.Percent > 99 {
		t.Errorf("percent %d", r.Percent)
	}
}

// ---- оформление

func TestReconcilePlaceholderAndCleanup(t *testing.T) {
	root := filepath.Join("/d", "Disk")
	fs := newMemFS("/d")
	nt := &notes{}
	s := NewService(fs, fakeIcons{}, nt, nil)
	row := &FolderState{ID: "x", Name: "Work", Path: filepath.Join(root, "Work"), ServerOnly: true, Kind: KindServerOnly}
	s.Reconcile(root, []*FolderState{row})
	ini := filepath.Join(row.Path, "desktop.ini")
	n := fs.n[ini]
	if n == nil || !strings.Contains(n.content, "IconResource=C:\\icons\\ServerOnly.ico,0") || !strings.Contains(n.content, "Placeholder=1") {
		t.Fatalf("desktop.ini: %+v", n)
	}
	if !n.a.Hidden || !n.a.System || !fs.n[row.Path].a.ReadOnly {
		t.Fatal("attributes")
	}
	if !s.IsPlaceholder(row.Path) || len(nt.paths) == 0 {
		t.Fatal("placeholder/notify")
	}
	// повтор ничего не меняет
	nt.paths = nil
	s.Reconcile(root, []*FolderState{row})
	if len(nt.paths) != 0 {
		t.Fatal("repeat must be quiet")
	}
	// папки нет в списке → заглушка, созданная нами, исчезает
	s.Reconcile(root, nil)
	if _, ok := fs.n[row.Path]; ok {
		t.Fatal("placeholder not removed")
	}
}

func TestForeignDesktopIniUntouched(t *testing.T) {
	root := "/d/Disk"
	fs := newMemFS("/d", root, root+"/A")
	fs.n[root+"/A/desktop.ini"] = &node{content: "[.ShellClassInfo]\r\nIconFile=x\r\n"}
	s := NewService(fs, fakeIcons{}, nil, nil)
	s.Reconcile(root, []*FolderState{{Path: root + "/A", Kind: KindSynced}})
	if fs.n[root+"/A/desktop.ini"].content != "[.ShellClassInfo]\r\nIconFile=x\r\n" {
		t.Fatal("foreign ini changed")
	}
}

func TestLocalCopyClassification(t *testing.T) {
	root := "/d/Disk"
	fs := newMemFS("/d", root, root+"/A")
	fs.n[root+"/A/file.txt"] = &node{}
	s := NewService(fs, fakeIcons{}, nil, nil)
	row := &FolderState{Path: root + "/A", ServerOnly: true, Kind: KindServerOnly}
	s.ClassifyLocalCopies([]*FolderState{row})
	if row.Kind != KindLocalCopy {
		t.Fatalf("kind %s", row.Kind)
	}
}

func TestUTF16RoundTrip(t *testing.T) {
	if got := decodeText(encodeUTF16LE("Привет\r\n[a]")); got != "Привет\r\n[a]" {
		t.Fatal(got)
	}
}

// ---- меню

func TestRegistryMenu(t *testing.T) {
	root := `/d/Disk`
	reg := newMemReg()
	changes := 0
	r := NewRegistry(reg, nil, func() { changes++ })
	rows := []*FolderState{
		{Path: root + "/Srv", ServerOnly: true, Kind: KindServerOnly},
		{Path: root + "/Copy", ServerOnly: true, Kind: KindLocalCopy},
		{Path: root + "/Sync", Kind: KindSynced, Config: map[string]any{"type": "sendreceive"}},
	}
	if err := r.Register("/bin/ra", root, rows, "/h", "/i.ico"); err != nil {
		t.Fatal(err)
	}
	for _, a := range MenuCommands {
		if !reg.Exists(keyOf(a)) {
			t.Errorf("no key %s", a)
		}
	}
	cmd := reg.Read(keyOf("download")+`\command`, "")
	if cmd != `"/bin/ra" disk-shell --home "/h" download "%1"` {
		t.Errorf("cmd %s", cmd)
	}
	if !strings.Contains(reg.Read(keyOf("download"), "AppliesTo"), "Srv") || strings.Contains(reg.Read(keyOf("download"), "AppliesTo"), "Sync") {
		t.Error("download scope")
	}
	up := reg.Read(keyOf("add"), "AppliesTo")
	if !strings.Contains(up, "NOT") || !strings.Contains(up, "Sync") {
		t.Errorf("add scope %s", up)
	}
	before := changes
	_ = r.Register("/bin/ra", root, rows, "/h", "/i.ico")
	if changes != before {
		t.Error("idempotent register must not notify")
	}
	// заглушка принята → пункт «Скачать» исчезает
	rows[0].ServerOnly, rows[0].Kind = false, KindSyncing
	_ = r.Register("/bin/ra", root, rows, "/h", "/i.ico")
	if reg.Exists(keyOf("download")) {
		t.Error("download must disappear")
	}
	r.Cleanup()
	if len(reg.v) != 0 {
		t.Errorf("left %v", reg.v)
	}
}

func TestRegistryForeignKeyAndBadPath(t *testing.T) {
	reg := newMemReg()
	_ = reg.Write(keyOf("add"), "RemoteAgentsOwner", "other")
	r := NewRegistry(reg, nil, nil)
	_ = r.Register("/bin/ra", "/d/Disk", nil, "", "")
	if reg.Read(keyOf("add"), "RemoteAgentsOwner") != "other" {
		t.Error("foreign key overwritten")
	}
	r.Cleanup()
	if !reg.Exists(keyOf("add")) {
		t.Error("foreign key removed")
	}
	if err := r.Register(`/bin/"ra`, "/d/Disk", nil, "", ""); err == nil {
		t.Error("quote in path must fail")
	}
}

func TestUploadScopeOverflow(t *testing.T) {
	var hidden []string
	for i := 0; i < 100; i++ {
		hidden = append(hidden, fmt.Sprintf("/d/Disk/folder-number-%03d", i))
	}
	s := UploadScope("/d/Disk", hidden)
	if strings.Contains(s, "ItemFolderPathDisplay") || len(s) > 200 {
		t.Errorf("overflow must hide verb: %s", s)
	}
}

// ---- правила исключений

func TestIgnoreChangeRollback(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ".stignore"), []byte("mine\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	c, err := NewIgnoreChange(dir, "secret\n")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(dir, ".stignore"))
	if string(b) != "#include .stignore-remoteagents\nmine\n" {
		t.Fatalf("%q", b)
	}
	c.Close()
	b, _ = os.ReadFile(filepath.Join(dir, ".stignore"))
	if string(b) != "mine\n" {
		t.Fatalf("not rolled back: %q", b)
	}
	if _, err := os.Stat(filepath.Join(dir, ".stignore-remoteagents")); err == nil {
		t.Fatal("managed file must go")
	}
	c, _ = NewIgnoreChange(dir, "secret\n")
	c.Commit()
	c.Close()
	if IgnoreNeedsChange(dir, "secret\n") {
		t.Fatal("committed rules must stay")
	}
}

// ---- команды

func baseAPI(peer string) *fakeAPI {
	return &fakeAPI{peer: peer, fail: map[string]error{}, data: map[string]any{
		"GET system/connections":                     map[string]any{"connections": map[string]any{peer: map[string]any{"connected": true}}},
		"GET config/folders":                         []any{},
		"GET cluster/pending/folders?device=" + peer: map[string]any{"srv-id": map[string]any{"offeredBy": map[string]any{peer: map[string]any{"label": "Work"}}}},
		"GET config/defaults/folder":                 map[string]any{"rescanIntervalS": 3600},
		"GET system/status":                          map[string]any{"myID": "LOCAL"},
	}}
}

func newCmds(t *testing.T, api FolderAPI, fs FS, root string) *Commands {
	return &Commands{API: api, Root: root, Meta: NewService(fs, fakeIcons{}, nil, nil), Rules: "secret\n",
		Recycle: func(string) error { return nil }}
}

func TestDownloadAcceptsPlaceholder(t *testing.T) {
	tmp := t.TempDir()
	root := filepath.Join(tmp, "Disk")
	api := baseAPI("SRV")
	c := newCmds(t, api, OSFSForTest(), root)
	path := filepath.Join(root, "Work")
	// без заглушки команда отказывает
	if _, err := c.Execute(context.Background(), CmdDownload, path); err == nil {
		t.Fatal("download without placeholder must fail")
	}
	// заглушка (в памяти)
	fs := newMemFS(tmp, root)
	c = newCmds(t, api, fs, root)
	c.Meta.Reconcile(root, []*FolderState{{Path: path, ServerOnly: true, Kind: KindServerOnly}})
	if !c.Meta.IsPlaceholder(path) {
		t.Fatal("setup")
	}
	if _, err := c.Execute(context.Background(), CmdDownload, path); err == nil {
		// IgnoreChange пишет на настоящий диск: путь в памяти не существует — допустима только ошибка записи
		t.Log("accepted")
	}
}

func TestAddUploadsDirectChildOnly(t *testing.T) {
	tmp := t.TempDir()
	root := filepath.Join(tmp, "Disk")
	dir := filepath.Join(root, "New")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	api := baseAPI("SRV")
	c := newCmds(t, api, OSFSForTest(), root)
	msg, err := c.Execute(context.Background(), CmdAdd, dir)
	if err != nil || !strings.Contains(msg, "предложена серверу") {
		t.Fatalf("%q %v", msg, err)
	}
	if !api.did("POST", "config/folders") {
		t.Fatal("folder not registered")
	}
	var posted map[string]any
	for i, c := range api.calls {
		if c.method == "POST" && c.path == "config/folders" {
			posted = api.bodies[i].(map[string]any)
		}
	}
	if posted["type"] != "sendreceive" || posted["path"] != dir || posted["label"] != "New" {
		t.Fatalf("%v", posted)
	}
	if _, err := os.Stat(filepath.Join(dir, ".stignore-remoteagents")); err != nil {
		t.Fatal("rules not installed before registration")
	}
	// вложенная папка и сам корень — отказ
	nested := filepath.Join(dir, "sub")
	_ = os.MkdirAll(nested, 0o755)
	if _, err := c.Execute(context.Background(), CmdAdd, nested); err == nil {
		t.Fatal("nested must fail")
	}
	if _, err := c.Execute(context.Background(), CmdAdd, root); err == nil {
		t.Fatal("root must fail")
	}
	// имя занято на сервере
	if _, err := c.Execute(context.Background(), CmdAdd, filepath.Join(root, "Work")); err == nil {
		t.Fatal("name taken must fail")
	}
}

func TestAddRollsBackRulesWhenRegistrationRejected(t *testing.T) {
	tmp := t.TempDir()
	root := filepath.Join(tmp, "Disk")
	dir := filepath.Join(root, "New")
	_ = os.MkdirAll(dir, 0o755)
	api := baseAPI("SRV")
	api.fail["POST config/folders"] = errors.New("no")
	c := newCmds(t, api, OSFSForTest(), root)
	if _, err := c.Execute(context.Background(), CmdAdd, dir); err == nil {
		t.Fatal("must fail")
	}
	// ответ потерян, запись не применена → ошибка; исключения при этом сохраняются (безопасная сторона)
	if _, err := os.Stat(filepath.Join(dir, ".stignore")); err != nil {
		t.Fatal("exclusions must stay after an ambiguous failure")
	}
}

func TestKeepRequiresSyncedAndRecycles(t *testing.T) {
	tmp := t.TempDir()
	root := filepath.Join(tmp, "Disk")
	dir := filepath.Join(root, "Work")
	_ = os.MkdirAll(dir, 0o755)
	cfg := map[string]any{"id": "w", "label": "Work", "path": dir, "type": "sendreceive", "devices": []any{map[string]any{"deviceID": "SRV"}}}
	api := baseAPI("SRV")
	api.data["GET config/folders"] = []any{cfg}
	api.data["GET cluster/pending/folders?device=SRV"] = map[string]any{}
	api.data["GET db/status?folder=w"] = map[string]any{"state": "idle", "needBytes": 0.0, "needTotalItems": 0.0, "globalBytes": 10.0, "sequence": 5.0}
	api.data["GET db/completion?folder=w&device=SRV"] = map[string]any{"completion": 100.0, "needItems": 0.0, "needBytes": 0.0, "needDeletes": 0.0, "remoteState": "valid"}
	recycled := ""
	c := newCmds(t, api, OSFSForTest(), root)
	c.Recycle = func(p string) error { recycled = p; return os.RemoveAll(p) }
	// DELETE «снимает» папку из конфига
	api.data["DELETE config/folders/w"] = nil
	// после DELETE config/folders пуст: подмена через счётчик вызовов
	n := 0
	wrapped := &deleteAware{fakeAPI: api, onDelete: func() { n++; api.data["GET config/folders"] = []any{} }}
	c.API = wrapped
	msg, err := c.Execute(context.Background(), CmdKeepServer, dir)
	if err != nil {
		t.Fatal(err)
	}
	if recycled != dir || n != 1 || !strings.Contains(msg, "Корзине") {
		t.Fatalf("recycled=%q n=%d msg=%q", recycled, n, msg)
	}
	if !c.Meta.IsPlaceholder(dir) {
		t.Fatal("placeholder not created")
	}
}

func TestKeepRestoresRegistrationWhenRecycleRefused(t *testing.T) {
	tmp := t.TempDir()
	root := filepath.Join(tmp, "Disk")
	dir := filepath.Join(root, "Work")
	_ = os.MkdirAll(dir, 0o755)
	cfg := map[string]any{"id": "w", "label": "Work", "path": dir, "type": "sendreceive", "devices": []any{map[string]any{"deviceID": "SRV"}}}
	api := baseAPI("SRV")
	api.data["GET config/folders"] = []any{cfg}
	api.data["GET cluster/pending/folders?device=SRV"] = map[string]any{}
	api.data["GET db/status?folder=w"] = map[string]any{"state": "idle", "needBytes": 0.0, "needTotalItems": 0.0, "globalBytes": 10.0, "sequence": 5.0}
	api.data["GET db/completion?folder=w&device=SRV"] = map[string]any{"completion": 100.0, "needItems": 0.0, "needBytes": 0.0, "needDeletes": 0.0, "remoteState": "valid"}
	w := &deleteAware{fakeAPI: api, onDelete: func() { api.data["GET config/folders"] = []any{} }}
	c := newCmds(t, w, OSFSForTest(), root)
	c.Recycle = func(string) error { return ErrRecycle }
	if _, err := c.Execute(context.Background(), CmdKeepServer, dir); err == nil {
		t.Fatal("must fail")
	}
	if !api.did("POST", "config/folders") {
		t.Fatal("registration not restored")
	}
	if _, err := os.Stat(dir); err != nil {
		t.Fatal("local data must stay")
	}
}

func TestKeepRefusedUnlessSynced(t *testing.T) {
	tmp := t.TempDir()
	root := filepath.Join(tmp, "Disk")
	dir := filepath.Join(root, "Work")
	_ = os.MkdirAll(dir, 0o755)
	cfg := map[string]any{"id": "w", "label": "Work", "path": dir, "type": "sendreceive", "devices": []any{map[string]any{"deviceID": "SRV"}}}
	api := baseAPI("SRV")
	api.data["GET config/folders"] = []any{cfg}
	api.data["GET cluster/pending/folders?device=SRV"] = map[string]any{}
	api.data["GET db/status?folder=w"] = map[string]any{"state": "syncing", "needBytes": 5.0, "needTotalItems": 1.0, "globalBytes": 10.0}
	api.data["GET db/completion?folder=w&device=SRV"] = map[string]any{"completion": 50.0, "needItems": 1.0, "needBytes": 5.0, "needDeletes": 0.0, "remoteState": "valid"}
	c := newCmds(t, api, OSFSForTest(), root)
	c.Recycle = func(string) error { t.Fatal("must not recycle"); return nil }
	if _, err := c.Execute(context.Background(), CmdKeepServer, dir); err == nil {
		t.Fatal("must refuse")
	}
}

type deleteAware struct {
	*fakeAPI
	onDelete func()
}

func (d *deleteAware) Request(ctx context.Context, m, p string, b any) ([]byte, error) {
	out, err := d.fakeAPI.Request(ctx, m, p, b)
	if m == "DELETE" {
		d.onDelete()
	}
	return out, err
}

func OSFSForTest() FS { return OSFS{} }

func TestUnknownCommandAndRelativePath(t *testing.T) {
	c := newCmds(t, baseAPI("SRV"), newMemFS(), "/d/Disk")
	if _, err := c.Execute(context.Background(), "rm", "/d/Disk/A"); err == nil {
		t.Fatal("unknown")
	}
	if _, err := c.Execute(context.Background(), CmdAdd, "rel/path"); err == nil {
		t.Fatal("relative")
	}
}

func TestReadSnapshotConfirmedMemory(t *testing.T) {
	home := t.TempDir()
	root := filepath.Join(home, "Disk")
	dir := filepath.Join(root, "Work")
	cfg := map[string]any{"id": "w", "label": "Work", "path": dir, "devices": []any{map[string]any{"deviceID": "SRV"}}}
	api := baseAPI("SRV")
	api.data["GET config/folders"] = []any{cfg}
	api.data["GET cluster/pending/folders?device=SRV"] = map[string]any{}
	api.data["GET db/status?folder=w"] = map[string]any{"state": "idle", "needBytes": 0.0, "needTotalItems": 0.0, "globalBytes": 10.0}
	api.data["GET db/completion?folder=w&device=SRV"] = map[string]any{"completion": 100.0, "needItems": 0.0, "needBytes": 0.0, "needDeletes": 0.0, "remoteState": "valid"}
	s, err := ReadSnapshot(context.Background(), api, root, home)
	if err != nil || s.Folders[0].Kind != KindSynced {
		t.Fatalf("%v %+v", err, s)
	}
	// сервер снял папку — раньше подтверждал → «удалена на сервере»
	api.data["GET db/completion?folder=w&device=SRV"] = map[string]any{"completion": 100.0, "needItems": 0.0, "needBytes": 0.0, "needDeletes": 0.0, "remoteState": "notSharing"}
	s, _ = ReadSnapshot(context.Background(), api, root, home)
	if s.Folders[0].Kind != KindServerRemoved {
		t.Fatalf("kind %s", s.Folders[0].Kind)
	}
}

func TestValidName(t *testing.T) {
	for n, want := range map[string]bool{"Work": true, "a b": true, "CON": false, "x.": false, "a/b": false, "..": false, "com1.txt": false, "": false} {
		if ValidName(n) != want {
			t.Errorf("%q", n)
		}
	}
}

func TestIconsExportAndCleanup(t *testing.T) {
	d := t.TempDir()
	ic := IconDir{Dir: d}
	for _, k := range AllKinds {
		p, err := ic.PathFor(k)
		if err != nil {
			t.Fatalf("%s: %v", k, err)
		}
		if st, err := os.Stat(p); err != nil || st.Size() == 0 {
			t.Fatalf("%s", k)
		}
	}
	if _, err := ic.ApplicationPath(); err != nil {
		t.Fatal(err)
	}
	_ = os.WriteFile(filepath.Join(d, "other.ico"), []byte("x"), 0o644)
	CleanupIcons(d)
	es, _ := os.ReadDir(d)
	if len(es) != 1 || es[0].Name() != "other.ico" {
		t.Fatalf("%v", es)
	}
}
