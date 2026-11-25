package cleanup

import (
	"context"
	"fmt"
)

func (c *Cleaner) Run(ctx context.Context, reason string) []string {
	return append([]string{"cleanup: incomplete: platform removal not implemented"}, c.Check(ctx)...)
}
func (c *Cleaner) Check(ctx context.Context) []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return []string{fmt.Sprintf("cleanup: context: %v", err)}
	}
	traces, err := c.read()
	if err != nil {
		return []string{fmt.Sprintf("cleanup: read: %v", err)}
	}
	active := map[string]bool{}
	for _, t := range traces {
		active[t.Kind+"/"+t.ID] = t.Phase != "done"
	}
	var issues []string
	for key, pending := range active {
		if pending {
			issues = append(issues, "cleanup: pending: "+key)
		}
	}
	return issues
}
