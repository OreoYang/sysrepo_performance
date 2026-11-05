/**
 * @file inv.c
 * @brief Inventory of everything in the production schemas that can make an edit invalid.
 *
 * Writes two CSV files:
 *   rules.csv   when / must / leafref / unique, classified by libyang's own classifier (validation_deps.c is
 *               compiled in, so the inventory cannot drift from what incremental validation does)
 *   struct.csv  mandatory leaves and choices, min-elements, max-elements, unique statements
 *
 * Usage: inv YANG_DIR MODULES_TXT RULES_CSV STRUCT_CSV
 */
#include <stdarg.h>

#include "ctxload.h"
#include "validation_deps.h"

/* libyang is built with -fvisibility=hidden, so validation_deps.c is compiled into this tool; this is the one
 * internal helper it needs */
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

static void
csv_escape(FILE *f, const char *str)
{
    fputc('"', f);
    for ( ; str && *str; ++str) {
        if (*str == '"') {
            fputc('"', f);
        }
        fputc((*str == '\n') || (*str == '\r') ? ' ' : *str, f);
    }
    fputc('"', f);
}

static char *
dpath(const struct lysc_node *n)
{
    return lysc_path(n, LYSC_PATH_DATA, NULL, 0);
}

static ly_bool
in_choice(const struct lysc_node *n)
{
    for ( ; n; n = n->parent) {
        if (n->nodetype & (LYS_CHOICE | LYS_CASE)) {
            return 1;
        }
    }
    return 0;
}

/* a node a default value can instantiate without any edit naming it */
static ly_bool
implicit_node(const struct lysc_node *n)
{
    if (n->nodetype == LYS_LEAF) {
        return ((const struct lysc_node_leaf *)n)->dflt ? 1 : 0;
    }
    if (n->nodetype == LYS_LEAFLIST) {
        return ((const struct lysc_node_leaflist *)n)->dflts ? 1 : 0;
    }
    if (n->nodetype == LYS_CONTAINER) {
        return (n->flags & LYS_PRESENCE) ? 0 : 1;
    }
    return 0;
}

static void
print_rules(FILE *out, const struct lys_module *mod, const struct lyd_val_dep_index *index)
{
    uint32_t i, c, d;

    for (i = 0; i < index->constraint_count; ++i) {
        const struct lyd_val_constraint *cons = &index->constraints[i];
        const struct lys_module *amods[16] = {NULL};
        uint32_t namods = 0, natoms;
        char *path = dpath(cons->snode), *unit = cons->unit ? dpath(cons->unit) : NULL;

        for (natoms = 0; cons->atoms && cons->atoms[natoms]; ++natoms) {
            for (d = 0; d < namods; ++d) {
                if (amods[d] == cons->atoms[natoms]->module) {
                    break;
                }
            }
            if ((d == namods) && (namods < 16)) {
                amods[namods++] = cons->atoms[natoms]->module;
            }
        }
        fprintf(out, "%s,%s,%s,%s,%u,%s,%u,%u,%u,%u,%u,", mod->name, path, lyd_val_dep_kind_str(cons->kind),
                lyd_val_dep_class_str(cons->cls), cons->creation_safe, unit ? unit : "", natoms, namods,
                in_choice(cons->snode), implicit_node(cons->snode), (cons->snode->flags & LYS_CONFIG_W) ? 1 : 0);
        csv_escape(out, cons->expr);
        fputc(',', out);
        fputc('"', out);
        for (c = 0; c < natoms; ++c) {
            char *ap = dpath(cons->atoms[c]);

            fprintf(out, "%s%s", c ? "|" : "", ap);
            free(ap);
        }
        fputc('"', out);
        fputc('\n', out);
        free(path);
        free(unit);
    }
}

static void
print_struct(FILE *out, const struct lys_module *mod)
{
    const struct lysc_node *root, *n;
    struct ly_set *set;
    uint32_t u;

    set = NULL;
    (void)set;
    (void)u;
    LY_LIST_FOR(mod->compiled->data, root) {
        LYSC_TREE_DFS_BEGIN(root, n) {
            char *p = dpath(n);

            if ((n->nodetype & (LYS_LEAF | LYS_CHOICE | LYS_ANYDATA)) && (n->flags & LYS_MAND_TRUE) &&
                    (n->flags & LYS_CONFIG_W)) {
                fprintf(out, "%s,%s,%s,%s,%u,\n", mod->name, p, (n->nodetype == LYS_CHOICE) ? "mandatory-choice" : "mandatory",
                        "", in_choice(n));
            }
            if (n->nodetype == LYS_LIST) {
                const struct lysc_node_list *l = (const struct lysc_node_list *)n;
                LY_ARRAY_COUNT_TYPE a;

                if (l->min) {
                    fprintf(out, "%s,%s,min-elements,%u,%u,\n", mod->name, p, l->min, in_choice(n));
                }
                if (l->max != UINT32_MAX) {
                    fprintf(out, "%s,%s,max-elements,%u,%u,\n", mod->name, p, l->max, in_choice(n));
                }
                LY_ARRAY_FOR(l->uniques, a) {
                    LY_ARRAY_COUNT_TYPE b;

                    fprintf(out, "%s,%s,unique,%u,%u,", mod->name, p, (unsigned)LY_ARRAY_COUNT(l->uniques[a]), in_choice(n));
                    fputc('"', out);
                    LY_ARRAY_FOR(l->uniques[a], b) {
                        char *up = dpath((const struct lysc_node *)l->uniques[a][b]);

                        fprintf(out, "%s%s", b ? "|" : "", up);
                        free(up);
                    }
                    fputs("\"\n", out);
                }
            } else if (n->nodetype == LYS_LEAFLIST) {
                const struct lysc_node_leaflist *l = (const struct lysc_node_leaflist *)n;

                if (l->min) {
                    fprintf(out, "%s,%s,min-elements,%u,%u,\n", mod->name, p, l->min, in_choice(n));
                }
                if (l->max != UINT32_MAX) {
                    fprintf(out, "%s,%s,max-elements,%u,%u,\n", mod->name, p, l->max, in_choice(n));
                }
            }
            free(p);
            LYSC_TREE_DFS_END(root, n);
        }
    }
}

int
main(int argc, char **argv)
{
    struct ly_ctx *ctx;
    const struct lys_module *mod;
    const struct lyd_val_dep_index *index;
    uint32_t idx = 0;
    FILE *rules, *st;

    if (argc < 5) {
        fprintf(stderr, "usage: inv YANG_DIR MODULES_TXT RULES_CSV STRUCT_CSV\n");
        return 1;
    }
    ctx = ctxload(argv[1], argv[2]);
    if (!ctx) {
        return 1;
    }
    rules = fopen(argv[3], "w");
    st = fopen(argv[4], "w");
    if (!rules || !st) {
        return 1;
    }
    fprintf(rules, "module,node,kind,class,creation_safe,unit,atoms,atom_modules,in_choice,implicit,config,expr,atom_paths\n");
    fprintf(st, "module,node,kind,value,in_choice,detail\n");

    while ((mod = ly_ctx_get_module_iter(ctx, &idx))) {
        if (!mod->implemented || !mod->compiled) {
            continue;
        }
        if (lyd_val_deps_get(mod, &index)) {
            fprintf(stderr, "indexing %s failed\n", mod->name);
            continue;
        }
        if (index->unanalysable) {
            fprintf(stderr, "always validated in full: %s\n", mod->name);
        }
        print_rules(rules, mod, index);
        print_struct(st, mod);
    }
    fclose(rules);
    fclose(st);
    ly_ctx_destroy(ctx);
    return 0;
}
