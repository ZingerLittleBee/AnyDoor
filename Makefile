.DEFAULT_GOAL := dev
.PHONY: dev build check docs-check release-tools-check swift-release install uninstall sparkle-tools release release-dryrun

# The `swiftbuild` backend (the default since Swift 6.4) stamps the deployment
# target into LC_BUILD_VERSION's `sdk` field instead of the real SDK version,
# and macOS 26+ gates the modern window appearance on that field: an unpatched
# local build renders the legacy chrome (compact toolbar, opaque sidebar, dark
# split divider) and no longer looks like a release. Record the real SDK
# version, mirroring the override in scripts/release/lib.sh.
MIN_MACOS := $(shell /usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Info.plist)
MACOS_SDK_VERSION := $(shell xcrun --show-sdk-version --sdk macosx)
SDK_STAMP_FLAGS := -Xlinker -platform_version -Xlinker macos -Xlinker $(MIN_MACOS) -Xlinker $(MACOS_SDK_VERSION)

dev:
	watchexec -r -e swift -- swift run $(SDK_STAMP_FLAGS) AnyDoor

build:
	swift build $(SDK_STAMP_FLAGS)

check:
	@bash scripts/check-swift.sh $(CHECK_SWIFT_FLAGS)

docs-check:
	@python3 scripts/check-docs.py
	@python3 -m unittest discover -s scripts/tests -p 'test_*.py'

# Unit tests for the tag-triggered release pipeline in scripts/release/.
release-tools-check:
	uv run --locked --project scripts/release python -m unittest discover -s scripts/release/tests

swift-release:
	swift build -c release $(SDK_STAMP_FLAGS)

APP_NAME := AnyDoor
APP_BUNDLE := $(APP_NAME).app
APP_DIR := /Applications/$(APP_BUNDLE)
BINARY := .build/release/$(APP_NAME)
RESOURCE_BUNDLE := .build/release/$(APP_NAME)_$(APP_NAME).bundle

LOAD_ENV := set -a; [[ ! -f .env ]] || source .env; set +a

# Signs with SIGNING_IDENTITY (.env) when the certificate is present. An ad-hoc
# signature has no team, so the app's designated requirement collapses to its
# cdhash -- which changes on every rebuild, and macOS then reads the reinstalled
# app as a different app: Accessibility and Screen Recording grants are dropped
# and Keychain ACLs stop matching. A Developer ID signature keeps the identity
# stable across rebuilds, so the grants survive. Ad hoc remains the fallback.
#
# The install itself replaces the bundle rather than copying over it: macOS
# guards a signed app's executable behind the App Management permission, so
# `cp` onto the running layout fails with "Operation not permitted" unless the
# calling terminal happens to hold that grant. Removing first needs no grant,
# and the bundle is fully reconstructed below anyway.
install: swift-release
	@rm -rf $(APP_DIR)
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
	if [ -z "$$SPARKLE_FW" ]; then echo "Missing Sparkle.framework" >&2; exit 1; fi; \
	rm -rf $(APP_DIR)/Contents/Frameworks/Sparkle.framework; \
	ditto "$$SPARKLE_FW" $(APP_DIR)/Contents/Frameworks/Sparkle.framework
	@SQLCIPHER_FW=""; for cand in \
	  .build/release/SQLCipher.framework \
	  .build/release/PackageFrameworks/SQLCipher.framework \
	  .build/artifacts/sqlcipher.swift/SQLCipher/SQLCipher.xcframework/macos-arm64_x86_64/SQLCipher.framework; do \
	  if [ -d "$$cand" ]; then SQLCIPHER_FW="$$cand"; break; fi; \
	done; \
	if [ -z "$$SQLCIPHER_FW" ]; then echo "Missing SQLCipher.framework" >&2; exit 1; fi; \
	rm -rf $(APP_DIR)/Contents/Frameworks/SQLCipher.framework; \
	ditto "$$SQLCIPHER_FW" $(APP_DIR)/Contents/Frameworks/SQLCipher.framework
	@if ! otool -l $(APP_DIR)/Contents/MacOS/$(APP_NAME) | grep -A2 LC_RPATH | grep -q "@executable_path/../Frameworks"; then \
	  install_name_tool -add_rpath "@executable_path/../Frameworks" $(APP_DIR)/Contents/MacOS/$(APP_NAME); \
	fi
	@otool -L $(APP_DIR)/Contents/MacOS/$(APP_NAME) | grep -q '@rpath/SQLCipher.framework/Versions/A/SQLCipher'
	@if otool -L $(APP_DIR)/Contents/MacOS/$(APP_NAME) | grep -q '/usr/lib/libsqlite3'; then \
	  echo "AnyDoor must not bind the system SQLite library" >&2; exit 1; \
	fi
	@bash -lc '$(LOAD_ENV); \
	  if [[ -n "$${SIGNING_IDENTITY:-}" ]] \
	    && security find-identity -v -p codesigning \
	      | grep -q "$$SIGNING_IDENTITY"; then \
	    codesign --force --deep --sign "$$SIGNING_IDENTITY" $(APP_DIR) \
	      >/dev/null 2>&1 && echo "Signed as $$SIGNING_IDENTITY"; \
	  else \
	    codesign --force --deep --sign - $(APP_DIR) >/dev/null 2>&1 \
	      && echo "Signed ad hoc; system permissions need re-granting"; \
	  fi'
	@touch $(APP_DIR)
	@echo "Installed $(APP_DIR)"

uninstall:
	@rm -rf $(APP_DIR)
	@echo "Removed $(APP_DIR)"

# ----- Release ---------------------------------------------------------------

# Sparkle CLI tools (generate_keys, sign_update) for key maintenance; the
# release pipeline fetches its own pinned copy (scripts/release/release.conf).
SPARKLE_VERSION := 2.9.2

sparkle-tools:
	@./scripts/install-sparkle-tools.sh $(SPARKLE_VERSION)

# Cut a release: preflight, bump Info.plist, cut CHANGELOG (Stable), commit,
# tag, and push; GitHub Actions builds, signs, and publishes it
# (docs/releasing.md).
#
#   make release                     next Stable, inferred from Info.plist
#   make release 4.3.0               explicit Stable
#   make release 4.3.0-beta.1        Beta, from release/4.3-beta
#   make release-dryrun [VERSION]    print the plan, change nothing
#   make release ... YES=1           skip the confirmation prompt (only 1 counts)
#
# VERSION=... works as well as the positional form.
RELEASE_GOAL := $(filter release release-dryrun,$(firstword $(MAKECMDGOALS)))
RELEASE_VERSION := $(or $(VERSION),$(if $(RELEASE_GOAL),$(word 2,$(MAKECMDGOALS))))
CUT_FLAGS := $(if $(RELEASE_VERSION),--version $(RELEASE_VERSION)) $(if $(filter 1,$(YES)),--yes)

ifneq ($(RELEASE_GOAL),)
ifneq ($(word 2,$(MAKECMDGOALS)),)
$(eval .PHONY: $(word 2,$(MAKECMDGOALS)))
$(eval $(word 2,$(MAKECMDGOALS)):; @:)
endif
endif

release:
	@python3 scripts/release/cut.py $(CUT_FLAGS)

release-dryrun:
	@python3 scripts/release/cut.py --dry-run $(CUT_FLAGS)
