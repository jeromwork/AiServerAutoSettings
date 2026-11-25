package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

func cmdStatus(ctx context.Context, stateDir, pc string) error {
	st, err := readState(stateDir, pc)
	if err != nil {
		return err
	}

	code, data, err := callAgent(ctx, st, "GET", "/status", nil, nil, 10*time.Second)
	if err != nil {
		return err
	}

	if code != 200 {
		return fmt.Errorf("ra3: агент ответил %d: %s", code, strings.TrimSpace(string(data)))
	}

	var buf bytes.Buffer
	if err := json.Indent(&buf, data, "", "  "); err != nil {
		fmt.Println(string(data))
	} else {
		fmt.Println(buf.String())
	}

	return nil
}
