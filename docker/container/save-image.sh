#!/bin/bash
set -euo pipefail
# save-image.sh
#
# Usage: save-image.sh <image:tag> <out.tar.gz>
#
# Shared by the three docker-build.sh (api, db, daemon): saves an image as a
# gzip-compressed tarball for docker/deploy/images/. Nothing uncompressed
# ever lands on disk - `docker save` is streamed straight into gzip.
#
# Loading needs no extra step: `docker load -i <out.tar.gz>` reads gzip
# natively (deploy.sh does exactly that), and `gunzip -k <out.tar.gz>` gives
# back the plain `docker save` tarball if ever needed.
#
# Next to it goes <out.tar.gz>.ids: the image's tag (line 1) and the image
# IDs it can have once loaded (following lines), the same values deploy.sh's
# tar_image_tag/tar_image_ids would read from the tarball's index.json and
# manifest.json. In a .tar.gz those sit at the very end of the stream, so
# reading them there means decompressing GBs on every deploy - the sidecar
# lets deploy.sh tell "already loaded" instantly.
#
# Written atomically (.part + mv): a failed save (e.g. disk full) never
# leaves a truncated tarball deploy.sh would try to load. A legacy
# uncompressed <name>.tar next to it is removed once the new one is in place.

if [ $# -ne 2 ]; then
    echo "Usage: $0 <image:tag> <out.tar.gz>" >&2
    exit 1
fi
IMAGE="$1"
OUT="$2"
case "$OUT" in
    *.tar.gz) ;;
    *) echo "❌ $0: output must end in .tar.gz: $OUT" >&2; exit 1 ;;
esac
OUT_DIR=$(dirname -- "$OUT")
LEGACY_TAR="${OUT%.gz}"

# pigz (parallel gzip) when available - same format, several times faster
# on multi-GB images; plain gzip otherwise.
if command -v pigz >/dev/null 2>&1; then
    GZIP_CMD=(pigz)
else
    GZIP_CMD=(gzip)
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; rm -f "$OUT.part" "$OUT.ids.part"' EXIT

# The tarball's index.json/manifest.json are pulled out of the same stream
# through a FIFO (a backgrounded reader we can `wait` for - unlike >(...)).
# `cat >/dev/null` drains the rest, so a tar that stops reading early can't
# make tee fail with SIGPIPE.
mkfifo "$TMP/stream"
( tar -xf - -C "$TMP" index.json manifest.json 2>/dev/null || true; cat >/dev/null ) < "$TMP/stream" &
meta_pid=$!

echo "Saving $IMAGE to $OUT (${GZIP_CMD[0]})..."
if ! docker save "$IMAGE" | tee "$TMP/stream" | "${GZIP_CMD[@]}" > "$OUT.part"; then
    wait "$meta_pid" || true
    echo "❌ docker save failed - no tarball written. Free space on that drive:" >&2
    df -h "$OUT_DIR" >&2 || true
    exit 1
fi
wait "$meta_pid" || true

# Same extraction as deploy.sh's tar_image_tag / tar_image_ids.
{
    grep -o '"RepoTags":\["[^"]*"' "$TMP/manifest.json" 2>/dev/null | head -n1 | sed 's/.*\["//; s/"$//' || true
    { grep -o '"digest":"sha256:[0-9a-f]*"' "$TMP/index.json" 2>/dev/null | head -n1
      grep -o '"Config":"[^"]*"' "$TMP/manifest.json" 2>/dev/null
    } | grep -o '[0-9a-f]\{64\}' || true
} > "$OUT.ids.part"

mv -f "$OUT.ids.part" "$OUT.ids"
mv -f "$OUT.part" "$OUT"
if [ -f "$LEGACY_TAR" ]; then
    echo "Removing the old uncompressed $(basename -- "$LEGACY_TAR")."
    rm -f "$LEGACY_TAR"
fi
echo "Saved $(du -h "$OUT" | awk '{print $1}') -> $OUT"
