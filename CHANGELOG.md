# Changelog

## 1.2.1

- **Desktop HTTP redirects**: Fresh downloads follow redirects manually (max 8 hops), refuse any non-HTTPS hop, and send custom `DownloadArtifactRequest.headers` only to the original origin (cross-origin CDN hops do not receive secrets such as `X-Api-Key`). Resume with `Range` still does not follow redirects.
- **Commit identity**: Partial rename commits re-check the stored partial inode identity from `.meta` on reopen (swap-before-commit is refused even when SHA-256 verification already ran).
- **POSIX**: Process umask is read without mutating libc umask (exclusive-create probe on macOS; `/proc/self/status` on Linux). macOS cancel/timeout sync paths pass stored partial identity into `F_FULLFSYNC`. Close failures after a successful sync action still surface the action error.
- **CI / tooling**: `extractions/setup-just` SHA-pinned; Justfile revert matrix no longer runs `git checkout -- .`; `just publish` no longer passes `--force`.
- **Docs (Android / Google Play)**: README sections on the Google Play data sync foreground service declaration (component, start/stop, ready-to-paste Play Console answers, required `SystemForegroundService` manifest entry for Android 14+, Android 15 six-hour limit), notifications and Android 13+ `POST_NOTIFICATIONS`, privacy and telemetry, removing the foreground service permission, large files and resume, and a Known gaps list.
- **Docs**: `AiroDownloadTelemetrySnapshot.toMap()` is documented as local diagnostics that the package never sends (it previously said "for analytics logging"). `DownloadNotificationConfig` and `AiroDownloadNotificationController` are documented as Dart-only helpers that do not change the native notification.
- **Docs**: The desktop-only error message and README now name `createBackgroundDownloads()`; `BackgroundDownloads.platform()` does not exist.
- **Tests**: `telemetry_stays_local_test.dart` (no analytics or HTTP dependency, telemetry imports only models) and `redirect_resume_test.dart` (desktop redirect behaviour on fresh download and on resume).
- **Desktop-only HTTP**: `HttpBackgroundDownloads` throws on Android/iOS; use `createBackgroundDownloads()` for native engines.
- **Download size**: No implicit 8 GiB cap — set `expectedBytes` and/or `maxDownloadBytes` to bound downloads.
- **POSIX variadic FFI**: `open(2)` and `fcntl(2)` use Dart `VarArgs` bindings so `O_CREAT` mode `0600` is correct on Apple arm64 (fixes macOS partial permission workarounds).
- **Resume protocol (F1)**: No macOS-only append of `200 OK` or synthetic `206` without `Content-Range`; `200` to a `Range` request always restarts from byte 0.
- **Commit**: `fchmod(0644)` on the partial fd before rename; explicit macOS `F_FULLFSYNC` via fd in `syncFile`; empty `.airo_partials` removed after successful commit.
- **Partial storage (E2/E3)**: Partials and `.meta` files live under `<dest-dir>/.airo_partials/` (0700 leaf only); no chmod of existing user or temp directories; `/tmp` and system temp use the same checks.
- **macOS / Darwin stat**: `lstat$INODE64` / `fstat$INODE64` on 64-bit macOS; Intel macOS **not claimed** when `macos-13` CI is queued or optional.
- **Partial I/O**: fd-level `O_NOFOLLOW` create/append with `fstat` identity checks on Linux and macOS.
- **Desktop HTTP downloads**: Resume partial files with `Range: bytes=N-`, append on valid `206`/`Content-Range`, and restart cleanly when the server returns `200` or a mismatched range.
- **Integrity**: `AiroChecksumProcessor` streams SHA-256/SHA-1/MD5 via `package:crypto`; desktop finalize verifies SHA-256 on `.partial` before atomic rename.
- **Requests**: `DownloadArtifactRequest.headers` are forwarded on outgoing HTTP requests (merged with `Range`).

## 1.2.0

- **Cross-Platform Transfer Engine Refactor**:
  - **Portable Intent Policies**: Introduced `AiroDownloadPolicy` (`NetworkPolicy.any/unmetered/connected`, `PowerPolicy.any/charging`, `RetryPolicy.exponential`) hiding platform-specific details.
  - **Application-Supplied Request ID**: Updated `AiroDownloadRequest` taking explicit application-supplied IDs, custom headers, and intent policies.
  - **Granular Transfer State Machine**: Added `AiroDownloadStatus` (`queued`, `waitingForNetwork`, `waitingForPower`, `preparing`, `downloading`, `paused`, `verifying`, `processing`, `completed`, `failed`, `cancelled`).
  - **Capability Discovery**: Added `AiroPlatformCapabilities` for querying platform features.
  - **Classified Failure Reasons**: Added `AiroFailureReason` (`network`, `timeout`, `server`, `client`, `storage`, `checksum`, `permission`, `unsupported`, `unknown`).
  - **First-Class Checksums & Processors**: Added `AiroChecksum` (`sha256`, `sha1`, `md5`) and pluggable `AiroDownloadProcessor` pipeline (`AiroChecksumProcessor`, `AiroArchiveProcessor`).
  - **Storage Requirement Matrix**: Added `AiroStorageRequirement` calculating required bytes across download, temporary, processing, and safety buffer dimensions.

## 1.1.0

- Added UX queue visualizer, network/storage constraints, file encryption, and telemetry loggers.

## 1.0.0

- Initial release.
