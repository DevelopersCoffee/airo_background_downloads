# Changelog

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

- Initial open-source stable release.
