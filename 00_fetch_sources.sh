#!/bin/bash
# Run on a DelftBlue LOGIN node (compute/GPU nodes have no internet access).
# Downloads the Yambo source, every external library Yambo builds internally,
# and the hBN tutorial used for the GW/BSE tests.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

mkdir -p "$SRC_DIR/extlibs"
cd "$SRC_DIR"

tarball=yambo-$YAMBO_VERSION.tar.gz
if [ ! -s "$tarball" ]; then
    curl -fL -o "$tarball" "https://github.com/yambo-code/yambo/archive/refs/tags/$YAMBO_VERSION.tar.gz"
fi

if [ ! -s hBN.tar.gz ]; then
    curl -fL -o hBN.tar.gz https://media.yambo-code.eu/educational/tutorials/files/hBN.tar.gz
fi

# Yambo's own downloader (lib/archive/Makefile.loc) fetches the pinned library versions.
# Without a configured tree it only downloads, which is what we want here.
work=$(mktemp -d)
tar -xzf "$tarball" -C "$work"
( cd "$work/yambo-$YAMBO_VERSION/lib/archive" && cp "$SRC_DIR"/extlibs/*.tar.gz . 2>/dev/null || true
  make -f Makefile.loc all
  cp -v ./*.tar.gz "$SRC_DIR/extlibs/" )

echo
echo "Downloaded external libraries:"
missing=0
for f in "$SRC_DIR"/extlibs/*.tar.gz; do
    if [ -s "$f" ]; then ls -l "$f"; else echo "EMPTY: $f"; missing=1; fi
done
echo "Download logs: $work/yambo-$YAMBO_VERSION/log/"
[ "$missing" = 0 ] || die "some downloads failed, see the logs above"
rm -rf "$work"
echo "All sources are in $SRC_DIR"
