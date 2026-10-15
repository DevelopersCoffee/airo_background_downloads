#!/usr/bin/env bash
# Revert one security guard at a time; the paired test must FAIL (non-zero exit).
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "MATRIX ERROR: $*" >&2; exit 1; }

run_test() {
  flutter test "$1" --name "$2" >/dev/null 2>&1
}

expect_fail() {
  local label="$1"
  local file="$2"
  local test_file="$3"
  local test_name="$4"
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
  exit 0
fi

# 1) nlink (path)
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
if $IS_MAC; then
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

echo "Done."
