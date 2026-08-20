## [1.0.0] - Jul 27,2026

### Breaking
- Removed deprecated `ChatwootChat` and `ChatwootChatDialog` native chat widgets. Use the webview-based `ChatwootWidget` or `ChatwootClient` with `ChatwootCallbacks` instead. This drops the `flutter_chat_ui`, `flutter_chat_types`, `intl`, and `uuid` dependencies.

### Changed
- Migrated storage from `hive` to `hive_ce` / `hive_ce_flutter` and scoped code generation to `lib/` via `build.yaml`.
- Migrated example Android build to Gradle 9.4.1, AGP 8.13.0, and Kotlin 2.2.20 with the declarative plugins DSL and `.kts` scripts.
- Removed the deprecated `encryptedSharedPreferences` option (flutter_secure_storage v10).
- Replaced the removed `overrideWithProvider` with `overrideWith` (riverpod 3).

### Fixed
- Keep widget navigation in-app on iOS instead of opening the initial load in an external browser.
- Preserve message attachments from websocket events.
- Prevent duplicate websocket connections in `listenForEvents`.
- Support image/file attachments in `sendMessage`.
- Support host-app integration via Hive typeId base and Dio interceptors.

## [0.0.9] - Jul 22,2021

- Fixed message sending issues
- Adds development docs

## [0.0.8] - Jul 22,2021

- Update dependencies

## [0.0.7] - Jul 22,2021

- Fixed ChatwootChatDialog avatar color
- Fixed ChatwootChatDialog chat bubble overflow

## [0.0.6] - Jul 20,2021

- Fixed received message widget overflow on mobile screens

## [0.0.5] - Jul 20,2021

- Added ChatwootChatModal
- Updated README.md

## [0.0.4] - Jul 15,2021

- Updated build_runner dependency to null safety version

## [0.0.3] - Jul 15,2021

- Fixed multiple Hive adapter registration issue
- Fixed theme background issue
- Resolved pub analysis issues

## [0.0.2] - Jul 15,2021

- Updated example

## [0.0.1] - Jul 15,2021

- Setup initial client sdk flow
