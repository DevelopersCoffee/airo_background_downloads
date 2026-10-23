#!/usr/bin/env bash
# Revert one security guard at a time; the paired test must FAIL (non-zero exit).
set -euo pipefail
cd "$(dirname "$0")/.."

MATRIX_TOUCHED=()
MATRIX_WAS_INTERRUPTED=false

fail() { echo "MATRIX ERROR: $*" >&2; exit 1; }

matrix_require_clean_tree() {
  if ! git diff --quiet || ! git diff --cached --quiet; then
    fail "refusing to start: working tree is dirty (commit or stash changes first)"
  fi
}

matrix_track() {
  local f
  for f in "$@"; do
    MATRIX_TOUCHED+=("$f")
  done
}

matrix_restore_touched() {
  local f seen=" "
  for f in "${MATRIX_TOUCHED[@]}"; do
    case "$seen" in *" $f "*) continue ;; esac
    seen="${seen}${f} "
    git checkout -- "$f" 2>/dev/null || true
  done
}

matrix_verify_clean() {
  if ! git diff --quiet || ! git diff --cached --quiet; then
    fail "matrix left the working tree dirty after restore"
  fi
}

matrix_on_exit() {
  local exit_code=$?
  matrix_restore_touched
  if $MATRIX_WAS_INTERRUPTED; then
    echo "MATRIX ERROR: revert matrix interrupted; restored files modified in this run" >&2
  fi
  exit "$exit_code"
}

trap matrix_on_exit EXIT
trap 'MATRIX_WAS_INTERRUPTED=true; exit 130' INT
trap 'MATRIX_WAS_INTERRUPTED=true; exit 143' TERM

matrix_require_clean_tree

run_test() {
  flutter test "$1" --name "$2" >/dev/null 2>&1
}

expect_fail() {
  local label="$1"
  local file="$2"
  local test_file="$3"
  local test_name="$4"
  matrix_track "$file"
  if run_test "$test_file" "$test_name"; then
    git checkout -- "$file"
    fail "$label: test still passed after revert"
  fi
  git checkout -- "$file"
  echo "Yes"
}

skip_row() {
  printf '%-22s' "$1"
  echo "n/a"
}

UNAME="$(uname -s)"
IS_LINUX=false
IS_MAC=false
case "$UNAME" in
  Linux) IS_LINUX=true ;;
  Darwin) IS_MAC=true ;;
esac

if $IS_MAC; then
  sed_inplace() { sed -i '' "$@"; }
else
  sed_inplace() { sed -i "$@"; }
fi

echo "Revert matrix (host=$UNAME; each row must fail its test when guard is reverted):"
printf '%-22s' "Row"
echo "Revert-proof"

if ! $IS_LINUX && ! $IS_MAC; then
  echo "Non-POSIX host: only path-level rows are not run here."
  matrix_verify_clean
  exit 0
fi

# 1) nlink (path)
matrix_track lib/src/http/partial_file_io.dart
sed_inplace 's/linkCount == 1/linkCount != null/' lib/src/http/partial_file_io.dart
printf '%-22s' "K1/nlink"
expect_fail "nlink" lib/src/http/partial_file_io.dart \
  test/k2_security_regressions_test.dart "K2 nlink>1 partial is not safe"

# 2) owner (path)
sed_inplace 's/ownedByUs &&/true \&\&/' lib/src/http/partial_file_io.dart
printf '%-22s' "owner"
expect_fail "owner" lib/src/http/partial_file_io.dart \
  test/k2_security_regressions_test.dart "K2 foreign owner partial is not safe"

# 3) dir fsync result
sed_inplace 's/if (result != 0)/if (false)/' lib/src/http/partial_file_io_posix.dart
printf '%-22s' "dir fsync"
expect_fail "dir fsync" lib/src/http/partial_file_io_posix.dart \
  test/posix_syscalls_revert_test.dart "K2 injected fsync -1 fails closed"

# 4) dir open failure
sed_inplace 's/if (fd < 0)/if (false)/' lib/src/http/partial_file_io_posix.dart
printf '%-22s' "dir open"
expect_fail "dir open" lib/src/http/partial_file_io_posix.dart \
  test/posix_syscalls_revert_test.dart "K2 injected open -1 fails closed"

# 5) size cap
sed_inplace 's/if (nextTotalBytes > cap)/if (false)/' lib/src/http_background_downloads.dart
printf '%-22s' "size cap"
expect_fail "size cap" lib/src/http_background_downloads.dart \
  test/k2_security_regressions_test.dart "K2 download size cap rejects oversized body"

# 6) meta identity
sed_inplace 's/if (record.source != request.source.toString()) return false;/if (false) return false;/' \
  lib/src/http/resume_validator_store.dart
printf '%-22s' "meta"
expect_fail "meta" lib/src/http/resume_validator_store.dart \
  test/k2_security_regressions_test.dart "K2 mismatched meta identity blocks resume validator reuse"

# 7) exclusive O_NOFOLLOW (Linux + Darwin patterns)
sed_inplace 's/return _linuxOWronly | _linuxOCreat | _linuxOExcl | _linuxONoFollow;/return _linuxOWronly | _linuxOCreat;/' \
  lib/src/http/partial_file_writer_posix.dart
sed_inplace 's/return _darwinOWronly | _darwinOCreat | _darwinOExcl | _darwinONoFollow;/return _darwinOWronly | _darwinOCreat;/' \
  lib/src/http/partial_file_writer_posix.dart
printf '%-22s' "exclusive"
expect_fail "exclusive" lib/src/http/partial_file_writer_posix.dart \
  test/k2_security_regressions_test.dart "K2 O_NOFOLLOW exclusive open refuses symlink partial target"

# 8) pre-commit symlink
sed_inplace '69s/if (!inspection.isSafeRegularFileOwnedByUs)/if (false)/' \
  lib/src/http/partial_path_guard.dart
printf '%-22s' "pre-commit"
expect_fail "pre-commit" lib/src/http/partial_path_guard.dart \
  test/k2_security_regressions_test.dart "K2 pre-commit refuses symlink partial"

# 9) connect timeout
sed_inplace 's/client.connectionTimeout = _connectionTimeout;/client.connectionTimeout = null;/' \
  lib/src/http_background_downloads.dart
printf '%-22s' "connect timeout"
expect_fail "connect timeout" lib/src/http_background_downloads.dart \
  test/k2_security_regressions_test.dart "K2 connection timeout fails unreachable host quickly"

# 10) fd-level nlink (independent of path guard)
sed_inplace 's/if (stat.linkCount != 1)/if (false)/' lib/src/http/partial_file_writer_posix.dart
printf '%-22s' "fd nlink"
expect_fail "fd nlink" lib/src/http/partial_file_writer_posix.dart \
  test/partial_file_writer_fd_guard_test.dart "fd-level nlink check rejects hardlinked inode"

# 11) fd-level owner
sed_inplace 's/if (stat.ownerUid != currentUid)/if (false)/' lib/src/http/partial_file_writer_posix.dart
printf '%-22s' "fd owner"
expect_fail "fd owner" lib/src/http/partial_file_writer_posix.dart \
  test/partial_file_writer_fd_guard_test.dart "fd-level owner check rejects foreign uid"

# 12) fd-level identity
sed_inplace 's/if (expectedIdentity != null && !expectedIdentity.matches(stat))/if (false)/' \
  lib/src/http/partial_file_writer_posix.dart
printf '%-22s' "fd identity"
expect_fail "fd identity" lib/src/http/partial_file_writer_posix.dart \
  test/partial_file_writer_fd_guard_test.dart "fd-level identity check rejects changed dev/ino"

# 13) openVerified write path (K1 integration)
matrix_track lib/src/http/partial_path_guard.dart lib/src/http/partial_file_writer_posix.dart
python3 - <<'PY'
from pathlib import Path
p = Path("lib/src/http/partial_path_guard.dart")
text = p.read_text()
sanitize_old = """  void _sanitizeOne(String path) {
    final inspection = _io.inspectPath(path);
    if (inspection.isAbsent) return;
    if (inspection.isSafeRegularFileOwnedByUs) return;
    _io.unlinkPartialEntry(path);
  }"""
sanitize_new = """  void _sanitizeOne(String path) {
    final inspection = _io.inspectPath(path);
    if (inspection.isAbsent) return;
    if (inspection.isSafeRegularFileOwnedByUs) return;
  }"""
bytes_old = """  int reusablePartialBytes(String partialPath) {
    final inspection = _io.inspectPath(partialPath);
    if (!inspection.isSafeRegularFileOwnedByUs) {
      if (!inspection.isAbsent) {
        _io.unlinkPartialEntry(partialPath);
      }
      return 0;
    }
    final size = platformPathFileSize(partialPath);
    if (size == null || size < 0) {
      // Keep the partial when lstat size is unavailable (macOS libc 0600);
      // resume byte count may still come from `.meta`.
      return 0;
    }
    return size;
  }"""
bytes_new = """  int reusablePartialBytes(String partialPath) {
    if (_io.inspectPath(partialPath).isAbsent) return 0;
    final size = platformPathFileSize(partialPath);
    return size ?? 0;
  }"""
for label, old, new in (
    ("sanitize", sanitize_old, sanitize_new),
    ("reusablePartialBytes", bytes_old, bytes_new),
):
    if old not in text:
        raise SystemExit(f"revert_matrix: {label} block not found")
    text = text.replace(old, new, 1)
p.write_text(text)
PY
sed_inplace 's/if (stat.linkCount != 1)/if (false)/' lib/src/http/partial_file_writer_posix.dart
printf '%-22s' "openVerified (K1)"
if run_test test/http_background_downloads_blockers_test.dart "K1 hardlinked partial with validator"; then
  git checkout -- lib/src/http/partial_path_guard.dart lib/src/http/partial_file_writer_posix.dart
  fail "openVerified: test still passed after revert"
fi
git checkout -- lib/src/http/partial_path_guard.dart lib/src/http/partial_file_writer_posix.dart
echo "Yes"

# 14) E1 variadic open mode (0600 partial create)
matrix_track lib/src/http/partial_file_writer_posix.dart
if $IS_MAC; then
  matrix_track lib/src/http/posix_variadic.dart
  sed_inplace 's/VarArgs<(Int32,)>/Int32/' lib/src/http/posix_variadic.dart
  sed_inplace 's/int flags, \[int mode\]/int flags, int mode/' lib/src/http/posix_variadic.dart
else
  sed_inplace 's/mode: 384/mode: 0/' lib/src/http/partial_file_writer_posix.dart
fi
printf '%-22s' "E1 open mode 0600"
if run_test test/partial_file_mode_test.dart "exclusive partial create uses mode 0600"; then
  git checkout -- lib/src/http/posix_variadic.dart lib/src/http/partial_file_writer_posix.dart 2>/dev/null || true
  git checkout -- lib/src/http/partial_file_writer_posix.dart
  fail "E1 open mode: test still passed after revert"
fi
git checkout -- lib/src/http/posix_variadic.dart lib/src/http/partial_file_writer_posix.dart 2>/dev/null || true
git checkout -- lib/src/http/partial_file_writer_posix.dart
echo "Yes"

# 15) E2 never chmod foreign parent dirs
python3 - <<'PY'
from pathlib import Path
p = Path("lib/src/http/download_directory_guard.dart")
text = p.read_text()
old = """  if (!destParent.existsSync()) {
    destParent.createSync(recursive: true);
  }

  final paths = PartialStoragePaths.forDestination(destinationPath);"""
new = """  if (!destParent.existsSync()) {
    destParent.createSync(recursive: true);
  }
  destParent.setModeSync(448);

  final paths = PartialStoragePaths.forDestination(destinationPath);"""
if old not in text:
    raise SystemExit("revert_matrix: E2 anchor not found")
p.write_text(text.replace(old, new, 1))
PY
printf '%-22s' "E2 parent chmod"
expect_fail "E2 parent chmod" lib/src/http/download_directory_guard.dart \
  test/download_directory_guard_test.dart "does not chmod an existing 0755 parent directory"

# 16) E3 temp-root bypass removed
python3 - <<'PY'
from pathlib import Path
p = Path("lib/src/http/download_directory_guard.dart")
text = p.read_text()
needle = "void ensurePrivatePartialStorage(String destinationPath) {"
insert = """void ensurePrivatePartialStorage(String destinationPath) {
  final _parentPath = File(destinationPath).parent.path;
  if (_parentPath == '/tmp' || _parentPath == Directory.systemTemp.path) {
    return;
  }"""
if needle not in text:
    raise SystemExit("revert_matrix: E3 anchor not found")
text = text.replace(needle, insert, 1)
p.write_text(text)
PY
printf '%-22s' "E3 temp private"
expect_fail "E3 temp private" lib/src/http/download_directory_guard.dart \
  test/download_directory_guard_test.dart "system temp destination uses private .airo_partials leaf"

# 17) F1 — 200 to Range must not append (macOS tail splice)
sed_inplace 's/final parsedRange = parse/var parsedRange = parse/' \
  lib/src/http_background_downloads.dart
python3 - <<'PY'
from pathlib import Path
p = Path("lib/src/http_background_downloads.dart")
text = p.read_text()
anchor = "      if (resumeOffset > 0 && !append) {"
insert = """      if (!append &&
          maySendRange &&
          resumeOffset > 0 &&
          response.statusCode == HttpStatus.ok &&
          job.request.expectedBytes != null) {
        final tailBytes = job.request.expectedBytes! - resumeOffset;
        final responseLen = _normalizedContentLength(response);
        if (tailBytes > 0 && responseLen == tailBytes) {
          parsedRange = ContentRangeSpec(
            start: resumeOffset,
            end: job.request.expectedBytes! - 1,
            total: job.request.expectedBytes,
          );
          append = true;
        }
      }

      if (resumeOffset > 0 && !append) {"""
if anchor not in text:
    raise SystemExit("revert_matrix: F1 anchor not found")
p.write_text(text.replace(anchor, insert, 1))
PY
printf '%-22s' "F1 range 200 splice"
expect_fail "F1 range 200 splice" lib/src/http_background_downloads.dart \
  test/http_background_downloads_blockers_test.dart "F1 200 response to Range request never splices"

# 18) G1 — synthetic Content-Range for 206 without header (must fail on all POSIX CI)
sed_inplace 's/final parsedRange = parse/var parsedRange = parse/' \
  lib/src/http_background_downloads.dart
python3 - <<'PY'
from pathlib import Path
p = Path("lib/src/http_background_downloads.dart")
text = p.read_text()
anchor = """      var parsedRange = parseContentRangeHeader(
        response.headers.value(HttpHeaders.contentRangeHeader),
      );

      var append ="""
insert = """      var parsedRange = parseContentRangeHeader(
        response.headers.value(HttpHeaders.contentRangeHeader),
      );
      if (parsedRange == null) {
        parsedRange = _syntheticContentRangeFor206(
          response: response,
          resumeOffset: resumeOffset,
          expectedBytes: job.request.expectedBytes,
        );
      }

      var append ="""
if anchor not in text:
    raise SystemExit("revert_matrix: G1 anchor not found")
text = text.replace(anchor, insert, 1)
method = """
  ContentRangeSpec? _syntheticContentRangeFor206({
    required HttpClientResponse response,
    required int resumeOffset,
    required int? expectedBytes,
  }) {
    if (response.statusCode != HttpStatus.partialContent) return null;
    if (resumeOffset <= 0 || expectedBytes == null) return null;
    final total = expectedBytes;
    final len = _normalizedContentLength(response);
    if (len != null && len > 0) {
      final segmentLen = len == total ? total - resumeOffset : len;
      if (segmentLen > 0 && resumeOffset + segmentLen == total) {
        return ContentRangeSpec(
          start: resumeOffset,
          end: total - 1,
          total: total,
        );
      }
    }
    return ContentRangeSpec(
      start: resumeOffset,
      end: total - 1,
      total: total,
    );
  }

"""
needle = "  void _recordResumeCapability(_HttpDownloadJob job, HttpClientResponse response) {"
if needle not in text:
    raise SystemExit("revert_matrix: G1 method anchor not found")
if "ContentRangeSpec? _syntheticContentRangeFor206" in text:
    raise SystemExit("revert_matrix: synthesis method already present")
text = text.replace(needle, method + needle, 1)
p.write_text(text)
PY
printf '%-22s' "G1 206 synth CR"
expect_fail "G1 206 synth CR" lib/src/http_background_downloads.dart \
  test/http_background_downloads_blockers_test.dart "G1 206 without Content-Range refuses resume splice"

# 19) HTTPS→HTTP redirect must be refused
sed_inplace 's/if (target.scheme.toLowerCase() != '\''https'\'')/if (false)/' \
  lib/src/http/secure_http_fetch.dart
printf '%-22s' "redirect downgrade"
expect_fail "redirect downgrade" lib/src/http/secure_http_fetch.dart \
  test/http_redirect_and_commit_security_test.dart \
  "K2 HTTPS to HTTP redirect is refused and destination is not committed"

# 20) Custom headers only on original origin
sed_inplace 's/if (httpSameOrigin(current, originalSource))/if (true)/' \
  lib/src/http/secure_http_fetch.dart
printf '%-22s' "redirect headers"
expect_fail "redirect headers" lib/src/http/secure_http_fetch.dart \
  test/http_redirect_and_commit_security_test.dart \
  "K2 cross-host HTTPS redirect never sends X-Api-Key to CDN"

# 21) Stored partial identity at commit (not fresh lstat only)
python3 - <<'PY'
from pathlib import Path
p = Path("lib/src/http_background_downloads.dart")
text = p.read_text()
old = """    PartialFileIdentity? storedIdentity;
    if (Platform.isLinux || Platform.isMacOS) {
      storedIdentity = await validatorStore.readPartialIdentityFor(request);
      if (storedIdentity == null) {
        throw FileSystemException(
          'Missing stored partial identity for commit',
          partial.path,
        );
      }
    }
    await _partialFileIo.syncFile(
      partial.path,
      expectedIdentityAtReopen: storedIdentity,
    );
    if (Platform.isLinux || Platform.isMacOS) {
      posixFchmodAndSyncBeforeRename(
        partial.path,
        expectedIdentity: storedIdentity!,
      );
    }"""
new = """    await _partialFileIo.syncFile(partial.path);
    if (Platform.isLinux || Platform.isMacOS) {
      final inspection = _partialFileIo.inspectPath(partial.path);
      final fresh = inspection.identity;
      if (fresh != null) {
        posixFchmodAndSyncBeforeRename(
          partial.path,
          expectedIdentity: fresh,
        );
      }
    }"""
if old not in text:
    raise SystemExit("revert_matrix: commit identity anchor not found")
p.write_text(text.replace(old, new, 1))
PY
printf '%-22s' "commit identity"
expect_fail "commit identity" lib/src/http_background_downloads.dart \
  test/http_redirect_and_commit_security_test.dart \
  "K2 swap before commit refuses attacker bytes despite SHA pin"

# 22) Close error must not mask action failure
sed_inplace 's/if (actionError == null)/if (true)/' lib/src/http/posix_variadic.dart
printf '%-22s' "close error mask"
expect_fail "close error mask" lib/src/http/posix_variadic.dart \
  test/http_redirect_and_commit_security_test.dart \
  "checked close keeps action error when close fails"

# 23) umask probe (no libc umask mutation on macOS / Linux fallback)
if $IS_MAC; then
  python3 - <<'PY'
from pathlib import Path
p = Path("lib/src/http/posix_variadic.dart")
text = p.read_text()
old = "  _cachedProcessUmask = _probeProcessUmaskViaExclusiveCreate();"
new = """  final umaskFn = posixLib().lookupFunction<
      Int32 Function(Int32),
      int Function(int)>('umask');
  final previous = umaskFn(0);
  umaskFn(previous);
  _cachedProcessUmask = previous & 511;"""
if old not in text:
    raise SystemExit("revert_matrix: umask probe anchor not found")
p.write_text(text.replace(old, new, 1))
PY
  printf '%-22s' "umask probe"
  expect_fail "umask probe" lib/src/http/posix_variadic.dart \
    test/http_redirect_and_commit_security_test.dart \
    "posixCurrentUmask uses exclusive-create probe on macOS"
else
  skip_row "umask probe"
fi

# 24) empty partial storage cleanup must be best-effort (never block terminal events)
matrix_track lib/src/http/partial_storage_cleanup.dart
python3 - <<'PY'
from pathlib import Path
p = Path("lib/src/http/partial_storage_cleanup.dart")
text = p.read_text()
old = """void tryRemoveEmptyPartialStorageDirectory(String destinationPath) {
  try {
    final override = removeEmptyPartialStorageOverrideForTest;
    if (override != null) {
      override(destinationPath);
      return;
    }
    _removeEmptyPartialStorageDirectoryImpl(destinationPath);
  } on FileSystemException {
    // Best effort — ignore AV locks, read-only parents, concurrent mkdir races, etc.
  }
}"""
new = """void tryRemoveEmptyPartialStorageDirectory(String destinationPath) {
  final override = removeEmptyPartialStorageOverrideForTest;
  if (override != null) {
    override(destinationPath);
    return;
  }
  _removeEmptyPartialStorageDirectoryImpl(destinationPath);
}"""
if old not in text:
    raise SystemExit("revert_matrix: cleanup best-effort anchor not found")
p.write_text(text.replace(old, new, 1))
PY
printf '%-22s' "cleanup best-effort"
expect_fail "cleanup best-effort" lib/src/http/partial_storage_cleanup.dart \
  test/partial_storage_cleanup_test.dart \
  "terminal failed event is emitted when empty-dir cleanup throws"

# 25) shared partial storage lease must block empty-dir cleanup for active siblings
matrix_track lib/src/http_background_downloads.dart lib/src/http/partial_storage_lease.dart
python3 - <<'PY'
from pathlib import Path
p = Path("lib/src/http_background_downloads.dart")
text = p.read_text()
old_acquire = "    acquirePartialStorageLease(destination.path);\n\n    try {"
if old_acquire not in text:
    raise SystemExit("revert_matrix: partial storage lease acquire anchor not found")
text = text.replace(old_acquire, "    try {", 1)
if "partial_storage_cleanup.dart" not in text:
    text = text.replace(
        "import 'http/partial_storage_lease.dart';",
        "import 'http/partial_storage_cleanup.dart';\nimport 'http/partial_storage_lease.dart';",
        1,
    )
old_finally = """    } finally {
      releasePartialStorageLeaseAndMaybeCleanup(destination.path);
      client.close(force: true);"""
new_finally = """    } finally {
      client.close(force: true);"""
if old_finally not in text:
    raise SystemExit("revert_matrix: partial storage lease finally anchor not found")
text = text.replace(old_finally, new_finally, 1)
old_success = """      _jobs.remove(job.request.artifactId);
    } on Object catch (error) {"""
new_success = """      _jobs.remove(job.request.artifactId);
      tryRemoveEmptyPartialStorageDirectory(destination.path);
    } on Object catch (error) {"""
if old_success not in text:
    raise SystemExit("revert_matrix: partial storage success cleanup anchor not found")
text = text.replace(old_success, new_success, 1)
old_catch = """      _emit(job.snapshot());
    } finally {
      client.close(force: true);"""
new_catch = """      _emit(job.snapshot());
      tryRemoveEmptyPartialStorageDirectory(destination.path);
    } finally {
      client.close(force: true);"""
if old_catch not in text:
    raise SystemExit("revert_matrix: partial storage failure cleanup anchor not found")
text = text.replace(old_catch, new_catch, 1)
p.write_text(text)
Path("lib/src/http/partial_storage_lease.dart").write_text(
    """import 'partial_storage_cleanup.dart';

void acquirePartialStorageLease(String destinationPath) {}

void releasePartialStorageLeaseAndMaybeCleanup(String destinationPath) {
  tryRemoveEmptyPartialStorageDirectory(destinationPath);
}

int partialStorageLeaseCountForDestination(String destinationPath) => 0;

void resetPartialStorageLeasesForTest() {}
"""
)
PY
printf '%-22s' "partial storage lease"
expect_fail "partial storage lease" lib/src/http/partial_storage_lease.dart \
  test/partial_storage_cleanup_test.dart \
  "failed sibling keeps shared partial storage while another job is mid-request"

# 26) ensurePrivatePartialStorage must run immediately before partial open
matrix_track lib/src/http_background_downloads.dart
python3 - <<'PY'
from pathlib import Path
p = Path("lib/src/http_background_downloads.dart")
text = p.read_text()
old = """      if (beforeOpen != null) {
        await beforeOpen(job.request.artifactId);
      }
      ensurePrivatePartialStorage(job.request.destinationPath);

      late final PartialFileWriter writer;"""
new = """      if (beforeOpen != null) {
        await beforeOpen(job.request.artifactId);
      }

      late final PartialFileWriter writer;"""
if old not in text:
    raise SystemExit("revert_matrix: pre-open ensure anchor not found")
p.write_text(text.replace(old, new, 1))
PY
printf '%-22s' "pre-open ensure"
expect_fail "pre-open ensure" lib/src/http_background_downloads.dart \
  test/partial_storage_cleanup_test.dart \
  "sibling completes after shared partial storage removed mid-request"

# 27) mkdir retry loop must tolerate empty-dir removal races
matrix_track lib/src/http/download_directory_guard.dart
python3 - <<'PY'
from pathlib import Path
p = Path("lib/src/http/download_directory_guard.dart")
text = p.read_text()
old = """  if (type == FileSystemEntityType.notFound) {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (Directory(directoryPath).existsSync()) {
        break;
      }
      final result = posixMkdir(directoryPath, _privateDirMode);
      if (result == 0 || Directory(directoryPath).existsSync()) {
        break;
      }
      if (attempt == 2) {
        throw FileSystemException(
          'Cannot create partial storage directory',
          directoryPath,
        );
      }
    }
  }"""
new = """  if (type == FileSystemEntityType.notFound) {
    if (Directory(directoryPath).existsSync()) {
      // ok
    } else {
      final result = posixMkdir(directoryPath, _privateDirMode);
      if (result != 0 && !Directory(directoryPath).existsSync()) {
        throw FileSystemException(
          'Cannot create partial storage directory',
          directoryPath,
        );
      }
    }
  }"""
if old not in text:
    raise SystemExit("revert_matrix: mkdir retry anchor not found")
p.write_text(text.replace(old, new, 1))
PY
printf '%-22s' "mkdir retry"
expect_fail "mkdir retry" lib/src/http/download_directory_guard.dart \
  test/partial_storage_cleanup_test.dart \
  "ensurePrivatePartialStorage retries mkdir after a lost create race"

echo "Done."
matrix_restore_touched
matrix_verify_clean
