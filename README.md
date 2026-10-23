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
- **Desktop HTTP engine** (Linux, macOS, Windows): `HttpBackgroundDownloads` with partial-file safety and resume. **Not** for direct use on Android/iOS — use `createBackgroundDownloads()` instead.

### Desktop download limits

When using `HttpBackgroundDownloads`, there is **no default byte cap** on response bodies. Set `DownloadArtifactRequest.expectedBytes` and/or pass `maxDownloadBytes` to bound size; otherwise downloads are limited only by disk and server behavior.

### macOS coverage

CI runs on **macOS arm64** (`macos-latest`). An optional **Intel macOS** (`macos-13`) job is **non-blocking** when runners are available. **Intel macOS support is not claimed** — behavior on Intel Macs is best-effort only until that job runs reliably. Darwin `stat` parsing uses `lstat$INODE64` / `fstat$INODE64` on 64-bit macOS (fail closed on Intel when those symbols are missing).

### Partial file layout (desktop HTTP)

Partial downloads and `.meta` sidecars live under a dedicated **`.airo_partials/`** directory next to the destination file. That leaf is created as **0700** and verified; parent directories (including `/tmp` or `Directory.systemTemp`) are **never chmodded**.

---

## Which API runs on Android

On Android and iOS, use `createBackgroundDownloads()` (or `MethodChannelBackgroundDownloads` directly) with `DownloadArtifactRequest`. That is the path the native engines understand: `artifactId`, `source` (HTTPS only), `destinationPath` (inside the app sandbox), `expectedBytes`, `expectedSha256`, `displayName`.

`AiroDownloadEngine` / `AiroPlatformBridge` with `AiroDownloadRequest` does **not** work against the native engines in this version: it sends `id`/`url`/`destination` keys, which the Android and iOS plugins reject (`invalid_request`), and its `AiroDownloadPolicy` (for example `NetworkPolicy.unmetered`) is not read by native code. See [Known gaps](#known-gaps).

---

## Google Play foreground service declaration

The plugin's manifest adds three permissions to your app: `INTERNET`, `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_DATA_SYNC`. Google Play asks you to declare and justify the data sync foreground service.

### Which component uses it

- Downloads run in `ProgressiveDownloadWorker`, a WorkManager `CoroutineWorker`. The plugin enqueues one unique FIFO chain, so **one download runs at a time**. The only WorkManager constraint is `NetworkType.CONNECTED`.
- The worker calls `setForeground(...)` with `ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC` (Android 10+). WorkManager then runs it inside its own service, **`androidx.work.impl.foreground.SystemForegroundService`**. That is the component Play sees as the data sync foreground service. The plugin has no service of its own.

### When it starts and stops

- **Starts:** at the start of every worker run, right before the HTTP request, after WorkManager schedules the work (the app called `enqueue`, `resume` or `retry`, and the device has a network connection). It is refreshed about every 500 ms while bytes arrive, to update the notification.
- **Stops:** when the worker returns: the file is downloaded, checked (size and SHA-256 when given) and moved into place; the download fails; the app calls `pause` or `cancel` (the transfer loop sees the change on its next read and returns); or Android/WorkManager stops the worker.

### Your app's manifest (Android 14+)

If your app targets Android 14 (API 34) or higher, Android requires a foreground service type on the service in the manifest. This plugin does **not** declare it for you. Add this inside `<application>` in your app's `AndroidManifest.xml` (the root `<manifest>` element needs `xmlns:tools="http://schemas.android.com/tools"`):

```xml
<service
    android:name="androidx.work.impl.foreground.SystemForegroundService"
    android:foregroundServiceType="dataSync"
    tools:node="merge" />
```

This is the declaration the [WorkManager long-running workers guide](https://developer.android.com/develop/background-work/background-tasks/persistent/how-to/long-running) asks for. If other workers in your app need more types, list them all (for example `dataSync|location`). Without it, `setForeground` fails, the worker throws before downloading, and the download does not run.

### Ready-to-paste Play Console answers

Replace `<App>` and the size with your own. Upload the video yourself; the text below only says what it must show.

**Foreground service type:** Data sync

**Describe the task that uses this foreground service type:**

> `<App>` downloads an on-device AI model file (about 1 to 2.6 GB) after the user taps to download it. The download runs in a WorkManager worker that is promoted to a data sync foreground service (androidx.work.impl.foreground.SystemForegroundService) only while the file is being transferred and checked, and shows an ongoing "Downloading N%" notification. The service starts when the download starts and stops as soon as the file is downloaded and verified, or when the user pauses or cancels the download in the app. Nothing is uploaded; the only network request is the download of the model file.

**User impact if the task is deferred or interrupted:**

> The model file is large and can take from several minutes to over an hour to download. Until it finishes, the app's on-device AI features cannot be used. If the system defers or stops the download when the user leaves the app, the user returns to an unfinished download and has to wait again. The download resumes from the bytes already saved when the server supports it, but it does not progress while deferred.

**What the video should show:**

> 1. Open `<App>` and tap the control that starts the model download (the download only starts from this user action).
> 2. Pull down the notification shade: the "Downloading N%" notification with a progress bar is visible.
> 3. Press Home to leave the app and show the notification still updating.
> 4. Return to the app, show the progress, then let the download finish (or pause or cancel it in the app) and show that the notification goes away.
>
> Record with notifications allowed for the app. On Android 13+ with notifications denied, the service still runs but the notification only appears in the Task Manager in quick settings.

### Android 14 and 15 notes

- **Android 14 (API 34):** the manifest service type above is required. Users can swipe away the foreground service notification; the download keeps running.
- **Android 15 (API 35):** `dataSync` foreground services may run for **6 hours in total per 24 hours**. Then Android calls `Service.onTimeout`, and the timer resets only when the user brings the app to the foreground. After the limit, a new `dataSync` foreground service cannot be started from the background (`ForegroundServiceStartNotAllowedException`). Apps targeting Android 15 also cannot start a `dataSync` foreground service from a `BOOT_COMPLETED` receiver; this plugin has no boot receiver.
- **What this package does at the 6 hour limit:** it has **no handling of its own** (no `onTimeout`, `onStopped` or `stopReason` code, and no dedicated failure code). WorkManager's `SystemForegroundService` receives the timeout and stops the worker. From the worker code, the expected result is: the coroutine is cancelled at its next progress update, the generic `catch` records `status: failed`, `failureCode: transport` ("Download was interrupted."), with `canResume: true` and the `.part` file kept. While an entry is `failed`, later `enqueue` calls queue but do not start. To continue, call `resume(artifactId)` (or `retry`) when the app is in the foreground; the worker resumes with `Range`. This path has not been reproduced on a device.
- **Starting from the background:** on Android 12+ Android can refuse to start a foreground service from the background. The first `setForeground` call is outside the worker's `try` block, so if it throws, the worker fails while the stored status stays `downloading`. Call `pause` then `resume` (or `cancel` and `enqueue` again) to recover. See [Known gaps](#known-gaps).

---

## Notifications

### What the Android notification shows

The Android engine builds the foreground service notification itself (`ProgressiveDownloadWorker.createForegroundInfo`):

- Channel `airo_platform_downloads`, named "Airo downloads", importance low (no sound).
- Title: the request's `displayName` (first 80 characters), or the `artifactId` when there is none.
- Text: "Downloading N%" when the size is known (`expectedBytes` or `Content-Length`), otherwise "Downloading", with a matching progress bar (indeterminate when the size is unknown).
- Small icon `android.R.drawable.stat_sys_download`, ongoing, alerts once.
- **No action buttons and no tap action.** Pause, resume and cancel are only available through the Dart API.

The only thing an app controls is the title, through `displayName`.

### `DownloadNotificationConfig`

`DownloadNotificationConfig` (`titlePattern`, `showProgressInNotification`, `enablePauseResumeActions`, `enableCancelAction`) and `AiroDownloadNotificationController` are **Dart-only helpers**. They are not sent to the Android or iOS engine and do not change the notification above. `AiroDownloadNotificationController` keeps a map of active downloads and formats `titlePattern` (replacing `{name}` with the artifact id); it posts nothing, and the package never calls `onNotificationAction`. Use them if you draw your own notification with another plugin.

### Android 13+ and `POST_NOTIFICATIONS`

- The plugin does **not** declare or request `POST_NOTIFICATIONS`.
- Android does not require it to start a foreground service. **The download still runs** without it.
- Without it (app targeting Android 13+, user has not granted it), the notification does not appear in the notification drawer; the running service is only listed in the Task Manager in quick settings.
- **If you want users to see the progress notification, your app must declare `<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>` and request it at runtime** (for example with `permission_handler`) before starting a download.

---

## Privacy and telemetry

- **No analytics dependency.** The package's runtime dependencies are `flutter`, `crypto` and `ffi` (see `pubspec.yaml`). The Android engine adds `androidx.work:work-runtime-ktx` and `com.squareup.okhttp3:okhttp` (see `android/build.gradle`). The iOS pod depends only on Flutter.
- **The only network request is the download itself.** Android makes one `GET` to the request's `source` per attempt (OkHttp, in `ProgressiveDownloadWorker`), iOS uses a background `URLSession` download task for `source`, and the desktop engine uses `HttpClient.getUrl(source)`. There is no other HTTP client code in the package.
- **Telemetry stays in memory on the device.** `AiroDownloadTelemetryLogger` keeps counters in memory only: no files, no network, reset when the process ends or `reset()` is called. `AiroDownloadTelemetrySnapshot.toMap()` returns a plain `Map` for local diagnostics. **The package never sends it anywhere. Sending it off the device is the app's choice.**
- `test/telemetry_stays_local_test.dart` checks the dependency list, the imports under `lib/`, and that the telemetry and notification helpers import nothing but the package's own models.

---

## Removing the foreground service permission

An app could try to drop the permission with:

```xml
<uses-permission
    android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC"
    tools:node="remove" />
```

**Do not do this with this version if you use the Android engine.** The worker always calls `setForeground` with the data sync type before it downloads, and there is no option to skip it. On apps targeting Android 14+ that call is refused without `FOREGROUND_SERVICE_DATA_SYNC`, so every Android download fails before the first byte (and the stored status stays `downloading`). Removing `FOREGROUND_SERVICE` breaks it on every supported Android version. There is also no "in-app only" Android path: `HttpBackgroundDownloads` throws on Android and iOS. An opt-out is listed under [Known gaps](#known-gaps).

---

## Large files and resume

### Android

- **Size:** byte counts are 64-bit (`Long`) throughout the worker, so files over 2 GB (for example 2.6 GB) are handled. If `expectedBytes` is set, the worker checks free space for the remaining bytes first and fails with `insufficient_storage` when it does not fit.
- **Resume:** partial data is kept in `<destinationPath>.part`. On the next attempt, if the `.part` file has bytes, the worker sends `Range: bytes=<size>-`. A `206` response is appended; any other success code (for example `200`) fails with `resume_not_supported`, and `retry` then deletes the `.part` file and starts again from byte 0.
- **Integrity:** the Android engine does not check `Content-Range` and does not send `If-Range` or an ETag, so a file that changed on the server between attempts is only caught by the final checks. **Always set `expectedSha256` (and `expectedBytes`) for large models.** On a mismatch the `.part` file is deleted and the download fails with `integrity_mismatch`.
- **Redirects (Hugging Face `resolve/main` URLs):** OkHttp follows redirects (`followRedirects(true)`), including HTTPS to HTTPS hops such as Hugging Face to its CDN; it does not follow redirects that switch between HTTP and HTTPS (`followSslRedirects(false)`). OkHttp builds the follow-up request from the original one, so the `Range` header goes to the CDN too. This is not covered by an automated test here (no Android SDK in CI) and has not been checked live against Hugging Face from this repo.
- **Headers:** the Android engine ignores `DownloadArtifactRequest.headers`, so an `Authorization` token for a gated Hugging Face repo is not sent. Use public files on Android.

### Desktop (`HttpBackgroundDownloads`)

- Resume with `Range` is only attempted when the request has `expectedSha256` or a strong validator (ETag) was stored; otherwise the partial file is discarded.
- A fresh download follows up to 8 redirects. **A resume request does not follow redirects.** Against a Hugging Face `resolve/main` URL (which answers with a redirect), the resume attempt gets the redirect, the partial file is deleted, and the download restarts from byte 0 and follows the redirect. The file still completes and is verified, but the bytes already on disk are downloaded again. `test/redirect_resume_test.dart` pins both behaviours.

---

## Known gaps

- **No Android 15 `dataSync` timeout handling.** No `onTimeout`/`stopReason` handling and no dedicated failure code; a timeout looks like `transport` "Download was interrupted.", and the app must call `resume` when it is in the foreground again.
- **First `setForeground` call is outside the worker's `try` block.** If Android refuses the foreground service (missing manifest type, missing permission, background start limits), the worker fails and the stored status stays `downloading`.
- **The plugin manifest does not declare `foregroundServiceType="dataSync"` on `SystemForegroundService`.** Apps targeting Android 14+ must add it themselves (see above).
- **No opt-out of the foreground service** for apps that only download while in the app.
- **`DownloadNotificationConfig` is not applied to the native notification**: no pause, resume or cancel actions, no tap action, no option to hide progress.
- **`AiroDownloadEngine` / `AiroPlatformBridge` do not match the native method channel** (wrong argument keys and event shape), and `AiroDownloadPolicy` (unmetered, charging, retries) is not applied on Android, which always uses `NetworkType.CONNECTED`. Use `createBackgroundDownloads()` with `DownloadArtifactRequest`; "Wi-Fi only" must be enforced by the app before calling `enqueue`.
- **Android ignores `DownloadArtifactRequest.headers`** (no auth tokens for gated downloads).
- **Android resume does not validate `Content-Range` or use `If-Range`**; it relies on the final size and SHA-256 checks.
- **Desktop resume restarts from byte 0 when the source URL redirects** (for example Hugging Face `resolve/main`).

---

## Local CI / publish (Just)

When GitHub Actions is unavailable, run the same checks locally with [just](https://github.com/casey/just):

```bash
just              # pub get, analyze, test, revert matrix (Linux/macOS)
just ci-core      # analyze + test only (e.g. Windows)
just publish-dry  # validate before pub.dev
just publish      # upload (after `dart pub token add https://pub.dev`)
just verify-pub version=1.2.1
```

---

## Installation

```yaml
dependencies:
  airo_background_downloads: ^1.2.1
```

---

## License

MIT License - see [LICENSE](LICENSE) for details.
