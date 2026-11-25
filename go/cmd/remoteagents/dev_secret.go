package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"

	"remoteagents/internal/api"
	"remoteagents/internal/secret"
)

func init() {
	for _, name := range []string{"secret", "p1"} {
		api.RegisterDev(api.DevCmd{Name: name, Help: "vector | open <config.json> <password>", Run: devSecret})
	}
}

func devSecret(ctx context.Context, args []string) int {
	var plain []byte
	var err error
	switch {
	case ctx.Err() != nil:
		err = errors.New("secret: canceled: driver canceled")
	case len(args) == 1 && args[0] == "vector":
		plain, err = secretVector()
	case len(args) == 3 && args[0] == "open":
		plain, err = secretFile(args[1], args[2])
	default:
		err = errors.New("secret: usage: vector | open <config.json> <password>")
	}
	defer clear(plain)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	fmt.Printf("ok len=%d\n", len(plain))
	return 0
}

func secretVector() ([]byte, error) {
	// Public compatibility vector: docs/CONFIG-SERVER.md, "Тестовый вектор enc1".
	salt, _ := base64.StdEncoding.DecodeString("AAECAwQFBgcICQoLDA0ODw==")
	key, err := secret.Derive("Мастер-пароль 1", salt, 200000)
	if err != nil {
		return nil, err
	}
	defer clear(key)
	const check = "enc1:EBESExQVFhcYGRobHB0eH5S/AYvjmvqbyp4eatsIP0ESDucdw0ufuFBNWskJNZdj/a/PyROkWqohaJO+d8dnCA=="
	const value = "enc1:EBESExQVFhcYGRobHB0eH9EATN4mI2yZF1iffFippgsKu5D1MyvAG2NfKVaGcnHzvCO5vWsIX2yfsu90ejzi8negWZF8qpwxkbFOMwPwBMnei8w8zX8GwmtQ4CNs3ZfL"
	if hex.EncodeToString(key) != "4a705d00d0b0eb61e464aac6aa0712bcb93c88417d7db998d56d72cfbb87cb6e23756d57411519ab4fd2f3cb1f4ce7d7594d96e01dbc6bafa100fc102eaf6b1b" || !secret.CheckPassword(key, check) {
		return nil, errors.New("secret: vector: derived key or check mismatch")
	}
	plain, err := secret.Open(key, value)
	defer clear(plain)
	if err != nil || string(plain) != "секрет\nвторая строка" {
		return nil, errors.New("secret: vector: plaintext mismatch")
	}
	sealed, err := secret.Seal(key, plain)
	if err != nil {
		return nil, err
	}
	opened, err := secret.Open(key, sealed)
	if err != nil || !bytes.Equal(opened, plain) {
		clear(opened)
		return nil, errors.New("secret: vector: roundtrip mismatch")
	}
	return opened, nil
}

func secretFile(path, password string) ([]byte, error) {
	var cfg struct {
		KDF struct {
			Salt       string
			Iterations int
		}
		Check  string
		Server struct{ Key string }
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, errors.New("secret: read: cannot read config")
	}
	if json.Unmarshal(bytes.TrimPrefix(data, []byte{0xef, 0xbb, 0xbf}), &cfg) != nil {
		return nil, errors.New("secret: json: invalid config")
	}
	salt, err := base64.StdEncoding.DecodeString(cfg.KDF.Salt)
	if err != nil {
		return nil, errors.New("secret: salt: invalid base64")
	}
	key, err := secret.Derive(password, salt, cfg.KDF.Iterations)
	defer clear(key)
	if err != nil {
		return nil, err
	}
	if !secret.CheckPassword(key, cfg.Check) {
		return nil, errors.New("secret: password: invalid password or check")
	}
	plain, err := secret.Open(key, cfg.Server.Key)
	if err != nil || !bytes.HasPrefix(plain, []byte("-----BEGIN")) {
		clear(plain)
		return nil, errors.New("secret: server-key: invalid encrypted key")
	}
	return plain, nil
}
