# Changelog

## 1.2.1

- **Desktop-only HTTP**: `HttpBackgroundDownloads` throws on Android/iOS; use `BackgroundDownloads.platform()` for native engines.
- **Download size**: No implicit 8 GiB cap — set `expectedBytes` and/or `maxDownloadBytes` to bound downloads.
- **POSIX variadic FFI**: `open(2)` and `fcntl(2)` use Dart `VarArgs` bindings so `O_CREAT` mode `0600` is correct on Apple arm64 (fixes macOS partial permission workarounds).
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
