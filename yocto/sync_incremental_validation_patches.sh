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

cat >"$BODY_LY" <<EOF
Squashed incremental validation on product libyang 3.9.13 (Yocto SRCREV
${LIBYANG_BASE:0:8}) through the current Oreo/incremental-stale-index-3.9.13 tip.
Applies with git am on a clean checkout at the base revision.

Validate only what an edit diff can have changed instead of the whole module.
lyd_validate_module_incr() builds a scope from the diff, checked against a
per-context dependency index (validation_deps.c), with fallback to full
lyd_validate_module() when safety cannot be proved (including late fallback
when validation deletes nodes). See tests/utests/data/test_validation_incr.c.
EOF

cat >"$BODY_SR" <<EOF
Squashed incremental validation on product sysrepo 3.7.11 (Yocto SRCREV
${SYSREPO_BASE:0:8}) through the current Oreo/incremental-validation-3.7.11 tip.
Applies with git am on a clean checkout at the base revision (after meta-xpon
patches 0001-0003).

sr_modinfo_validate() uses lyd_validate_module_incr() when the edit diff is
complete (build option ENABLE_VALIDATE_INCREMENTAL, default ON). See
tests/test_validation_incr.c.
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

LY_HEAD="$(git -C "$LIBYANG_DIR" rev-parse --short HEAD)"
SR_HEAD="$(git -C "$SYSREPO_DIR" rev-parse --short HEAD)"
if grep -q 'Squash tips' "$OUT/APPLY.txt" 2>/dev/null; then
  sed -i "s/^Squash tips.*/Squash tips: libyang ${LY_HEAD} on base ${LIBYANG_BASE:0:8}; sysrepo ${SR_HEAD} on base ${SYSREPO_BASE:0:8}./" \
    "$OUT/APPLY.txt"
fi

echo "Done. Verify: git am on libyang/sysrepo bases; git apply --check -p1 meta-xpon bundle on ${META_XPON_BASE:0:7}."
