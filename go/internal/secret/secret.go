package secret

func Derive(password string, salt []byte, iter int) ([]byte, error) { panic("not implemented") }
func Open(key []byte, s string) ([]byte, error)                     { panic("not implemented") }
func Seal(key, plain []byte) (string, error)                        { panic("not implemented") }
func CheckPassword(key []byte, check string) bool                   { panic("not implemented") }
