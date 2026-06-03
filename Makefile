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
RESOURCE_BUNDLE := .build/release/$(APP_NAME)_$(APP_NAME).bundle

install: swift-release
	@mkdir -p $(APP_DIR)/Contents/MacOS
	@mkdir -p $(APP_DIR)/Contents/Resources
	@mkdir -p $(APP_DIR)/Contents/Frameworks
	@cp $(BINARY) $(APP_DIR)/Contents/MacOS/
	@cp .build/release/AnyDoorHostsHelper $(APP_DIR)/Contents/MacOS/ 2>/dev/null || true
	@mkdir -p $(APP_DIR)/Contents/Library/LaunchDaemons
	@cp Resources/dev.bybee.AnyDoor.HostsHelper.plist $(APP_DIR)/Contents/Library/LaunchDaemons/
	@cp Info.plist $(APP_DIR)/Contents/
	@cp Resources/AppIcon.icns $(APP_DIR)/Contents/Resources/
	@rm -rf $(APP_DIR)/Contents/Resources/$(APP_NAME)_$(APP_NAME).bundle
	@cp -R $(RESOURCE_BUNDLE) $(APP_DIR)/Contents/Resources/
	@SPARKLE_FW=""; for cand in \
	  .build/release/Sparkle.framework \
	  .build/release/PackageFrameworks/Sparkle.framework; do \
	  if [ -d "$$cand" ]; then SPARKLE_FW="$$cand"; break; fi; \
	done; \
	if [ -n "$$SPARKLE_FW" ]; then \
	  rm -rf $(APP_DIR)/Contents/Frameworks/Sparkle.framework; \
	  ditto "$$SPARKLE_FW" $(APP_DIR)/Contents/Frameworks/Sparkle.framework; \
	fi
	@if ! otool -l $(APP_DIR)/Contents/MacOS/$(APP_NAME) | grep -A2 LC_RPATH | grep -q "@executable_path/../Frameworks"; then \
	  install_name_tool -add_rpath "@executable_path/../Frameworks" $(APP_DIR)/Contents/MacOS/$(APP_NAME); \
	fi
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
RELEASE_GOAL := $(filter release release-dryrun,$(firstword $(MAKECMDGOALS)))
RELEASE_VERSION := $(or $(VERSION),$(if $(RELEASE_GOAL),$(word 2,$(MAKECMDGOALS))))

ifneq ($(RELEASE_GOAL),)
ifneq ($(word 2,$(MAKECMDGOALS)),)
$(eval .PHONY: $(word 2,$(MAKECMDGOALS)))
$(eval $(word 2,$(MAKECMDGOALS)):; @:)
endif
endif

sparkle-tools:
	@./scripts/install-sparkle-tools.sh $(SPARKLE_VERSION)

notary-profile:
	@bash -lc '$(LOAD_ENV); xcrun notarytool store-credentials "$${NOTARY_PROFILE:?NOTARY_PROFILE is required}" --apple-id "$${APPLE_ID:?APPLE_ID is required}" --team-id "$${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"'

notary-check:
	@bash -lc '$(LOAD_ENV); xcrun notarytool history --keychain-profile "$${NOTARY_PROFILE:?NOTARY_PROFILE is required}"'

release: sparkle-tools
	@bash -lc '$(LOAD_ENV); ./scripts/release.sh "$(RELEASE_VERSION)"'

release-dryrun: sparkle-tools
	@bash -lc '$(LOAD_ENV); DRYRUN=1 ./scripts/release.sh "$(RELEASE_VERSION)"'
