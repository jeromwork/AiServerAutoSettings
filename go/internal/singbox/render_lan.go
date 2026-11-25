package singbox

import "remoteagents/internal/api"

// renderLAN — заглушка до N2. Возвращает пустую Part.
func renderLAN(rc api.RenderContext) (api.Part, error) { return api.Part{}, nil }
