/**
 * @file yang_dep_report.c
 * @brief Offline classifier report for incremental YANG validation.
 *
 * Connects to a sysrepo repository, takes its libyang context (so the module set and the enabled features
 * are exactly the ones the product runs with) and classifies every when / must / leafref / unique reachable
 * from every implemented module.
 *
 * Reuses libyang's own classifier (src/validation_deps.c) so the report can never drift from what the
 * incremental validator actually does at run time.
 *
 * Usage: yang_dep_report [out.csv]
 *   SYSREPO_REPOSITORY_PATH / SYSREPO_SHM_DIR select the repository, as for any sysrepo tool.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libyang/libyang.h>
#include <sysrepo.h>

#include "validation_deps.h"

#include <stdarg.h>

/* libyang is built with -fvisibility=hidden, so validation_deps.c is compiled into this tool instead of
 * linked from the shared library; this is the one internal helper it needs */
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
        /* YANG allows expressions to span lines; keep every record on one CSV line */
        fputc((*str == '\n') || (*str == '\r') ? ' ' : *str, f);
    }
    fputc('"', f);
}

int
main(int argc, char **argv)
{
    sr_conn_ctx_t *conn = NULL;
    const struct ly_ctx *ctx;
    const struct lys_module *mod;
    const struct lyd_val_dep_index *index;
    uint32_t idx = 0, i, c;
    uint64_t total[LYD_VAL_DEP_CLASS_COUNT] = {0};
    uint64_t total_all = 0, total_unsafe = 0, total_unconfined = 0, total_toplevel_atoms = 0;
    FILE *out;
    char *path;
    int rc = 1;

    out = (argc > 1) ? fopen(argv[1], "w") : stdout;
    if (!out) {
        fprintf(stderr, "cannot open %s\n", argv[1]);
        return 1;
    }

    if (sr_connect(0, &conn) != SR_ERR_OK) {
        fprintf(stderr, "sr_connect failed\n");
        goto cleanup;
    }
    ctx = sr_acquire_context(conn);

    fprintf(out, "module,node,kind,class,creation_safe,unit,atoms,expr\n");

    while ((mod = ly_ctx_get_module_iter(ctx, &idx))) {
        if (!mod->implemented) {
            continue;
        }
        if (lyd_val_deps_get(mod, &index)) {
            fprintf(stderr, "indexing %s failed\n", mod->name);
            continue;
        }

        total_toplevel_atoms += index->toplevel_atoms.count;

        for (i = 0; i < index->constraint_count; ++i) {
            const struct lyd_val_constraint *cons = &index->constraints[i];
            char *unit;

            for (c = 0; cons->atoms && cons->atoms[c]; ++c) {}

            path = lysc_path(cons->snode, LYSC_PATH_LOG, NULL, 0);
            unit = cons->unit ? lysc_path(cons->unit, LYSC_PATH_LOG, NULL, 0) : NULL;
            fprintf(out, "%s,%s,%s,%s,%u,%s,%u,", mod->name, path ? path : "?",
                    lyd_val_dep_kind_str(cons->kind), lyd_val_dep_class_str(cons->cls), cons->creation_safe,
                    unit ? unit : "", c);
            csv_escape(out, cons->expr);
            fputc('\n', out);
            free(path);
            free(unit);

            ++total[cons->cls];
            ++total_all;
            if ((cons->cls > LYD_VAL_DEP_LIST_SCOPE) && !cons->creation_safe) {
                ++total_unsafe;
            }
            if ((cons->cls <= LYD_VAL_DEP_LIST_SCOPE) && !cons->unit) {
                ++total_unconfined;
            }
        }
    }

    fprintf(stderr, "constraints: %llu\n", (unsigned long long)total_all);
    for (i = 0; i < LYD_VAL_DEP_CLASS_COUNT; ++i) {
        fprintf(stderr, "  %-11s %6llu  %5.1f%%\n", lyd_val_dep_class_str(i), (unsigned long long)total[i],
                total_all ? (100.0 * total[i]) / total_all : 0.0);
    }
    fprintf(stderr, "  cross-instance and not creation-safe: %llu (%.1f%%)\n", (unsigned long long)total_unsafe,
            total_all ? (100.0 * total_unsafe) / total_all : 0.0);
    fprintf(stderr, "  confined but not to any list: %llu (%.1f%%), %llu schema nodes widen the scope\n",
            (unsigned long long)total_unconfined, total_all ? (100.0 * total_unconfined) / total_all : 0.0,
            (unsigned long long)total_toplevel_atoms);

    rc = 0;

cleanup:
    if (conn) {
        sr_release_context(conn);
        sr_disconnect(conn);
    }
    if (out != stdout) {
        fclose(out);
    }
    return rc;
}
