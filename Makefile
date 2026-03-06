VERSION := $(shell git describe --tags --match 'pyrolis-connector-v*' --always 2>/dev/null | sed 's/^pyrolis-connector-v//')
LDFLAGS := -X main.version=$(VERSION)
BINARY := pyrolis-connector
GO := go

.PHONY: build desktop headless clean version

# Default: desktop build (with systray, requires CGO)
build: desktop

desktop:
	CGO_ENABLED=1 $(GO) build -tags desktop -ldflags "$(LDFLAGS)" -o $(BINARY) ./cmd/pyrolis-connector/

headless:
	CGO_ENABLED=0 $(GO) build -ldflags "$(LDFLAGS)" -o $(BINARY) ./cmd/pyrolis-connector/

clean:
	rm -f $(BINARY)

version:
	@echo $(VERSION)
