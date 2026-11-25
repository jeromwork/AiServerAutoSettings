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

	"golang.org/x/crypto/pbkdf2"
)

var errSecret = errors.New("secret: invalid-secret: invalid password or damaged secret")
var errKey = errors.New("secret: key-length: key must contain 64 bytes")

// Derive follows v2 secretbox.derive; v2config bounds the iteration count.
func Derive(password string, salt []byte, iter int) ([]byte, error) {
	if iter < 1 || iter > 5_000_000 {
		return nil, errors.New("secret: iterations: must be between 1 and 5000000")
	}
	return pbkdf2.Key([]byte(password), salt, iter, 64, sha256.New), nil
}

// Open authenticates before decrypting, as in lab/ralab/secretbox.py.
// Callers register returned secrets with their logger before using them.
func Open(key []byte, s string) ([]byte, error) {
	if len(key) != 64 {
		return nil, errKey
	}
	if !strings.HasPrefix(s, "enc1:") {
		return nil, errSecret
	}
	raw, err := base64.StdEncoding.DecodeString(s[5:])
	if err != nil || len(raw) < aes.BlockSize*2+sha256.Size {
		return nil, errSecret
	}
	payload, tag := raw[:len(raw)-sha256.Size], raw[len(raw)-sha256.Size:]
	mac := hmac.New(sha256.New, key[32:])
	_, _ = mac.Write(payload) // hash.Hash.Write always succeeds.
	if !hmac.Equal(mac.Sum(nil), tag) {
		return nil, errSecret
	}
	iv, ct := payload[:aes.BlockSize], payload[aes.BlockSize:]
	if len(ct)%aes.BlockSize != 0 {
		return nil, errSecret
	}
	block, err := aes.NewCipher(key[:32])
	if err != nil {
		return nil, errKey
	}
	plain := make([]byte, len(ct))
	cipher.NewCBCDecrypter(block, iv).CryptBlocks(plain, ct)
	pad := int(plain[len(plain)-1])
	if pad < 1 || pad > aes.BlockSize || !bytes.Equal(plain[len(plain)-pad:], bytes.Repeat([]byte{byte(pad)}, pad)) {
		clear(plain)
		return nil, errSecret
	}
	return plain[:len(plain)-pad], nil
}

func Seal(key, plain []byte) (string, error) {
	if len(key) != 64 {
		return "", errKey
	}
	block, err := aes.NewCipher(key[:32])
	if err != nil {
		return "", errKey
	}
	pad := aes.BlockSize - len(plain)%aes.BlockSize
	raw := make([]byte, aes.BlockSize+len(plain)+pad+sha256.Size)
	iv, ct := raw[:aes.BlockSize], raw[aes.BlockSize:len(raw)-sha256.Size]
	if _, err := rand.Read(iv); err != nil {
		return "", errors.New("secret: random: cannot generate IV")
	}
	copy(ct, plain)
	copy(ct[len(plain):], bytes.Repeat([]byte{byte(pad)}, pad))
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(ct, ct)
	mac := hmac.New(sha256.New, key[32:])
	_, _ = mac.Write(raw[:len(raw)-sha256.Size]) // hash.Hash.Write always succeeds.
	copy(raw[len(raw)-sha256.Size:], mac.Sum(nil))
	return "enc1:" + base64.StdEncoding.EncodeToString(raw), nil
}

func CheckPassword(key []byte, check string) bool {
	plain, err := Open(key, check)
	defer clear(plain)
	return err == nil && bytes.Equal(plain, []byte("remoteagents"))
}
