#!/bin/bash
set -euo pipefail

JULIA_VERSION="$1"
JULIA_PREFIX="$2"
INSTALL_DIR="${JULIA_PREFIX}"
JULIA_ARCHIVE="julia-$JULIA_VERSION-linux-x86_64.tar.gz"

JULIA_MINOR_VERSION=$(echo "$JULIA_VERSION" | cut -d. -f1,2)
JULIA_URL="https://julialang-s3.julialang.org/bin/linux/x64/${JULIA_MINOR_VERSION}/$JULIA_ARCHIVE"

echo "=============================="
echo "⬇️ Downloading Julia $JULIA_VERSION"
echo "=============================="

if [ -f "$JULIA_ARCHIVE" ]; then
    echo "📦 Julia archive already downloaded."
else
    wget "$JULIA_URL"
fi

echo "=============================="
echo "🧹 Removing previous Julia installation if it exists"
echo "=============================="

if [[ -d "$INSTALL_DIR" && ! -w "$INSTALL_DIR" ]]; then
    echo "🔐 Using sudo to remove $INSTALL_DIR"
    sudo rm -rf "$INSTALL_DIR"
else
    rm -rf "$INSTALL_DIR"
fi

echo "=============================="
echo "📦 Extracting Julia archive"
echo "=============================="

if [[ ! -w $(dirname "$INSTALL_DIR") ]]; then
    echo "🔐 $INSTALL_DIR not writable, using sudo for extraction"
    sudo mkdir -p "$INSTALL_DIR"
    sudo tar -xzf "$JULIA_ARCHIVE" -C "$INSTALL_DIR" --strip-components=1
    sudo chown -R "$USER:$USER" "$INSTALL_DIR"
else
    mkdir -p "$INSTALL_DIR"
    tar -xzf "$JULIA_ARCHIVE" -C "$INSTALL_DIR" --strip-components=1
fi

echo "=============================="
echo "✅ Julia $JULIA_VERSION installed at $INSTALL_DIR"
echo "=============================="

echo "=============================="
echo "📌 Adding Julia to PATH in ~/.bashrc"
echo "=============================="

JULIA_BIN_PATH="$INSTALL_DIR/bin"

# Avoid duplicate entries
if ! grep -q "$JULIA_BIN_PATH" ~/.bashrc 2>/dev/null; then
    {
        echo ""
        echo "# Added by Julia install script"
        echo "export PATH=\"$JULIA_BIN_PATH:\$PATH\""
    } >> ~/.bashrc
    echo "✅ Julia path added to ~/.bashrc"
else
    echo "⚠️ Julia path already present in ~/.bashrc, skipping..."
fi

echo "👉 To apply the changes, run: source ~/.bashrc"

