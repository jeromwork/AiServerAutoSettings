package api

import "context"

type Component interface {
	Name() string
	Start(ctx context.Context) error
	Stop(ctx context.Context) error
	Status() map[string]any
}
