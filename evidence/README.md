# evidence — measured results only

Each folder is one measurement session: raw data and the report written from it. Large media (videos, photos,
screenshots, location dumps) are not in git; their SHA-256 values are in each folder's `MEDIA_SHA256SUMS.txt`.
Positions are redacted. The tools that produced the data are in `../tests/`.

| Folder | What | Result |
|---|---|---|
| `2026-11-06-final3-benchmark/` | FINAL3 test plan A–F on the bench/parked car, G drive by the owner | 74/74 post-boot checks, MIB4 showed 99.5 % of a 60 fps video, 45 min stable, voice key and GPS OK |
| `2026-11-01-gps-searching/` | Maps "Searching for GPS" while driving | cause found and fixed: satellite extras on the car fixes |

Earlier sessions are written up in `../docs/history/` (2026-10-26 car session, 2026-10-31 chain test).
