package view

import "github.com/charmbracelet/lipgloss"

// k9s-inspired color palette — neon on dark.
var (
	colorLogo     = lipgloss.Color("#FFCC00") // k9s yellow
	colorCrumb    = lipgloss.Color("#00BFFF") // bright cyan
	colorHeader   = lipgloss.Color("#444444") // table header bg
	colorHdrText  = lipgloss.Color("#AAAAAA") // table header fg
	colorCyan     = lipgloss.Color("#00E5FF")
	colorGreen    = lipgloss.Color("#00E676")
	colorYellow   = lipgloss.Color("#FFD600")
	colorOrange   = lipgloss.Color("#FF9100")
	colorRed      = lipgloss.Color("#FF1744")
	colorWhite    = lipgloss.Color("#E0E0E0")
	colorDim      = lipgloss.Color("#666666")
	colorDimmer   = lipgloss.Color("#444444")
	colorRowEven  = lipgloss.Color("#1A1A2E") // subtle alternating
	colorRowOdd   = lipgloss.Color("#16213E")
	colorSelected = lipgloss.Color("#1E88E5")
)

// Logo and breadcrumb.
var logoStyle = lipgloss.NewStyle().
	Bold(true).
	Foreground(colorLogo)

var crumbStyle = lipgloss.NewStyle().
	Foreground(colorCrumb).
	Bold(true)

var crumbSep = lipgloss.NewStyle().
	Foreground(colorDim)

// Metrics bar styles.
var metricLabel = lipgloss.NewStyle().
	Foreground(colorDim)

var metricVal = lipgloss.NewStyle().
	Foreground(colorCyan).
	Bold(true)

var metricValGreen = lipgloss.NewStyle().
	Foreground(colorGreen).
	Bold(true)

var metricValYellow = lipgloss.NewStyle().
	Foreground(colorYellow).
	Bold(true)

var metricValRed = lipgloss.NewStyle().
	Foreground(colorRed).
	Bold(true)

// Table styles.
var tableHdrStyle = lipgloss.NewStyle().
	Foreground(colorHdrText).
	Background(colorHeader).
	Bold(true)

var cellStyle = lipgloss.NewStyle().
	Foreground(colorWhite)

var cellDim = lipgloss.NewStyle().
	Foreground(colorDim)

// Footer key hints.
var footerKey = lipgloss.NewStyle().
	Foreground(colorLogo).
	Bold(true)

var footerDesc = lipgloss.NewStyle().
	Foreground(colorDim)

var footerSep = lipgloss.NewStyle().
	Foreground(colorDimmer)

// Status badge styles.
var badgeRunning = lipgloss.NewStyle().
	Foreground(lipgloss.Color("#000")).
	Background(colorGreen).
	Bold(true).
	Padding(0, 1)

var badgePaused = lipgloss.NewStyle().
	Foreground(lipgloss.Color("#000")).
	Background(colorOrange).
	Bold(true).
	Padding(0, 1)

// Prompt.
var promptStyle = lipgloss.NewStyle().
	Foreground(colorYellow).
	Bold(true)

// Sparkline.
var sparkStyle = lipgloss.NewStyle().
	Foreground(colorCyan)

// Section title (used for backoff queue).
var sectionTitle = lipgloss.NewStyle().
	Foreground(colorCrumb).
	Bold(true)

// Retry row styles.
var (
	retryIdentifierStyle = lipgloss.NewStyle().Foreground(colorRed).Bold(true)
	retryAttemptStyle    = lipgloss.NewStyle().Foreground(colorYellow)
	retryCountdownStyle  = lipgloss.NewStyle().Foreground(colorCyan)
	retryErrorStyle      = lipgloss.NewStyle().Foreground(colorDim)
	promptLabelStyle     = lipgloss.NewStyle().Foreground(colorYellow).Bold(true)
	actionErrStyle       = lipgloss.NewStyle().Foreground(colorRed).Bold(true)
)
