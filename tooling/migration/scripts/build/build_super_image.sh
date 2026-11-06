#!/data/data/com.termux/files/usr/bin/bash
# OTTO A17 permanent — build the complete A17 super image (offline, phone) and validate it.
# Layout = live slot-1 layout minus product_b/system_ext_b/cow, with the new system_b.
#   super 6442450944 B, metadata 65536 B x 3 slots, virtual_ab header flag,
#   group qti_dynamic_partitions_b max 6438256640 B.
# Usage: build_super_image.sh <workdir> <out.simg> <logfile>   (raw built next to it, validated, then img2simg)
#   workdir must hold: system_b.img (patched+shrunk ext4), vendor_b.img, vendor_dlkm_b.img,
#                      system_dlkm_b.img, odm_b.img (byte copies of the live A13 dm devices)
set -Eeuo pipefail
W=$1; OUT=$2; LOG=$3; RAW=${OUT%.simg}.raw
exec > >(tee -a "$LOG") 2>&1
echo "== build_super_image $(date '+%F %T')"
SUPER=6442450944; GROUP=qti_dynamic_partitions_b; GMAX=6438256640
args=(--metadata-size 65536 --super-name super --metadata-slots 3 --device super:$SUPER
      --group $GROUP:$GMAX --virtual-ab --output "$RAW")
total=0
for p in odm_b system_b system_dlkm_b vendor_b vendor_dlkm_b; do
  f=$W/$p.img; [ -f "$f" ] || { echo "MISSING $f"; exit 2; }
  sz=$(stat -c %s "$f"); [ $((sz % 4096)) -eq 0 ] || { echo "SIZE_NOT_4K $p $sz"; exit 3; }
  total=$((total + sz))
  args+=(--partition $p:readonly:$sz:$GROUP --image $p=$f)
  echo "part $p size=$sz sha=$(sha256sum "$f" | cut -c1-16)"
done
echo "sum=$total group_max=$GMAX free=$((GMAX - total))"
[ $total -lt $GMAX ] || { echo "DOES_NOT_FIT"; exit 4; }
lpmake "${args[@]}"
echo "== validate"
lpdump -a "$RAW" > "$OUT.lpdump.txt"
grep -E "Name:|Maximum size|Header flags|Metadata slot count" "$OUT.lpdump.txt"
V=$(mktemp -d "$W/unpack.XXXX"); trap 'rm -rf "$V"' EXIT
# one partition at a time (disk space); lpdump/lpunpack need a local fs with flock (not FUSE /storage)
for p in odm_b system_b system_dlkm_b vendor_b vendor_dlkm_b; do
  lpunpack -p $p "$RAW" "$V" >/dev/null 2>&1
  a=$(sha256sum "$W/$p.img" | cut -d' ' -f1); b=$(sha256sum "$V/$p.img" | cut -d' ' -f1)
  rm -f "$V/$p.img"
  [ "$a" = "$b" ] && echo "UNPACK_MATCH $p $a" || { echo "UNPACK_MISMATCH $p"; exit 5; }
done
for p in product_b system_ext_b odm_b-cow product_b-cow; do
  grep -q "Name: $p\$" "$OUT.lpdump.txt" && { echo "UNEXPECTED_PARTITION $p"; exit 6; } || echo "absent as intended: $p"
done
RSHA=$(sha256sum "$RAW" | cut -d' ' -f1); echo "raw_sha=$RSHA raw_size=$(stat -c %s "$RAW")"
img2simg "$RAW" "$OUT"
XSHA=$(python3 -I "$(dirname "$0")/simg_sha256.py" "$OUT" | cut -d' ' -f1)
[ "$XSHA" = "$RSHA" ] && echo "SIMG_EXPANDS_TO_RAW $XSHA" || { echo "SIMG_EXPAND_MISMATCH $XSHA"; exit 7; }
echo "$RSHA  OTTO_A17_super.raw (expanded content of OTTO_A17_super.simg, 6442450944 B)" > "$OUT.content.sha256"
sha256sum "$OUT" | sed 's#  .*/#  #' | tee "$OUT.sha256"
rm -f "$RAW"
echo "SUPER_IMAGE_VALID"
