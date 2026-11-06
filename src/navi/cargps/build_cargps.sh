#!/bin/sh
# Reproducible build of otto_cargps.jar. Recipe verified 2026-10-31: the same two steps on the P5 source (2b1c6071…)
# give the running FINAL2 classes.dex bit-exactly (437cece7…). javac 21 (--release 8, default -g:source,lines),
# Termux d8 --release --min-api 26. Usage: sh build_cargps.sh <OttoCarGps.java> <out.jar>
set -e
W=$(mktemp -d); javac -nowarn --release 8 -d "$W/cls" "$1"; mkdir -p "$W/dex"
d8 --release --min-api 26 --output "$W/dex" "$W"/cls/*.class
(cd "$W/dex" && rm -f "$2.tmp" && python3 -I -c "
import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],'w',zipfile.ZIP_DEFLATED); i=zipfile.ZipInfo('classes.dex',(2026,10,31,0,0,0)); i.compress_type=zipfile.ZIP_DEFLATED; z.writestr(i,open('classes.dex','rb').read()); z.close()" "$2")
sha256sum "$W/dex/classes.dex" "$2"; rm -rf "$W"
