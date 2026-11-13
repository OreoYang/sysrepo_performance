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

commit_list() {
  git -C "$1" log --reverse --format='  %h %s' "$2..HEAD"
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

Squash of Oreo/incremental-stale-index-3.9.13 (${LY_HEAD}) on the product base
${LIBYANG_BASE:0:12} (Yocto libyang_3.13.5). Commits:
$(commit_list "$LIBYANG_DIR" "$LIBYANG_BASE")
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

Requires the libyang incremental validation patch. Squash of
Oreo/incremental-validation-3.7.11 (${SR_HEAD}) on the product base
${SYSREPO_BASE:0:12} (Yocto sysrepo_3.7.11). Commits:
$(commit_list "$SYSREPO_DIR" "$SYSREPO_BASE")
EOF

die() { echo "ERROR: $*" >&2; exit 1; }

# Preflight: a squash is base..HEAD, so anything not committed would be silently missing from the patches.
preflight_repo() {
  local d="$1" base="$2" branch untracked
  git -C "$d" rev-parse HEAD >/dev/null 2>&1 || die "missing git repo: $d"
  git -C "$d" rev-parse --verify "${base}^{commit}" >/dev/null 2>&1 || die "$d: base ${base:0:12} not found"
  git -C "$d" merge-base --is-ancestor "$base" HEAD || die "$d: HEAD does not contain base ${base:0:12}"
  branch="$(git -C "$d" branch --show-current)"
  [[ "$branch" == Oreo/* ]] || die "$d: branch '$branch' does not start with Oreo/"
  git -C "$d" diff --quiet HEAD -- || die "$d: tracked files have uncommitted changes, commit them first (they would be missing from the patch)"
  untracked="$(git -C "$d" ls-files --others --exclude-standard -- src tests CMakeLists.txt)"
  [[ -z "$untracked" ]] || die "$d: untracked source files would be missing from the patch:
$untracked"
}

preflight_repo "$LIBYANG_DIR" "$LIBYANG_BASE"
preflight_repo "$SYSREPO_DIR" "$SYSREPO_BASE"

gen_squash_patch "$LIBYANG_DIR" "$LIBYANG_BASE" \
  "$OUT/libyang-incremental-validation.patch" \
  "validation FEATURE incremental validation driven by an edit diff" \
  "$BODY_LY"

gen_squash_patch "$SYSREPO_DIR" "$SYSREPO_BASE" \
  "$OUT/sysrepo-incremental-validation.patch" \
  "validation FEATURE use the incremental validator when the diff is complete" \
  "$BODY_SR"

PATCH_LY_NAME="0001-validation-FEATURE-incremental-validation-driven-by-.patch"
PATCH_SR_NAME="0004-validation-FEATURE-use-the-incremental-validator-whe.patch"
LY_BBAPPEND="recipes-extended/libyang/libyang_%.bbappend"
SR_BBAPPEND="recipes-extended/sysrepo/sysrepo_%.bbappend"
LY_PATCH_PATH="recipes-extended/libyang/libyang/$PATCH_LY_NAME"
SR_PATCH_PATH="recipes-extended/sysrepo/sysrepo/$PATCH_SR_NAME"
BUNDLE="$OUT/meta-xpon-incremental-validation.patch"

git -C "$META_XPON_DIR" rev-parse HEAD >/dev/null 2>&1 || die "META_XPON_DIR not found: $META_XPON_DIR (set META_XPON_DIR); libyang/sysrepo patches were written, the meta-xpon bundle was NOT"
git -C "$META_XPON_DIR" rev-parse --verify "${META_XPON_BASE}^{commit}" >/dev/null 2>&1 || die "meta-xpon base ${META_XPON_BASE:0:12} not found in $META_XPON_DIR"

# Insert a file:// entry before the closing quote of "SRC_URI += \" in a bbappend read from stdin.
add_src_uri() {
  awk -v entry="    file://$1 \\\\" '
    /^SRC_URI \+= "\\$/ { in_src = 1 }
    in_src && $0 == "\"" { print entry; in_src = 0 }
    { print }'
}

# Build the bundle as base -> (base + 0001/0004 + two bbappend lines) in a throw-away index and object store, so it
# needs no commit in meta-xpon and does not touch its working tree, index or objects.
(
  cd "$META_XPON_DIR"
  TMPD="$(mktemp -d)"
  trap 'rm -rf "$TMPD"' EXIT
  export GIT_ALTERNATE_OBJECT_DIRECTORIES="$(git rev-parse --absolute-git-dir)/objects"
  export GIT_OBJECT_DIRECTORY="$TMPD/objects"
  export GIT_INDEX_FILE="$TMPD/index"
  mkdir -p "$GIT_OBJECT_DIRECTORY"
  git read-tree "$META_XPON_BASE"

  put() { git update-index --add --cacheinfo "100644,$(git hash-object -w --stdin),$1"; }
  put "$LY_PATCH_PATH" <"$OUT/libyang-incremental-validation.patch"
  put "$SR_PATCH_PATH" <"$OUT/sysrepo-incremental-validation.patch"
  git show "${META_XPON_BASE}:${LY_BBAPPEND}" | add_src_uri "$PATCH_LY_NAME" | put "$LY_BBAPPEND"
  git show "${META_XPON_BASE}:${SR_BBAPPEND}" | add_src_uri "$PATCH_SR_NAME" | put "$SR_BBAPPEND"

  git diff --cached --no-color "$META_XPON_BASE" >"$BUNDLE"
  echo "wrote $BUNDLE ($(wc -l <"$BUNDLE") lines) from meta-xpon ${META_XPON_BASE:0:7} + current squash patches"
)

# Optional: also drop the two patch files into the meta-xpon working tree (SYNC_META_XPON_TREE=1).
if [[ "${SYNC_META_XPON_TREE:-0}" == 1 ]]; then
  mkdir -p "$META_XPON_DIR/$(dirname "$LY_PATCH_PATH")" "$META_XPON_DIR/$(dirname "$SR_PATCH_PATH")"
  cp "$OUT/libyang-incremental-validation.patch" "$META_XPON_DIR/$LY_PATCH_PATH"
  cp "$OUT/sysrepo-incremental-validation.patch" "$META_XPON_DIR/$SR_PATCH_PATH"
fi

# Mirror the squash patches next to the recipe layout kept in this repo.
cp "$OUT/libyang-incremental-validation.patch" "$SCRIPT_DIR/libyang/$PATCH_LY_NAME"
cp "$OUT/sysrepo-incremental-validation.patch" "$SCRIPT_DIR/sysrepo/$PATCH_SR_NAME"

if grep -q 'Squash tips' "$OUT/APPLY.txt" 2>/dev/null; then
  sed -i "s/^Squash tips.*/Squash tips: libyang ${LY_HEAD} on base ${LIBYANG_BASE:0:8}; sysrepo ${SR_HEAD} on base ${SYSREPO_BASE:0:8}./" \
    "$OUT/APPLY.txt"
fi

# Verification: nothing may be missing from the patches and every patch must apply to its base.
VT="$(mktemp -d)"
trap 'rm -f "$BODY_LY" "$BODY_SR"; rm -rf "$VT"' EXIT

# 1. Every commit base..HEAD is in the cover letter, and the patch body is exactly git diff base..HEAD.
verify_squash() {
  local repo="$1" base="$2" patch="$3" name="$4" h n missing=0
  n="$(git -C "$repo" rev-list --count "${base}..HEAD")"
  for h in $(git -C "$repo" rev-list --abbrev-commit "${base}..HEAD"); do
    grep -q "^  ${h} " "$patch" || { echo "ERROR: $name: commit $h missing from the cover letter" >&2; missing=1; }
  done
  [[ "$missing" == 0 ]] || exit 1
  awk '/^diff --git /{p=1} p' "$patch" >"$VT/$name.body"
  git -C "$repo" diff "${base}..HEAD" | cmp -s - "$VT/$name.body" || die "$name: patch body differs from git diff ${base:0:8}..HEAD"
  echo "ok $name: $n commits listed, body equals git diff ${base:0:8}..HEAD"
}
verify_squash "$LIBYANG_DIR" "$LIBYANG_BASE" "$OUT/libyang-incremental-validation.patch" libyang
verify_squash "$SYSREPO_DIR" "$SYSREPO_BASE" "$OUT/sysrepo-incremental-validation.patch" sysrepo

# 2. Each squash applies to a clean checkout of its base.
for spec in "libyang:$LIBYANG_DIR:$LIBYANG_BASE" "sysrepo:$SYSREPO_DIR:$SYSREPO_BASE"; do
  IFS=: read -r name repo base <<<"$spec"
  mkdir -p "$VT/$name-base"
  git -C "$repo" archive "$base" | tar -x -C "$VT/$name-base"
  (cd "$VT/$name-base" && git apply --check "$OUT/$name-incremental-validation.patch") || die "$name patch does not apply to base ${base:0:8}"
  echo "ok $name patch applies to base ${base:0:8}"
done

# 3. The bundle applies to a clean meta-xpon base and carries exactly the current squash patches.
mkdir -p "$VT/meta"
git -C "$META_XPON_DIR" archive "$META_XPON_BASE" | tar -x -C "$VT/meta"
(cd "$VT/meta" && git apply --whitespace=nowarn --check -p1 "$BUNDLE" && git apply --whitespace=nowarn -p1 "$BUNDLE") || die "bundle does not apply to meta-xpon base ${META_XPON_BASE:0:7}"
cmp -s "$VT/meta/$LY_PATCH_PATH" "$OUT/libyang-incremental-validation.patch" || die "bundle carries a stale libyang patch"
cmp -s "$VT/meta/$SR_PATCH_PATH" "$OUT/sysrepo-incremental-validation.patch" || die "bundle carries a stale sysrepo patch"
grep -q "file://$PATCH_LY_NAME" "$VT/meta/$LY_BBAPPEND" || die "libyang bbappend lacks 0001"
grep -q "file://$PATCH_SR_NAME" "$VT/meta/$SR_BBAPPEND" || die "sysrepo bbappend lacks 0004"
echo "ok bundle applies to meta-xpon ${META_XPON_BASE:0:7} and embeds the current libyang/sysrepo patches"

echo "Done. Apply on the build server: cd <meta-xpon> && git apply -p1 $BUNDLE"
