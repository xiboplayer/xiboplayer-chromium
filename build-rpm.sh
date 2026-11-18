#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2024-2026 Pau Aliagas <linuxnow@gmail.com>
# Build xiboplayer-chromium RPM package (self-contained with bundled PWA)
# Usage: ./build-rpm.sh [version] [release]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${PKG_LIB_RPM:-${SCRIPT_DIR}/scripts/packaging/lib-rpm.sh}"

PKG_NAME="xiboplayer-chromium"
VERSION="${1:-0.7.23}"
RELEASE="${2:-1}"

echo "==> Building ${PKG_NAME}-${VERSION}-${RELEASE} RPM (self-contained)"

if ! command -v rpmbuild &>/dev/null; then
    echo "ERROR: rpmbuild not found. Install: sudo dnf install rpm-build"
    exit 1
fi
if ! command -v node &>/dev/null; then
    echo "ERROR: node not found. Install: sudo dnf install nodejs"
    exit 1
fi

BUILD_ROOT="${SCRIPT_DIR}/_rpmbuild"
rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

# ── Create source tarball ─────────────────────────────────────────────
echo "==> Creating source tarball..."
SRC_DIR="${BUILD_ROOT}/SOURCES/${PKG_NAME}-${VERSION}"
mkdir -p "$SRC_DIR/server"

cp "$SCRIPT_DIR/xiboplayer/launch-kiosk.sh" "$SRC_DIR/"
cp "$SCRIPT_DIR/xiboplayer/config.json" "$SRC_DIR/"
cp "$SCRIPT_DIR/xiboplayer/xiboplayer-chromium.service" "$SRC_DIR/"
cp "$SCRIPT_DIR/xiboplayer/xiboplayer-chromium.desktop" "$SRC_DIR/"
cp "$SCRIPT_DIR/xiboplayer/xiboplayer.png" "$SRC_DIR/"
cp "$SCRIPT_DIR/xiboplayer/server/server.js" "$SRC_DIR/server/"
cp "$SCRIPT_DIR/xiboplayer/server/package.json" "$SRC_DIR/server/"
cp "$SCRIPT_DIR/xiboplayer/config.json.example" "$SRC_DIR/"
cp "$SCRIPT_DIR/CONFIG.md" "$SRC_DIR/"
cp "$SCRIPT_DIR/README.md" "$SRC_DIR/"
cp -r "$SCRIPT_DIR/configs" "$SRC_DIR/"

cd "${BUILD_ROOT}/SOURCES"
tar czf "${PKG_NAME}-${VERSION}.tar.gz" "${PKG_NAME}-${VERSION}"
rm -rf "${PKG_NAME}-${VERSION}"

# Copy spec with version substitution
sed -e "s/^Version:.*/Version:        ${VERSION}/" \
    "$SCRIPT_DIR/xiboplayer-chromium.spec" \
    > "$BUILD_ROOT/SPECS/${PKG_NAME}.spec"

echo "==> Running rpmbuild..."
rpmbuild \
    --define "_topdir $BUILD_ROOT" \
    -ba "$BUILD_ROOT/SPECS/${PKG_NAME}.spec"

# ── Collect and display results ───────────────────────────────────────
DIST_DIR="${SCRIPT_DIR}/dist"
pkg_collect_rpms "$BUILD_ROOT"
pkg_show_result_rpm

rm -rf "$BUILD_ROOT"
