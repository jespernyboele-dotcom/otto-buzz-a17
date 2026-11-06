#!/usr/bin/env python3
"""Assemble otto_edl_partition_tool.py from the PROVEN R29E worker (root_writer.py, sha a08d41c6...).
Protocol code is copied verbatim by line range; only orchestration (GPT lookup by name, streaming
jobs, chunk ledger, compact logging) is new. Writes EDL_TOOL_PROVENANCE.tsv with per-slice sha256."""
import hashlib, sys
from pathlib import Path
here = Path(__file__).resolve().parent
ref = here / "root_writer_R29E_proven_reference.py"
REF_SHA = "a08d41c6e3b2be9ec84416e58a26303f9a30093dfdae2de6638de38278c0238d"
src = ref.read_bytes()
if hashlib.sha256(src).hexdigest() != REF_SHA:
    sys.exit("reference worker hash mismatch")
L = src.decode().splitlines(keepends=True)
def sl(a, b):  # 1-based inclusive
    return "".join(L[a-1:b])
SLICES = [  # (name, first, last) — verbatim from the proven worker
    ("ioctl_structs",        25, 37),
    ("helpers_H_q",          39, 40),
    ("ioctl_ctrl_discover",  64, 93),
    ("bulk_io_and_firehose", 98, 245),
    ("sahara_nop_configure", 301, 325),
]
head = (here / "edl_tool_head.py").read_text()
tail = (here / "edl_tool_tail.py").read_text()
out = [head]
prov = ["slice\tref_first\tref_last\tsha256"]
for name, a, b in SLICES:
    body = sl(a, b)
    prov.append(f"{name}\t{a}\t{b}\t{hashlib.sha256(body.encode()).hexdigest()}")
    if name == "sahara_nop_configure":
        # wrap the verbatim top-level block in a function (indent only; tokens unchanged)
        body = "def sahara_nop_configure():\n    global end_status, na, nn, ca, cn, uploaded\n" + \
               "".join(("    " + ln if ln.strip() else ln) for ln in body.splitlines(keepends=True)) + \
               "    return True\n"
    out.append(f"\n# ---- VERBATIM from root_writer.py lines {a}-{b} ({name}) ----\n")
    out.append(body)
    out.append(f"# ---- END VERBATIM {name} ----\n")
out.append(tail)
tool = here / "otto_edl_partition_tool.py"
tool.write_text("".join(out))
(here / "EDL_TOOL_PROVENANCE.tsv").write_text("\n".join(prov) + "\n")
print("built", tool, hashlib.sha256(tool.read_bytes()).hexdigest())
