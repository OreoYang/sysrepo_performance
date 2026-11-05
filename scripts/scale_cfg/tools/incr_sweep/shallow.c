/**
 * @file shallow.c
 * @brief For every config list and leaf-list of the production schemas: would deleting one instance get the narrow
 * scope of LYD_VALIDATE_INCR_SHALLOW_DELETE, or a scope root?
 *
 * Mirrors lyd_val_incr_shallow_ok() of validation_incr.c, minus the one check that needs data (the diff must name
 * only the instance itself, which is what a delete of one instance gives). The checks, in the order of the code:
 *   top-level   the instance has no parent, the whole top-level instance goes away, nothing to scope
 *   list-above  a list or leaf-list is the parent or sits above it
 *   top-atoms   a rule that no list confines reads the deleted node or something below it
 *   unknown     a rule with unknown atoms is attached at or below the parent, unless it is a local rule
 *               confined to a list instance
 *   SHALLOW     none of the above: only the parent is checked
 *
 * Usage: shallow YANG_DIR MODULES_TXT OUT_CSV
 */
#include <stdarg.h>

#include "ctxload.h"
#include "validation_deps.h"

void
ly_log(const struct ly_ctx *ctx, LY_LOG_LEVEL level, LY_ERR err, const char *format, ...)
{
    va_list ap;

    (void)ctx;
    (void)level;
    (void)err;
    va_start(ap, format);
    vfprintf(stderr, format, ap);
    va_end(ap);
    fputc('\n', stderr);
}

static int
covers(const struct lysc_node *anc, const struct lysc_node *snode)
{
    for ( ; snode; snode = lysc_data_parent(snode)) {
        if (snode == anc) {
            return 1;
        }
    }
    return 0;
}

static const char *
verdict(const struct lyd_val_dep_index *index, const struct lysc_node *n)
{
    const struct lysc_node *parent = lysc_data_parent(n), *iter;
    const struct lyd_val_constraint *cons;
    uint32_t i;

    if (!parent) {
        return "top-level";
    }
    for (iter = parent; iter; iter = lysc_data_parent(iter)) {
        if (iter->nodetype & (LYS_LIST | LYS_LEAFLIST)) {
            return "list-above";
        }
    }
    for (i = 0; i < index->toplevel_atoms.count; ++i) {
        if (covers(n, index->toplevel_atoms.snodes[i])) {
            return "top-atoms";
        }
    }
    for (i = 0; i < index->constraint_count; ++i) {
        cons = &index->constraints[i];
        if ((cons->kind != LYD_VAL_DEP_UNIQUE) && (!cons->atoms || !cons->atoms[0]) &&
                !((cons->cls == LYD_VAL_DEP_LOCAL) && cons->unit) && covers(parent, cons->snode)) {
            return "unknown";
        }
    }
    return "SHALLOW";
}

int
main(int argc, char **argv)
{
    struct ly_ctx *ctx;
    const struct lys_module *mod;
    const struct lyd_val_dep_index *index;
    const struct lysc_node *root, *n;
    uint32_t idx = 0;
    FILE *out;
    char *path;

    if (argc < 4) {
        fprintf(stderr, "usage: shallow YANG_DIR MODULES_TXT OUT_CSV\n");
        return 1;
    }
    ctx = ctxload(argv[1], argv[2]);
    out = ctx ? fopen(argv[3], "w") : NULL;
    if (!out) {
        return 1;
    }
    fprintf(out, "module,node,verdict\n");
    while ((mod = ly_ctx_get_module_iter(ctx, &idx))) {
        if (!mod->implemented || !mod->compiled || lyd_val_deps_get(mod, &index)) {
            continue;
        }
        LY_LIST_FOR(mod->compiled->data, root) {
            LYSC_TREE_DFS_BEGIN(root, n) {
                if ((n->nodetype & (LYS_LIST | LYS_LEAFLIST)) && (n->flags & LYS_CONFIG_W) && (n->module == mod)) {
                    /* validated by the module that owns the node, an augment included */
                    path = lysc_path(n, LYSC_PATH_DATA, NULL, 0);
                    fprintf(out, "%s,%s,%s\n", mod->name, path, verdict(index, n));
                    free(path);
                }
                LYSC_TREE_DFS_END(root, n);
            }
        }
    }
    fclose(out);
    ly_ctx_destroy(ctx);
    return 0;
}
