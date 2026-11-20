# Check the running and startup databases for bad data (no change to production)

**Goal:** find out whether the running or startup datastore holds data that full YANG validation would reject, for
example data that incremental validation let in. Nothing on the OLT is changed.

**Scope:** running and startup only. Incremental validation applies to edits of these two datastores (`sr_apply_changes`,
copy-config, edit-config). The candidate datastore is not validated on apply and the operational datastore is state
owned by publishers, so neither is checked.

## One command, on the OLT

```bash
sr_validate_ds              # running and startup
sr_validate_ds -d running   # one of them (running | startup | both)
```

```
VALID    running  full validation, 0.11 s
INVALID  startup  full validation failed:
  - Invalid leafref value "NO-SUCH-VANI" ... (path /ietf-interfaces:interfaces/interface[name=...]/...)
```

| Exit | Meaning |
|---|---|
| 0 | Every checked datastore passes full validation |
| 1 | At least one datastore holds data that full validation rejects. Each error is printed with its data path |
| 2 | Tool or connection problem |

## How it works

`sr_validate()` on running or startup checks only a pending edit, so with no edit it checks nothing. The tool therefore:

1. reads the datastore with `sr_get_data()` (a copy of the configuration in memory), and
2. runs libyang's `lyd_validate_all()` on the copy. That function always validates the whole tree in full (when, must,
   leafref, unique, mandatory, min/max-elements). It never takes the incremental path.

It uses only the public API of the `libsysrepo` and `libyang` already installed on the OLT. It writes nothing, applies no
edit, takes read locks only (0.11 s on Chicago, 247 modules), and needs no reboot or restart.

### Where it comes from

`sr_validate_ds` is part of the `xpon-apps` repository (`sr-validate/`), built by the existing `xpon-apps` recipe and
installed in `/usr/bin` of the OLT image. No extra recipe, no copy step: images built after that change have it.

### Older image without the tool (fallback)

The tool is one C file (`xpon-apps/sr-validate/sr_validate_ds.c`). The OLT image has no compiler but is x86_64, so build
on a PC against the headers of the image (same sysrepo version) and copy the binary:

```bash
cd ~/works/private/sysrepo_performance/scripts/scale_cfg
tools/build_sr_validate_ds.sh .local/runtime-prod-rel-incr /tmp/sr_validate_ds
scp /tmp/sr_validate_ds root@<olt>:/root/chicago_smoke/olt/
```

The build script sets the Yocto dynamic linker (`/lib/ld-linux-x86-64.so.2`). On "required file not found" rebuild with
the script. The binary uses the image's own `libsysrepo.so.7` and `libyang` at run time.

## Proven on test data

A copy of the Chicago data, after one `lower-layer-interface` was changed to a name that does not exist. Running is
copied from startup at boot without validation, so bad data can sit in either place:

| Where the bad data is | running | startup |
|---|---|---|
| nowhere | VALID | VALID |
| only in the startup file | VALID | INVALID |
| only in the running datastore | INVALID | VALID |

The result was the same for the incremental build and the full-only build. For contrast, a `sysrepocfg --edit` of an
unrelated module on the incremental build accepts such data (rc 0): an edit only checks what it touches.

## Limits

- It finds bad data that is **already stored**. It does not prove that every future edit is judged like full validation.
  For that use the A/B runs (`run_product_pin_editdiff.sh`, `run_product_pin_voip_editdiff.sh`, `AB_EXPORT_AFTER=1`).
- Configuration only (`LYD_VALIDATE_NO_STATE`), no operational state.
- Schema install, upgrade and context change already validate in full inside sysrepo, they are not what this checks.

## Deeper check on a PC (optional)

`scripts/scale_cfg/audit_running_snapshot.sh` replays an exported running on a PC with the full-only and the incremental
build and probes edits through both. It needs the `xpon-yang` of the image. Use it for the differential comparison, not
for a routine check.
