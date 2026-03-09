package view

import (
	"fmt"
	"math"
	"strings"

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
		metricRow("Tokens In", valueYellow.Render(formatCount(m.InputTokens))),
		metricRow("Tokens Out", valueYellow.Render(formatCount(m.OutputTokens))),
		metricRow("Cache", fmt.Sprintf("%s  %s",
			valueYellow.Render(formatCount(m.CacheReadTokens)),
			valueDim.Render(fmt.Sprintf("(%.1f%% hit)", m.CacheHitRate)))),
		metricRow("Total", valueHighlight.Render(formatCount(m.TotalTokens))),
	}

	codeStats := []string{
		metricRow("Lines", valueGreen.Render(fmt.Sprintf("+%d", m.LinesChanged))),
		metricRow("Commits", valueGreen.Render(fmt.Sprintf("%d", m.Commits))),
		metricRow("PRs", valueGreen.Render(fmt.Sprintf("%d", m.PRs))),
	}

	toolStats := []string{
		metricRow("Tool Calls", valueStyle.Render(fmt.Sprintf("%d", m.ToolCalls))),
		metricRow("Avg Dur", valueStyle.Render(fmt.Sprintf("%dms", m.ToolAvgDurationMs))),
		metricRow("Errors", toolErrorStyle(m.ToolErrors)),
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
	barWidth := width - 30
	if barWidth < 10 {
		barWidth = 10
	}
	if barWidth > 40 {
		barWidth = 40
	}

	for _, rl := range limits {
		pct := 0.0
		if rl.Limit > 0 {
			pct = float64(rl.Used) / float64(rl.Limit)
		}
		bar := renderProgressBar(barWidth, pct)
		resetStr := valueDim.Render(fmt.Sprintf("%ds", rl.ResetInSec))
		row := fmt.Sprintf("  %-12s %s %s/%s %s",
			labelStyle.Render(rl.Name),
			bar,
			rateLimitColor(pct).Render(fmt.Sprintf("%d", rl.Used)),
			valueDim.Render(fmt.Sprintf("%d", rl.Limit)),
			resetStr,
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
		metricRow("Linear", valueDim.Render(info.LinearURL)),
		metricRow("Dashboard", valueDim.Render(info.DashboardURL)),
		metricRow("Refresh", valueDim.Render(fmt.Sprintf("%ds", info.RefreshSec))),
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
	return fmt.Sprintf("  %s %s", labelStyle.Width(12).Render(label+":"), value)
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
