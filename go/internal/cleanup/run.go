package cleanup

import "context"

func (c *Cleaner) Run(ctx context.Context, reason string) []string { return nil }
func (c *Cleaner) Check(ctx context.Context) []string              { return nil }
