.DEFAULT_GOAL := dev
.PHONY: dev build swift-release install uninstall sparkle-tools notary-profile notary-check release release-dryrun

dev:
	watchexec -r -e swift -- swift run AnyDoor

build:
	swift build

swift-release:
	swift build -c release

APP_NAME := AnyDoor
APP_BUNDLE := $(APP_NAME).app
APP_DIR := /Applications/$(APP_BUNDLE)
BINARY := .build/release/$(APP_NAME)

install: swift-release
	@mkdir -p $(APP_DIR)/Contents/MacOS
	@mkdir -p $(APP_DIR)/Contents/Resources
	@cp $(BINARY) $(APP_DIR)/Contents/MacOS/
	@cp Info.plist $(APP_DIR)/Contents/
	@cp Resources/AppIcon.icns $(APP_DIR)/Contents/Resources/
	@codesign --force --deep --sign - $(APP_DIR) >/dev/null 2>&1 || true
	@touch $(APP_DIR)
	@echo "Installed $(APP_DIR)"

uninstall:
	@rm -rf $(APP_DIR)
	@echo "Removed $(APP_DIR)"

# ----- Release pipeline --------------------------------------------------

# Pin SPM dependency and downloaded CLI tools to the same Sparkle release.
SPARKLE_VERSION := 2.9.2
LOAD_ENV := set -a; [[ ! -f .env ]] || source .env; set +a

sparkle-tools:
	@./scripts/install-sparkle-tools.sh $(SPARKLE_VERSION)

notary-profile:
	@bash -lc '$(LOAD_ENV); xcrun notarytool store-credentials "$${NOTARY_PROFILE:?NOTARY_PROFILE is required}" --apple-id "$${APPLE_ID:?APPLE_ID is required}" --team-id "$${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"'

notary-check:
	@bash -lc '$(LOAD_ENV); xcrun notarytool history --keychain-profile "$${NOTARY_PROFILE:?NOTARY_PROFILE is required}"'

release: sparkle-tools
	@./scripts/release.sh $(VERSION)

release-dryrun: sparkle-tools
	@DRYRUN=1 ./scripts/release.sh $(VERSION)
