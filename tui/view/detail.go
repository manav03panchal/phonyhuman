package view

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"

	"github.com/humancorp/symphony/tui/types"
)

// RenderDetailView renders the k9s-style detail pane for a selected agent.
func RenderDetailView(a types.Agent, width, height int, statusText string) string {
	if width == 0 {
		return "Loading..."
	}

	w := width

	// ─── Line 1: breadcrumb ───
	logo := logoStyle.Render("🤪")
	sep := crumbSep.Render(" 〉")
	crumb := logo + sep + crumbStyle.Render("fleet") + sep + crumbStyle.Render("agents") + sep + crumbStyle.Render(a.ID)

	dot := lipgloss.NewStyle().Foreground(lipgloss.Color(a.Status.StatusColor())).Render("●")
	right := dot + " " + stateColor(a.Stage).Render(a.Stage)

	gap := w - lipgloss.Width(crumb) - lipgloss.Width(right)
	if gap < 1 {
		gap = 1
	}
	header := crumb + strings.Repeat(" ", gap) + right

	// ─── Line 2: title ───
	titleLine := ""
	if a.Title != "" {
		titleLine = lipgloss.NewStyle().Foreground(colorWhite).Bold(true).Render(a.Title)
	}

	// ─── Description ───
	var descLines []string
	if a.Description != "" {
		// Word-wrap description to content width
		maxW := w - 2
		if maxW < 20 {
			maxW = 20
		}
		descLines = wrapText(a.Description, maxW)
	}

	// ─── Labels + URL ───
	var metaLine string
	var metaParts []string
	if len(a.Labels) > 0 {
		var tags []string
		for _, l := range a.Labels {
			tags = append(tags, lipgloss.NewStyle().
				Foreground(lipgloss.Color("#000")).
				Background(colorCyan).
				Padding(0, 1).
				Render(l))
		}
		metaParts = append(metaParts, strings.Join(tags, " "))
	}
	if a.URL != "" {
		metaParts = append(metaParts, cellDim.Render(a.URL))
	}
	if len(metaParts) > 0 {
		metaLine = strings.Join(metaParts, "  ")
	}

	// ─── Divider ───
	divider := cellDim.Render(strings.Repeat("─", w))

	// ─── Metrics grid — compact two-column layout ───
	model := "—"
	if a.Model != "" {
		model = shortModel(a.Model)
	}
	sessionShort := a.SessionID
	if len(sessionShort) > 20 {
		sessionShort = sessionShort[:18] + "…"
	}

	grid := []string{
		kvRow(w,
			kv("Session", sessionShort),
			kv("Model", model),
			kv("Age", fmtAge(a.StartedAt)),
		),
		kvRow(w,
			kv("In", fmtCompactTokens(a.InputTokens)),
			kv("Out", fmtCompactTokens(a.OutputTokens)),
			kv("Cache", fmtCompactTokens(a.CacheReadTokens)),
			kv("Cost", fmtCost(a.CostUSD)),
		),
		kvRow(w,
			kv("Lines", fmt.Sprintf("+%d", a.LinesChanged)),
			kv("Tools", fmt.Sprintf("%d", a.ToolCalls)),
		),
	}

	// ─── Last event ───
	var eventLine string
	if a.LastEventStr != "" {
		eventLine = metricLabel.Render("Event: ") + metricVal.Render(a.LastEventStr)
	}

	// ─── Status message (tmux errors etc) ───
	var statusLine string
	if statusText != "" {
		statusLine = lipgloss.NewStyle().Foreground(colorRed).Render(statusText)
	}

	// ─── Footer ───
	keys := []struct{ key, desc string }{
		{"a", "Attach"},
		{"esc", "Back"},
	}
	var fparts []string
	for _, k := range keys {
		fparts = append(fparts, footerKey.Render("<"+k.key+">")+footerDesc.Render(" "+k.desc))
	}
	footer := lipgloss.NewStyle().Width(w).Render(strings.Join(fparts, footerSep.Render("  ")))

	// ─── Assemble ───
	var sections []string
	sections = append(sections, header)
	if titleLine != "" {
		sections = append(sections, titleLine)
	}
	for _, dl := range descLines {
		sections = append(sections, cellDim.Render(dl))
	}
	if metaLine != "" {
		sections = append(sections, metaLine)
	}
	sections = append(sections, divider)
	sections = append(sections, grid...)
	if eventLine != "" {
		sections = append(sections, divider)
		sections = append(sections, eventLine)
	}

	if statusLine != "" {
		sections = append(sections, "")
		sections = append(sections, statusLine)
	}

	// Pad remaining height
	usedLines := len(sections) + 1 // +1 for footer
	for i := usedLines; i < height-1; i++ {
		sections = append(sections, "")
	}
	sections = append(sections, footer)

	page := lipgloss.JoinVertical(lipgloss.Left, sections...)
	return lipgloss.NewStyle().MaxWidth(w).MaxHeight(height).Render(page)
}

// kv formats a single key:value pair for the detail grid.
func kv(label, value string) string {
	return metricLabel.Render(label+":") + metricVal.Render(value)
}

// kvRow joins kv pairs into a single row with even spacing.
func kvRow(width int, pairs ...string) string {
	joined := strings.Join(pairs, "   ")
	return joined
}

func fmtCost(cost float64) string {
	if cost == 0 {
		return "$0.00"
	}
	return fmt.Sprintf("$%.2f", cost)
}

// wrapText breaks s into lines of at most maxW runes, splitting on spaces.
func wrapText(s string, maxW int) []string {
	if maxW <= 0 {
		return []string{s}
	}
	words := strings.Fields(s)
	if len(words) == 0 {
		return nil
	}
	var lines []string
	line := words[0]
	for _, w := range words[1:] {
		if len([]rune(line))+1+len([]rune(w)) > maxW {
			lines = append(lines, line)
			line = w
		} else {
			line += " " + w
		}
	}
	if line != "" {
		lines = append(lines, line)
	}
	return lines
}

func stateColor(state string) lipgloss.Style {
	switch state {
	case "running", "active", "in_progress", "In Progress":
		return lipgloss.NewStyle().Foreground(colorGreen)
	case "error":
		return lipgloss.NewStyle().Foreground(colorRed)
	case "idle", "waiting":
		return lipgloss.NewStyle().Foreground(colorYellow)
	default:
		return cellStyle
	}
}
