package secret

import "errors"

func Derive(password string, salt []byte, iter int) ([]byte, error) {
	return nil, errors.New("secret: not-implemented")
}
func Open(key []byte, s string) ([]byte, error) {
	return nil, errors.New("secret: not-implemented")
}
func Seal(key, plain []byte) (string, error) {
	return "", errors.New("secret: not-implemented")
}
func CheckPassword(key []byte, check string) bool { return false }
