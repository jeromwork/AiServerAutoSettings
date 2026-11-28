package disk

import "testing"

func TestParseConfig(t *testing.T) {
	c, err := ParseConfig([]byte(`{"enabled":false,"home":"h","base":"b","folders":["A",{"id":"B","path":"p"},"A"]}`), 22001)
	if err != nil || c.On() || c.Home != "h" || c.Base != "b" || c.SyncPort != 22001 ||
		len(c.Folders) != 2 || c.Folders[1] != (Folder{"B", "p"}) {
		t.Fatalf("%+v %v", c, err)
	}
	if c, err = ParseConfig(nil, 0); err != nil || !c.On() || len(c.Folders) != 0 {
		t.Fatalf("%+v %v", c, err)
	}
	for _, bad := range []string{`[]`, `{"enabled":1}`, `{"folders":"x"}`, `{"folders":["../x"]}`, `{"folders":[{"id":"a","path":5}]}`, `{"home":3}`} {
		if _, err := ParseConfig([]byte(bad), 0); err == nil {
			t.Errorf("ожидалась ошибка: %s", bad)
		}
	}
	if _, err := ParseConfig(nil, 70000); err == nil {
		t.Error("порт")
	}
}
