package main

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"time"
)

func cmdRollback(ctx context.Context, stateDir, pc string) error {
	st, err := readState(stateDir, pc)
	if err != nil {
		return err
	}

	code, respData, err := callAgent(ctx, st, "POST", "/rollback", strings.NewReader("{}"), map[string]string{
		"Content-Type": "application/json",
	}, 15*time.Second)
	if err != nil {
		return err
	}

	if code != http.StatusOK {
		return fmt.Errorf("ra3: агент ответил %d: %s", code, strings.TrimSpace(string(respData)))
	}

	fmt.Println("откат запрошен")
	return nil
}
