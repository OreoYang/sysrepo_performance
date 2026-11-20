# Design: `sr_validate_ds` (read-only full validation of running and startup)

Status: for review. Branch `Oreo/sr-validate-ds` in `xpon-apps`, not committed.

## Purpose

Incremental YANG validation checks only what an edit can have changed. Two kinds of bad data can therefore stay in the
datastore:

- **Wrong-accept:** an edit that full validation would reject, but incremental validation accepted.
- **Previously inconsistent data:** data that was already bad before the edit (copied from startup at boot, written
  around sysrepo, left by an interrupted process). Incremental validation does not check it again.

`sr_validate_ds` detects both on a live OLT. It has three modes, all with full validation, none writing anything:

| Mode | Question it answers |
|---|---|
| Stored data (default) | Does the stored running or startup configuration pass full validation right now? |
| Edit dry run (`-e`) | Would full validation accept this edit-config content on running or startup? |
| Copy-config source (`-f`) | Would this file pass full validation as the whole new content of a datastore? |

It needs no reboot and no restart.

Scope: running and startup only. Candidate (not validated on apply) and operational (state owned by publishers) are out
of scope.

## Usage

```bash
sr_validate_ds                         # stored running and startup
sr_validate_ds -d running              # running | startup | both (default both)
sr_validate_ds -d running -e edit.xml  # dry run of an edit-config content (merge), nothing is applied
sr_validate_ds -f config.xml           # copy-config source file, no datastore is read
sr_validate_ds -v                      # also show sysrepo log lines
```

`FILE` is XML, or JSON when the name ends with `.json`. It holds top-level data nodes, as for `sysrepocfg --edit` and
`sysrepocfg --import`: the children of `<config>`, not the `<rpc>` envelope. `nc:operation` attributes (create, delete,
replace, ...) are supported in `-e`. `-e` and `-f` cannot be combined.

```
VALID    running  full validation, 0.08 s
INVALID  startup  full validation failed:
  - Invalid leafref value "NO-SUCH-VANI" ... (path /ietf-interfaces:interfaces/interface[name=...]/...)

INVALID  running  edit bad_delete.xml rejected (Validation failed):
  - Invalid leafref value "ALCLFCAA6718-vani" ... (path "/bbf-xpongemtcont:xpongemtcont/tconts/tcont[...]/...")
```

| Exit | Meaning |
|---|---|
| 0 | Every checked datastore passes full validation |
| 1 | Invalid: stored data, edit or file rejected (also an edit or file that does not match the schema). Each error is printed |
| 2 | Wrong option, file not readable, empty edit, or connection problem |

Check the exit code right after the tool. A pipe such as `| grep` hides it.

## How it works

The tool opens its own sysrepo connection. Files are parsed with the schema of the OLT, with the same options as
`sysrepocfg`.

| Mode | Steps |
|---|---|
| Stored data | `sr_get_data(sess, "/*", ...)` copies the whole configuration, libyang `lyd_validate_all()` validates the copy |
| Edit dry run | `sr_edit_batch(sess, edit, "merge")`, then `sr_validate(sess)`, then `sr_discard_changes(sess)` |
| Copy-config source | Parse the file, then `lyd_validate_all()` on it. Every module counts, a module missing from the file is empty |

Full validation checks `when`, `must`, `leafref`, `unique`, mandatory and min/max-elements. None of the modes takes the
incremental path:

- `lyd_validate_all()` is always full validation.
- `sr_validate()` on running or startup applies the session edit to a copy and calls `sr_modinfo_validate()` with no
  finished diff, so it validates the changed modules, and the modules that depend on them, in full. The incremental
  path needs a finished edit diff and exists only inside sysrepo apply-changes.
- `sr_validate()` alone is not used for stored data: on running and startup it checks only a pending edit and does
  nothing when there is none.

## Impact

| Area | Impact |
|---|---|
| Datastores | None. Nothing written in any mode. The `-e` edit lives only in the tool's session and is discarded |
| Running daemons | None. Own connection; no subscriptions, no callbacks, no change events (also for `-e`) |
| Locks | Short read locks while data is read or validated (as `sr_get_data` and `sr_validate`) |
| Time and memory | 0.08 s per datastore on Chicago. Memory is one copy of the configuration, freed on exit |
| Reboot or restart | Not needed |
| YANG, protobuf, netconf-polt, DbgCli | No change |
| Build and image | One small binary, `/usr/bin/sr_validate_ds`. No new Yocto recipe |

## Changed repo: `xpon-apps`

| File | Change |
|---|---|
| `sr-validate/sr_validate_ds.c` | New. The tool (about 330 lines) |
| `sr-validate/CMakeLists.txt` | New. `make_bin(sr_validate_ds)`, links `sysrepo` and `yang`, same pattern as `debug-client` |
| `CMakeLists.txt` | One line: `add_subdirectory(sr-validate)` inside the `xpon` block |
| `sr-validate/test/` | CTest `sr_validate_ds`: builds its own small database from `vds-test.yang` (leafref and must), 21 cases for stored data, `-e` and `-f`. Needs only `sysrepoctl` and `sysrepocfg`, skipped when they are missing |

No change in `meta-xpon`. The existing `xpon-apps` recipe packages `${bindir}` by default, so the binary ships like
`dbc`. The `dpoe` build is not touched.

## Verification done

| Test | Result |
|---|---|
| Strict compile (`-Wall -Wextra -Werror`) against sysrepo 3.7.11 headers | Clean |
| Host, Chicago-scale data copy, clean | exit 0, both `VALID` |
| Bad value only in startup | `INVALID startup`, exit 1 |
| Bad value only in running (after SHM init) | `INVALID running`, `VALID startup`, exit 1 |
| Bad option, or `-e` with `-f` | usage message, exit 2 |
| `-e` good edit (merge a description) | `VALID running`, exit 0 |
| `-e` bad leafref (JSON, both datastores) | `INVALID` running and startup, leafref and `must` errors, exit 1 |
| `-e` `nc:operation="delete"` of a v-ani still in use | `INVALID`, errors in `ietf-interfaces` and `bbf-xpongemtcont`, exit 1 |
| `-e` `nc:operation="create"` of an existing interface | `INVALID`, "already exists", exit 1 |
| `-e` unknown leaf | `INVALID`, does not match the schema, exit 1 |
| `-e` missing file | exit 2 |
| Stored data after all `-e` runs | Byte-identical (md5 of running and startup) |
| `-f` full export of running | `VALID`, exit 0 |
| `-f` same export with a bad leafref | `INVALID`, exit 1 |
| `-f` export of one module only | `INVALID` (references into other modules), exit 1 |
| Chicago OLT, live (earlier build, stored-data mode only) | `VALID` both, 0.08 s, exit 0 |

How to repeat the PC test: `docs/running-snapshot-audit.md`.

## Not done yet

- `bitbake xpon-apps -c compile -f` and a check that the binary lands in the image. The Yocto workspace builds the
  `Oreo/XGS-11457-lz4` branch, which does not contain this change.
- Run of the image-built binary on Chicago, including `-e` and `-f`.

## Limits

- Stored-data mode checks the data present now. It does not say which edit let bad data in. For edit replay
  (incremental against full) use the host A/B tools (`flip_diff_check.py`, product-pin edit-diff).
- `-e` uses default-operation merge. It does not run the "update" callbacks of subscribers or NACM, so an edit that an
  application would change or that a user may not write is judged as sent.
- `-e` gives the full-validation verdict. It does not show what incremental validation would decide for the same edit.
- `-f` treats the file as the whole datastore (copy-config without a module filter). A file with only some modules
  fails on the missing references.
- Configuration only. State data is skipped, as in apply validation.
- Running is copied from startup at boot without validation, so bad data can sit in only one of them. Check both.
- Not a proof of "no wrong-accept ever". `VALID` covers the data present at that moment.

## Review questions

1. Is `/usr/bin` the right place, or should it be a support or debug path?
2. Keep it in the `xpon` block only (current), or also build it for `dpoe`?
3. Should the exit-code contract (0, 1, 2) be kept as is for scripts and health checks?
