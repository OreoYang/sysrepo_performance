# Scale config A/B — plan, analysis & WSL handoff

**Purpose:** Single reference when moving this work to WSL (or another dev host).  
**Branch:** `Oreo/host-scale-cfg-ab` in `netconf-polt` (do **not** develop on `hank-dev`).  
**Runbook (commands):** [`README.md`](README.md)  
**Last updated:** 2026-07-29

---

## 1. Problem statement

### Symptom

Large ONU + template config (~1024 ONUs) takes **7+ hours** in the field. Growth appears **superlinear** (not linear with N).

### Question

Where does Phase A (config / datastore apply) spend time?

| Layer | Examples |
|-------|----------|
| **Stack** | sysrepo, libyang, netopeer2 |
| **netconf-polt** | `bbf_cache`, L1 locks, long `sr_module_change_subscribe` callback chains |

### Scope of this harness (Phase A only)

- Config / datastore apply on a **large pre-built DB**
- **No** real BAL / OMCI / hardware I/O
- **Not** full e2e discovery or `omci_ready` template push (likely much of field 7h)

---

## 2. Architecture analysis (background)

### Can sysrepo change callbacks be routed to workers like BAL indications?

**Technically yes**, but not as fire-and-forget as `nc_ind_router`:

- sysrepo supports `SR_ERR_CALLBACK_SHELVE`, `SR_SUBSCR_NO_THREAD`, shelved resume
- NETCONF edits are **transactional** — unlike indication fan-out, you cannot simply drop work on a queue and return without completing or shelving the transaction

**Conclusion:** Worker routing for change CBs is a **separate design** (not part of this harness). This project **measures** whether Phase A cost is stack vs polt first.

### Why field 7h may not show up in Phase A

Heavy OMCI (`xpon_create_onu_flows_on_onu_w_template` on **omci_ready**) runs largely **outside** the sysrepo change callback path. If Mode S and Mode P are both fast but field is slow → bottleneck is **outside** Phase A.

---

## 3. A/B test design

### Modes

| Mode | Processes | What it measures |
|------|-----------|------------------|
| **S** (stack) | netopeer2 + sysrepo (+ libyang) | Parse / validate / datastore only |
| **P** (polt) | Mode S + `bcmolt_netconf_server` + stubs | Stack + polt change callbacks / `bbf_cache` / L1 |

```text
scripts/scale_cfg/largescaleDb.tar
        │
        ▼
  prep_largescale_db.sh  (extract, clean locks)
        │
   ┌────┴────┐
   ▼         ▼
 Mode S    Mode P
(sysrepo)  (+ polt + LD_PRELOAD stub)
```

### Tests

| ID | Procedure | Priority |
|----|-----------|----------|
| **D1** | Fresh DB → start Mode S vs P → time until settle / cache ready | P0 |
| **D2** | Export XML from snapshot → clean repo + modules → time apply (S vs P) | P0 |
| **N-sweep** | Generate config N=64…1024, plot wall time vs N | P1 (optional) |

### Interpretation

| Observation | Likely cause |
|-------------|--------------|
| Mode S slow | sysrepo / libyang / data size |
| Mode S fast, Mode P slow | netconf-polt (`bbf_cache`, L1, change CBs) |
| Both fast vs field 7h | Phase A is not the field bottleneck (OMCI / discovery) |

---

## 4. Input database (`scripts/scale_cfg/largescaleDb.tar`)

~6.3 MB. **Not** a plain `/var/db/sysrepo` tree — overlay layout:

```text
var_db/upper/sysrepo/              ← SYSREPO_REPOSITORY_PATH
var_db/upper/sysrepo/data/*.startup
var_db/upper/sysrepo/sr_evpipe*    ← DELETE before use (stale)
var_db/upper/sysrepo/conn/*.lock   ← DELETE before use
var_db/upper/sysrepo-migration/
var_db/work/                       ← ignore for host
```

**Prep** (`prep_largescale_db.sh`):

1. Extract to `scripts/scale_cfg/work/`
2. Set `SYSREPO_REPOSITORY_PATH=.../work/var_db/upper/sysrepo`
3. Remove `sr_evpipe*`, `conn/`, `sr_main_lock`

**Risks:**

- **YANG revision skew** between tarball and host `build/fs` modules → migration errors or empty export
- Tarball has **`.startup`** binaries, not XML — D2 export may be 0 bytes until modules are installed in staged runtime
- Modules are **not** inside the tar — come from host sim `build/fs` or Yocto `sysrepo` package

---

## 5. Implementation status (as of handoff)

### Done

| Item | Location |
|------|----------|
| Harness scripts | `scripts/scale_cfg/` |
| DB prep | `prep_largescale_db.sh` |
| Mode S D2 | `run_mode_s_d2.sh` |
| Mode P D1 | `run_mode_p_d1.sh` |
| Orchestrator | `run_ab.sh` |
| Yocto cmake wrapper | `setup_local_tools.sh` → `.local/bin/cmake` |
| Yocto x86 headers | `lib/yocto_host_env.sh` (`CPATH` / `CFLAGS`) |
| Stage runtime | `stage_runtime.sh`, `stage_from_yocto_sysrepo.sh` |
| BAL cfg stub | `netconf_server/stubs/bcmolt_cfg_stub.c` + CMake |
| CMake options | `BCMOLT_CFG_STUB`, `ONU_MGMT_STUB`, `ONU_MGMT_OMCI_STUB` |
| `add_dependencies` fix | `netconf_server/CMakeLists.txt` (after `bcm_create_app_target`) |
| Gitignore | `scripts/scale_cfg/work/`, `results/`, `.local/` |

### Partial / blocked

| Item | Notes |
|------|-------|
| `make host` full build | Past `sys/un.h`; blocked on `bcmos_system.h` / third_party clone until full sim tree builds |
| Mode S export smoke | Script runs; export XML may be **0 bytes** (binary `.startup` + module install) |
| Mode P on x86 | Needs host sim binary in `.local/runtime` or `build/fs` |
| D1 Mode S runner | Not separate script yet (P has `run_mode_p_d1.sh`) |
| Instrumentation | Timers in `bbf_cache_object_execute` / L1 — not done |
| N-sweep generator | Optional Phase 2 |

### Effort estimate (original plan)

| Phase | Estimate |
|-------|----------|
| 0 DB prep + docs | 0.5 d |
| 1 host stubs + link | 1.5–3 d (+1–2 d if BAL symbols fight) |
| 2 Mode S/P + D1/D2 | 1.5–2 d |
| 3 light timers | 0.5 d |
| 4 N-sweep (optional) | 1.5–2 d |
| **MVP total** | **~4–6 person-days** |

---

## 6. Repository layout (portable)

Assume Vecima standard tree (adjust `REPO_ROOT` on WSL):

```text
${REPO_ROOT}/                          # e.g. ~/works/repo
├── setup-env                          # → lands in build-xpon/
├── vcmos/                             # meta-xpon, netconf-polt.bb
└── build-xpon/
    ├── conf/bblayers.conf             # includes workspace layer
    ├── tmp/work/                      # Yocto build artifacts
    └── workspace/
        ├── appends/netconf-polt.bbappend   # EXTERNALSRC — update path on WSL!
        ├── conf/layer.conf                 # recipes/*/*.bb, appends/*.bbappend
        └── sources/
            └── netconf-polt/               # this repo
                ├── scripts/scale_cfg/      # harness (this doc)
                │   └── largescaleDb.tar
                ├── build/                  # target OR host sim (see §7)
                ├── build-hostsim/          # recommended if using hostsim recipe
                └── .local/                 # gitignored runtime staging
```

**Path resolution in scripts:** `lib/repo_paths.sh` derives `BUILDDIR` from `netconf-polt` location — **no hardcoded user** in scripts. Only `workspace/appends/netconf-polt.bbappend` may have a machine-specific `EXTERNALSRC` path.

---

## 7. Build paths — avoid target / host collision

### The overlap problem

Both **target** `bitbake netconf-polt` and **host sim** `make host` use `externalsrc` → same source tree. Default Makefile output:

```text
netconf-polt/build/          # BUILD_TOP_DIR=./build
netconf-polt/build/fs/       # install tree (bcmolt_netconf_server, libs, sysrepo)
```

| Build | BOARD | Compiler | Binary arch |
|-------|-------|----------|-------------|
| `bitbake netconf-polt` | `exs1610` | `x86_64-vcm-linux-gcc` + target sysroot | **aarch64** |
| `make host` (sim) | `sim` | native `gcc` | **x86_64** |

Sharing `build/` causes CMake reconfigure and **forced rebuild** when switching. Stale cross `flags.make` in `build/` broke host sim until cleaned.

### Rules

1. **Target dev:** `bitbake netconf-polt -c compile` → uses `build/` (today)
2. **Host sim / scale:** use **`BUILD_TOP_DIR=./build-hostsim`** (recommended for future `netconf-polt-hostsim` recipe)
3. **`build_host_inrepo.sh`** still uses default `build/` — on WSL, avoid alternating target bitbake and `./build_host_inrepo.sh` without `make clean_all`
4. **Yocto work dirs** are already separate: `tmp/work/exs1610-vcm-linux/netconf-polt/` vs future `.../netconf-polt-hostsim/`

### Host sim make flags (reference)

```bash
BOARD=sim OPEN_SOURCE=y OPEN_SOURCE_SIM=y \
  ONU_MGMT=y ONU_MGMT_STUB=y ONU_MGMT_OMCI_STUB=y \
  BCMOLT_CFG_STUB=y NETCONF_SERVER=y \
  CMAKE_C_COMPILER=gcc CMAKE_CXX_COMPILER=g++ \
  host
```

Optional isolation:

```bash
make BUILD_TOP_DIR=./build-hostsim ... host
```

---

## 8. Borrowing Yocto headers & tools (no build-essential)

WSL/minimal host may lack `sys/un.h`. Prefer Yocto sysroots after at least `bitbake sysrepo`:

| Borrow from | Arch | Use |
|-------------|------|------|
| `tmp/sysroots-components/corei7-64/glibc/usr/include` | x86_64 | Host sim headers (`lib/yocto_host_env.sh`) |
| `tmp/work/corei7-64-vcm-linux/*/recipe-sysroot` | x86_64 | Fallback; Mode S sysrepo staging |
| `tmp/work/.../recipe-sysroot-native/usr/bin/cmake` | x86_64 | CMake via `setup_local_tools.sh` |
| `tmp/work/exs1610-vcm-linux/netconf-polt/.../recipe-sysroot` | **aarch64** | **bitbake target / OLT only** — not host `gcc` |

Fallback: `sudo apt install build-essential`.

**Do not** mix aarch64 target sysroot with native `gcc` for host sim.

---

## 9. Optional: custom Yocto recipe `netconf-polt-hostsim`

### Where to put it

```text
build-xpon/workspace/recipes/netconf-polt-hostsim/netconf-polt-hostsim.bb
```

Workspace layer (`workspace/conf/layer.conf`, priority 99) picks up `recipes/*/*.bb` automatically.

### Why

- Reproducible host x86 build without hand-tuning `CPATH`
- Separate from target `netconf-polt.bb`
- `inherit` + `DEPENDS` on `sysrepo-native`, `cmake-native`, etc.

### Critical `do_compile` pattern

```bitbake
EXTERNALSRC:pn-netconf-polt-hostsim = "${REPO}/build-xpon/workspace/sources/netconf-polt"

do_compile() {
    cd ${S}
    oe_runmake BUILD_TOP_DIR=./build-hostsim \
        BOARD=sim OPEN_SOURCE=y OPEN_SOURCE_SIM=y \
        ONU_MGMT=y ONU_MGMT_STUB=y ONU_MGMT_OMCI_STUB=y \
        BCMOLT_CFG_STUB=y NETCONF_SERVER=y host
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${S}/build-hostsim/fs/bcmolt_netconf_server ${D}${bindir}
}
```

Build: `bitbake netconf-polt-hostsim -c compile`  
Output: `tmp/work/corei7-64-vcm-linux/netconf-polt-hostsim/...` + package under `tmp/deploy/`

**Not implemented yet** — scripts path is the current MVP.

---

## 10. WSL migration checklist

### Before copy

- [ ] Commit or stash `netconf-polt` on branch `Oreo/host-scale-cfg-ab`
- [ ] Note whether `build-xpon/tmp` is copied or rebuilt (full Yocto tmp is huge — usually **rebuild** on WSL)
- [ ] Copy or re-fetch `scripts/scale_cfg/largescaleDb.tar` if not in git

### On WSL after clone

```bash
# 1. Standard env
cd ~/works/repo && . setup-env

# 2. Fix externalsrc path if username/path differs
#    Edit: build-xpon/workspace/appends/netconf-polt.bbappend
#    EXTERNALSRC:pn-netconf-polt = "/home/<user>/works/repo/build-xpon/workspace/sources/netconf-polt"

# 3. Checkout branch
cd workspace/sources/netconf-polt
git checkout Oreo/host-scale-cfg-ab

# 4. Prime Yocto (pick one)
bitbake sysrepo                    # Mode S minimum
# bitbake netconf-polt -c compile  # target + cmake in tmp

# 5. Harness
cd scripts/scale_cfg
./setup_local_tools.sh
./stage_from_yocto_sysrepo.sh      # Mode S runtime → .local/runtime
./prep_largescale_db.sh --force
./run_ab.sh                        # Mode S D2
```

### WSL-specific notes

- Use **Linux filesystem** (`~/works/...`), not `/mnt/c/...` for bitbake (performance + inode/watchers)
- Ensure `git`, `python3`, enough disk for `build-xpon/tmp` (tens of GB for full builds)
- Line endings: `core.autocrlf` / `.gitattributes` — shell scripts must stay LF
- If `find ... recipe-sysroot-native/usr/bin/cmake` fails → run any recipe compile once

### What not to do

- Do not `source env_host.sh` in login shell (only `run_*.sh` use it)
- Do not install harness tools to `/usr` or `$HOME` — everything under `netconf-polt/.local/`
- Do not commit on `hank-dev`

---

## 11. Quick command reference

### Mode S only (no polt binary)

```bash
cd ~/works/repo && . setup-env && bitbake sysrepo
cd workspace/sources/netconf-polt/scripts/scale_cfg
./setup_local_tools.sh
./stage_from_yocto_sysrepo.sh
./prep_largescale_db.sh --force
./run_mode_s_d2.sh
```

### Full host sim attempt (Mode S + P)

```bash
cd workspace/sources/netconf-polt/scripts/scale_cfg
./build_host_inrepo.sh
./prep_largescale_db.sh --force
./run_ab.sh --with-polt
```

### Target (OLT / aarch64)

```bash
cd ~/works/repo && . setup-env
bitbake netconf-polt -c compile -f
# Binary: tmp/work/exs1610-vcm-linux/netconf-polt/.../build/fs/bcmolt_netconf_server
# Deploy: tmp/deploy/rpm/exs1610/...
```

---

## 12. Script index

| Script | Role |
|--------|------|
| `prep_largescale_db.sh` | Extract tar, clean locks |
| `setup_local_tools.sh` | Yocto cmake → `.local/bin/` |
| `stage_from_yocto_sysrepo.sh` | Native sysrepo pkg → `.local/runtime` |
| `build_host_inrepo.sh` | `make host` + stage (uses `build/`) |
| `stage_runtime.sh` | Copy `build/fs` → `.local/runtime` |
| `run_mode_s_d2.sh` | Mode S export/import timing |
| `run_mode_p_d1.sh` | Mode P boot + cache timing |
| `run_ab.sh` | Prep + Mode S; `--with-polt` for P |
| `env_host.sh` | Sourced by runners only |
| `lib/repo_paths.sh` | Repo-relative paths |
| `lib/yocto_host_env.sh` | x86 Yocto headers for gcc |

---

## 13. Open items (next engineer)

1. Fix Mode S D2 export (0-byte XML) — install YANG modules into staged runtime before `sysrepocfg -X`
2. Complete `make host` / third_party (`bcmos_system.h`, balapi clone)
3. Add `run_mode_s_d1.sh` for symmetric D1 vs `run_mode_p_d1.sh`
4. Use `BUILD_TOP_DIR=./build-hostsim` in `build_host_inrepo.sh` + optional `netconf-polt-hostsim.bb`
5. Optional instrumentation in `bbf_cache_object_execute` / L1
6. Optional N-sweep XML generator
7. Compare MVP timings → Confluence / JIRA conclusion (stack vs polt vs field 7h)

---

## 14. Out of scope

- Implementing change-CB worker / `SR_ERR_CALLBACK_SHELVE` routing
- Real BAL, OMCI, discovery pacing fixes
- Fixing production OLT 7h in this branch (measure first)

---

## 15. Related files outside this directory

| File | Role |
|------|------|
| `netconf-polt/netconf_server/stubs/` | BAL cfg stub |
| `netconf-polt/netconf_server/CMakeLists.txt` | `BCMOLT_CFG_STUB` option |
| `netconf-polt/onu_mgmt/CMakeLists.txt` | `ONU_MGMT_STUB` options |
| `vcmos/meta-xpon/recipes-core/broadcom/netconf-polt.bb` | Target recipe |
| `build-xpon/workspace/appends/netconf-polt.bbappend` | externalsrc override |
| `build-xpon/workspace/conf/layer.conf` | Custom recipe layer |
