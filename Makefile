# Root Makefile — Symphony (phonyhuman)
#
# Delegates to sub-project Makefiles and builds the Go TUI binary.

# ── TUI build variables ──────────────────────────────────────────────
TUI_DIR     := tui
TUI_BIN     := bin/symphony-tui
TUI_PKG     := ./...
GO          ?= go
GO_LDFLAGS   = -s -w \
               -X main.version=0.1.0 \
               -X main.commit=$(shell git rev-parse --short HEAD 2>/dev/null || echo unknown) \
               -X main.buildDate=$(shell date -u +%Y-%m-%dT%H:%M:%SZ)

HAS_GO := $(shell command -v $(GO) 2>/dev/null)

.PHONY: help all tui tui-linux tui-darwin tui-clean elixir-all

help:
	@echo "Targets:"
	@echo "  tui          Build TUI binary (native)"
	@echo "  tui-linux    Cross-compile TUI for linux/amd64"
	@echo "  tui-darwin   Cross-compile TUI for darwin/amd64"
	@echo "  tui-clean    Remove TUI binaries"
	@echo "  elixir-all   Run Elixir quality gate (format, lint, coverage, dialyzer)"
	@echo "  all          Run full build pipeline"

# ── Native TUI build ─────────────────────────────────────────────────
tui:
ifdef HAS_GO
	cd $(TUI_DIR) && $(GO) build -ldflags '$(GO_LDFLAGS)' -o ../$(TUI_BIN) .
else
	@echo "SKIP: Go toolchain not found — skipping TUI build"
endif

# ── Cross-compilation ────────────────────────────────────────────────
tui-linux:
ifdef HAS_GO
	cd $(TUI_DIR) && GOOS=linux GOARCH=amd64 $(GO) build -ldflags '$(GO_LDFLAGS)' -o ../$(TUI_BIN)-linux-amd64 .
else
	@echo "SKIP: Go toolchain not found — skipping TUI linux build"
endif

tui-darwin:
ifdef HAS_GO
	cd $(TUI_DIR) && GOOS=darwin GOARCH=amd64 $(GO) build -ldflags '$(GO_LDFLAGS)' -o ../$(TUI_BIN)-darwin-amd64 .
else
	@echo "SKIP: Go toolchain not found — skipping TUI darwin build"
endif

tui-clean:
	rm -f $(TUI_BIN) $(TUI_BIN)-linux-amd64 $(TUI_BIN)-darwin-amd64

# ── Elixir quality gate ──────────────────────────────────────────────
elixir-all:
	$(MAKE) -C elixir all

# ── Full pipeline ────────────────────────────────────────────────────
all: elixir-all tui
