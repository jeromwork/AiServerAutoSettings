package main

import (
	"context"
	"os"
)

var version = "dev"
var build = "0"

// pubKeys and releaseRepo are set via -ldflags.
var pubKeys = ""
var releaseRepo = ""

func main() {
	os.Exit(dispatch(context.Background(), os.Args[1:]))
}
