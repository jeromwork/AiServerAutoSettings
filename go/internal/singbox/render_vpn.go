package singbox

import "remoteagents/internal/api"

// renderVPN — заглушка до N1a. Возвращает пустую Part.
func renderVPN(rc api.RenderContext) (api.Part, error) { return api.Part{}, nil }

// Keep the render scaffold until N1a wires it into Render.
var _ = renderVPN
