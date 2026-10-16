# `airo_background_downloads`

[![pub package](https://img.shields.io/pub/v/airo_background_downloads.svg)](https://pub.dev/packages/airo_background_downloads)
[![CI](https://github.com/DevelopersCoffee/airo_background_downloads/actions/workflows/ci.yml/badge.svg)](https://github.com/DevelopersCoffee/airo_background_downloads/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Progressive background-downloader contracts for Flutter apps with WorkManager resume policies, background URLSession lifecycle handling, and checksum integrity verification.

---

## Features

- **Progressive Background Download**: Pause, resume, and track progress across app restarts.
- **Integrity Verification**: Built-in sha256/md5 integrity verification.
- **Native Android & iOS Engines**: WorkManager worker on Android and URLSession background task on iOS.
- **Desktop HTTP engine** (Linux, macOS, Windows): `HttpBackgroundDownloads` with partial-file safety and resume. **Not** for direct use on Android/iOS — use `BackgroundDownloads.platform()` instead.

### Desktop download limits

When using `HttpBackgroundDownloads`, there is **no default byte cap** on response bodies. Set `DownloadArtifactRequest.expectedBytes` and/or pass `maxDownloadBytes` to bound size; otherwise downloads are limited only by disk and server behavior.

### macOS coverage

CI runs on **macOS arm64** (`macos-latest`). An optional **Intel macOS** (`macos-13`) job is **non-blocking** when runners are available. **Intel macOS support is not claimed** — behavior on Intel Macs is best-effort only until that job runs reliably. Darwin `stat` parsing uses `lstat$INODE64` / `fstat$INODE64` on 64-bit macOS (fail closed on Intel when those symbols are missing).

### Partial file layout (desktop HTTP)

Partial downloads and `.meta` sidecars live under a dedicated **`.airo_partials/`** directory next to the destination file. That leaf is created as **0700** and verified; parent directories (including `/tmp` or `Directory.systemTemp`) are **never chmodded**.

---

## Installation

```yaml
dependencies:
  airo_background_downloads: ^1.0.0
```

---

## License

MIT License - see [LICENSE](LICENSE) for details.
