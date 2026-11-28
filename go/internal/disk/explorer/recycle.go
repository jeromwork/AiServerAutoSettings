package explorer

import "errors"

// ErrRecycle — папку нельзя поместить в Корзину; удаление навсегда не делаем никогда.
var ErrRecycle = errors.New("Папка не помещается в Корзину — освободите место или удалите вручную")
