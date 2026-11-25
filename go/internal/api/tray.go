package api

import "context"

// Tray owns the notification-area UI for the supervisor's lifetime.
type Tray interface{ Run(context.Context) error }
