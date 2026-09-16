# Changelog

## 1.1.0

- **Advanced UX & UI Enhancements**: Added `AiroDownloadNotificationController` for persistent lockscreen notification controls and `AiroDownloadQueueVisualizer` for categorizing queue state into Downloading, Queued, Paused, Completed, and Failed with real-time transfer speed & ETA estimation.
- **Network & Storage Optimization**: Added `AiroNetworkConstraintManager` for Wi-Fi only gating, `AiroStorageConstraintManager` for pre-flight disk space safety buffer verification, and `AiroAutoRetryScheduler` with exponential backoff (5s, 15s, 30s).
- **File Security & Post-Processing**: Added `AiroDownloadFileEncryptor` stream-based XOR cipher for post-download file encryption and `AiroPostProcessingPipeline` for automated checksum, encryption, and extraction workflows.
- **Telemetry & Analytics**: Added `AiroDownloadTelemetryLogger` and `AiroDownloadTelemetrySnapshot` for tracking average speed, success/failure rates, retry attempts, and structured failure codes.

## 1.0.0

- Initial open-source stable release.
- Progressive background downloader contracts, WorkManager resume policies, and iOS background URLSession integration.
- Atomic artifact promotion with SHA-256 integrity verification.
