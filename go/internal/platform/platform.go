package platform

import "remoteagents/internal/api"

func Current() api.Platform                                            { panic("not implemented") }
func NewLANOps(log api.Logger, tr api.Traces, inst8 string) api.LANOps { panic("not implemented") }
