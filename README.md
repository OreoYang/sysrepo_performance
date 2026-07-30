# sysrepo_performance

Host-side **sysrepo + libyang** scale harness for XPON largescale config (~1022 ONU).  
Measures incremental `sysrepocfg --edit` time (Mode S D2b): base + per-ONU provision + service RPCs.

Detailed design notes: [`scripts/scale_cfg/PLAN.md`](scripts/scale_cfg/PLAN.md).

## Repository layout

```text
sysrepo_performance/
├── README.md                 # this file
└── scripts/scale_cfg/        # harness root (cd here to run)
    ├── largescaleDb.tar      # input DB snapshot (~6.3 MB)
    ├── split_export.py       # export.xml → base + ONU XML
    ├── run_mode_s_d2b.sh     # main benchmark
    ├── work/                 # generated (repo, shm, configs) — optional in git
    ├── results/              # logs, CSV
    └── .local/runtime/       # staged sysrepocfg (after setup)
```

## Prerequisites

| Requirement | Purpose |
|-------------|---------|
| **Yocto `build-xpon`** | `bitbake sysrepo` → native `sysrepocfg` / libyang |
| **`xpon-yang`** | YANG modules + `setup_datastore.sh` |
| **Python 3** | `split_export.py`, `verify_base_ready.py` |

Default paths (auto-detected if present):

- `~/works/repo/build-xpon` — Yocto build dir (`XPON_BUILDDIR`)
- `~/works/repo/build-xpon/workspace/sources/xpon-yang/yang` — YANG tree (`XPON_YANG_ROOT`)

Override when paths differ:

```bash
export XPON_BUILDDIR=~/works/repo/build-xpon
export XPON_YANG_ROOT=~/works/repo/build-xpon/workspace/sources/xpon-yang/yang
```

## One-time setup

```bash
# 1. Yocto: build native sysrepo tools (once per machine / after recipe bump)
cd ~/works/repo && . setup-env
bitbake sysrepo

# 2. Stage sysrepocfg into harness-local runtime
cd ~/works/private/sysrepo_performance/scripts/scale_cfg
./stage_from_yocto_sysrepo.sh
```

Runtime lands in `scripts/scale_cfg/.local/runtime/` (not system `/usr`).

Verify:

```bash
./stage_from_yocto_sysrepo.sh   # should print sysrepocfg version (libsysrepo 3.7.x)
```

## Run benchmark (D2b)

Full flow: split `export.xml` → load base → 1022 provision + 1016 service edits (timed).

```bash
cd ~/works/private/sysrepo_performance/scripts/scale_cfg

# optional: clean previous run state
rm -rf work/fresh_repo work/shm

./run_mode_s_d2b.sh
```

Results:

| Output | Content |
|--------|---------|
| `results/mode_s_d2b.csv` | provision/service ok/fail + seconds |
| `results/mode_s_d2b.log` | full sysrepocfg log |
| `work/configs/` | split XML (regenerated each run) |

Typical successful run (~1022 ONU): **provision ~340 s**, **service ~1900 s**, total **~37 min**.

## Regenerate split XML only

If `results/export.xml` already exists (from tar export or copied):

```bash
cd ~/works/private/sysrepo_performance/scripts/scale_cfg
python3 split_export.py --export results/export.xml --out work/configs
```

### Split output layout

| Path | Description |
|------|-------------|
| `work/configs/00-base/` | Platform shared config (hardware, qos, platform, templates, …) |
| `work/configs/00-base/onu-templates/` | `00-onu-template-shared.xml` + one file per ONU template (19) |
| `work/configs/onu-provision/` | RPC 1 per ONU (1022) — **used by benchmark** |
| `work/configs/onu-service/` | RPC 2 per ONU (1016) — **used by benchmark** |
| `work/configs/rpc/` | Same content with `<edit-config>` wrapper — **review only** |

Inspect RPC messages (compare with production captures):

```bash
less work/configs/rpc/provision/0080-ALCLF88C08B8.edit-config.xml
less work/configs/00-base/onu-templates/10-template-Prod_GPON_SFU_BVL3A8JNAAG010SA.xml
```

## What this harness tests

| Included | Not included |
|----------|----------------|
| sysrepo + libyang via `sysrepocfg --edit` | netopeer2 NETCONF server |
| Single-threaded serial edits | netconf-polt change callbacks |
| Split from `export.xml` final state | Live controller RPC capture |

Components: **sysrepo 3.7.x**, **libyang 3.9.x** (from Yocto `sysrepo-native`, same recipe family as OLT image).

## Optional: prep DB from tarball

`run_mode_s_d2b.sh` exports from `largescaleDb.tar` automatically if `results/export.xml` is missing.

```bash
./prep_largescale_db.sh --force
# then run_mode_s_d2.sh logic inside d2b, or manual export — see PLAN.md
```

## Git / what to commit

Recommended to track:

- `scripts/scale_cfg/*.{sh,py}`, `lib/`, `README.md`, `PLAN.md`, `largescaleDb.tar`

Usually **gitignore** (regenerable):

- `work/`, `results/*.log`, `.local/`

## Troubleshooting

| Error | Fix |
|-------|-----|
| `staged runtime missing` | Run `./stage_from_yocto_sysrepo.sh` after `bitbake sysrepo` |
| `YANG root missing` | Set `XPON_YANG_ROOT` to `xpon-yang/yang` |
| `build-xpon not found` | Set `XPON_BUILDDIR` or run from tree that contains `conf/bblayers.conf` |
| preflight template missing | Base load failed — check `mode_s_d2b.log` for failed `onu-templates/*.xml` |

## Related scripts

See [`scripts/scale_cfg/README.md`](scripts/scale_cfg/README.md) for per-script reference.
