package main

import (
	"flag"
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/humancorp/symphony/tui/client"
	"github.com/humancorp/symphony/tui/model"
)

func main() {
	url := flag.String("url", "http://localhost:4000", "Symphony API base URL")
	flag.Parse()

	c := client.New(*url)
	m := model.New(c)

	p := tea.NewProgram(m, tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}
