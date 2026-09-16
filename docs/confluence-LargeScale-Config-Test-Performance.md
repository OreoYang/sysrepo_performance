# LargeScale Config Test Performance

**Last updated:** 2026-08-15

Host-side **Mode S** benchmark: serial per-ONU `sysrepocfg --edit` / `sr_edit_files` on ~1022–1522 ONU (provision + service). Measures **sysrepo + libyang** only — not netopeer2, netconf-polt, or OMCI.

**Harness:** [sysrepo_performance](https://github.com/OreoYang/sysrepo_performance) → `scripts/scale_cfg`

---

## 概要

- 每条 ADD-ONU RPC 触发 `sr_apply_changes` → **整模块** `lyd_validate_module`，对已有 `ietf-interfaces` 反复跑 `when derived-from-or-self(if:type,…)`。
- N 次独立 RPC → 单次耗时随 N 线性增长 → **总墙钟 O(N²)**（1022 ONU 约 36 min，1522 约 93 min）。
- 瓶颈在 **YANG validate**，不是 `sysrepocfg` fork 冷启动（D2b fork vs 长会话 harness 同量级）。
- 产品钉 **recipe libyang 3.13.5 实为 LY_VERSION 3.9.13**；升 4.5.4+5.8 全量 validate 仅约 **2×** 常数改善，斜率不变。
- **edit-diff 增量校验 PoC**（`SR_VALIDATE_EDIT_DIFF=1`）同二进制 A/B：**23–32×**；3.x backport 已验证。PoC 有漏检，**不能默认开启**。

---

## 测试平台

| 项 | 说明 |
|----|------|
| Host | WSL2 / x86_64 开发机 |
| 输入 | `largescaleDb.tar` → `export.xml` → 1022 provision + 1016 service XML |
| 并发 | **单线程**串行 edit（与现场 per-ONU RPC 一致，不可批量） |
| Harness | `sr_edit_files` 长会话 `sr_edit_batch` + `sr_apply_changes`；对照 D2b 为 fork `sysrepocfg --edit` |
| 不在范围 | netopeer2、netconf-polt change callback、OMCI、真机 NETCONF |
| 现场对比 | 整机 Mode S ~7 h vs host 1022 ~36 min / 1522 ~93 min（host 仅 sysrepo+libyang） |

---

## 组件版本（产品钉）

来源：`meta-xpon/conf/distro/include/xpon-oss-manifest.conf`

| 组件 | Recipe / 实测 |
|------|----------------|
| sysrepo | **3.7.11** (SO 7.34.6) |
| libyang | Recipe **3.13.5**，native **`LY_VERSION 3.9.13`** (`libyang.so.3.9.13`) |
| netopeer2 / libnetconf2 | 2.4.5 / 3.7.10 |
| YANG | xpon-yang（~249 modules） |
| meta-xpon patch | sysrepo: SHM/sort/factory-reset；**libyang bbappend 无 validation patch** |

私有对比栈：sysrepo **4.5.4** + libyang **5.8.6**（Release）。  
3.x edit-diff backport：`libyang-3.9.13` + `sysrepo-3.7.11` worktrees（产品 SHA）。

---

## 测试结果

### D2b 基线（fork sysrepocfg，2026-07-30）

| 阶段 | 结果 | 墙钟 |
|------|------|------|
| Provision 1022 | 1022/1022 ok | ~340 s |
| Service 1016 | 1016/1016 ok | ~1908 s |
| **合计** | | **~37 min** |

末次 service #1016：**3042 ms**。

### 产品钉全量 validate（Yocto native，`sr_edit_files`，2026-08-14）

| N | Provision | Service | Total | 末次 service |
|---|-----------|---------|-------|--------------|
| 1022 | 252 s (38→447 ms) | 1901 s (423→**3378 ms**) | **~36 min** | fail=6* |
| 1522 | 545 s (39→744 ms) | 5010 s (760→**6979 ms**) | **~93 min** | ok |

\*1022 截断 harness：后 6 条 service 对应未 provision 的 ONU（0180, 0239–0242, 0976）；先 provision 1522 则无此 fail。

### 同 harness：4.5.4 + 5.8 全量 vs edit-diff PoC

| N | full total | edit-diff total | 加速 |
|---|------------|-----------------|------|
| 1022 | ~20 min | **43 s** | ~50× |
| 1522 | — | **3.4 min** | ~27× (vs Yocto 93 min) |

### 产品钉 3.x edit-diff backport（同二进制 A/B，host Release，2026-08-15）

| N | full | edit-diff | 加速 |
|---|------|-----------|------|
| 1022 | 29 min (末次 2.84 s, fail=6) | **61 s** (末次 87 ms) | **~29×** |
| 1522 | 79 min (末次 5.79 s) | **3.4 min** (末次 368 ms) | **~23×** |

CSV：`scripts/scale_cfg/results/ab_validate_product_pin*.csv`、`ab_validate_product_pin_editdiff.csv`

---

## 问题分析

### 根因

```text
sr_apply_changes → sr_modinfo_validate → lyd_validate_module (整模块)
                 → 每条 interface 的 when/must/leafref  ≈ O(N) per RPC
N 次独立 RPC                                    ≈ O(N²) 总时间
```

热点：`ietf-interfaces` 上 `when "derived-from-or-self(if:type, …)"` — 即使本 RPC 未改该 instance，全树 validate 仍会重算。

### libyang / sysrepo 上游 issue（CESNET）

| Issue | 与 XPON 关系 | 结论 |
|-------|--------------|------|
| [#1382](https://github.com/CESNET/libyang/issues/1382) validate from diff | 同类需求；维护者：libyang 2+ **不做**跨 apply 的 validate 缓存 | 需新 API + 依赖图 + 未知时回退全量 |
| [#894](https://github.com/CESNET/libyang/issues/894) `LYD_VAL_OK` | FRR；`when` 不缓存 | 同 #1382 设计 |
| [#2347](https://github.com/CESNET/libyang/issues/2347) `node_when` 分层 | 最接近；他们树 when ~50% wall，**整体验证仍 ~89%** | 约 **10%** 墙钟；**不跳过**未改 sibling interface |
| [#865](https://github.com/CESNET/libyang/issues/865) `must` O(n²) | SONiC ACL | 我们是大量廉价 per-instance `when` × N |
| [#1831](https://github.com/CESNET/libyang/issues/1831) leafref | 大组件 embedded validate | 我们有 tcont/gem/fwd leafref，斜率仍匹配 interface when |
| [#2326](https://github.com/CESNET/libyang/issues/2326) | 跳过 validate = UB | 不能关 validate |
| [#706](https://github.com/CESNET/libyang/issues/706) | `lyd_new` ≠ full validate | `sr_apply_changes` 走 `lyd_validate_module` |

### PoC 局限

- `SR_VALIDATE_EDIT_DIFF=1` 仅校验 edit-diff 脏子树；**无完整依赖图** → N≥200 可能 **false negative**（全量 reject，edit-diff 仍成功）。
- N=1022 上 6 条非法 service 在 edit-diff 下仍 apply 成功（漏检例证）。
- 默认必须 **关闭**；import/upgrade/candidate commit 仍须全量 validate。

---

## 后续可行性方案

| 选项 | 对 O(N²) | 证据 | 建议 |
|------|----------|------|------|
| A. 认为 recipe 3.13.5 已升级 | 无 | `LY_VERSION` 仍为 3.9.13 | **否** |
| B. 升 sysrepo 4.x + libyang 5.x，保持全量 validate | 常数 ~2× | 36 min → 20 min (1022) | 有用，**不够** |
| C. Backport [#2347](https://github.com/CESNET/libyang/issues/2347) 到 3.9.13 | ~10% wall | 他们 autodel when 场景 | **非主路径** |
| **D. 增量 validate**（dirty ∪ deps，未知→全量 fallback） | **打平 per-RPC** | 3.x：**29 min→61 s**；1522：**79 min→3.4 min** | **主路径** |
| E. 弱化 YANG / 跳过 validate / 合并 RPC | 作弊或运维不接受 | #2326 UB | **否** |

**推荐落地：**

1. **短期（产品栈）：** 在 **3.7.11 + 3.9.13** 上完成 production-quality edit-diff（依赖图 + dirty 子树 mandatory/`when`），经 Yocto bbappend 进镜像；`SR_VALIDATE_EDIT_DIFF` 默认 off，修完漏检后再评估默认开。
2. **中期：** 可选同步升 4.5.4+5.8，全量 fallback 再快约 2×。
3. **验证：** host A/B 已完成；下一步 **Yocto 编镜 + 整机 Mode S** 复测同 CSV 口径。
4. **不要** 仅 bump `PREFERRED_VERSION_LIBYANG` 到 3.13.5 当作完成 — 须确认 sysroot `LY_VERSION` 真变。

---

## 参考

- 详细数据与脚本：`sysrepo_performance/scripts/scale_cfg/INCREMENTAL_VALIDATION.md`
- 产品钉全量：`./run_product_pin_baseline.sh`
- 3.x edit-diff：`./stage_from_private_3x.sh` + `./run_product_pin_editdiff.sh`
