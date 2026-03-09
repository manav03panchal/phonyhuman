package view

import (
	"fmt"
	"math"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"

	"github.com/humancorp/symphony/tui/types"
)

var sparkBlocks = []rune{'▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'}

// RenderHeader renders the "S Y M P H O N Y" banner with border and gradient.
func RenderHeader(width int) string {
	banner := "S Y M P H O N Y"
	subtitle := "Fleet Orchestrator Dashboard"

	bannerRendered := bannerStyle.Width(min(width-6, 40)).Render(banner)
	subtitleRendered := lipgloss.NewStyle().
		Foreground(colorDimGray).
		Italic(true).
		Align(lipgloss.Center).
		Width(min(width-6, 40)).
		Render(subtitle)

	content := lipgloss.JoinVertical(lipgloss.Center, bannerRendered, subtitleRendered)
	bordered := bannerBorder.Width(min(width-4, 44)).Render(content)

	return lipgloss.PlaceHorizontal(width, lipgloss.Center, bordered)
}

// RenderCompactHeader renders a minimal header for narrow terminals.
func RenderCompactHeader(width int) string {
	banner := bannerStyle.Render("SYMPHONY")
	return lipgloss.PlaceHorizontal(width, lipgloss.Center, banner)
}

// RenderMetricsPanel renders the two-column metrics grid.
func RenderMetricsPanel(m types.AgentMetrics, width int) string {
	leftMetrics := []string{
		metricRow("Agents", fmt.Sprintf("%s/%s  %s",
			valueHighlight.Render(fmt.Sprintf("%d", m.Running)),
			valueDim.Render(fmt.Sprintf("%d", m.MaxAgents)),
			fleetBadge(m.FleetStatus))),
		metricRow("Throughput", fmt.Sprintf("%s tps  %s",
			valueHighlight.Render(fmt.Sprintf("%.1f", m.TPS)),
			renderSparkline(m.TPSHistory))),
		metricRow("Runtime", valueHighlight.Render(formatDuration(m.RuntimeSeconds))),
		metricRow("Cost", fmt.Sprintf("%s  %s",
			valueHighlight.Render(fmt.Sprintf("$%.4f", m.CostUSD)),
			valueDim.Render(m.Model))),
	}

	rightMetrics := []string{
		metricRowW("Tokens In", valueYellow.Render(formatCount(m.InputTokens)), 14),
		metricRowW("Tokens Out", valueYellow.Render(formatCount(m.OutputTokens)), 14),
		metricRowW("Cache", fmt.Sprintf("%s  %s",
			valueYellow.Render(formatCount(m.CacheReadTokens)),
			valueDim.Render(fmt.Sprintf("(%.1f%% hit)", m.CacheHitRate))), 14),
		metricRowW("Total", valueHighlight.Render(formatCount(m.TotalTokens)), 14),
	}

	codeStats := []string{
		metricRow("Lines", valueGreen.Render(fmt.Sprintf("+%d", m.LinesChanged))),
		metricRow("Commits", valueGreen.Render(fmt.Sprintf("%d", m.Commits))),
		metricRow("PRs", valueGreen.Render(fmt.Sprintf("%d", m.PRs))),
	}

	toolStats := []string{
		metricRowW("Tool Calls", valueStyle.Render(fmt.Sprintf("%d", m.ToolCalls)), 14),
		metricRowW("Avg Dur", valueStyle.Render(fmt.Sprintf("%dms", m.ToolAvgDurationMs)), 14),
		metricRowW("Errors", toolErrorStyle(m.ToolErrors), 14),
	}

	colWidth := (width - 8) / 2
	if colWidth < 20 {
		colWidth = 20
	}

	leftTitle := sectionTitle.Render("─ Fleet & Performance")
	rightTitle := sectionTitle.Render("─ Token Breakdown")
	codeTitle := sectionTitle.Render("─ Code Stats")
	toolTitle := sectionTitle.Render("─ Tool Stats")

	leftCol := lipgloss.JoinVertical(lipgloss.Left,
		append([]string{leftTitle}, leftMetrics...)...,
	)
	leftCol = lipgloss.JoinVertical(lipgloss.Left,
		leftCol,
		"",
		lipgloss.JoinVertical(lipgloss.Left,
			append([]string{codeTitle}, codeStats...)...,
		),
	)

	rightCol := lipgloss.JoinVertical(lipgloss.Left,
		append([]string{rightTitle}, rightMetrics...)...,
	)
	rightCol = lipgloss.JoinVertical(lipgloss.Left,
		rightCol,
		"",
		lipgloss.JoinVertical(lipgloss.Left,
			append([]string{toolTitle}, toolStats...)...,
		),
	)

	leftPanel := lipgloss.NewStyle().Width(colWidth).Render(leftCol)
	rightPanel := lipgloss.NewStyle().Width(colWidth).Render(rightCol)

	grid := lipgloss.JoinHorizontal(lipgloss.Top, leftPanel, rightPanel)
	return panelBorder.Width(width - 4).Render(grid)
}

// RenderCompactMetrics renders a single-column metrics view for narrow terminals.
func RenderCompactMetrics(m types.AgentMetrics, width int) string {
	rows := []string{
		sectionTitle.Render("─ Metrics"),
		metricRow("Agents", fmt.Sprintf("%d/%d %s", m.Running, m.MaxAgents, fleetBadge(m.FleetStatus))),
		metricRow("TPS", fmt.Sprintf("%.1f %s", m.TPS, renderSparkline(m.TPSHistory))),
		metricRow("Runtime", formatDuration(m.RuntimeSeconds)),
		metricRow("Cost", fmt.Sprintf("$%.4f (%s)", m.CostUSD, m.Model)),
		"",
		metricRow("Tokens", fmt.Sprintf("in %s / out %s / cache %s (%.0f%%)",
			formatCount(m.InputTokens), formatCount(m.OutputTokens),
			formatCount(m.CacheReadTokens), m.CacheHitRate)),
		metricRow("Total", formatCount(m.TotalTokens)),
		"",
		metricRow("Code", fmt.Sprintf("+%d lines, %d commits, %d PRs", m.LinesChanged, m.Commits, m.PRs)),
		metricRow("Tools", fmt.Sprintf("%d calls, %dms avg, %d err", m.ToolCalls, m.ToolAvgDurationMs, m.ToolErrors)),
	}
	content := lipgloss.JoinVertical(lipgloss.Left, rows...)
	return panelBorder.Width(width - 4).Render(content)
}

// RenderRateLimits renders rate limit progress bars.
func RenderRateLimits(limits []types.RateLimit, width int) string {
	if len(limits) == 0 {
		return panelBorder.Width(width - 4).Render(
			sectionTitle.Render("─ Rate Limits") + "\n" +
				valueDim.Render("  No rate limit data"),
		)
	}

	rows := []string{sectionTitle.Render("─ Rate Limits")}
	barWidth := width - 50
	if barWidth < 10 {
		barWidth = 10
	}
	if barWidth > 35 {
		barWidth = 35
	}

	// Pre-format numbers to find max widths for alignment
	type rlFormatted struct {
		name    string
		bar     string
		used    string
		limit   string
		reset   string
		pct     float64
	}
	var formatted []rlFormatted
	maxUsedLen := 0
	maxLimitLen := 0
	for _, rl := range limits {
		pct := 0.0
		if rl.Limit > 0 {
			pct = float64(rl.Used) / float64(rl.Limit)
		}
		usedStr := fmt.Sprintf("%d", rl.Used)
		limitStr := fmt.Sprintf("%d", rl.Limit)
		if len(usedStr) > maxUsedLen {
			maxUsedLen = len(usedStr)
		}
		if len(limitStr) > maxLimitLen {
			maxLimitLen = len(limitStr)
		}
		formatted = append(formatted, rlFormatted{
			name:  rl.Name,
			bar:   renderProgressBar(barWidth, pct),
			used:  usedStr,
			limit: limitStr,
			reset: fmt.Sprintf("%ds", rl.ResetInSec),
			pct:   pct,
		})
	}

	for _, rl := range formatted {
		label := fmt.Sprintf("%-10s", rl.name)
		usage := fmt.Sprintf("%*s", maxUsedLen, rl.used) +
			valueDim.Render("/") +
			fmt.Sprintf("%-*s", maxLimitLen, rl.limit)
		row := fmt.Sprintf("  %s  %s  %s  %s",
			labelStyle.Render(label),
			rl.bar,
			rateLimitColor(rl.pct).Render(usage),
			valueDim.Render(fmt.Sprintf("⏱ %s", rl.reset)),
		)
		rows = append(rows, row)
	}
	content := lipgloss.JoinVertical(lipgloss.Left, rows...)
	return panelBorder.Width(width - 4).Render(content)
}

// RenderProjectInfo renders project URLs and refresh countdown.
func RenderProjectInfo(info types.ProjectInfo, width int) string {
	rows := []string{
		sectionTitle.Render("─ Project Info"),
		metricRowW("Linear", valueDim.Render(info.LinearURL), 14),
		metricRowW("Dashboard", valueDim.Render(info.DashboardURL), 14),
		metricRowW("Refresh", valueDim.Render(fmt.Sprintf("%ds", info.RefreshSec)), 14),
	}
	content := lipgloss.JoinVertical(lipgloss.Left, rows...)
	return panelBorder.Width(width - 4).Render(content)
}

// RenderFooter renders keybinding hints.
func RenderFooter(width int) string {
	keys := []struct{ key, desc string }{
		{"q", "quit"},
		{"tab", "switch panels"},
		{"↑↓", "scroll"},
		{"p", "pause/resume"},
	}

	var parts []string
	for _, k := range keys {
		parts = append(parts,
			footerKeyStyle.Render(k.key)+" "+footerDescStyle.Render(k.desc))
	}

	bar := strings.Join(parts, valueDim.Render("  │  "))
	return footerStyle.Width(width).Render(bar)
}

// --- Helpers ---

func metricRow(label, value string) string {
	return metricRowW(label, value, 14)
}

func metricRowW(label, value string, labelWidth int) string {
	padded := fmt.Sprintf("%-*s", labelWidth, label+":")
	return fmt.Sprintf("  %s %s", labelStyle.Render(padded), value)
}

func fleetBadge(status string) string {
	if status == "paused" {
		return lipgloss.NewStyle().
			Foreground(colorWhite).
			Background(colorOrange).
			Padding(0, 1).
			Render("PAUSED")
	}
	return lipgloss.NewStyle().
		Foreground(colorWhite).
		Background(colorGreen).
		Padding(0, 1).
		Render("RUNNING")
}

func renderSparkline(data []float64) string {
	if len(data) == 0 {
		return valueDim.Render("────────")
	}
	maxVal := 0.0
	for _, v := range data {
		if v > maxVal {
			maxVal = v
		}
	}
	if maxVal == 0 {
		maxVal = 1
	}

	var sb strings.Builder
	for _, v := range data {
		idx := int(v / maxVal * float64(len(sparkBlocks)-1))
		if idx >= len(sparkBlocks) {
			idx = len(sparkBlocks) - 1
		}
		if idx < 0 {
			idx = 0
		}
		sb.WriteRune(sparkBlocks[idx])
	}
	return sparkStyle.Render(sb.String())
}

func renderProgressBar(width int, pct float64) string {
	if pct > 1 {
		pct = 1
	}
	if pct < 0 {
		pct = 0
	}
	filled := int(math.Round(float64(width) * pct))
	empty := width - filled

	color := rateLimitColor(pct)
	bar := color.Render(strings.Repeat("█", filled)) +
		lipgloss.NewStyle().Foreground(colorDarkGray).Render(strings.Repeat("░", empty))
	return bar
}

func rateLimitColor(pct float64) lipgloss.Style {
	switch {
	case pct >= 0.9:
		return valueRed
	case pct >= 0.7:
		return valueYellow
	default:
		return valueGreen
	}
}

func toolErrorStyle(errors int) string {
	if errors > 0 {
		return valueRed.Render(fmt.Sprintf("%d", errors))
	}
	return valueGreen.Render("0")
}

func formatCount(n int64) string {
	switch {
	case n >= 1_000_000:
		return fmt.Sprintf("%.1fM", float64(n)/1_000_000)
	case n >= 1_000:
		return fmt.Sprintf("%.1fK", float64(n)/1_000)
	default:
		return fmt.Sprintf("%d", n)
	}
}

func formatDuration(seconds int) string {
	if seconds < 60 {
		return fmt.Sprintf("%ds", seconds)
	}
	if seconds < 3600 {
		return fmt.Sprintf("%dm %ds", seconds/60, seconds%60)
	}
	h := seconds / 3600
	m := (seconds % 3600) / 60
	s := seconds % 60
	return fmt.Sprintf("%dh %dm %ds", h, m, s)
}

const maxErrorLen = 60

var (
	retryIdentifierStyle = lipgloss.NewStyle().Foreground(colorRed).Bold(true)
	retryAttemptStyle    = lipgloss.NewStyle().Foreground(colorYellow)
	retryCountdownStyle  = lipgloss.NewStyle().Foreground(colorCyan)
	retryErrorStyle      = lipgloss.NewStyle().Foreground(colorDimGray)
	promptLabelStyle     = lipgloss.NewStyle().Foreground(colorYellow).Bold(true)
)

// RenderBackoffQueue renders the backoff/retry queue panel.
func RenderBackoffQueue(state *types.State, width int) string {
	title := sectionTitle.Render("─ Backoff Queue")

	if state == nil || len(state.Retrying) == 0 {
		content := title + "\n" + valueDim.Render("  No queued retries")
		return panelBorder.Width(width - 4).Render(content)
	}

	rows := []string{title}
	for _, entry := range state.Retrying {
		rows = append(rows, renderRetryRow(entry))
	}

	content := lipgloss.JoinVertical(lipgloss.Left, rows...)
	return panelBorder.Width(width - 4).Render(content)
}

func renderRetryRow(entry types.RetryEntry) string {
	identifier := entry.IssueIdentifier
	if identifier == "" {
		identifier = entry.IssueID
	}

	countdown := countdownFromDueAt(entry.DueAt)
	errText := truncateError(entry.Error)

	row := fmt.Sprintf("  ↻ %s  %s  in %s",
		retryIdentifierStyle.Render(identifier),
		retryAttemptStyle.Render(fmt.Sprintf("attempt=%d", entry.Attempt)),
		retryCountdownStyle.Render(countdown),
	)

	if errText != "" {
		row += "  " + retryErrorStyle.Render(errText)
	}

	return row
}

func countdownFromDueAt(dueAt string) string {
	if dueAt == "" {
		return "n/a"
	}

	t, err := time.Parse(time.RFC3339, dueAt)
	if err != nil {
		return "n/a"
	}

	remaining := time.Until(t)
	if remaining <= 0 {
		return "now"
	}

	secs := remaining.Seconds()
	if secs < 60 {
		return fmt.Sprintf("%.1fs", secs)
	}
	mins := int(math.Floor(secs / 60))
	remSecs := int(secs) % 60
	return fmt.Sprintf("%dm%ds", mins, remSecs)
}

func truncateError(s string) string {
	if s == "" {
		return ""
	}
	s = strings.ReplaceAll(s, "\n", " ")
	s = strings.ReplaceAll(s, "\r", " ")
	if len(s) > maxErrorLen {
		s = s[:maxErrorLen-1] + "…"
	}
	return s
}

// RenderPrompt renders the fleet pause/resume confirmation prompt.
func RenderPrompt(isPause bool, width int) string {
	msg := "Resume fleet? (y/n)"
	if isPause {
		msg = "Pause fleet? (y/n)"
	}
	return lipgloss.PlaceHorizontal(width, lipgloss.Center,
		promptLabelStyle.Render(msg))
}
