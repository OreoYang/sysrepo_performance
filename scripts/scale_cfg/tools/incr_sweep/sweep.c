/**
 * @file sweep.c
 * @brief Differential sweep of incremental against full validation on real configuration data.
 *
 * usage: sweep YANG_DIR MODULES_TXT DATASET_LIST ONU_LIST OUT_CSV COVER_TXT [SEED] [PER_NODE] [MIXED]
 *
 * DATASET_LIST: one XML file per line, merged in order into the starting configuration.
 * ONU_LIST:     lines "provision-file service-file" of further ONUs, used as value pool and as ADD edits.
 *
 * Every edit is validated twice, in full and incrementally (once per scope option, like the unit tests do), and the
 * two verdicts and the resulting trees are compared. A "WRONG ACCEPT" is an edit that full validation rejects and
 * incremental validation accepts. The COVER_TXT lines use the format of the unit tests, so matrix.py can credit
 * each rejecting rule with the action that triggered it.
 */
#define _GNU_SOURCE
#include <time.h>

#include "ctxload.h"

#define MAXOPS 6
#define POOL_MAX 6

enum op_kind {OP_DEL, OP_SET, OP_ADD_SRC, OP_ADD_FILE, OP_ADD_XML};

struct op {
    enum op_kind kind;
    char *path;
    char *val;
    const struct lyd_node *src;     /* OP_ADD_SRC: node of the original tree to put back */
    char *file;                     /* OP_ADD_FILE */
};

struct edit {
    const char *cls;
    int nops;
    struct op ops[MAXOPS];
};

struct item {
    char *skey;
    char *dpath;
    struct lyd_node *node;
};

struct pool_ent {
    char *skey;
    char *vals[POOL_MAX];
    int n;
};

static struct ly_ctx *ctx;
static FILE *csv, *cov;
static long n_total, n_skipped, n_both_acc, n_both_rej, n_wrong_acc, n_wrong_rej, n_tree_diff, n_fallback;
static long cls_tot[8], cls_wa[8], cls_wr[8], cls_td[8], cls_rej[8];
static const char *cls_names[] = {"delete", "add", "modify", "mixed", "readd", "clone", NULL};

static int
cls_idx(const char *c)
{
    int i;

    for (i = 0; cls_names[i]; ++i) {
        if (!strcmp(cls_names[i], c)) {
            return i;
        }
    }
    return 7;
}

static char *
schema_key(const struct lyd_node *n)
{
    return lysc_path(n->schema, LYSC_PATH_DATA, NULL, 0);
}

static const char *
errmsg(void)
{
    return ly_err_last(ctx) ? ly_err_last(ctx)->msg : "-";
}

static struct lyd_node *
load_files(const char *list, int merge_into_one)
{
    FILE *f = fopen(list, "r");
    char line[2048];
    struct lyd_node *tree = NULL, *t;

    (void)merge_into_one;
    if (!f) {
        fprintf(stderr, "cannot open %s\n", list);
        exit(1);
    }
    while (fgets(line, sizeof line, f)) {
        line[strcspn(line, "\r\n")] = 0;
        if (!line[0]) {
            continue;
        }
        t = NULL;
        if (lyd_parse_data_path(ctx, line, LYD_XML, LYD_PARSE_STRICT | LYD_PARSE_ONLY, 0, &t)) {
            fprintf(stderr, "parse %s: %s\n", line, errmsg());
            exit(1);
        }
        if (t && lyd_merge_siblings(&tree, t, LYD_MERGE_DESTRUCT)) {
            fprintf(stderr, "merge %s: %s\n", line, errmsg());
            exit(1);
        }
    }
    fclose(f);
    return tree;
}

/* modules of every data node of the tree, so that the full and incremental runs cover the same ones */
static uint32_t
collect_mods(const struct lyd_node *tree, const struct lys_module **mods, uint32_t cnt, uint32_t cap)
{
    const struct lyd_node *top, *elem;
    uint32_t i;

    LY_LIST_FOR(tree, top) {
        LYD_TREE_DFS_BEGIN(top, elem) {
            for (i = 0; i < cnt; ++i) {
                if (mods[i] == elem->schema->module) {
                    break;
                }
            }
            if ((i == cnt) && (cnt < cap)) {
                mods[cnt++] = elem->schema->module;
            }
            LYD_TREE_DFS_END(top, elem);
        }
    }
    return cnt;
}

static int
full_validate(struct lyd_node **tree, const struct lys_module **mods, uint32_t cnt)
{
    uint32_t i;
    int rc = 0;

    for (i = 0; !rc && (i < cnt); ++i) {
        rc = lyd_validate_module(tree, mods[i], LYD_VALIDATE_NO_STATE | LYD_VALIDATE_NOT_FINAL, NULL);
    }
    for (i = 0; !rc && (i < cnt); ++i) {
        rc = lyd_validate_module_final(*tree, mods[i], LYD_VALIDATE_NO_STATE);
    }
    return rc;
}

/* same format as cover_report() of the unit tests */
static void
cover_report(const struct lyd_node *before, const struct lyd_node *after, const struct lyd_node *full, int rc,
        const char *msg, const char *dpath)
{
    struct lyd_node *diff = NULL, *dropped = NULL, *iter, *elem;
    struct lyd_meta *meta;
    char *line = malloc(1 << 20), *p;
    size_t len, cap = 1 << 20;

    len = (size_t)snprintf(line, cap, "[  COVER   ] rc=%d ops=", rc);
    if (lyd_diff_siblings(before, after, 0, &diff)) {
        free(line);
        return;
    }
    LY_LIST_FOR(diff, iter) {
        LYD_TREE_DFS_BEGIN(iter, elem) {
            for (meta = elem->meta; meta; meta = meta->next) {
                if (!strcmp(meta->name, "operation") && strcmp(lyd_get_meta_value(meta), "none") && (len < cap - 600)) {
                    char *sp = lysc_path(elem->schema, LYSC_PATH_DATA, NULL, 0);

                    len += (size_t)snprintf(line + len, cap - len, "%s:%s;", lyd_get_meta_value(meta), sp);
                    free(sp);
                }
            }
            LYD_TREE_DFS_END(iter, elem);
        }
    }
    if (!rc && !lyd_diff_siblings(after, full, 0, &dropped)) {
        len += (size_t)snprintf(line + len, cap - len, " dropped=");
        LY_LIST_FOR(dropped, iter) {
            LYD_TREE_DFS_BEGIN(iter, elem) {
                for (meta = elem->meta; meta; meta = meta->next) {
                    if (!strcmp(meta->name, "operation") && !strcmp(lyd_get_meta_value(meta), "delete") &&
                            (len < cap - 600)) {
                        char *sp = lysc_path(elem->schema, LYSC_PATH_DATA, NULL, 0);

                        len += (size_t)snprintf(line + len, cap - len, "%s;", sp);
                        free(sp);
                    }
                }
                LYD_TREE_DFS_END(iter, elem);
            }
        }
        lyd_free_siblings(dropped);
    }
    len += (size_t)snprintf(line + len, cap - len, " | %s | %s", msg, dpath ? dpath : "-");
    for (p = line; *p; ++p) {
        if ((*p == '\n') || (*p == '\r')) {
            *p = ' ';
        }
    }
    fprintf(cov, "%s\n", line);
    free(line);
    lyd_free_siblings(diff);
}

static void
csv_quote(FILE *f, const char *s)
{
    fputc('"', f);
    for (; s && *s; ++s) {
        if ((*s == '"') || (*s == '\n') || (*s == '\r')) {
            fputc(*s == '"' ? '\'' : ' ', f);
        } else {
            fputc(*s, f);
        }
    }
    fputc('"', f);
}

/* apply the ops to a copy of @p before; returns the tree or NULL if some op does not apply */
static struct lyd_node *
apply_edit(const struct lyd_node *before, const struct edit *e)
{
    struct lyd_node *after = NULL, *n, *dup, *top, *t;
    int i;

    if (lyd_dup_siblings(before, NULL, LYD_DUP_RECURSIVE | LYD_DUP_WITH_FLAGS, &after)) {
        return NULL;
    }
    for (i = 0; i < e->nops; ++i) {
        const struct op *o = &e->ops[i];

        switch (o->kind) {
        case OP_DEL:
            if (lyd_find_path(after, o->path, 0, &n)) {
                goto fail;
            }
            if (n == after) {
                after = after->next;
            }
            lyd_free_tree(n);
            break;
        case OP_SET:
            if (lyd_find_path(after, o->path, 0, &n) || (n->schema->nodetype != LYS_LEAF)) {
                goto fail;
            }
            if (lyd_change_term(n, o->val)) {
                ly_err_clean(ctx, NULL);
                goto fail;
            }
            break;
        case OP_ADD_SRC:
            if (lyd_dup_single(o->src, NULL, LYD_DUP_RECURSIVE | LYD_DUP_WITH_PARENTS | LYD_DUP_WITH_FLAGS, &dup)) {
                goto fail;
            }
            for (top = dup; top->parent; top = lyd_parent(top)) {}
            if (lyd_merge_siblings(&after, top, LYD_MERGE_DESTRUCT)) {
                goto fail;
            }
            break;
        case OP_ADD_FILE:
            t = NULL;
            if (lyd_parse_data_path(ctx, o->file, LYD_XML, LYD_PARSE_STRICT | LYD_PARSE_ONLY, 0, &t)) {
                goto fail;
            }
            if (t && lyd_merge_siblings(&after, t, LYD_MERGE_DESTRUCT)) {
                goto fail;
            }
            break;
        case OP_ADD_XML:
            t = NULL;
            if (lyd_parse_data_mem(ctx, o->val, LYD_XML, LYD_PARSE_STRICT | LYD_PARSE_ONLY, 0, &t)) {
                goto fail;
            }
            if (t && lyd_merge_siblings(&after, t, LYD_MERGE_DESTRUCT)) {
                goto fail;
            }
            break;
        }
    }
    return after;
fail:
    ly_err_clean(ctx, NULL);
    lyd_free_siblings(after);
    return NULL;
}

static char *
describe(const struct edit *e)
{
    size_t cap = 4096, len = 0;
    char *s = malloc(cap);
    int i;

    s[0] = 0;
    for (i = 0; i < e->nops; ++i) {
        const struct op *o = &e->ops[i];
        const char *k = (o->kind == OP_DEL) ? "del" : (o->kind == OP_SET) ? "set" : (o->kind == OP_ADD_XML) ? "clone" : "add";

        len += (size_t)snprintf(s + len, cap - len, "%s%s %s%s%s", i ? " ; " : "", k,
                o->kind == OP_ADD_FILE ? o->file : o->kind == OP_ADD_XML ? o->path : o->kind == OP_ADD_SRC ? lyd_path(o->src, LYD_PATH_STD, NULL, 0) : o->path,
                (o->val && (o->kind != OP_ADD_XML)) ? " = " : "", (o->val && (o->kind != OP_ADD_XML)) ? o->val : "");
        if (len > cap - 600) {
            break;
        }
    }
    return s;
}

/* ---- replay of edits through sysrepo: each sampled edit is written as an edit-config file ---- */
static const char *emit_dir;
static long emit_every, emit_count;
static FILE *emit_idx;
static const struct lyd_node *emit_base;    /* only edits made on the starting data can be replayed */

/**
 * Express the ops of an edit as one data tree for "sysrepocfg --edit": a delete is the node with its parents and
 * operation "remove", a set is the leaf with its parents and the new value, an added file is the file itself.
 */
static struct lyd_node *
edit_tree(const struct lyd_node *before, const struct edit *e)
{
    struct lyd_node *tree = NULL, *n, *dup, *top, *t;
    int i;

    for (i = 0; i < e->nops; ++i) {
        const struct op *o = &e->ops[i];

        switch (o->kind) {
        case OP_DEL:
        case OP_SET:
            if (lyd_find_path(before, o->path, 0, &n)) {
                goto fail;
            }
            if (lyd_dup_single(n, NULL, LYD_DUP_WITH_PARENTS | (o->kind == OP_DEL ? 0 : LYD_DUP_WITH_FLAGS), &dup)) {
                goto fail;
            }
            if (o->kind == OP_SET) {
                if (lyd_change_term(dup, o->val)) {
                    goto fail;
                }
            } else if (lyd_new_meta(ctx, dup, NULL, "ietf-netconf:operation", "remove", 0, NULL)) {
                goto fail;
            }
            for (top = dup; top->parent; top = lyd_parent(top)) {}
            if (lyd_merge_siblings(&tree, top, LYD_MERGE_DESTRUCT)) {
                goto fail;
            }
            break;
        case OP_ADD_FILE:
            t = NULL;
            if (lyd_parse_data_path(ctx, o->file, LYD_XML, LYD_PARSE_STRICT | LYD_PARSE_ONLY, 0, &t)) {
                goto fail;
            }
            if (t && lyd_merge_siblings(&tree, t, LYD_MERGE_DESTRUCT)) {
                goto fail;
            }
            break;
        case OP_ADD_XML:
            t = NULL;
            if (lyd_parse_data_mem(ctx, o->val, LYD_XML, LYD_PARSE_STRICT | LYD_PARSE_ONLY, 0, &t)) {
                goto fail;
            }
            if (t && lyd_merge_siblings(&tree, t, LYD_MERGE_DESTRUCT)) {
                goto fail;
            }
            break;
        default:
            goto fail;
        }
    }
    return tree;
fail:
    ly_err_clean(ctx, NULL);
    lyd_free_siblings(tree);
    return NULL;
}

static void
emit_edit(const struct lyd_node *before, const struct edit *e, long id, int rc_full, const char *verdict)
{
    struct lyd_node *tree;
    char path[1024];

    if (!emit_dir || (before != emit_base) || (id % emit_every)) {
        return;
    }
    tree = edit_tree(before, e);
    if (!tree) {
        return;
    }
    snprintf(path, sizeof path, "%s/e%06ld.xml", emit_dir, id);
    lyd_print_path(path, tree, LYD_XML, LYD_PRINT_WITHSIBLINGS);
    fprintf(emit_idx, "%ld,%s,%d\n", id, e->cls, rc_full);
    ++emit_count;
    lyd_free_siblings(tree);
}

static const uint32_t opt_sets[] = {0, LYD_VALIDATE_INCR_SHALLOW_DELETE};

/**
 * Run one edit. @p settled receives the full-validation result if the edit is accepted (a valid starting tree for
 * a follow-up edit), unless NULL.
 * @return 0 skipped, 1 both accept, 2 both reject, 3 mismatch of some kind.
 */
static int
run_edit(const struct lyd_node *before, const struct lys_module **base_mods, uint32_t base_cnt, const struct edit *e,
        struct lyd_node **settled)
{
    struct lyd_node *after, *full = NULL, *incr = NULL, *diff = NULL, *val_diff;
    const struct lys_module *mods[256];
    char *full_str = NULL, *incr_str = NULL, *desc;
    char full_msg[300], incr_msg[300], fdp[400] = "-";
    uint32_t i, s, cnt;
    uint64_t fb0, fb1;
    int rc_full, rc_incr, res = 1, ci = cls_idx(e->cls), tree_diff, fell_back = 0;
    char verdict[32] = "";
    const struct ly_err_item *ei;

    after = apply_edit(before, e);
    if (!after) {
        ++n_skipped;
        return 0;
    }
    memcpy(mods, base_mods, base_cnt * sizeof *mods);
    cnt = collect_mods(after, mods, base_cnt, 256);

    if (lyd_dup_siblings(after, NULL, LYD_DUP_RECURSIVE | LYD_DUP_WITH_FLAGS, &full)) {
        lyd_free_siblings(after);
        ++n_skipped;
        return 0;
    }
    rc_full = full_validate(&full, mods, cnt);
    snprintf(full_msg, sizeof full_msg, "%s", errmsg());
    ei = ly_err_last(ctx);
    if (ei && ei->data_path) {
        snprintf(fdp, sizeof fdp, "%s", ei->data_path);
    }
    cover_report(before, after, full, rc_full, full_msg, ei ? ei->data_path : NULL);
    ly_err_clean(ctx, NULL);
    if (!rc_full) {
        lyd_print_mem(&full_str, full, LYD_XML, LYD_PRINT_WITHSIBLINGS | LYD_PRINT_WD_ALL);
    }
    desc = describe(e);

    ++n_total;
    emit_edit(before, e, n_total, rc_full, "ok");
    ++cls_tot[ci];
    for (s = 0; s < sizeof opt_sets / sizeof *opt_sets; ++s) {
        uint32_t opts = opt_sets[s];

        lyd_validate_incr_stats(ctx, NULL, &fb0);
        diff = NULL;
        incr = NULL;
        if (lyd_diff_siblings(before, after, 0, &diff) || lyd_dup_siblings(after, NULL, LYD_DUP_RECURSIVE | LYD_DUP_WITH_FLAGS, &incr)) {
            fprintf(stderr, "internal error preparing the incremental run\n");
            exit(2);
        }
        rc_incr = 0;
        for (i = 0; !rc_incr && (i < cnt); ++i) {
            val_diff = NULL;
            rc_incr = lyd_validate_module_incr(&incr, mods[i], diff, opts | LYD_VALIDATE_NO_STATE | LYD_VALIDATE_NOT_FINAL, &val_diff);
            if (val_diff) {
                lyd_diff_merge_all(&diff, val_diff, 0);
                lyd_free_all(val_diff);
            }
        }
        for (i = 0; !rc_incr && (i < cnt); ++i) {
            rc_incr = lyd_validate_module_incr_final(incr, mods[i], diff, opts | LYD_VALIDATE_NO_STATE);
        }
        snprintf(incr_msg, sizeof incr_msg, "%s", errmsg());
        ly_err_clean(ctx, NULL);
        lyd_validate_incr_stats(ctx, NULL, &fb1);
        if (fb1 > fb0) {
            fell_back = 1;
        }

        tree_diff = 0;
        incr_str = NULL;
        if (!rc_full && !rc_incr) {
            lyd_print_mem(&incr_str, incr, LYD_XML, LYD_PRINT_WITHSIBLINGS | LYD_PRINT_WD_ALL);
            tree_diff = strcmp(full_str ? full_str : "", incr_str ? incr_str : "") != 0;
        }
        if (rc_full && !rc_incr) {
            snprintf(verdict, sizeof verdict, "WRONG_ACCEPT");
            ++n_wrong_acc;
            ++cls_wa[ci];
            res = 3;
        } else if (!rc_full && rc_incr) {
            snprintf(verdict, sizeof verdict, "WRONG_REJECT");
            ++n_wrong_rej;
            ++cls_wr[ci];
            res = 3;
        } else if (tree_diff) {
            snprintf(verdict, sizeof verdict, "TREE_MISMATCH");
            ++n_tree_diff;
            ++cls_td[ci];
            res = 3;
        } else {
            snprintf(verdict, sizeof verdict, "ok");
        }
        if (strcmp(verdict, "ok") || (s == 0)) {
            fprintf(csv, "%ld,%s,%u,%d,%d,%s,%d,", n_total, e->cls, opts, rc_full, rc_incr, verdict, fb1 > fb0);
            csv_quote(csv, desc);
            fputc(',', csv);
            csv_quote(csv, full_msg);
            fputc(',', csv);
            csv_quote(csv, fdp);
            fputc(',', csv);
            csv_quote(csv, incr_msg);
            fputc('\n', csv);
        }
        free(incr_str);
        lyd_free_siblings(incr);
        lyd_free_siblings(diff);
    }
    if (fell_back) {
        ++n_fallback;
    }
    if (rc_full) {
        ++cls_rej[ci];
        if (res != 3) {
            ++n_both_rej;
            res = 2;
        }
    } else if (res == 1) {
        ++n_both_acc;
        if (settled) {
            *settled = full;
            full = NULL;
        }
    }
    free(full_str);
    free(desc);
    lyd_free_siblings(after);
    lyd_free_siblings(full);
    if ((n_total % 500) == 0) {
        fprintf(stderr, "%ld edits: wrong accept %ld, wrong reject %ld, tree mismatch %ld, rejected %ld\n", n_total,
                n_wrong_acc, n_wrong_rej, n_tree_diff, n_both_rej);
    }
    return res;
}

/* ---- inventory of the starting tree ---- */

static int
cmp_item(const void *a, const void *b)
{
    return strcmp(((const struct item *)a)->skey, ((const struct item *)b)->skey);
}

static int
cmp_pool(const void *a, const void *b)
{
    return strcmp(((const struct pool_ent *)a)->skey, ((const struct pool_ent *)b)->skey);
}

static struct pool_ent *pool;
static size_t pool_n, pool_cap;

static void
pool_add(const char *skey, const char *val)
{
    size_t i;
    int j;

    for (i = 0; i < pool_n; ++i) {
        if (!strcmp(pool[i].skey, skey)) {
            break;
        }
    }
    if (i == pool_n) {
        if (pool_n == pool_cap) {
            pool_cap = pool_cap ? pool_cap * 2 : 512;
            pool = realloc(pool, pool_cap * sizeof *pool);
        }
        memset(&pool[pool_n], 0, sizeof *pool);
        pool[pool_n++].skey = strdup(skey);
    }
    for (j = 0; j < pool[i].n; ++j) {
        if (!strcmp(pool[i].vals[j], val)) {
            return;
        }
    }
    if (pool[i].n < POOL_MAX) {
        pool[i].vals[pool[i].n++] = strdup(val);
    }
}

static void
pool_from_tree(const struct lyd_node *tree)
{
    const struct lyd_node *top, *elem;

    LY_LIST_FOR(tree, top) {
        LYD_TREE_DFS_BEGIN(top, elem) {
            if ((elem->schema->nodetype == LYS_LEAF) && !(elem->flags & LYD_DEFAULT)) {
                char *k = schema_key(elem);

                pool_add(k, lyd_get_value(elem));
                free(k);
            }
            LYD_TREE_DFS_END(top, elem);
        }
    }
}

static struct pool_ent *
pool_find(const char *skey)
{
    struct pool_ent key = {(char *)skey, {0}, 0};

    return bsearch(&key, pool, pool_n, sizeof *pool, cmp_pool);
}

/* phases of the sweep to run, SWEEP_PHASES letters: d delete+readd, m modify, a add files, c clone, x mixed */
static int
ph(char c)
{
    return !getenv("SWEEP_PHASES") || strchr(getenv("SWEEP_PHASES"), c);
}

static unsigned
rnd(unsigned n)
{
    return n ? (unsigned)rand() % n : 0;
}

static struct edit *
new_edit(const char *cls)
{
    struct edit *e = calloc(1, sizeof *e);

    e->cls = cls;
    return e;
}

static void
op_del(struct edit *e, const char *path)
{
    e->ops[e->nops].kind = OP_DEL;
    e->ops[e->nops++].path = strdup(path);
}

static void
op_set(struct edit *e, const char *path, const char *val)
{
    e->ops[e->nops].kind = OP_SET;
    e->ops[e->nops].path = strdup(path);
    e->ops[e->nops++].val = strdup(val);
}

/* values to try on a leaf besides the pool: type driven */
static int
type_values(const struct lyd_node *leaf, const char *cur, char out[6][128])
{
    const struct lysc_node_leaf *sl = (const struct lysc_node_leaf *)leaf->schema;
    const struct lysc_type *t = sl->type;
    int n = 0;
    const struct lysc_type_enum *te;
    LY_ARRAY_COUNT_TYPE u;

    switch (t->basetype) {
    case LY_TYPE_BOOL:
        snprintf(out[n++], 128, "%s", strcmp(cur, "true") ? "true" : "false");
        break;
    case LY_TYPE_ENUM:
        te = (const struct lysc_type_enum *)t;
        LY_ARRAY_FOR(te->enums, u) {
            if (strcmp(te->enums[u].name, cur) && (n < 3)) {
                snprintf(out[n++], 128, "%s", te->enums[u].name);
            }
        }
        break;
    case LY_TYPE_UINT8: case LY_TYPE_UINT16: case LY_TYPE_UINT32: case LY_TYPE_UINT64:
    case LY_TYPE_INT8: case LY_TYPE_INT16: case LY_TYPE_INT32: case LY_TYPE_INT64:
        snprintf(out[n++], 128, "%llu", strtoull(cur, NULL, 10) + 1);
        snprintf(out[n++], 128, "%u", (unsigned)(strtoull(cur, NULL, 10) ? strtoull(cur, NULL, 10) - 1 : 0));
        snprintf(out[n++], 128, "0");
        break;
    case LY_TYPE_LEAFREF:
        snprintf(out[n++], 128, "zz-missing-target");
        break;
    case LY_TYPE_STRING:
        snprintf(out[n++], 128, "%s-x", cur);
        break;
    default:
        break;
    }
    return n;
}

int
main(int argc, char **argv)
{
    struct lyd_node *tree, *settled;
    struct item *items = NULL;
    size_t ni = 0, icap = 0, i, j, g, ge;
    const struct lys_module *base_mods[256];
    uint32_t base_cnt;
    unsigned seed = argc > 7 ? (unsigned)atoi(argv[7]) : 1;
    int per_node = argc > 8 ? atoi(argv[8]) : 4, n_mixed = argc > 9 ? atoi(argv[9]) : 1500;
    struct edit **pool_edits = NULL;
    size_t npe = 0, pecap = 0;
    char line[4096], sfile[2048];
    FILE *ol;
    char **onu_p = NULL, **onu_s = NULL;
    size_t nonu = 0, onucap = 0;
    const struct lyd_node *top, *elem;
    time_t t0 = time(NULL);

    if (argc < 7) {
        fprintf(stderr, "usage: %s YANG_DIR MODULES_TXT DATASET_LIST ONU_LIST OUT_CSV COVER_TXT [SEED] [PER_NODE] [MIXED]\n", argv[0]);
        return 1;
    }
    srand(seed);
    ctx = ctxload(argv[1], argv[2]);
    if (!ctx) {
        return 1;
    }
    csv = fopen(argv[5], "w");
    cov = fopen(argv[6], "w");
    fprintf(csv, "id,class,opts,rc_full,rc_incr,verdict,fallback,edit,full_msg,full_path,incr_msg\n");

    tree = load_files(argv[3], 1);
    base_cnt = collect_mods(tree, base_mods, 0, 256);
    if (full_validate(&tree, base_mods, base_cnt)) {
        fprintf(stderr, "starting data does not validate: %s\n", errmsg());
        return 1;
    }
    fprintf(stderr, "starting data valid, %u modules\n", base_cnt);
    if (getenv("SWEEP_DUMP_DATASET")) {
        lyd_print_path(getenv("SWEEP_DUMP_DATASET"), tree, LYD_XML, LYD_PRINT_WITHSIBLINGS);
    }
    if (getenv("SWEEP_EMIT_DIR")) {
        char p[1024];

        emit_dir = getenv("SWEEP_EMIT_DIR");
        emit_base = tree;
        emit_every = getenv("SWEEP_EMIT_EVERY") ? atol(getenv("SWEEP_EMIT_EVERY")) : 10;
        snprintf(p, sizeof p, "%s/index.csv", emit_dir);
        emit_idx = fopen(p, "w");
    }

    /* value pool: the dataset and every further ONU file */
    pool_from_tree(tree);
    ol = fopen(argv[4], "r");
    while (ol && fgets(line, sizeof line, ol)) {
        char p[2048], s[2048];

        if (sscanf(line, "%2047s %2047s", p, s) != 2) {
            continue;
        }
        if (nonu == onucap) {
            onucap = onucap ? onucap * 2 : 64;
            onu_p = realloc(onu_p, onucap * sizeof *onu_p);
            onu_s = realloc(onu_s, onucap * sizeof *onu_s);
        }
        onu_p[nonu] = strdup(p);
        onu_s[nonu++] = strdup(s);
    }
    if (ol) {
        fclose(ol);
    }
    for (i = 0; i < nonu; ++i) {
        struct lyd_node *t = NULL;
        const char *fl[2] = {onu_p[i], onu_s[i]};
        int k;

        if ((i % 8) && (i + 1 != nonu)) {
            continue;   /* every 8th ONU is enough to see the value spread */
        }
        for (k = 0; k < 2; ++k) {
            t = NULL;
            if (!lyd_parse_data_path(ctx, fl[k], LYD_XML, LYD_PARSE_STRICT | LYD_PARSE_ONLY, 0, &t)) {
                pool_from_tree(t);
                lyd_free_siblings(t);
            }
        }
    }
    qsort(pool, pool_n, sizeof *pool, cmp_pool);

    /* nodes of the starting tree grouped by schema node */
    LY_LIST_FOR(tree, top) {
        LYD_TREE_DFS_BEGIN(top, elem) {
            if (ni == icap) {
                icap = icap ? icap * 2 : 4096;
                items = realloc(items, icap * sizeof *items);
            }
            items[ni].skey = schema_key(elem);
            items[ni].dpath = lyd_path(elem, LYD_PATH_STD, NULL, 0);
            items[ni++].node = (struct lyd_node *)elem;
            LYD_TREE_DFS_END(top, elem);
        }
    }
    qsort(items, ni, sizeof *items, cmp_item);
    fprintf(stderr, "%zu nodes, %zu pool schema nodes, %zu ONUs for adds\n", ni, pool_n, nonu);

    /* ---- DELETE and READD: a few instances of every schema node ---- */
    for (g = 0; ph('d') && (g < ni); g = ge) {
        size_t picks[8], np = 0;
        int k;

        for (ge = g; (ge < ni) && !strcmp(items[ge].skey, items[g].skey); ++ge) {}
        if ((items[g].node->schema->flags & LYS_CONFIG_R) || lysc_is_key(items[g].node->schema)) {
            continue;
        }
        picks[np++] = g;
        if (ge - g > 1) {
            picks[np++] = ge - 1;
        }
        for (k = 2; (k < per_node) && (ge - g > (size_t)k); ++k) {
            picks[np++] = g + rnd((unsigned)(ge - g));
        }
        for (k = 0; k < (int)np; ++k) {
            struct item *it = &items[picks[k]];
            struct edit *e;
            struct lyd_node *st = NULL;
            int r;

            if (it->node->flags & LYD_DEFAULT) {
                continue;
            }
            e = new_edit("delete");
            op_del(e, it->dpath);
            r = run_edit(tree, base_mods, base_cnt, e, &st);
            (void)r;
            if (npe == pecap) {
                pecap = pecap ? pecap * 2 : 1024;
                pool_edits = realloc(pool_edits, pecap * sizeof *pool_edits);
            }
            pool_edits[npe++] = e;
            if (st) {
                /* put the same node back into the tree the accepted delete left behind */
                struct edit *re = new_edit("readd");

                re->ops[0].kind = OP_ADD_SRC;
                re->ops[0].src = it->node;
                re->nops = 1;
                run_edit(st, base_mods, base_cnt, re, NULL);
                lyd_free_siblings(st);
                free(re);
            }
        }
    }
    fprintf(stderr, "deletes done (%ld s)\n", (long)(time(NULL) - t0));

    /* ---- MODIFY: type driven and pool values on a few instances of every leaf ---- */
    for (g = 0; ph('m') && (g < ni); g = ge) {
        size_t picks[8], np = 0;
        int k;

        for (ge = g; (ge < ni) && !strcmp(items[ge].skey, items[g].skey); ++ge) {}
        if ((items[g].node->schema->nodetype != LYS_LEAF) || (items[g].node->schema->flags & LYS_CONFIG_R) ||
                lysc_is_key(items[g].node->schema)) {
            continue;
        }
        picks[np++] = g;
        if (ge - g > 1) {
            picks[np++] = ge - 1;
        }
        for (k = 2; (k < per_node - 1) && (ge - g > (size_t)k); ++k) {
            picks[np++] = g + rnd((unsigned)(ge - g));
        }
        for (k = 0; k < (int)np; ++k) {
            struct item *it = &items[picks[k]];
            const char *cur = lyd_get_value(it->node);
            char tv[6][128];
            int nt = type_values(it->node, cur, tv), v;
            struct pool_ent *pe = pool_find(it->skey);

            for (v = 0; v < nt + (pe ? pe->n : 0); ++v) {
                const char *nv = (v < nt) ? tv[v] : pe->vals[v - nt];
                struct edit *e;

                if (!strcmp(nv, cur)) {
                    continue;
                }
                e = new_edit("modify");
                op_set(e, it->dpath, nv);
                run_edit(tree, base_mods, base_cnt, e, NULL);
                if (npe == pecap) {
                    pecap = pecap ? pecap * 2 : 1024;
                    pool_edits = realloc(pool_edits, pecap * sizeof *pool_edits);
                }
                pool_edits[npe++] = e;
            }
        }
    }
    fprintf(stderr, "modifies done (%ld s)\n", (long)(time(NULL) - t0));

    /* ---- ADD: further ONUs from the production set, and a service without its provision ---- */
    for (i = 0; ph('a') && (i < nonu); ++i) {
        struct edit *e;

        if ((i % 4) && (i + 1 != nonu)) {
            continue;
        }
        e = new_edit("add");
        e->ops[0].kind = OP_ADD_FILE; e->ops[0].file = onu_p[i]; e->nops = 1;
        run_edit(tree, base_mods, base_cnt, e, NULL);
        free(e);
        e = new_edit("add");
        e->ops[0].kind = OP_ADD_FILE; e->ops[0].file = onu_s[i]; e->nops = 1;
        run_edit(tree, base_mods, base_cnt, e, NULL);    /* service alone: the v-ani it sits on is missing */
        free(e);
        e = new_edit("add");
        e->ops[0].kind = OP_ADD_FILE; e->ops[0].file = onu_p[i];
        e->ops[1].kind = OP_ADD_FILE; e->ops[1].file = onu_s[i]; e->nops = 2;
        run_edit(tree, base_mods, base_cnt, e, NULL);
        free(e);
        /* the second step of two edits: provision first, then service on the accepted result */
        e = new_edit("add");
        e->ops[0].kind = OP_ADD_FILE; e->ops[0].file = onu_p[i]; e->nops = 1;
        settled = NULL;
        if (run_edit(tree, base_mods, base_cnt, e, &settled) == 1 && settled) {
            struct edit *e2 = new_edit("add");

            e2->ops[0].kind = OP_ADD_FILE; e2->ops[0].file = onu_s[i]; e2->nops = 1;
            run_edit(settled, base_mods, base_cnt, e2, NULL);
            free(e2);
        }
        lyd_free_siblings(settled);
        free(e);
    }
    fprintf(stderr, "adds done (%ld s)\n", (long)(time(NULL) - t0));

    /* ---- CLONE: copy a few instances of every list under a new key, subtree and references renamed with it ---- */
    for (g = 0; ph('c') && (g < ni); g = ge) {
        size_t picks[4], np = 0;
        int k;

        for (ge = g; (ge < ni) && !strcmp(items[ge].skey, items[g].skey); ++ge) {}
        if (items[g].node->schema->nodetype != LYS_LIST || (items[g].node->schema->flags & LYS_CONFIG_R)) {
            continue;
        }
        picks[np++] = g;
        if (ge - g > 1) {
            picks[np++] = ge - 1;
        }
        for (k = 2; (k < per_node) && (k < 4) && (ge - g > (size_t)k); ++k) {
            picks[np++] = g + rnd((unsigned)(ge - g));
        }
        for (k = 0; k < (int)np; ++k) {
            struct item *it = &items[picks[k]];
            const struct lyd_node *key = lyd_child(it->node);
            struct lyd_node *dup, *top;
            char *xml = NULL, *out, *p, *q, oldk[256], newk[300];
            size_t olen, nlen;
            struct edit *e;
            int numeric;

            if (!key || !lysc_is_key(key->schema)) {
                continue;
            }
            snprintf(oldk, sizeof oldk, "%s", lyd_get_value(key));
            numeric = (key->schema->nodetype == LYS_LEAF) &&
                    (((const struct lysc_node_leaf *)key->schema)->type->basetype >= LY_TYPE_INT8) &&
                    (((const struct lysc_node_leaf *)key->schema)->type->basetype <= LY_TYPE_UINT64);
            if (numeric) {
                snprintf(newk, sizeof newk, "%llu", strtoull(oldk, NULL, 10) + 1000);
            } else {
                snprintf(newk, sizeof newk, "%s-dup", oldk);
            }
            if (lyd_dup_single(it->node, NULL, LYD_DUP_RECURSIVE | LYD_DUP_WITH_PARENTS | LYD_DUP_WITH_FLAGS, &dup)) {
                continue;
            }
            for (top = dup; top->parent; top = lyd_parent(top)) {}
            lyd_print_mem(&xml, top, LYD_XML, LYD_PRINT_SHRINK);
            lyd_free_siblings(top);
            if (!xml) {
                continue;
            }
            /* a long key is renamed everywhere it appears (children are named after it), a short one only where it is a value */
            olen = strlen(oldk);
            nlen = strlen(newk);
            out = malloc(strlen(xml) * 3 + 64);
            out[0] = 0;
            for (p = xml, q = out; *p;) {
                if (!strncmp(p, oldk, olen) && ((olen >= 8) ||
                        ((p > xml) && (p[-1] == '>') && (p[olen] == '<')))) {
                    memcpy(q, newk, nlen);
                    q += nlen;
                    p += olen;
                } else {
                    *q++ = *p++;
                }
            }
            *q = 0;
            free(xml);
            e = new_edit("clone");
            e->ops[0].kind = OP_ADD_XML;
            e->ops[0].path = strdup(it->dpath);
            e->ops[0].val = out;
            e->nops = 1;
            run_edit(tree, base_mods, base_cnt, e, NULL);
        }
    }
    fprintf(stderr, "clones done (%ld s)\n", (long)(time(NULL) - t0));

    /* ---- MIXED: two to five of the single edits above in one go ---- */
    for (i = 0; ph('x') && ((int)i < n_mixed) && (npe > 4); ++i) {
        struct edit *e = new_edit("mixed");
        int k, want = 2 + (int)rnd(4);

        for (k = 0; k < want; ++k) {
            const struct edit *src = pool_edits[rnd((unsigned)npe)];

            e->ops[e->nops++] = src->ops[0];
        }
        run_edit(tree, base_mods, base_cnt, e, NULL);
        free(e);
    }
    (void)j;
    (void)sfile;

    printf("edits %ld, skipped %ld, rejected by both %ld, accepted by both %ld\n", n_total, n_skipped, n_both_rej, n_both_acc);
    printf("WRONG ACCEPT %ld, WRONG REJECT %ld, TREE MISMATCH %ld, edits with a full-pass fallback %ld\n", n_wrong_acc,
            n_wrong_rej, n_tree_diff, n_fallback);
    for (i = 0; cls_names[i]; ++i) {
        printf("  %-7s edits %5ld rejected %5ld wrong-accept %ld wrong-reject %ld tree-mismatch %ld\n", cls_names[i],
                cls_tot[i], cls_rej[i], cls_wa[i], cls_wr[i], cls_td[i]);
    }
    fclose(csv);
    fclose(cov);
    if (emit_idx) {
        fclose(emit_idx);
        printf("emitted %ld edit files\n", emit_count);
    }
    return (n_wrong_acc || n_wrong_rej || n_tree_diff) ? 3 : 0;
}
