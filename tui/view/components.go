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

// ─── Crumb Bar ──────────────────────────────────────────────────────

// RenderCrumbBar renders the k9s-style top bar: logo > context > resource.
func RenderCrumbBar(m types.AgentMetrics, width int) string {
	logo := logoStyle.Render("🤪")
	sep := crumbSep.Render(" 〉")
	ctx := crumbStyle.Render("fleet")

	var badge string
	if m.FleetStatus == "paused" {
		badge = badgePaused.Render("PAUSED")
	} else {
		badge = badgeRunning.Render("RUNNING")
	}

	agents := metricVal.Render(fmt.Sprintf("%d", m.Running)) +
		cellDim.Render(fmt.Sprintf("/%d", m.MaxAgents))

	left := logo + sep + ctx + sep + crumbStyle.Render("agents") + " " + badge + " " + agents

	// Right side: wall clock, total agent time, parallelism multiplier
	wall := fmtDuration(m.RuntimeSeconds)
	agentT := fmtDuration(m.AgentTimeSeconds)
	var multi string
	if m.RuntimeSeconds > 0 && m.AgentTimeSeconds > m.RuntimeSeconds {
		x := float64(m.AgentTimeSeconds) / float64(m.RuntimeSeconds)
		multi = metricValGreen.Render(fmt.Sprintf(" %.1fx", x))
	}
	right := cellDim.Render("Wall ") + metricVal.Render(wall) +
		cellDim.Render(" Agent ") + metricVal.Render(agentT) + multi

	gap := width - lipgloss.Width(left) - lipgloss.Width(right)
	if gap < 1 {
		gap = 1
	}
	return left + strings.Repeat(" ", gap) + right
}

// ─── Metrics Bar ────────────────────────────────────────────────────

// RenderMetricsBar renders a single-line metrics strip.
func RenderMetricsBar(m types.AgentMetrics, limits []types.RateLimit, width int) string {
	parts := []string{
		metricPair("TPS", fmt.Sprintf("%.1f", m.TPS)) + " " + renderSparkline(m.TPSHistory),
		metricPair("In", fmtTokens(m.InputTokens)),
		metricPair("Out", fmtTokens(m.OutputTokens)),
		metricPair("Cache", fmt.Sprintf("%s %.0f%%", fmtTokens(m.CacheReadTokens), m.CacheHitRate)),
		metricPairCost(m.CostUSD),
	}
	if m.Model != "" {
		parts = append(parts, metricLabel.Render("Model:")+cellDim.Render(m.Model))
	}

	// Code stats
	if m.Commits > 0 || m.LinesChanged > 0 {
		parts = append(parts,
			metricLabel.Render("Code:")+metricValGreen.Render(fmt.Sprintf("+%d", m.LinesChanged))+
				cellDim.Render(fmt.Sprintf(" %dc %dpr", m.Commits, m.PRs)))
	}

	// Tool stats
	if m.ToolCalls > 0 {
		errStr := metricValGreen.Render("0err")
		if m.ToolErrors > 0 {
			errStr = metricValRed.Render(fmt.Sprintf("%derr", m.ToolErrors))
		}
		parts = append(parts,
			metricLabel.Render("Tools:")+cellStyle.Render(fmt.Sprintf("%d", m.ToolCalls))+
				cellDim.Render(fmt.Sprintf(" %dms ", m.ToolAvgDurationMs))+errStr)
	}

	// Rate limits inline
	for _, rl := range limits {
		pct := 0.0
		if rl.Limit > 0 {
			pct = float64(rl.Used) / float64(rl.Limit)
		}
		bar := miniBar(8, pct)
		parts = append(parts,
			metricLabel.Render(rl.Name+":")+bar+cellDim.Render(fmt.Sprintf(" %d/%d", rl.Used, rl.Limit)))
	}

	line := strings.Join(parts, cellDim.Render(" │ "))

	// Dim background strip
	bg := lipgloss.NewStyle().Width(width)
	return bg.Render(line)
}

func metricPair(label, value string) string {
	return metricLabel.Render(label+":") + metricVal.Render(value)
}

func metricPairCost(cost float64) string {
	label := metricLabel.Render("Cost:")
	if cost == 0 {
		return label + cellDim.Render("$0.00")
	}
	style := metricValYellow
	if cost > 1.0 {
		style = metricValRed
	}
	return label + style.Render(fmt.Sprintf("$%.2f", cost))
}

func miniBar(width int, pct float64) string {
	if pct > 1 {
		pct = 1
	}
	if pct < 0 {
		pct = 0
	}
	filled := int(math.Round(float64(width) * pct))
	empty := width - filled

	var color lipgloss.Style
	switch {
	case pct >= 0.9:
		color = metricValRed
	case pct >= 0.7:
		color = metricValYellow
	default:
		color = metricValGreen
	}
	return color.Render(strings.Repeat("█", filled)) +
		lipgloss.NewStyle().Foreground(colorDimmer).Render(strings.Repeat("░", empty))
}

// ─── Agents Table ───────────────────────────────────────────────────

const minTableWidth = 40

// RenderAgentsTable renders the main k9s-style table.
func RenderAgentsTable(agents []types.Agent, width, height int, selectedRow ...int) string {
	if width < minTableWidth {
		return cellDim.Render("Terminal too narrow")
	}

	if len(agents) == 0 {
		empty := cellDim.Render("  No active agents. Waiting for issues...")
		pad := ""
		if height > 2 {
			pad = strings.Repeat("\n", height/3)
		}
		return pad + lipgloss.PlaceHorizontal(width, lipgloss.Center, empty) +
			strings.Repeat("\n", max(0, height-height/3-1))
	}

	// Column definitions: ISSUE STATE AGE IN OUT CACHE COST CODE LAST EVENT
	cols := []col{
		{"ISSUE", 14},
		{"STATE", 13},
		{"AGE", 7},
		{"IN", 9},
		{"OUT", 9},
		{"CACHE", 9},
		{"COST", 8},
		{"CODE", 16},
	}

	// Last column gets remaining width
	fixedW := 0
	for _, c := range cols {
		fixedW += c.width
	}
	lastColW := width - fixedW - 2
	if lastColW < 12 {
		lastColW = 12
	}
	cols = append(cols, col{"LAST EVENT", lastColW})

	// Header row
	var hdrParts []string
	for _, c := range cols {
		hdrParts = append(hdrParts, tableHdrStyle.Width(c.width).Render(c.title))
	}
	header := lipgloss.JoinHorizontal(lipgloss.Top, hdrParts...)

	// Resolve selected row index
	selIdx := -1
	if len(selectedRow) > 0 {
		selIdx = selectedRow[0]
	}

	// Data rows
	rows := []string{header}
	for i, a := range agents {
		if i >= height-1 { // leave room for header
			break
		}
		rows = append(rows, agentRow(a, cols, i, i == selIdx))
	}

	// Pad remaining height with empty lines
	for len(rows) < height {
		rows = append(rows, "")
	}

	return lipgloss.JoinVertical(lipgloss.Left, rows...)
}

type col struct {
	title string
	width int
}

func agentRow(a types.Agent, cols []col, idx int, selected bool) string {
	// Status dot — use ▸ cursor for selected row, ● otherwise
	var indicator string
	if selected {
		indicator = lipgloss.NewStyle().Foreground(colorCyan).Bold(true).Render("▸")
	} else {
		indicator = lipgloss.NewStyle().Foreground(lipgloss.Color(a.Status.StatusColor())).Render("●")
	}
	id := indicator + " " + truncStr(a.ID, cols[0].width-3)

	// Age
	age := fmtAge(a.StartedAt)

	// State with color
	stateStyle := cellStyle
	switch a.Stage {
	case "running", "active", "in_progress":
		stateStyle = lipgloss.NewStyle().Foreground(colorGreen)
	case "error":
		stateStyle = lipgloss.NewStyle().Foreground(colorRed)
	case "idle", "waiting":
		stateStyle = lipgloss.NewStyle().Foreground(colorYellow)
	}

	// Cost with color
	costStr := "—"
	costStyle := cellDim
	if a.CostUSD > 0 {
		costStr = fmt.Sprintf("$%.2f", a.CostUSD)
		costStyle = lipgloss.NewStyle().Foreground(colorYellow)
		if a.CostUSD > 0.50 {
			costStyle = lipgloss.NewStyle().Foreground(colorOrange)
		}
		if a.CostUSD > 1.0 {
			costStyle = lipgloss.NewStyle().Foreground(colorRed)
		}
	}

	// Code stats: +lines nc npr
	codeStr := "—"
	if a.LinesChanged > 0 || a.CommitsCount > 0 || a.PRsCount > 0 {
		codeStr = fmt.Sprintf("+%d %dc %dpr", a.LinesChanged, a.CommitsCount, a.PRsCount)
	} else if a.ToolCalls > 0 {
		codeStr = fmt.Sprintf("%d tools", a.ToolCalls)
	}

	// Last event text
	lastEvent := "—"
	if a.LastEventStr != "" {
		lastEvent = a.LastEventStr
	}

	parts := []string{
		lipgloss.NewStyle().Width(cols[0].width).Render(id),
		stateStyle.Width(cols[1].width).Render(a.Stage),
		cellDim.Width(cols[2].width).Render(age),
		metricVal.Width(cols[3].width).Render(fmtCompactTokens(a.InputTokens)),
		metricVal.Width(cols[4].width).Render(fmtCompactTokens(a.OutputTokens)),
		metricVal.Width(cols[5].width).Render(fmtCompactTokens(a.CacheReadTokens)),
		costStyle.Width(cols[6].width).Render(costStr),
		metricVal.Width(cols[7].width).Render(truncStr(codeStr, cols[7].width)),
		cellDim.Width(cols[8].width).Render(truncStr(lastEvent, cols[8].width)),
	}

	return lipgloss.JoinHorizontal(lipgloss.Top, parts...)
}

// ─── Backoff Queue ──────────────────────────────────────────────────

const maxErrorLen = 60

// RenderBackoffQueue renders the retry queue.
func RenderBackoffQueue(state *types.State, width int) string {
	if state == nil || len(state.Retrying) == 0 {
		return ""
	}

	rows := []string{sectionTitle.Render("↻ Retrying")}
	for _, entry := range state.Retrying {
		rows = append(rows, renderRetryRow(entry))
	}
	return lipgloss.JoinVertical(lipgloss.Left, rows...)
}

func renderRetryRow(entry types.RetryEntry) string {
	identifier := entry.IssueIdentifier
	if identifier == "" {
		identifier = entry.IssueID
	}
	countdown := countdownFromDueAt(entry.DueAt)
	errText := truncError(entry.Error)

	row := fmt.Sprintf("  ↻ %s  %s  in %s",
		retryIdentifierStyle.Render(identifier),
		retryAttemptStyle.Render(fmt.Sprintf("×%d", entry.Attempt)),
		retryCountdownStyle.Render(countdown),
	)
	if errText != "" {
		row += "  " + retryErrorStyle.Render(errText)
	}
	return row
}

// ─── Action Error ───────────────────────────────────────────────────

// RenderActionError renders a fleet action error as a centered status line.
func RenderActionError(err error, width int) string {
	if err == nil {
		return ""
	}
	msg := truncError(err.Error())
	return lipgloss.PlaceHorizontal(width, lipgloss.Center, actionErrStyle.Render("⚠ "+msg))
}

// ─── Footer ─────────────────────────────────────────────────────────

// RenderFooter renders k9s-style keybinding bar.
func RenderFooter(width int) string {
	keys := []struct{ key, desc string }{
		{"q", "Quit"},
		{"p", "Pause/Resume"},
		{"j/k", "Navigate"},
		{"enter", "Detail"},
	}

	var parts []string
	for _, k := range keys {
		parts = append(parts, footerKey.Render("<"+k.key+">")+footerDesc.Render(" "+k.desc))
	}
	bar := strings.Join(parts, footerSep.Render("  "))
	return lipgloss.NewStyle().Width(width).Render(bar)
}

// RenderPrompt renders the fleet confirmation prompt.
func RenderPrompt(isPause bool, width int) string {
	msg := "Resume fleet? (y/n)"
	if isPause {
		msg = "Pause fleet? (y/n)"
	}
	return lipgloss.PlaceHorizontal(width, lipgloss.Center, promptStyle.Render(msg))
}

// RenderQuitPrompt renders the quit confirmation prompt.
func RenderQuitPrompt(width int) string {
	return lipgloss.PlaceHorizontal(width, lipgloss.Center, promptStyle.Render("Quit dashboard? (y/n)"))
}

// ─── Formatting Helpers ─────────────────────────────────────────────

func renderSparkline(data []float64) string {
	if len(data) == 0 {
		return cellDim.Render("────────")
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

func fmtTokens(n int64) string {
	switch {
	case n >= 1_000_000:
		return fmt.Sprintf("%.1fM", float64(n)/1_000_000)
	case n >= 1_000:
		return fmt.Sprintf("%.1fK", float64(n)/1_000)
	default:
		return fmt.Sprintf("%d", n)
	}
}

func fmtCompactTokens(tokens int) string {
	if tokens == 0 {
		return "0"
	}
	if tokens >= 1_000_000 {
		return fmt.Sprintf("%.1fM", float64(tokens)/1_000_000)
	}
	if tokens >= 1_000 {
		return fmt.Sprintf("%.1fk", float64(tokens)/1_000)
	}
	return fmt.Sprintf("%d", tokens)
}

func fmtDuration(seconds int) string {
	if seconds < 60 {
		return fmt.Sprintf("%ds", seconds)
	}
	if seconds < 3600 {
		return fmt.Sprintf("%dm%ds", seconds/60, seconds%60)
	}
	h := seconds / 3600
	m := (seconds % 3600) / 60
	return fmt.Sprintf("%dh%dm", h, m)
}

func fmtAge(started time.Time) string {
	if started.IsZero() {
		return "—"
	}
	d := time.Since(started).Truncate(time.Second)
	if d < time.Minute {
		return fmt.Sprintf("%ds", int(d.Seconds()))
	}
	if d < time.Hour {
		return fmt.Sprintf("%dm%ds", int(d.Minutes()), int(d.Seconds())%60)
	}
	return fmt.Sprintf("%dh%dm", int(d.Hours()), int(d.Minutes())%60)
}

// shortModel shortens model IDs like "claude-sonnet-4-20250514" → "sonnet-4".
func shortModel(model string) string {
	// Strip "claude-" prefix and date suffix
	s := strings.TrimPrefix(model, "claude-")
	// Remove date suffix like "-20250514"
	if idx := strings.LastIndex(s, "-"); idx > 0 {
		suffix := s[idx+1:]
		if len(suffix) == 8 {
			allDigits := true
			for _, c := range suffix {
				if c < '0' || c > '9' {
					allDigits = false
					break
				}
			}
			if allDigits {
				s = s[:idx]
			}
		}
	}
	return s
}

func truncStr(s string, max int) string {
	runes := []rune(s)
	if len(runes) > max {
		if max > 3 {
			return string(runes[:max-3]) + "…"
		}
		return string(runes[:max])
	}
	return s
}

func truncError(s string) string {
	if s == "" {
		return ""
	}
	s = strings.ReplaceAll(s, "\n", " ")
	s = strings.ReplaceAll(s, "\r", " ")
	runes := []rune(s)
	if len(runes) > maxErrorLen {
		return string(runes[:maxErrorLen-1]) + "…"
	}
	return s
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
