# Changelog

All notable changes will be documented in this file.

## [Unreleased]

### Added

- Initial open-source project structure.
- Customer-specific Noir Gold theme template.
- Loopback-only CDP injection engine.
- Offline Windows installation, verification, recovery, diagnostics, and uninstall flows.
- Customer package builder with asset-rights, dimensions, type, size, placeholder, and checksum gates.
- End-to-end Windows validation.

### Security

- Enforced a complete one-to-one checksum inventory and rejected reparse points and undeclared files.
- Restricted CDP WebSocket targets to the selected `127.0.0.1` port.
- Added CDP open/command timeouts and renderer payload size/path validation.
- Added lifecycle mutexes, duplicate-handoff prevention, and stronger recorded-process verification.
- Made install upgrades transactional across engine, theme, runtime, uninstaller, and install metadata.
- Made backup deletion the default uninstall behavior to avoid retaining customer images.
