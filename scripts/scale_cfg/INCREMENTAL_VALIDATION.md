# Incremental YANG validation (edit-diff)

## Problem

Each `sr_apply_changes` validates the **whole module tree** (`lyd_validate_module`), so per-edit time grows with ONU count and total config time is **O(N²)**. This matches CESNET’s design for libyang 2+: no cross-apply validation cache ([#1382](https://github.com/CESNET/libyang/issues/1382)).

On the XPON ADD-ONU path, the dominant cost is re-evaluating `when "derived-from-or-self(if:type, …)"` (and related must/leafref) on **every existing interface**, even when this RPC did not touch those instances.

```text
sr_apply_changes → sr_modinfo_validate → lyd_validate_module (whole module)
                 → when on all interfaces  ≈ O(N) per RPC
N independent RPCs                         ≈ O(N²) total
```

---

## Product pin vs what we actually ran

Product pin lives in `~/works/repo/vcmos/meta-xpon/conf/distro/include/xpon-oss-manifest.conf`:

| Recipe pin | Value |
|------------|--------|
| `PREFERRED_VERSION_SYSREPO` | **3.7.11** |
| `PREFERRED_VERSION_LIBYANG` | **3.13.5** |
| netopeer2 / libnetconf2 | 2.4.5 / 3.7.10 |

`meta-xpon/recipes-extended/libyang/libyang_%.bbappend` has an empty `SRC_URI`: **no validation patches**. sysrepo bbappend is SHM / sort / factory-reset only.

**Important:** Yocto `libyang_3.13.5.bb` (`SRCREV efe43e37…`) still compiles **`LY_VERSION "3.9.13"`** (`version.h` + `libyang.so.3.9.13`). pkgconfig `Version: 3.13.5` is the recipe `PV`, not CESNET 3.13.5. The “product 3.13.5” native sysroot **is libyang 3.9.13**.

Yocto `libyang.inc`: `CMAKE_BUILD_TYPE=Release` but `NDEBUG=NO`.

---

## Measured stacks (same XML, host WSL2)

### N=1022 (1016 successful services; 6 fail — see below)

| Stack | sysrepo | libyang | Harness | Provision | Service | Total | Late service |
|-------|---------|---------|---------|-----------|---------|-------|--------------|
| D2b 2026-07-30 | 3.7.11 | 3.9.13 | fork `sysrepocfg --edit` | ~340 s | ~1908 s | **~37 min** | #1016 **3042 ms** |
| **Product pin 2026-08-14** | **3.7.11** | **3.9.13** (recipe 3.13.5) | **`sr_edit_files` session** | **252 s** (38→241→447 ms) | **1901 s** (423→1737→**3378 ms**) | **~36 min** | same slope |
| A/B full 2026-08-14 | 4.5.4 | 5.8.6 Release | `sr_edit_files` | 202 s (96→166→326 ms) | 978 s (314→853→**1614 ms**) | **~20 min** | ~1.9× faster last apply |
| A/B edit-diff | 4.5.4 | 5.8.6 + PoC | `sr_edit_files` | 8.6 s | 34.5 s | **43 s** | **11–57 ms** (flat) |

### N=1522 (all 1522 provisioned, then 1516 services — **fail=0**)

| Stack | Provision | Service | Total | First → mid → last service |
|-------|-----------|---------|-------|----------------------------|
| **Product pin 3.7.11+3.9.13** (Yocto native) | **545 s** (39→319→744 ms) | **5010 s** (760→3094→**6979 ms**) | **~93 min** | linear in N |
| **3.x backport full** (host Release) | **464 s** (42→282→598 ms) | **4282 s** (587→2819→**5789 ms**) | **~79 min** | same slope, smaller constant |
| **3.x backport edit-diff** | **20.3 s** | **183.5 s** | **3.4 min** | 19→59→**368 ms** |
| A/B edit-diff 4.5.4+5.8 PoC | 15.4 s | 188.2 s | **3.4 min** | 11→22→**772 ms** (not flat at this N) |
| A/B full 4.5.4+5.8 | not run at 1522 | — | — | last-apply ~2× vs 3.9.13 at N=1022 |

Product-pin CSV: `results/ab_validate_product_pin.csv` (1022 + 1522). Snapshots: `ab_validate_product_pin_1022.csv`, `ab_validate_product_pin_1522.csv`.  
Private A/B: `results/ab_validate_edit_diff_onu_scale.csv`.  
N=1522 first/mid taken from that run’s `SR_EDIT` lines (not the appended per-edit file).

**Same-harness comparison (the fair one):**

- Product 3.7.11+3.9.13 vs 4.5.4+5.8 **full** (N=1022): service **1901 s / 978 s ≈ 1.94×**. Last apply **3.38 s / 1.61 s ≈ 2.1×**. Upgrade helps the constant; **curve still linear in N**.
- Product full vs edit-diff: N=1022 service **1901 / 34.5 ≈ 55×**, total **36 min / 43 s ≈ 50×**. N=1522 service **5010 / 188 ≈ 27×**, total **93 min / 3.4 min ≈ 27×** (edit-diff last apply already 772 ms — PoC is leaking cost).
- D2b 37 min vs product-pin 36 min (N=1022): **`sysrepocfg` cold start is not why D2b was slow** on the service path (validate already ~3 s). Fork shows up more on cheap early provision edits (340 s vs 252 s).
- **O(N²) on product pin:** last service **3.38 s → 6.98 s** (×2.07) while N grows ×1.49; service wall **1901 s → 5010 s** (×2.64) vs (1522/1022)² ≈ 2.22. First service after 1522 provisions is already **760 ms** (vs 423 ms after 1022) because the tree is larger before any service XML.

Serial service N=1022 **fail=6** on all full runs: last six files are `1023-SCLE…`–`1028-SCLE…`, ONUs not in the first 1022 provision files (six provision-only serials at 0180, 0239–0242, 0976). First **1016 services succeeded** (last ok = `1022-ZYXE537259F9.xml`, 3378 ms). Original D2b, and the N=1522 product-pin run, provisioned all 1522 first, so those six never appeared (**fail=0**). Not a 3.9 vs 5.8 regression.

---

## CESNET issues vs this workload

Upstream ([#1382](https://github.com/CESNET/libyang/issues/1382), [#894](https://github.com/CESNET/libyang/issues/894), [#1831](https://github.com/CESNET/libyang/issues/1831)): `when`/`must`/leafref can depend on arbitrary other data, so libyang 2 **does not** cache “already valid” across `lyd_validate_*`. `when` is re-run on purpose.

| Issue | Relation to XPON | Takeaway |
|-------|------------------|----------|
| [#1382](https://github.com/CESNET/libyang/issues/1382) validate from diff | Same request. Reply: v1 cached; v2 always whole tree (“bad idea”) | Incremental API will not arrive as a silent default; must be a new design with deps + fallback |
| [#2347](https://github.com/CESNET/libyang/issues/2347) layering `node_when` | Closest: `sr_modinfo_validate` ~95%, 456k `node_when`, libyang **3.7.8** | Speeds **autodel of nested when** (~70 s→32 s). Incomplete terminals stayed **~290/327 s (~89%)**. **~10% wall**. Does **not** skip unchanged sibling `interface` list instances |
| [#894](https://github.com/CESNET/libyang/issues/894) `LYD_VAL_OK` | FRR; `when` **not** cached | Same design as #1382 |
| [#706](https://github.com/CESNET/libyang/issues/706) `lyd_new` | `lyd_new` is not full validate | `sr_apply_changes` calls `lyd_validate_module` — that is the full path |
| [#2018](https://github.com/CESNET/libyang/issues/2018) / [#2326](https://github.com/CESNET/libyang/issues/2326) | FRR 6 s / 8+ s `lyd_validate_all` | Upgrade 2.0.7→2.1.55: 6 s→0.8 s (**constant**). Maintainer: skipping validate is undefined behavior |
| [#865](https://github.com/CESNET/libyang/issues/865) `must` | SONiC ACL, must ~78%, O(n²) XPath | Our slope is many **cheap per-instance `when`** × N instances. A `count(//interface)` must would be worse |
| [#1831](https://github.com/CESNET/libyang/issues/1831) leafref | 862 components, ~1 min embedded | We have tcont/gem/fwd leafrefs; late linear growth still matches walking `ietf-interfaces` `when` |
| [#27](https://github.com/CESNET/libyang/issues/27) | 50k interfaces, 48–80 s one-shot | Scale reference only (libyang 1 era) |

Host profile (private 4.5.4 Debug): N=100 validate **90%** of apply; N=200 **94%**. Field ~7 h vs host N=1022 **~36 min** / N=1522 **~93 min**: Mode S is sysrepo+libyang; field adds netopeer2 / netconf-polt / OMCI. Validate is the Mode S bottleneck, not the only field cost.

---

## Approach (PoC on libyang 5.8 + sysrepo 4.5.4)

**libyang** (`~/works/private/libyang`):

- `lyd_validate_module_edit(tree, module, edit_diff, val_opts, diff)`
- `lyd_validate_module_edit_final(tree, module, edit_diff, val_opts)`

Only subtrees in `edit_diff` (`yang:operation` create/replace) are walked; unique/min/max on touched lists. **No XPath dependency graph yet.**

**sysrepo** (`~/works/private/sysrepo`):

- `SR_VALIDATE_EDIT_DIFF=1` and `notify_diff` present → edit APIs.
- Default: off (full validation).

PoC **false negative**: dirty-subtree checks are incomplete; N≥200 late-edit can apply an illegal tree that full validate rejects. Production needs: full constraints on dirty subtrees + leafref/`when`/`must` expansion + unknown → full fallback.

### Product-pin 3.x backport (this round)

Worktrees (do not touch 4.5.4 / 5.8):

- `~/works/private/libyang-3.9.13` branch `edit-diff-3.9.13` @ Yocto `efe43e37`
- `~/works/private/sysrepo-3.7.11` branch `edit-diff-3.7.11` @ `v3.7.11`

3.9 has `lyd_validate_subtree` (not 5.8 `lyd_validate_tree`); `ext_node` is passed into `lyd_validate_unres`. Same env flag, default off.

```bash
cd scripts/scale_cfg
./stage_from_private_3x.sh
# gcc sr_edit_files → .local/bin/sr_edit_files_yocto_editdiff
AB_N_LIST=40 AB_MODE=both ./run_product_pin_editdiff.sh
AB_N_LIST="1022 1522" AB_MODE=both ./run_product_pin_editdiff.sh
```

Host (same 3.7.11+3.9.13 binary, 2026-08-15). CSV: `results/ab_validate_product_pin_editdiff.csv`.

| N | Mode | Provision | Service | Total | Last service | Status |
|---|------|-----------|---------|-------|--------------|--------|
| 40 | full | 1.61 s | 2.52 s | 4.1 s | 82 ms | ok |
| 40 | edit-diff | 0.31 s | 0.39 s | 0.70 s | 9 ms | ok (~6.5×) |
| **1022** | full | **203 s** (38→371 ms) | **1546 s** (370→**2842 ms**) | **~29 min** | same 6-fail as Yocto pin | fail=6 |
| **1022** | edit-diff | **12.2 s** | **48.4 s** | **61 s** | **87 ms** | **ok** (PoC leak: those 6 still apply) |
| **1522** | full | **464 s** (42→598 ms) | **4282 s** (587→**5789 ms**) | **~79 min** | fail=0 | ok |
| **1522** | edit-diff | **20.3 s** | **183.5 s** | **3.4 min** | **368 ms** | ok |

N=1022 service **1546 / 48.4 ≈ 32×**. Total **29 min / 61 s ≈ 29×**. Last apply **2.84 s / 87 ms ≈ 33×**.  
N=1522 service **4282 / 184 ≈ 23×**. Total **79 min / 3.4 min ≈ 23×**. Last apply **5.79 s / 368 ms ≈ 16×** (PoC last-apply rises, same as 4.x at this N).  
Same binary as full — 3.x backport, not a 4.x/5.8 upgrade. Yocto-native full was ~36 min / ~93 min (no `-DNDEBUG`); this Release build is the same slope, smaller constant.

### Build (private 5.8)

```bash
cd /home/oreo/works/private/libyang/build
cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/home/oreo/works/private/libyang/install ..
cmake --build . -j$(nproc) && cmake --install .

cd /home/oreo/works/private/sysrepo/build
cmake -DCMAKE_BUILD_TYPE=Release \
  -DLIBYANG_INCLUDE_DIR=/home/oreo/works/private/libyang/install/include \
  -DLIBYANG_LIBRARY=/home/oreo/works/private/libyang/install/lib/libyang.so ..
cmake --build . -j$(nproc)
```

### Product-pin baseline (3.7.11 + 3.9.13)

Does not overwrite `.local/runtime` (4.5.4):

```bash
cd scripts/scale_cfg
# once: SCALECFG_RUNTIME_DIR=.local/runtime-yocto ./stage_from_yocto_sysrepo.sh
./run_product_pin_baseline.sh              # serial N=1022 and N=1522
AB_N_LIST=1022 ./run_product_pin_baseline.sh
AB_N_LIST=1522 AB_APPEND=1 ./run_product_pin_baseline.sh
```

### Private A/B

```bash
export SR_VALIDATE_EDIT_DIFF=1   # or unset for full
# ./run_ab_onu_scale.sh  — editdiff 1022/1522 then full 1022/1056
```

N≤100 A/B (same 4.5.4 binary): serial service N=40 **10.2×**; late #100 **6.4×**. CSV: `results/ab_validate_edit_diff.csv`.

N≥200 late `--edit` after edit-diff populate: full can fail (`if:type` / `when`); edit-diff may still succeed (PoC leak). CSV: `results/ab_validate_edit_diff_scale.csv`.

libyang 5.8 loads internal IETF modules from disk; `sr_ly_ctx_new` includes `ly_yang_module_dir()`.

---

## Feasibility and chosen path

| Option | Effect on O(N²) | Evidence | Decision |
|--------|-----------------|----------|----------|
| **A.** Believe recipe 3.13.5 is newer than 3.9.13 | None | Native `LY_VERSION` is still **3.9.13** | Not an upgrade |
| **B.** Upgrade sysrepo 4.x + libyang 5.x, keep full validate | Constant ~**2×** | N=1022 same harness: 36 min → 20 min; last service 3.38 s → 1.61 s | Useful, **not sufficient** |
| **C.** Backport [#2347](https://github.com/CESNET/libyang/issues/2347) onto 3.9.13 | ~10% if like their tree; maybe less here (little autodel) | Their when halved, wall ~10% | **Not primary** |
| **D.** Incremental validate (dirty ∪ deps, unknown→full) | **Flattens** per-RPC cost | 3.x same-binary: N=1022 **29 min → 61 s (~29×)**; N=1522 **79 min → 3.4 min (~23×)**. 4.x PoC similar wall at 1522 | **Primary** |
| **E.** Weaken YANG / skip validate / batch customer RPCs | Cheats semantics or rejected by ops | #2326: skip validate = UB | **No** |

**Chosen path:** complete **D** (dependency graph + dirty-subtree mandatory/`when` so PoC cannot accept illegal trees). Land either:

1. Stay on product 3.7.11 + 3.9.13 and **backport** the edit-diff APIs (smaller stack change), or
2. Move to 4.5.4 + 5.8 **and** ship a production-quality edit-diff (gets the extra ~2× on remaining full-validate fallbacks).

Do **not** treat bumping `PREFERRED_VERSION_LIBYANG` to 3.13.5 as done until `LY_VERSION` in the sysroot is actually 3.13.5. Do **not** ship today’s PoC as the production default (`SR_VALIDATE_EDIT_DIFF` stays off until leak is fixed).

---

## Limitations (PoC)

- DELETE/replace-key: list checks run; leafref reverse-deps not expanded.
- `must`/`when` with whole-tree XPath (`count(//...)`) need full validation.
- INV_DEP modules with no diff nodes are skipped when edit-diff is on.
- Keep full validation for import/upgrade/candidate commit.

## Next implementation steps

- Compile-time dependency graph; skip unchanged `when "derived-from-or-self(if:type,…)`.
- `lyd_validate_module_edit` fallback to full module when analysis is unknown.
- On dirty list instances, still enforce mandatory `if:type` and `when` (fix N≥200 false negative).

---

## Production tag vs latest tag (host, 2026-10-26)

Same host, same Release flags, same ONU workload, serial one apply per ONU, runs one after another.

| Stack | sysrepo | libyang | Source |
|-------|---------|---------|--------|
| prod | 3.7.11 | 3.9.13 | `~/works/private/sysrepo-3.7.11`, `libyang-3.9.13` (branch `Oreo/incremental-stale-index-3.9.13`) |
| latest | v5.2.27 | v6.4.13 (reports `LY_VERSION` 5.11.11) | `~/works/private/sysrepo` `Oreo/incremental-validation-v5.2.27` (`b6feee7c`), `libyang` `Oreo/incremental-validation-v6.4.13` (`8826cf748`) |

Each stack has two builds that differ only by `-DENABLE_VALIDATE_INCREMENTAL=ON|OFF`. Reproduce:

```bash
# stage: LY_PREFIX=<libyang install> SR_PREFIX=<sysrepo install> SCALECFG_RUNTIME_DIR=$PWD/.local/runtime-<stack>-<incr|full> ./stage_from_private_3x.sh
# helper: gcc sr_edit_files.c against .local/runtime-<stack>-incr -> .local/bin/sr_edit_files_<stack>
AB_N_LIST="40 1022" ./run_stack_compare.sh latest      # results/stack_cmp_latest*.csv
AB_N_LIST="40 1022" ./run_stack_compare.sh prod        # results/stack_cmp_prod*.csv
```

### N=1022 (CSV `results/stack_cmp_{prod,latest}.csv`)

| Stack | Validator | Provision | Service | Total | Last service apply |
|-------|-----------|-----------|---------|-------|--------------------|
| prod | full | 197.6 s | 1363.8 s | 26.0 min | 2.88 s |
| prod | incremental | 28.3 s | 131.6 s | 2.7 min | 0.244 s |
| latest | full | 102.8 s | 1007.4 s | 18.5 min | 1.91 s |
| latest | incremental | 27.7 s | 130.9 s | 2.6 min | 0.238 s |

- Version upgrade alone (full vs full): total **1.41x** faster (provision 1.9x, service 1.35x).
- Incremental validation on the same stack: prod **9.8x**, latest **7.0x** (total).
- Production full vs latest incremental: **9.9x** (26.0 min to 2.6 min).
- With the incremental validator both stacks end at the same time (158.5 s vs 159.9 s). Re-running the two
  incremental arms gave 142.5 s and 171.7 s, so differences below about 10 percent are noise.
- N=40: prod full 4.2 s, prod incremental 1.3 s, latest full 2.2 s, latest incremental 1.1 s.

### Correctness and fallbacks

- Final running datastore exported after the service phase (85,543 nodes) is identical for all four runs
  (canonical XML hash equal), at N=40 and N=1022.
- The same 6 service files (`SCLE00000001` to `06`) are rejected with "Validation failed" in all four runs, as in earlier
  product-pin runs: they fail on the data, not on the validator.
- Incremental validator fallbacks on this workload: **0 of 19,424** calls (10,220 provision, 9,204 service) on both
  stacks. The 12.4 percent seen in `tests/test_validation_incr` comes from a toy schema built to force fallbacks.
- Nested default under a cross-instance `when` (fixed 2026-10-28, libyang `Oreo/incremental-stale-index-3.9.13`):
  when an edit changes what such a `when` reads, the default can appear in list instances the edit did not touch,
  and the incremental pass never created or checked it there (wrong accept if the default breaks a `must`). These
  edits now fall back to full validation. In the 211 product modules with all features on, only
  `bbf-voip-sip:.../authentication/aka-secret-key` has this shape, and its feature
  `authentication-and-key-agreement` is not enabled by `setup_datastore.sh`, so the product workload is not affected.

### Assumption: stored data is valid

Incremental validation checks only what the edit can break. It trusts that the data in the datastore was valid
before the edit. Full validation checks everything, so it also reports old errors that the edit did not cause.

| Where invalid stored data can come from | Covered? |
|---|---|
| Module install, update, feature change | Yes. sysrepo fully validates startup, running and factory-default (`sr_lycc_update_data`). |
| Boot: running is copied from startup | No. `sr_shmmod_reboot_init` copies without validation. |
| Startup file or datastore written outside sysrepo | No. |
| A datastore plugin or validator bug | No. |

What happens if stored data is invalid:

- Incremental: an edit that does not touch the invalid part is accepted. The error stays until an edit touches that
  part, which is then rejected with an error about data the user did not change.
- Full: every edit to that module is rejected until the old error is fixed.

With stock sysrepo the first edit after boot runs a full validation and finds bad startup data. With incremental
validation that check is gone. If this matters, add one full validation per module on the first edit after boot
(not implemented). `sr_validate()` does not help: on running with no pending edit it validates no module.

### Caveats

- Host Release builds, not the Yocto image: earlier Yocto-native product numbers are slower (service 1901 s at N=1022).
- N=1522 not rerun on the new stack.
- `sr_edit_files.c`: `SR_EDIT_LOG_WRN=1` prints sysrepo info and warning logs (fallback counter).
  `ab_validate_edit_diff.sh`: `AB_EXPORT_AFTER=1` exports running after the service phase for state comparison.
