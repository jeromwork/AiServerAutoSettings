package explorer

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// FolderAPI — то, что Проводнику нужно от локального Syncthing. Реализует клиент REST (этап D);
// здесь только интерфейс. Request выполняет запрос к /rest/<path> и возвращает тело ответа
// (пустое для 204). Ошибка — любой отказ или таймаут. Peer — ID устройства сервера.
type FolderAPI interface {
	Peer() string
	Request(ctx context.Context, method, path string, body any) ([]byte, error)
}

// call — запрос с разбором ответа в any.
func call(ctx context.Context, api FolderAPI, method, path string, body any) (any, error) {
	b, err := api.Request(ctx, method, path, body)
	if err != nil {
		return nil, err
	}
	if len(b) == 0 {
		return nil, nil
	}
	var v any
	if err := json.Unmarshal(b, &v); err != nil {
		return nil, fmt.Errorf("Syncthing вернул неожиданный ответ")
	}
	return v, nil
}

func esc(s string) string { return url.QueryEscape(s) }

// ReadSnapshot читает папки Syncthing и предложенные сервером; root — база Диска (туда встают заглушки).
// diskHome — где хранится память «сервер эту папку уже подтверждал» (пусто — без памяти).
func ReadSnapshot(ctx context.Context, api FolderAPI, root, diskHome string) (*Snapshot, error) {
	snap := &Snapshot{}
	peer := api.Peer()
	v, err := call(ctx, api, "GET", "system/connections", nil)
	if err != nil {
		return nil, err
	}
	snap.Connected = boolv(mp(mp(mp(v)["connections"])[peer]), "connected")
	confirmedBefore := loadConfirmed(diskHome, peer)
	v, err = call(ctx, api, "GET", "config/folders", nil)
	if err != nil {
		return nil, err
	}
	var shared, confirmedNow []string
	for _, it := range arr(v) {
		cfg := mp(it)
		id, path := str(cfg, "id"), str(cfg, "path")
		if id == "" || path == "" {
			continue
		}
		// Чужая регистрация может быть с ~/ или неверным путём: такие пропускаем, остальные нужны для проверки пересечений.
		cp, err := cleanPath(path)
		if err != nil {
			continue
		}
		label := str(cfg, "label")
		if label == "" {
			label = id
		}
		row := &FolderState{ID: id, Name: label, Path: cp, Config: cfg, Paused: boolv(cfg, "paused")}
		isShared := false
		for _, d := range arr(cfg["devices"]) {
			if str(mp(d), "deviceID") == peer {
				isShared = true
			}
		}
		if isShared {
			shared = append(shared, id)
			local, e1 := call(ctx, api, "GET", "db/status?folder="+esc(id), nil)
			remote, e2 := call(ctx, api, "GET", "db/completion?folder="+esc(id)+"&device="+esc(peer), nil)
			if e1 != nil || e2 != nil {
				row.Kind = KindUnavailable
			} else {
				status(row, mp(local), mp(remote), snap.Connected, confirmedBefore[id])
				if snap.Connected && confirmedByServer(mp(remote)) {
					confirmedNow = append(confirmedNow, id)
				}
			}
		} else {
			row.Kind = KindLocal
		}
		snap.Folders = append(snap.Folders, row)
	}
	updateConfirmed(diskHome, peer, shared, confirmedNow)
	v, err = call(ctx, api, "GET", "cluster/pending/folders?device="+esc(peer), nil)
	if err != nil {
		return nil, err
	}
	ids := make([]string, 0)
	for id := range mp(v) {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		offer := mp(mp(mp(mp(v)[id])["offeredBy"])[peer])
		name := str(offer, "label")
		if name == "" {
			name = id
		}
		if len(offer) == 0 || !ValidName(name) || boolv(offer, "receiveEncrypted") || boolv(offer, "remoteEncrypted") || hasID(snap.Folders, id) {
			continue
		}
		snap.Folders = append(snap.Folders, &FolderState{ID: id, Name: name, Path: filepath.Join(root, name), ServerOnly: true, Kind: KindServerOnly})
	}
	// Одинаковые пути на Windows: ни одну не выбираем наугад.
	count := map[string]int{}
	for _, f := range snap.Folders {
		count[strings.ToLower(f.Path)]++
	}
	for _, f := range snap.Folders {
		if count[strings.ToLower(f.Path)] > 1 {
			f.Kind, f.Detail = KindError, "Несколько папок с одинаковым именем"
		}
	}
	return snap, nil
}

func hasID(rows []*FolderState, id string) bool {
	for _, r := range rows {
		if r.ID == id {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------- память «сервер эту папку подтверждал»

type confirmedFile struct {
	Peer    string   `json:"peer"`
	Folders []string `json:"folders"`
}

func confirmedPath(diskHome string) string { return filepath.Join(diskHome, "explorer-confirmed.json") }

func loadConfirmed(diskHome, peer string) map[string]bool {
	known := map[string]bool{}
	if diskHome == "" {
		return known
	}
	b, err := os.ReadFile(confirmedPath(diskHome))
	if err != nil {
		return known
	}
	var f confirmedFile
	if json.Unmarshal(b, &f) != nil || f.Peer != peer {
		return known
	}
	for _, id := range f.Folders {
		known[id] = true
	}
	return known
}

func updateConfirmed(diskHome, peer string, configured, now []string) {
	if diskHome == "" {
		return
	}
	before := loadConfirmed(diskHome, peer)
	wanted := map[string]bool{}
	for _, id := range configured {
		wanted[id] = true
	}
	known := map[string]bool{}
	for id := range before {
		if wanted[id] {
			known[id] = true
		}
	}
	for _, id := range now {
		if wanted[id] {
			known[id] = true
		}
	}
	same := len(known) == len(before)
	for id := range known {
		if !before[id] {
			same = false
		}
	}
	if same {
		return
	}
	ids := make([]string, 0, len(known))
	for id := range known {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	b, _ := json.Marshal(confirmedFile{Peer: peer, Folders: ids})
	_ = writeFileAtomic(confirmedPath(diskHome), b)
}

func writeFileAtomic(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".*.tmp")
	if err != nil {
		return err
	}
	tmp := f.Name()
	_, werr := f.Write(data)
	cerr := f.Close()
	if werr != nil || cerr != nil {
		_ = os.Remove(tmp)
		if werr != nil {
			return werr
		}
		return cerr
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

// tailEvent — id последнего события Syncthing (0, если событий нет или чтение не удалось).
func tailEvent(ctx context.Context, api FolderAPI) int64 {
	v, err := call(ctx, api, "GET", "events?since=0&limit=1&timeout=0", nil)
	if err != nil {
		return 0
	}
	var last int64
	for _, e := range arr(v) {
		if id := int64(num(mp(e), "id")); id > last {
			last = id
		}
	}
	return last
}

// folderEvents — события, после которых состояние папок могло измениться.
const folderEvents = "ConfigSaved,PendingFoldersChanged,DeviceConnected,DeviceDisconnected,StateChanged,FolderSummary,FolderCompletion,FolderErrors,ClusterConfigReceived,LocalIndexUpdated,RemoteIndexUpdated,FolderPaused,FolderResumed"

// events ждёт события (long-poll) до timeout секунд и возвращает их и новый since.
func events(ctx context.Context, api FolderAPI, since int64, timeout int) ([]any, int64, error) {
	v, err := call(ctx, api, "GET", fmt.Sprintf("events?since=%d&timeout=%d&events=%s", since, timeout, folderEvents), nil)
	if err != nil {
		return nil, since, err
	}
	evs := arr(v)
	for _, e := range evs {
		if id := int64(num(mp(e), "id")); id > since {
			since = id
		}
	}
	return evs, since, nil
}

// waitEvent блокируется до события Syncthing (не дольше 5 с — страховка на случай потерянных событий).
func waitEvent(ctx context.Context, api FolderAPI, since int64) int64 {
	_, n, _ := events(ctx, api, since, 5)
	return n
}
