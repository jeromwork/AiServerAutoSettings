// Package secret implements the v2 enc1 wire format (secretbox.py).
package secret

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"strings"
	"unicode/utf8"

	"golang.org/x/crypto/pbkdf2"
)

var ErrSecret = errors.New("Неверный пароль или повреждённый секрет")

func Derive(password string, salt []byte, iter int) ([]byte, error) {
	if iter < 1 || iter > 5000000 {
		return nil, ErrSecret
	}
	return pbkdf2.Key([]byte(password), salt, iter, 64, sha256.New), nil
}

func Open(key []byte, s string) ([]byte, error) {
	if len(key) != 64 || !strings.HasPrefix(s, "enc1:") {
		return nil, ErrSecret
	}
	raw, err := base64.StdEncoding.DecodeString(s[5:])
	if err != nil || len(raw) < 64 {
		return nil, ErrSecret
	}
	payload, tag := raw[:len(raw)-32], raw[len(raw)-32:]
	mac := hmac.New(sha256.New, key[32:])
	mac.Write(payload)
	if !hmac.Equal(tag, mac.Sum(nil)) || (len(payload)-16)%16 != 0 {
		return nil, ErrSecret
	}
	block, _ := aes.NewCipher(key[:32])
	plain := make([]byte, len(payload)-16)
	cipher.NewCBCDecrypter(block, payload[:16]).CryptBlocks(plain, payload[16:])
	n := int(plain[len(plain)-1])
	if n < 1 || n > 16 || !bytes.Equal(plain[len(plain)-n:], bytes.Repeat([]byte{byte(n)}, n)) {
		return nil, ErrSecret
	}
	plain = plain[:len(plain)-n]
	if !utf8.Valid(plain) {
		return nil, ErrSecret
	}
	return plain, nil
}

func Seal(key, plain []byte) (string, error) {
	if len(key) != 64 || !utf8.Valid(plain) {
		return "", ErrSecret
	}
	n := 16 - len(plain)%16
	padded := append(append([]byte(nil), plain...), bytes.Repeat([]byte{byte(n)}, n)...)
	payload := make([]byte, 16+len(padded))
	if _, err := rand.Read(payload[:16]); err != nil {
		return "", err
	}
	block, _ := aes.NewCipher(key[:32])
	cipher.NewCBCEncrypter(block, payload[:16]).CryptBlocks(payload[16:], padded)
	mac := hmac.New(sha256.New, key[32:])
	mac.Write(payload)
	return "enc1:" + base64.StdEncoding.EncodeToString(append(payload, mac.Sum(nil)...)), nil
}

func CheckPassword(key []byte, check string) bool {
	plain, err := Open(key, check)
	return err == nil && string(plain) == "remoteagents"
}
