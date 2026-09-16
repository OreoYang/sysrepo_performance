# sysrepo 3.x edit-diff incremental validation

**Status:** approved (host A/B this round; Yocto/整机 later)  
**Date:** 2026-08-15

## Goal

Port the existing edit-diff PoC onto the **product pin** (sysrepo 3.7.11 + libyang 3.9.13) so host A/B can prove the O(N²) flatten still holds on the stack that will go to the OLT.

## Trees

Do **not** modify `~/works/private/libyang` (5.8.6) or `~/works/private/sysrepo` (4.5.4).

| Path | Pin | Branch |
|------|-----|--------|
| `~/works/private/libyang-3.9.13` | Yocto `libyang_3.13.5.bb` `SRCREV efe43e37` (`LY_VERSION` 3.9.13) | `edit-diff-3.9.13` |
| `~/works/private/sysrepo-3.7.11` | Yocto `sysrepo_3.7.11.bb` `v3.7.11` / `1b720b19` | `edit-diff-3.7.11` |

## Behavior

- libyang: `lyd_validate_module_edit` / `_final` validate only subtrees referenced by `yang:operation` create/replace on `notify_diff`.
- sysrepo: `sr_modinfo_validate` uses those APIs iff `SR_VALIDATE_EDIT_DIFF=1` and `notify_diff` is present. Default remains full `lyd_validate_module`.
- 3.9 adaptation: call `lyd_validate_subtree` (not 5.8 `lyd_validate_tree`); pass `ext_node` into `lyd_validate_unres`; pass `ext=NULL` into `lyd_validate_siblings_schema_r`.

## Out of scope this round

Yocto bbappend, OLT image, fixing PoC false negatives, test XML, 4.x trees.

## Success

Same 3.x binary, host harness:

- env unset ≈ existing product-pin baseline (N=1022 ~36 min, N=1522 ~93 min)
- env=1 order-of-magnitude drop vs that baseline (4.x PoC was ~50× / ~27×)
