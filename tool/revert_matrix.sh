#!/usr/bin/env bash
# Revert one security guard at a time; the paired test must FAIL (non-zero exit).
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$PWD"
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

echo "Revert matrix (each row must fail its test when guard is reverted):"
printf '%-22s' "Row"
echo "Revert-proof"

# 1) nlink
sed -i 's/linkCount == 1/linkCount != null/' lib/src/http/partial_file_io.dart
printf '%-22s' "K1/nlink"
expect_fail "nlink" lib/src/http/partial_file_io.dart \
  test/k2_security_regressions_test.dart "K2 nlink>1 partial is not safe"

# 2) owner
sed -i 's/ownedByUs &&/true \&\&/' lib/src/http/partial_file_io.dart
printf '%-22s' "owner"
expect_fail "owner" lib/src/http/partial_file_io.dart \
  test/k2_security_regressions_test.dart "K2 foreign owner partial is not safe"

# 3) dir fsync result
sed -i 's/if (result != 0)/if (false)/' lib/src/http/partial_file_io_posix.dart
printf '%-22s' "dir fsync"
expect_fail "dir fsync" lib/src/http/partial_file_io_posix.dart \
  test/posix_syscalls_revert_test.dart "K2 injected fsync -1 fails closed"

# 4) dir open failure
sed -i 's/if (fd < 0)/if (false)/' lib/src/http/partial_file_io_posix.dart
printf '%-22s' "dir open"
expect_fail "dir open" lib/src/http/partial_file_io_posix.dart \
  test/posix_syscalls_revert_test.dart "K2 injected open -1 fails closed"

# 5) size cap
sed -i 's/if (nextTotalBytes > cap)/if (false)/' lib/src/http_background_downloads.dart
printf '%-22s' "size cap"
expect_fail "size cap" lib/src/http_background_downloads.dart \
  test/k2_security_regressions_test.dart "K2 download size cap rejects oversized body"

# 6) meta identity
sed -i 's/if (record.source != request.source.toString()) return false;/if (false) return false;/' \
  lib/src/http/resume_validator_store.dart
printf '%-22s' "meta"
expect_fail "meta" lib/src/http/resume_validator_store.dart \
  test/k2_security_regressions_test.dart "K2 mismatched meta identity blocks resume validator reuse"

# 7) exclusive O_NOFOLLOW
sed -i 's/return _linuxOWronly | _linuxOCreat | _linuxOExcl | _linuxONoFollow;/return _linuxOWronly | _linuxOCreat;/' \
  lib/src/http/partial_file_writer_posix.dart
sed -i 's/return _darwinOWronly | _darwinOCreat | _darwinOExcl | _darwinONoFollow;/return _darwinOWronly | _darwinOCreat;/' \
  lib/src/http/partial_file_writer_posix.dart
printf '%-22s' "exclusive"
expect_fail "exclusive" lib/src/http/partial_file_writer_posix.dart \
  test/k2_security_regressions_test.dart "K2 O_NOFOLLOW exclusive open refuses symlink partial target"

# 8) pre-commit symlink (line-specific; other guards share the same condition)
sed -i '52s/if (!inspection.isSafeRegularFileOwnedByUs)/if (false)/' \
  lib/src/http/partial_path_guard.dart
printf '%-22s' "pre-commit"
expect_fail "pre-commit" lib/src/http/partial_path_guard.dart \
  test/k2_security_regressions_test.dart "K2 pre-commit refuses symlink partial"

# 9) connect timeout
sed -i 's/client.connectionTimeout = _connectionTimeout;/client.connectionTimeout = null;/' \
  lib/src/http_background_downloads.dart
printf '%-22s' "connect timeout"
expect_fail "connect timeout" lib/src/http_background_downloads.dart \
  test/k2_security_regressions_test.dart "K2 connection timeout fails unreachable host quickly"

# 10) openVerified write path (K1): verified open + sanitize must block hardlink resume
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
    return File(partialPath).lengthSync();
  }"""
bytes_new = """  int reusablePartialBytes(String partialPath) {
    if (_io.inspectPath(partialPath).isAbsent) return 0;
    return File(partialPath).lengthSync();
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
sed -i 's/if (stat.linkCount != 1)/if (false)/' lib/src/http/partial_file_writer_posix.dart
printf '%-22s' "openVerified (K1)"
if run_test test/http_background_downloads_blockers_test.dart "K1 hardlinked partial with validator"; then
  git checkout -- lib/src/http/partial_path_guard.dart lib/src/http/partial_file_writer_posix.dart
  fail "openVerified: test still passed after revert"
fi
git checkout -- lib/src/http/partial_path_guard.dart lib/src/http/partial_file_writer_posix.dart
echo "Yes"

echo "Done."
