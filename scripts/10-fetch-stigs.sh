#!/usr/bin/env bash
# Download the current DISA SRG/STIG Library compilation into stigs/library.
#
# The filename is not stable: DISA publishes one compilation a quarter and names
# it after the month, e.g. U_SRG-STIG_Library_October_2026.zip. There is no
# "latest" alias and public.cyber.mil is a JavaScript portal with no .zip hrefs
# to scrape, so this walks backwards from the current month and takes the first
# name that answers. That keeps working as new compilations are published,
# without anyone editing a version string.
#
# Nothing in the lab depends on this content: STIG Manager imports whatever you
# give it. The download is ~375 MB and stigs/ is gitignored.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$LAB_DIR/stigs/library"
BASE="https://dl.dod.cyber.mil/wp-content/uploads/stigs/zip"
MONTHS_BACK="${MONTHS_BACK:-15}"

mkdir -p "$DEST" "$LAB_DIR/stigs/selected" "$LAB_DIR/stigs/xccdf"

echo "==> looking for the most recent compilation"
url=""
for i in $(seq 0 "$MONTHS_BACK"); do
  name="U_SRG-STIG_Library_$(date -d "-$i month" +%B_%Y).zip"
  code="$(curl -sIL --max-time 20 -o /dev/null -w '%{http_code}' "$BASE/$name" || echo 000)"
  printf '    %-42s %s\n' "$name" "$code"
  if [ "$code" = "200" ]; then url="$BASE/$name"; file="$name"; break; fi
done

[ -n "$url" ] || { echo "No compilation found in the last $MONTHS_BACK months. Check https://public.cyber.mil/stigs/compilations/" >&2; exit 1; }

if [ -s "$DEST/$file" ]; then
  echo "==> already have $file ($(stat -c%s "$DEST/$file") bytes); nothing to do"
  exit 0
fi

echo "==> downloading $file"
# Needs the space: the compilation is ~375 MB and kubelet evicts pods on this
# host below 1Gi free, which takes both clusters down with it.
avail_kb="$(df -Pk "$DEST" | awk 'NR==2 {print $4}')"
if [ "$avail_kb" -lt 2097152 ]; then
  echo "Only $((avail_kb / 1024)) MB free on the volume holding stigs/." >&2
  echo "Free up space first: filling this disk re-triggers kubelet eviction." >&2
  exit 1
fi

curl -fL --progress-bar --max-time 3600 -o "$DEST/$file.part" "$url"
mv "$DEST/$file.part" "$DEST/$file"

echo "==> $DEST/$file"
ls -l "$DEST/$file"
sha256sum "$DEST/$file"

cat <<'TIP'

To pull a single product's XCCDF out without extracting all ~1.5 GB:

  unzip -l stigs/library/*.zip | grep -i <product>
  unzip -o -j stigs/library/*.zip 'U_MOZ_Firefox_V6R9_STIG.zip' -d stigs/selected/
  unzip -o -j stigs/selected/U_MOZ_Firefox_V6R9_STIG.zip '*Manual-xccdf.xml' -d stigs/xccdf/
TIP
