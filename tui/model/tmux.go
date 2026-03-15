package model

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/humancorp/symphony/tui/types"
)

// tmuxResultMsg carries the result of a tmux window open attempt.
type tmuxResultMsg struct {
	err error
}

// openAgentTmux opens a tmux window showing filtered log output for the agent.
func openAgentTmux(agent types.Agent) tea.Cmd {
	return func() tea.Msg {
		// Check if tmux is available
		if _, err := exec.LookPath("tmux"); err != nil {
			return tmuxResultMsg{err: fmt.Errorf("tmux not found in PATH")}
		}

		if os.Getenv("TMUX") == "" {
			return tmuxResultMsg{err: fmt.Errorf("not inside a tmux session — run the TUI inside tmux first")}
		}

		name := agent.ID

		// Resolve workspace directory
		wsRoot := os.Getenv("SYMPHONY_WORKSPACE_ROOT")
		if wsRoot == "" {
			wsRoot = "~/code/symphony-workspaces"
		}
		wsDir := filepath.Join(expandHome(wsRoot), name)

		// Resolve log file path
		logPath := findLogFile()

		// Build the shell command for the tmux window
		var shellCmd string
		if logPath != "" {
			shellCmd = fmt.Sprintf(
				"cd %s 2>/dev/null; tail -f %s | grep --line-buffered %s",
				shellQuote(wsDir), shellQuote(logPath), shellQuote(name),
			)
		} else {
			shellCmd = fmt.Sprintf(
				"cd %s 2>/dev/null || cd ~; exec $SHELL",
				shellQuote(wsDir),
			)
		}

		cmd := exec.Command("tmux", "new-window", "-n", name, "bash", "-c", shellCmd)
		out, err := cmd.CombinedOutput()
		if err != nil {
			detail := strings.TrimSpace(string(out))
			if detail != "" {
				return tmuxResultMsg{err: fmt.Errorf("tmux: %s", detail)}
			}
			return tmuxResultMsg{err: fmt.Errorf("tmux: %w", err)}
		}
		return tmuxResultMsg{}
	}
}

// findLogFile returns the path to the symphony log file.
func findLogFile() string {
	if env := os.Getenv("SYMPHONY_LOG"); env != "" {
		p := expandHome(env)
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}

	candidates := []string{
		"log/symphony.log",
		"../log/symphony.log",
	}
	for _, c := range candidates {
		abs, err := filepath.Abs(c)
		if err != nil {
			continue
		}
		if _, err := os.Stat(abs); err == nil {
			return abs
		}
	}
	return ""
}

func expandHome(path string) string {
	if strings.HasPrefix(path, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return path
		}
		return filepath.Join(home, path[2:])
	}
	return path
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'"
}
