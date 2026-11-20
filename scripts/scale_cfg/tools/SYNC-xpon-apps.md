# Keep `sr_validate_ds` in sync with xpon-apps

| xpon-apps (`sr-validate/`) | sysrepo_performance (`scripts/scale_cfg/tools/`) |
|---|---|
| `sr_validate_ds.c` | `sr_validate_ds.c` (same logic; perf copy has no Vecima file header) |
| `test/sr_validate_ds_test.py` | `test/sr_validate_ds_test.py` |
| `test/fixtures/*` | `test/fixtures/*` |
| `test/CMakeLists.txt` | `test/CMakeLists.txt` (mirror for CTest in xpon-apps build) |

Product packaging and `make_bin` live only in xpon-apps. Host build uses `build_sr_validate_ds.sh` here.

After editing either side, copy the matching paths and run the unit cases:

```bash
# from sysrepo_performance
scripts/scale_cfg/tools/test/run_ut.sh

# from xpon-apps (after cmake build of sr_validate_ds)
ctest -R sr_validate_ds -V
```