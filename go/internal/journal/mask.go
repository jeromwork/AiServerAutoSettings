package journal

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"sync"
	"unicode"
	"unicode/utf8"
)

const (
	fieldMax   = 2000
	recMax     = 16000
	ringMax    = 2000
	secretsMax = 2000
)

var (
	secretKeys = map[string]struct{}{
		"uuid":                   {},
		"password":               {},
		"private_key":            {},
		"short_id":               {},
		"public_key":             {},
		"private_key_passphrase": {},
		"path":                   {},
	}

	secretsMu sync.RWMutex
	secretSet = make(map[string]struct{})
	sortedSec []string
)

// RegisterSecret adds secret values to the process-wide registry.
func RegisterSecret(val string) {
	if val == "" {
		return
	}
	secretsMu.Lock()
	defer secretsMu.Unlock()

	addSecretLocked := func(s string) {
		s = strings.TrimSpace(s)
		if utf8.RuneCountInString(s) >= 2 && len(secretSet) < secretsMax {
			secretSet[s] = struct{}{}
		}
	}

	addSecretLocked(val)
	lines := strings.FieldsFunc(val, func(r rune) bool {
		return r == '\n' || r == '\r'
	})
	for _, l := range lines {
		addSecretLocked(l)
	}

	rebuildSortedLocked()
}

func rebuildSortedLocked() {
	sortedSec = make([]string, 0, len(secretSet))
	for s := range secretSet {
		sortedSec = append(sortedSec, s)
	}
	sort.Slice(sortedSec, func(i, j int) bool {
		li := utf8.RuneCountInString(sortedSec[i])
		lj := utf8.RuneCountInString(sortedSec[j])
		if li != lj {
			return li > lj
		}
		return sortedSec[i] < sortedSec[j]
	})
}

// MaskString masks registered secrets in a string.
func MaskString(x string) string {
	secretsMu.RLock()
	secs := sortedSec
	secretsMu.RUnlock()

	if len(secs) == 0 || x == "" {
		return x
	}

	for _, s := range secs {
		if utf8.RuneCountInString(s) >= 4 {
			if strings.Contains(x, s) {
				x = strings.ReplaceAll(x, s, "***")
			}
		} else {
			x = maskToken(x, s)
		}
	}
	return x
}

func maskToken(x string, s string) string {
	if !strings.Contains(x, s) {
		return x
	}
	sLen := len(s)
	var b strings.Builder
	i := 0
	for i < len(x) {
		idx := strings.Index(x[i:], s)
		if idx == -1 {
			b.WriteString(x[i:])
			break
		}
		pos := i + idx

		prevOK := false
		if pos == 0 {
			prevOK = true
		} else {
			r, _ := utf8.DecodeLastRuneInString(x[:pos])
			if !isWordOrHyphenRune(r) {
				prevOK = true
			}
		}

		nextOK := false
		endPos := pos + sLen
		if endPos == len(x) {
			nextOK = true
		} else {
			r, _ := utf8.DecodeRuneInString(x[endPos:])
			if !isWordOrHyphenRune(r) {
				nextOK = true
			}
		}

		if prevOK && nextOK {
			b.WriteString(x[i:pos])
			b.WriteString("***")
			i = endPos
		} else {
			_, size := utf8.DecodeRuneInString(x[pos:])
			b.WriteString(x[i : pos+size])
			i = pos + size
		}
	}
	return b.String()
}

func isWordOrHyphenRune(r rune) bool {
	return unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_' || r == '-'
}

// MaskValue recursively masks strings within data structures.
func MaskValue(v any) any {
	collectSecrets(v)
	return maskValue(v)
}
func collectSecrets(v any) {
	switch x := v.(type) {
	case map[string]any:
		for k, e := range x {
			if _, ok := secretKeys[k]; ok {
				registerSecretsFrom(e)
			} else {
				collectSecrets(e)
			}
		}
	case []any:
		for _, e := range x {
			collectSecrets(e)
		}
	}
}
func maskValue(v any) any {
	if v == nil {
		return nil
	}
	switch val := v.(type) {
	case string:
		return MaskString(val)
	case error:
		return MaskString(val.Error())
	case fmt.Stringer:
		return MaskString(val.String())
	case map[string]any:
		res := make(map[string]any, len(val))
		for k, elem := range val {
			if _, ok := secretKeys[k]; ok {
				registerSecretsFrom(elem)
			}
		}
		for k, elem := range val {
			if _, isSecret := secretKeys[k]; isSecret {
				registerSecretsFrom(elem)
			}
			res[MaskString(k)] = maskValue(elem)
		}
		return res
	case []any:
		res := make([]any, len(val))
		for i, elem := range val {
			res[i] = maskValue(elem)
		}
		return res
	case []string:
		res := make([]any, len(val))
		for i, elem := range val {
			res[i] = MaskString(elem)
		}
		return res
	case int, int8, int16, int32, int64, uint, uint8, uint16, uint32, uint64, float32, float64, bool:
		return val
	default:
		b, err := json.Marshal(val)
		if err == nil {
			var generic any
			if json.Unmarshal(b, &generic) == nil {
				return MaskValue(generic)
			}
		}
		return MaskString(fmt.Sprint(val))
	}
}

func registerSecretsFrom(v any) {
	switch val := v.(type) {
	case string:
		RegisterSecret(val)
	case []string:
		for _, s := range val {
			RegisterSecret(s)
		}
	case []any:
		for _, item := range val {
			registerSecretsFrom(item)
		}
	case map[string]any:
		for _, item := range val {
			registerSecretsFrom(item)
		}
	}
}

func clipValue(v any) any {
	if v == nil {
		return nil
	}
	switch val := v.(type) {
	case string:
		return clipString(val)
	case map[string]any:
		res := make(map[string]any, len(val))
		for k, elem := range val {
			res[k] = clipValue(elem)
		}
		return res
	case []any:
		limit := len(val)
		if limit > 200 {
			limit = 200
		}
		res := make([]any, limit)
		for i := 0; i < limit; i++ {
			res[i] = clipValue(val[i])
		}
		return res
	default:
		return val
	}
}

func clipString(s string) string {
	r := []rune(s)
	if len(r) <= fieldMax {
		return s
	}
	return string(r[:fieldMax]) + fmt.Sprintf("...(+%d)", len(r)-fieldMax)
}
