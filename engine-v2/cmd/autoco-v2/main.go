package main

import (
	"fmt"
	"os"

	"github.com/aleka7sk/auto-company-safe/engine-v2/internal/cli"
)

func main() {
	runner := cli.New()
	if err := runner.Run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "autoco-v2:", err)
		os.Exit(1)
	}
}
