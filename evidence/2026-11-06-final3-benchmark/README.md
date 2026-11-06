# FINAL3 benchmark (2026-11-06)

Report (Danish, owner-facing): `RAPPORT_FINAL3_BENCHMARK.txt` — A integrity 74/74, B boot ×3, C chain, D camera on the
MIB4 (99.5 % of source pictures), E functions, F 45-min endurance, G drive (owner).

- `camera_test.sh <otto-ip>` drives OTTO (Home, 60 fps clip, Maps pan, 5 app switches) while the owner films the MIB4;
  `camera_run_101445/actions.tsv` is the run that was filmed. Guide: `VEJLEDNING_KAMERATEST.txt`.
- `camera_analyze.py <video> [--crop x:y:w:h] [--cam-fps 120]` counts distinct panel pictures (index method).
- `endurance.txt`, `sampler.txt`, `phases.txt`: raw data for F and C.
- Videos, photos and the recorder log are not in git: `MEDIA_SHA256SUMS.txt`
  (originals in `Download/OTTO/OTTO_FINAL3_BENCHMARK_20261106/`).
- Coordinates in `smearwatch.log` are redacted.
