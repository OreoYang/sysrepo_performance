#!/usr/bin/env bash
# Regenerate yocto/device-patches from libyang/sysrepo product worktrees.
# Run before any commit that touches device-patches or when libyang/sysrepo move.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="$SCRIPT_DIR/device-patches"

LIBYANG_DIR="${LIBYANG_DIR:-$HOME/works/private/libyang-3.9.13}"
SYSREPO_DIR="${SYSREPO_DIR:-$HOME/works/private/sysrepo-3.7.11}"
META_XPON_DIR="${META_XPON_DIR:-$HOME/works/repo/vcmos/meta-xpon}"

LIBYANG_BASE="${LIBYANG_BASE:-efe43e3790822a3dc64d7d28db935d03fff8b81f}"
SYSREPO_BASE="${SYSREPO_BASE:-1b720b196f630f348d9e0c131d326b3fb8c6aca7}"
META_XPON_BASE="${META_XPON_BASE:-cbb2a433c2ec23a25377b57cef95b7d47e05c292}"

gen_squash_patch() {
  local repo="$1" base="$2" out="$3" subject="$4" body_file="$5"
  (
    cd "$repo"
    local head_hash date
    head_hash="$(git rev-parse HEAD)"
    date="$(git log -1 --format='%aD' HEAD)"
    {
      echo "From ${head_hash} Mon Sep 17 00:00:00 2001"
      echo "From: OreoYang <oreo.yang@vecima.com>"
      echo "Date: ${date}"
      echo "Subject: [PATCH] ${subject}"
      echo
      cat "$body_file"
      echo "---"
      git diff "${base}..HEAD" --stat
      echo
      git diff "${base}..HEAD"
    } >"$out"
    echo "wrote $out ($(wc -l <"$out") lines) from ${repo} ${base:0:7}..${head_hash:0:7}"
  )
}

BODY_LY="$(mktemp)"
BODY_SR="$(mktemp)"
trap 'rm -f "$BODY_LY" "$BODY_SR"' EXIT

LY_HEAD="$(git -C "$LIBYANG_DIR" rev-parse --short HEAD)"
SR_HEAD="$(git -C "$SYSREPO_DIR" rev-parse --short HEAD)"

cat >"$BODY_LY" <<EOF
Validating a whole module after every edit is quadratic in the size of the
datastore, which dominates the cost of provisioning thousands of instances.

Add lyd_validate_module_incr(): every when/must/leafref/unique constraint is
classified by how far its dependencies reach (local, list-scope, bounded,
unbounded) and cached per context. Given a diff that describes every change
since the data were last valid, only the subtrees the diff can invalidate are
revalidated. Whatever cannot be reduced to a finite set of paths falls back to
full validation, so the verdict always equals validating the whole module. A
late fallback is taken when validation itself deletes a node. Counters are
exposed by lyd_validate_incr_stats() and lyd_validate_incr_late_stats().

Later fixes in this series: dependency index rebuilt after schema changes,
default nodes appearing in untouched list instances, mandatory/min-elements
nodes behind a remote when, relative negation/count/arithmetic reading sibling
instances, deep delete chains, and shallow scope for list deletes
(LYD_VALIDATE_INCR_SHALLOW_DELETE). Differential unit tests compare every case
against full validation.
EOF

cat >"$BODY_SR" <<EOF
sr_apply_changes() and the copy-config/replace-config path reach
sr_changes_notify_store() with a notify_diff that describes every change made
to the stored data, which is the precondition of libyang's incremental
validator. Validate changed modules with lyd_validate_module_incr() instead of
in full; whenever libyang cannot prove the edit safe, the module is validated
in full as before.

Incremental validation is a build option: cmake -DENABLE_VALIDATE_INCREMENTAL=ON
(default) or OFF (every edit validated in full). Each process logs once, at its
first sr_connect, which one it was built with. At sr_disconnect the call,
fallback and late-fallback counters are logged, as a warning only when there
were fallbacks. The shallow delete option is passed from modinfo, and the
assumption that the stored data was valid before the edit is documented.

Tests: end-to-end sr_apply_changes cases (cross-module leafref, must, when,
cascades, replaced default case), delete matrix, and add/modify/product-shape
differential cases that expect the same verdict as full validation.

Requires the libyang incremental validation patch.
EOF

for d in "$LIBYANG_DIR" "$SYSREPO_DIR"; do
  git -C "$d" rev-parse HEAD >/dev/null 2>&1 || { echo "missing git repo: $d" >&2; exit 1; }
done

gen_squash_patch "$LIBYANG_DIR" "$LIBYANG_BASE" \
  "$OUT/libyang-incremental-validation.patch" \
  "validation FEATURE incremental validation driven by an edit diff" \
  "$BODY_LY"

gen_squash_patch "$SYSREPO_DIR" "$SYSREPO_BASE" \
  "$OUT/sysrepo-incremental-validation.patch" \
  "validation FEATURE use the incremental validator when the diff is complete" \
  "$BODY_SR"

if git -C "$META_XPON_DIR" rev-parse HEAD >/dev/null 2>&1; then
  cp "$OUT/libyang-incremental-validation.patch" \
    "$META_XPON_DIR/recipes-extended/libyang/libyang/0001-validation-FEATURE-incremental-validation-driven-by-.patch"
  cp "$OUT/sysrepo-incremental-validation.patch" \
    "$META_XPON_DIR/recipes-extended/sysrepo/sysrepo/0004-validation-FEATURE-use-the-incremental-validator-whe.patch"
  (
    cd "$META_XPON_DIR"
    git rev-parse --verify "$META_XPON_BASE^{commit}" >/dev/null
    git diff "${META_XPON_BASE}..HEAD" >"$OUT/meta-xpon-incremental-validation.patch"
    echo "wrote $OUT/meta-xpon-incremental-validation.patch from meta-xpon ${META_XPON_BASE:0:7}..HEAD"
  )
else
  echo "META_XPON_DIR not found; skipped meta-xpon-incremental-validation.patch" >&2
fi

if grep -q 'Squash tips' "$OUT/APPLY.txt" 2>/dev/null; then
  sed -i "s/^Squash tips.*/Squash tips: libyang ${LY_HEAD} on base ${LIBYANG_BASE:0:8}; sysrepo ${SR_HEAD} on base ${SYSREPO_BASE:0:8}./" \
    "$OUT/APPLY.txt"
fi

echo "Done. Verify: git am on libyang/sysrepo bases; git apply --check -p1 meta-xpon bundle on ${META_XPON_BASE:0:7}."
