# Local CI/CD for airo_background_downloads (use when GitHub Actions is unavailable).
# Install: https://github.com/casey/just — e.g. `cargo install just` or your package manager.
#
# Common:
#   just              # same as `just ci`
#   just ci           # pub get, analyze, test, revert matrix (POSIX only)
#   just publish-dry  # validate package before pub.dev upload
#   just publish      # pub.dev upload (requires `dart pub token add https://pub.dev`)

default: ci

# --- dependencies & checks ---

get:
    flutter pub get

analyze:
    flutter analyze

test:
    flutter test

# Revert security guards one-at-a-time; restores working tree after (see tool/revert_matrix.sh).
matrix:
    #!/usr/bin/env bash
    set -euo pipefail
    case "$(uname -s)" in
      Linux|Darwin)
        ./tool/revert_matrix.sh
        git checkout -- .
        ;;
      *)
        echo "skip revert matrix on $(uname -s) (run on Linux or macOS)"
        ;;
    esac

# Full local CI (mirrors .github/workflows/ci.yml on this host).
ci: get analyze test matrix

# Analyze + tests only (handy on Windows or quick checks).
ci-core: get analyze test

# --- pub.dev ---

publish-dry:
    flutter pub publish --dry-run

# Requires: dart pub token add https://pub.dev  (upload token for this package)
publish:
    flutter pub publish --force

verify-pub version="1.2.1":
    #!/usr/bin/env bash
    set -euo pipefail
    got="$(curl -fsSL 'https://pub.dev/api/packages/airo_background_downloads' | python3 -c "import sys,json; print(json.load(sys.stdin)['latest']['version'])")"
    if [[ "$got" != "{{version}}" ]]; then
      echo "pub.dev latest=$got expected={{version}}" >&2
      exit 1
    fi
    echo "pub.dev latest={{version}} OK"

# --- git release helpers (optional; no GitHub Actions required) ---

tag version:
    git tag "v{{version}}"
    git push origin "v{{version}}"
