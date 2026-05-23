# Changelog

All notable changes to AnyDoor are documented here. This project follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and uses semantic
versioning.

## [Unreleased]

### Added

- Auto-update via Sparkle 2 with assets published to GitHub Releases.
- "关于与更新" section in General settings.
- Menu bar panel banner when a new version is available.

### Changed

- Lowered the minimum supported macOS version to 14.0 (Sonoma) while keeping
  Liquid Glass effects on macOS 26+ only. OCR now uses the legacy
  VNRecognizeTextRequest path, and Settings falls back to the classic
  TabView/tabItem API.

## [1.0.0] - 2026-05-23

- Initial release.
