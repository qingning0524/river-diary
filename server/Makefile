GO ?= go
GOARCH ?= amd64
TEST_DATABASE_URL ?=

.PHONY: fmt test test-race test-integration admin-ui build-linux release-linux

fmt:
	$(GO) fmt ./...

test:
	$(GO) test ./...

test-race:
	$(GO) test -race ./...

test-integration:
	@test -n "$(TEST_DATABASE_URL)" || (echo 'Set TEST_DATABASE_URL to an isolated PostgreSQL test database.' >&2; exit 2)
	TEST_DATABASE_URL='$(TEST_DATABASE_URL)' $(GO) test ./...

admin-ui:
	cd admin-ui && npm ci && npm run build

build-linux: admin-ui
	mkdir -p dist
	CGO_ENABLED=0 GOOS=linux GOARCH=$(GOARCH) $(GO) build -trimpath -ldflags='-s -w' -o dist/flowriver-api ./cmd/api

release-linux: admin-ui
	mkdir -p dist
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 $(GO) build -trimpath -ldflags='-s -w' -o dist/flowriver-api-linux-amd64 ./cmd/api
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 $(GO) build -trimpath -ldflags='-s -w' -o dist/flowriver-api-linux-arm64 ./cmd/api
	./scripts/package-releases.sh
