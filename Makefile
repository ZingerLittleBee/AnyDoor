.DEFAULT_GOAL := dev

dev:
	watchexec -r -e swift -- swift run AnyDoor

build:
	swift build

release:
	swift build -c release
