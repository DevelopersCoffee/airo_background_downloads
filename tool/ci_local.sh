#!/usr/bin/env bash
# Local substitute when GitHub Actions is unavailable. Mirrors .github/workflows/ci.yml
# on this host (Linux/macOS: includes revert matrix; Windows: tests only).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> flutter pub get"
flutter pub get

echo "==> flutter analyze"
flutter analyze

echo "==> flutter test"
flutter test

UNAME="$(uname -s)"
if [[ "$UNAME" == "Linux" || "$UNAME" == "Darwin" ]]; then
  echo "==> revert matrix (POSIX)"
  ./tool/revert_matrix.sh
  git checkout -- .
  echo "==> restored working tree after revert matrix"
else
  echo "==> skip revert matrix (host=$UNAME; run on Linux or macOS)"
fi

echo "==> ci_local: OK"
