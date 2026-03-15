package model

import (
	"os"
	"path/filepath"
	"testing"
)

func TestExpandHome_TildePrefix(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skipf("cannot determine home dir: %v", err)
	}

	got := expandHome("~/code/symphony")
	want := filepath.Join(home, "code/symphony")
	if got != want {
		t.Errorf("expandHome(~/code/symphony) = %q, want %q", got, want)
	}
}

func TestExpandHome_AbsolutePath(t *testing.T) {
	got := expandHome("/tmp/foo")
	if got != "/tmp/foo" {
		t.Errorf("expandHome(/tmp/foo) = %q, want /tmp/foo", got)
	}
}

func TestExpandHome_RelativePath(t *testing.T) {
	got := expandHome("relative/path")
	if got != "relative/path" {
		t.Errorf("expandHome(relative/path) = %q, want relative/path", got)
	}
}

func TestShellQuote_Simple(t *testing.T) {
	got := shellQuote("hello")
	if got != "'hello'" {
		t.Errorf("shellQuote(hello) = %q, want 'hello'", got)
	}
}

func TestShellQuote_WithSingleQuote(t *testing.T) {
	got := shellQuote("it's")
	want := "'it'\\''s'"
	if got != want {
		t.Errorf("shellQuote(it's) = %q, want %q", got, want)
	}
}

func TestShellQuote_Empty(t *testing.T) {
	got := shellQuote("")
	if got != "''" {
		t.Errorf("shellQuote(\"\") = %q, want ''", got)
	}
}

func TestShellQuote_WithSpaces(t *testing.T) {
	got := shellQuote("path with spaces")
	if got != "'path with spaces'" {
		t.Errorf("shellQuote(path with spaces) = %q", got)
	}
}

func TestFindLogFile_EnvOverride(t *testing.T) {
	// Create a temporary log file
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "symphony.log")
	if err := os.WriteFile(logPath, []byte("test log"), 0644); err != nil {
		t.Fatal(err)
	}

	t.Setenv("SYMPHONY_LOG", logPath)
	got := findLogFile()
	if got != logPath {
		t.Errorf("findLogFile() = %q, want %q", got, logPath)
	}
}

func TestFindLogFile_EnvMissing(t *testing.T) {
	t.Setenv("SYMPHONY_LOG", "/nonexistent/path/symphony.log")
	// When env points to nonexistent file, it should fall through to candidates
	got := findLogFile()
	// Should return empty or a candidate — either way not the invalid env path
	if got == "/nonexistent/path/symphony.log" {
		t.Error("findLogFile() should not return env path when file does not exist")
	}
}

func TestFindLogFile_NoEnvNoCandidates(t *testing.T) {
	t.Setenv("SYMPHONY_LOG", "")
	// In a test temp directory, no candidates should exist
	origDir, _ := os.Getwd()
	tmpDir := t.TempDir()
	os.Chdir(tmpDir)
	defer os.Chdir(origDir)

	got := findLogFile()
	if got != "" {
		t.Errorf("findLogFile() = %q, want empty string when no log exists", got)
	}
}
