//go:build !linux && !darwin && !windows

package cleanup

func scanPlatformProcesses(home, bin string) (Report, error) {
	return Report{
		Found:     []string{},
		Removed:   []string{},
		Unremoved: []string{},
	}, nil
}
