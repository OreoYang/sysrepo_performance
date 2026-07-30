# scale_cfg harness

Part of **[sysrepo_performance](../../README.md)** — host sysrepo scale benchmark for ~1022 ONU.

**Quick start** (from this directory):

```bash
./stage_from_yocto_sysrepo.sh    # once, after bitbake sysrepo
./run_mode_s_d2b.sh              # full benchmark
```

Set paths if not using default Yocto layout:

```bash
export XPON_BUILDDIR=~/works/repo/build-xpon
export XPON_YANG_ROOT=~/works/repo/build-xpon/workspace/sources/xpon-yang/yang
```

Do **not** `source env_host.sh` in your login shell — only `run_*.sh` scripts source it.

## Directory layout

| Path | Purpose |
|------|---------|
| `largescaleDb.tar` | Largescale sysrepo DB input (~6.3 MB) |
| `work/configs/` | Split XML (base, onu-provision, onu-service, rpc/) |
| `work/fresh_repo/` | Empty sysrepo used during benchmark |
| `work/shm/` | sysrepo SHM for benchmark |
| `.local/runtime/` | Staged `sysrepocfg` / libyang from Yocto |
| `results/` | `mode_s_d2b.csv`, `mode_s_d2b.log`, `export.xml` |

## D2b flow (`run_mode_s_d2b.sh`)

1. **Split** `results/export.xml` → `work/configs/`
2. **Install YANG** on fresh repo (`install_yang_modules.sh`)
3. **Base** — `00-base/*.xml` + `00-base/onu-templates/*.xml` (merge `--edit`, not timed)
4. **Preflight** — `verify_base_ready.py`
5. **Provision** — loop `onu-provision/*.xml` (timed)
6. **Service** — loop `onu-service/*.xml` (timed)

Actual下发 uses **config bodies** in `00-base/`, `onu-provision/`, `onu-service/`.  
`work/configs/rpc/` adds `<edit-config>` envelope for manual review only.

### Per-ONU two-RPC model

| Phase | Directory | Contents |
|-------|-----------|----------|
| Provision | `onu-provision/` | hardware, v-ani, onu meta |
| Service | `onu-service/` | eth/vlan, shaper, tcont/gem, fwd port, template replace |
| Templates (base) | `00-base/onu-templates/` | shared qos/vsi + one XML per template name |

## Scripts

| Script | Purpose |
|--------|---------|
| `stage_from_yocto_sysrepo.sh` | Copy Yocto sysrepo-native → `.local/runtime` |
| `install_yang_modules.sh` | Install YANG via `xpon-yang/setup_datastore.sh` |
| `prep_largescale_db.sh` | Extract `largescaleDb.tar` → `work/var_db` |
| `split_export.py` | Split export → base + provision + service + rpc |
| `verify_base_ready.py` | Preflight before ONU provision |
| `run_mode_s_d2b.sh` | **Main benchmark** (incremental edit timing) |
| `run_mode_s_d2.sh` | Full export.xml import (D2, single shot) |
| `run_ab.sh` | Thin wrapper |
| `lib/repo_paths.sh` | Paths; honors `XPON_BUILDDIR`, `XPON_YANG_ROOT` |

## Split / review commands

```bash
python3 split_export.py --export results/export.xml --out work/configs

# optional hardware init for split
python3 split_export.py --hardware "$XPON_YANG_ROOT/init-data/ietf-hardware.xml" ...

less work/configs/manifest.json
less work/configs/rpc/README.txt
```

## Performance notes

- **Single-threaded**: one `sysrepocfg` process at a time
- **Per-ONU time grows** with ONU count (larger running datastore) — see `results/onu_timing_sample.csv` if present
- Typical totals @1022 ONU: provision ~340 s, service ~1900 s

## Further reading

- Design / A-B plan: [`PLAN.md`](PLAN.md)
- Repo-level setup: [`../../README.md`](../../README.md)
