#!/bin/bash

# Both arches pkg-add 1password. Apple Silicon still wraps the binary for
# software GL from this installer (the menu calls it) and from the hardware leaf.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

installer="$ROOT/bin/omarchy-install-service-1password"
grep -Fq 'omarchy-pkg-add 1password 1password-cli' "$installer" ||
  fail "1Password installs from the repos on every architecture"
! grep -Fq 'downloads.1password.com/linux/tar' "$installer" ||
  fail "1Password no longer unpacks the aarch64 tarball"
! grep -Fq 'remove_aarch64_tarball' "$installer" ||
  fail "1Password installer does not clean unpackaged tarball paths"
grep -Fq 'install_chromium_extension' "$installer" ||
  fail "1Password still installs the Chromium extension"
grep -Fq 'wrap_1password_for_agx' "$installer" ||
  fail "1Password still wraps the packaged binary for software GL"
grep -Fq '1password' "$ROOT/packages/omarchy-mac/lib/electron-launchers" ||
  fail "Apple Silicon still wraps 1Password for software GL"
pass "1Password uses pkg-add and keeps the Chromium extension and AGX wrap"
