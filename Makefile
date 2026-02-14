.PHONY: build run clean release install dev sign dmg help prepare-cache postprocess-smoke

# Variables
APP_NAME = Flowstay
BUILD_DIR = .build
OUTPUT_DIR = dist
CLANG_MODULE_CACHE_PATH ?= $(PWD)/.clang-module-cache
SWIFT_USE_LOCAL_CLANG_MODULE_CACHE ?= 1
SWIFTPM_CLANG_MODULE_CACHE_PATH ?= $(CLANG_MODULE_CACHE_PATH)
SWIFTPM_ENABLE_SANDBOX ?= 0

export CLANG_MODULE_CACHE_PATH
export SWIFT_USE_LOCAL_CLANG_MODULE_CACHE
export SWIFTPM_CLANG_MODULE_CACHE_PATH
export SWIFTPM_ENABLE_SANDBOX

prepare-cache:
	@mkdir -p $(CLANG_MODULE_CACHE_PATH)

# Default target
help:
	@echo "Flowstay Build System"
	@echo "===================="
	@echo ""
	@echo "Available targets:"
	@echo "  make dev       - Build and run in debug mode"
	@echo "  make build     - Build in debug mode"
	@echo "  make release   - Build signed release version"
	@echo "  make install   - Build and install to /Applications"
	@echo "  make dmg       - Build release version with DMG"
	@echo "  make clean     - Clean build artifacts"
	@echo "  make run       - Run the debug build"
	@echo ""
	@echo "Advanced options:"
	@echo "  make sign      - Build with code signing"
	@echo "  make unsigned  - Build without code signing"

# Development build and run
dev: build run

# Build in debug mode
build: prepare-cache
	@echo "Building $(APP_NAME) (debug)..."
	@swift build --disable-sandbox

# Run the debug build
run: prepare-cache
	@echo "Running $(APP_NAME)..."
	@swift run $(APP_NAME)

# Build release version with signing
release: prepare-cache
	@echo "Building release version..."
	@./build_app.sh

# Build release without signing
unsigned: prepare-cache
	@echo "Building unsigned release version..."
	@./build_app.sh --no-sign --skip-install

# Build with signing (alias for release)
sign: release

# Build release and create DMG
dmg: prepare-cache
	@echo "Building release with DMG..."
	@./create_release.sh

# Build and install to /Applications
install: prepare-cache release
	@echo "Installing $(APP_NAME) to /Applications..."
	@if [ -d "$(OUTPUT_DIR)/$(APP_NAME).app" ]; then \
		rm -rf "/Applications/$(APP_NAME).app" 2>/dev/null || true; \
		cp -R "$(OUTPUT_DIR)/$(APP_NAME).app" "/Applications/"; \
		echo "✅ $(APP_NAME) installed to /Applications"; \
		echo ""; \
		echo "You can now:"; \
		echo "  1. Open $(APP_NAME) from /Applications"; \
		echo "  2. Or run: open '/Applications/$(APP_NAME).app'"; \
	else \
		echo "❌ Build failed or app not found"; \
		exit 1; \
	fi

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	@swift package clean
	@rm -rf $(BUILD_DIR)
	@rm -rf $(OUTPUT_DIR)
	@rm -rf $(CLANG_MODULE_CACHE_PATH)
	@echo "✅ Clean complete"

# Test the build
test: prepare-cache
	@echo "Running tests..."
	@swift test --disable-sandbox

postprocess-smoke: prepare-cache
	@echo "Running MLX post-processing smoke test (prompt builder)..."
	@swift test --disable-sandbox --filter PostProcessingPromptBuilderTests

# Format code
format:
	@echo "Formatting Swift code..."
	@if command -v swift-format >/dev/null 2>&1; then \
		swift-format -i -r Sources/ Tests/; \
	else \
		echo "swift-format not installed. Install with: brew install swift-format"; \
	fi

# Check for signing certificates
check-certs:
	@echo "Checking for signing certificates..."
	@security find-identity -v -p codesigning | grep -E "Developer ID|Apple Development" || echo "No signing certificates found"

# Open the app if it exists
open:
	@if [ -d "/Applications/$(APP_NAME).app" ]; then \
		open "/Applications/$(APP_NAME).app"; \
	elif [ -d "$(OUTPUT_DIR)/$(APP_NAME).app" ]; then \
		open "$(OUTPUT_DIR)/$(APP_NAME).app"; \
	else \
		echo "❌ $(APP_NAME).app not found. Run 'make release' or 'make install' first."; \
	fi
