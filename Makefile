.PHONY: build test watch lint coverage server server-down server-test clean help

# Generic destination for builds (no concrete simulator needed)
IOS_DEST := generic/platform=iOS Simulator
WATCHOS_DEST := generic/platform=watchOS Simulator
# Concrete simulator for tests (dynamically finds first available iPhone, falls back to iPhone 16 Pro)
IOS_TEST_DEST := $(shell dest=$$(xcrun simctl list devices available -j 2>/dev/null | python3 -c "import sys,json; devs=json.load(sys.stdin)['devices']; print(next(('platform=iOS Simulator,name='+d['name'] for rt in devs for d in devs[rt] if 'iPhone' in d['name'] and d['isAvailable']),  ''))" 2>/dev/null); if [ -z "$$dest" ]; then echo 'platform=iOS Simulator,name=iPhone 16 Pro'; else echo "$$dest"; fi)

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

build: ## Build the iOS app
	xcodebuild build -scheme AnxietyWatch -destination '$(IOS_DEST)' -quiet

watch: ## Build the watchOS app
	xcodebuild build -scheme "AnxietyWatch Watch App" -destination '$(WATCHOS_DEST)' -quiet

test: ## Run iOS unit tests
	xcodebuild test -scheme AnxietyWatch -destination '$(IOS_TEST_DEST)' -only-testing:AnxietyWatchTests -quiet

coverage: ## Run tests with code coverage report
	xcodebuild test -scheme AnxietyWatch -destination '$(IOS_TEST_DEST)' -enableCodeCoverage YES -resultBundlePath /tmp/coverage.xcresult -quiet
	xcrun xccov view --report /tmp/coverage.xcresult

lint: ## Lint the server code (flake8)
	cd server && flake8 . --max-line-length=120 --exclude=__pycache__

server: ## Start the sync server via Docker
	@test -f server/.env || { echo "Error: server/.env not found. Copy server/.env.example and fill in values."; exit 1; }
	docker compose --env-file server/.env -f server/docker-compose.yml up -d

server-down: ## Stop the sync server
	@test -f server/.env || { echo "Error: server/.env not found."; exit 1; }
	docker compose --env-file server/.env -f server/docker-compose.yml down

server-test: ## Run server tests
	cd server && python -m pytest tests/

clean: ## Clean Xcode build artifacts
	xcodebuild clean -scheme AnxietyWatch -destination '$(IOS_DEST)' -quiet
