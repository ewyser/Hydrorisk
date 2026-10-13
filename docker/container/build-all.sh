#!/bin/bash
set -uo pipefail
# build-all.sh
#
# Usage: build-all.sh [service ...]     (services: db api daemon; default: all)
#
# Builds several images in one go by running each service's own build.sh in
# turn. Their prompts (stage, overwrite existing tarball, use cache) are
# asked once here up front and handed down as HR_STAGE / HR_OVERWRITE /
# HR_USE_CACHE, so the builds then run unattended. Always builds the
# `runtime` stage - the only one deploy.sh consumes.
#
# No `set -e`: a failed service doesn't stop the others; the summary at the
# end lists each result and the exit status is non-zero if any failed.

SH_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
DEPLOY_IMAGES_DIR="$SH_DIR/../deploy/images"

# Cheapest first, so quick failures surface before the long daemon build.
# Sequential on purpose: parallel builds would interleave their output and
# compete for disk while saving multi-GB tarballs.
ALL_SERVICES=(db api daemon)
if [ $# -gt 0 ]; then
    SERVICES=("$@")
else
    SERVICES=("${ALL_SERVICES[@]}")
fi
for svc in "${SERVICES[@]}"; do
    if [[ ! " ${ALL_SERVICES[*]} " =~ " ${svc} " ]] || [ ! -f "$SH_DIR/$svc/build.sh" ]; then
        echo "❌ Unknown service '$svc' (expected: ${ALL_SERVICES[*]})." >&2
        exit 1
    fi
done

echo "Building: ${SERVICES[*]} (stage: runtime)"

# Phrased positively, like each build.sh.
read -p "Use --use-cache? (Y/n): " cache_input
if [[ "$cache_input" =~ ^[Nn]$ ]]; then
    export HR_USE_CACHE=n
else
    export HR_USE_CACHE=y
fi

# Only ask about overwriting if there is something to overwrite.
existing=()
for svc in "${SERVICES[@]}"; do
    tar="$DEPLOY_IMAGES_DIR/hydrorisk-$svc.tar.gz"
    [ -f "$tar" ] && existing+=("$(basename -- "$tar")")
done
if [ ${#existing[@]} -gt 0 ]; then
    echo "Existing tarballs in deploy/images/: ${existing[*]}"
    read -p "Delete them and continue? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborting to avoid overwriting existing tarballs."
        exit 1
    fi
fi
export HR_OVERWRITE=y
export HR_STAGE=runtime

results=()
failed=0
for svc in "${SERVICES[@]}"; do
    echo ""
    echo "=================== $svc ==================="
    start=$SECONDS
    # stdin closed: any prompt not covered by HR_* fails fast instead of
    # waiting forever in the middle of an unattended run.
    if "$SH_DIR/$svc/build.sh" </dev/null; then
        status="✅"
    else
        status="❌"
        failed=1
    fi
    elapsed=$(( SECONDS - start ))
    results+=("$(printf '%s %-7s %3dm%02ds' "$status" "$svc" $((elapsed / 60)) $((elapsed % 60)))")
done

echo ""
echo "=================== summary ==================="
for line in "${results[@]}"; do
    echo "$line"
done
echo ""
if [ $failed -eq 0 ]; then
    echo "✅ All built into docker/deploy/images/."
    echo "   docker/deploy/deploy.sh --reload loads them and starts the stack."
else
    echo "❌ Some builds failed - see their output above." >&2
fi
exit $failed
