package platform

import "remoteagents/internal/api"

// stubPlatform — каркас платформы до реализации P5b.
type stubPlatform struct{}

var _ api.Platform = (*stubPlatform)(nil)
