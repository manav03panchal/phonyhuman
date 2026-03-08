package main

import "github.com/charmbracelet/lipgloss"

// Color palette — inspired by btop/lazygit aesthetic.
var (
	colorPurple    = lipgloss.Color("#7C3AED")
	colorViolet    = lipgloss.Color("#8B5CF6")
	colorIndigo    = lipgloss.Color("#6366F1")
	colorBlue      = lipgloss.Color("#3B82F6")
	colorCyan      = lipgloss.Color("#06B6D4")
	colorGreen     = lipgloss.Color("#10B981")
	colorYellow    = lipgloss.Color("#F59E0B")
	colorOrange    = lipgloss.Color("#F97316")
	colorRed       = lipgloss.Color("#EF4444")
	colorWhite     = lipgloss.Color("#F8FAFC")
	colorGray      = lipgloss.Color("#94A3B8")
	colorDimGray   = lipgloss.Color("#64748B")
	colorDarkGray  = lipgloss.Color("#334155")
	colorBg        = lipgloss.Color("#0F172A")
	colorPanelBg   = lipgloss.Color("#1E293B")
	colorBorderDim = lipgloss.Color("#475569")
)

// Panel border style.
var panelBorder = lipgloss.NewStyle().
	Border(lipgloss.RoundedBorder()).
	BorderForeground(colorBorderDim).
	Padding(0, 1)

// Header banner styles.
var bannerStyle = lipgloss.NewStyle().
	Bold(true).
	Foreground(colorWhite).
	Background(colorPurple).
	Padding(0, 2).
	Align(lipgloss.Center)

var bannerBorder = lipgloss.NewStyle().
	Border(lipgloss.DoubleBorder()).
	BorderForeground(colorViolet).
	Padding(0, 1).
	Align(lipgloss.Center)

// Metric label style.
var labelStyle = lipgloss.NewStyle().
	Foreground(colorGray).
	Bold(true)

// Metric value style.
var valueStyle = lipgloss.NewStyle().
	Foreground(colorWhite)

var valueHighlight = lipgloss.NewStyle().
	Foreground(colorCyan).
	Bold(true)

var valueGreen = lipgloss.NewStyle().
	Foreground(colorGreen)

var valueYellow = lipgloss.NewStyle().
	Foreground(colorYellow)

var valueRed = lipgloss.NewStyle().
	Foreground(colorRed)

var valueDim = lipgloss.NewStyle().
	Foreground(colorDimGray)

// Footer styles.
var footerStyle = lipgloss.NewStyle().
	Foreground(colorDimGray).
	Align(lipgloss.Center)

var footerKeyStyle = lipgloss.NewStyle().
	Foreground(colorCyan).
	Bold(true)

var footerDescStyle = lipgloss.NewStyle().
	Foreground(colorGray)

// Section title style.
var sectionTitle = lipgloss.NewStyle().
	Foreground(colorViolet).
	Bold(true).
	PaddingBottom(0)

// Sparkline colors.
var sparkStyle = lipgloss.NewStyle().
	Foreground(colorCyan)
