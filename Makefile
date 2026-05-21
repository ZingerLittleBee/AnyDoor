.DEFAULT_GOAL := dev

dev:
	watchexec -r -e swift -- swift run AnyDoor

build:
	swift build

release:
	swift build -c release

APP_NAME := AnyDoor
APP_BUNDLE := $(APP_NAME).app
APP_DIR := /Applications/$(APP_BUNDLE)
BINARY := .build/release/$(APP_NAME)

install: release
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
