package view

import (
	"fmt"

	"github.com/charmbracelet/lipgloss"
)

var (
	titleStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("212")).
			MarginBottom(1)

	statusOKStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("42"))

	statusErrStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("196"))

	helpStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("241")).
			MarginTop(1)
)

// Render returns the full TUI view string.
func Render(baseURL string, loading bool, healthStatus string, healthErr error, spinnerView string) string {
	title := titleStyle.Render("Symphony TUI")

	var status string
	switch {
	case loading:
		status = fmt.Sprintf("%s Connecting to %s ...", spinnerView, baseURL)
	case healthErr != nil:
		status = statusErrStyle.Render(fmt.Sprintf("✗ %s — %s", baseURL, healthErr))
	default:
		status = statusOKStyle.Render(fmt.Sprintf("✓ Connected to %s — status: %s", baseURL, healthStatus))
	}

	help := helpStyle.Render("Press q or ctrl+c to quit")

	return fmt.Sprintf("%s\n%s\n%s\n", title, status, help)
}
