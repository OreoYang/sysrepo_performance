/*
 * sr_validate_ds: full YANG validation of running and startup, read only. Nothing is ever written.
 *
 * Stored data (default): each datastore is read with sr_get_data() and the copy is checked with libyang
 * lyd_validate_all(). sr_validate() is not used here because on running and startup it checks only a pending edit.
 *
 * Edit dry run (-e): the edit-config content is loaded into a session with sr_edit_batch() (merge), checked with
 * sr_validate() and discarded. sr_validate() applies the edit to a copy and validates the changed modules and the
 * modules depending on them in full; it sends no change event and takes read locks only.
 *
 * Copy-config source (-f): the file is parsed with the schema of this OLT and checked with lyd_validate_all() as the
 * whole new content of a datastore. No datastore is read.
 *
 * None of the modes takes the incremental path, which needs an edit diff and exists only inside sysrepo
 * apply-changes. The tool opens its own sysrepo connection, so it does not touch the connections or subscriptions
 * of any daemon.
 *
 * usage: sr_validate_ds [-d running|startup|both] [-e edit.xml | -f config.xml] [-v]
 * exit : 0 valid, 1 invalid, 2 other error
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <libyang/libyang.h>
#include <sysrepo.h>

#define EXIT_VALID    0
#define EXIT_INVALID  1
#define EXIT_ERROR    2

/* same parse options as "sysrepocfg --edit" and "sysrepocfg --import" */
#define CFG_PARSE_OPTS  (LYD_PARSE_NO_STATE | LYD_PARSE_ONLY | LYD_PARSE_STORE_ONLY | LYD_PARSE_STRICT)
#define CFG_VAL_OPTS    (LYD_VALIDATE_NO_STATE | LYD_VALIDATE_MULTI_ERROR)

static void
usage(void)
{
    fprintf(stderr,
        "usage: sr_validate_ds [-d running|startup|both] [-e edit.xml | -f config.xml] [-v]\n"
        "  (none)       full validation of the stored data of the datastores in -d\n"
        "  -e FILE      dry run of an edit-config content (merge) on the datastores in -d, nothing is applied\n"
        "  -f FILE      full validation of a copy-config source file, no datastore is read\n"
        "  -d DS        running, startup or both (default both)\n"
        "  FILE         XML, or JSON when the name ends with .json; top-level data nodes as for sysrepocfg\n");
}

static double
elapsed(const struct timespec *t0)
{
    struct timespec t1;

    clock_gettime(CLOCK_MONOTONIC, &t1);
    return (double)(t1.tv_sec - t0->tv_sec) + (double)(t1.tv_nsec - t0->tv_nsec) / 1e9;
}

static void
print_ly_errors(const struct ly_ctx *ctx)
{
    const struct ly_err_item *err;

    for (err = ly_err_first(ctx); err; err = err->next)
    {
        printf("  - %s%s%s\n", err->msg, err->data_path ? " (path " : "", err->data_path ? err->data_path : "");
    }
}

static void
print_sr_errors(sr_session_ctx_t *sess)
{
    const sr_error_info_t *err_info = NULL;
    uint32_t i;

    if (sr_session_get_error(sess, &err_info) || !err_info)
    {
        return;
    }
    for (i = 0; i < err_info->err_count; ++i)
    {
        printf("  - %s\n", err_info->err[i].message);
    }
}

/* parse a data file with the schema of this OLT; returns EXIT_VALID, EXIT_INVALID or EXIT_ERROR */
static int
parse_file(const struct ly_ctx *ctx, const char *label, const char *path, struct lyd_node **tree)
{
    struct ly_in *in = NULL;
    size_t len = strlen(path);
    LYD_FORMAT format = ((len > 5) && !strcmp(path + len - 5, ".json")) ? LYD_JSON : LYD_XML;

    *tree = NULL;
    if (ly_in_new_filepath(path, 0, &in))
    {
        fprintf(stderr, "%s: cannot read \"%s\"\n", label, path);
        return EXIT_ERROR;
    }
    ly_err_clean((struct ly_ctx *)ctx, NULL);
    if (lyd_parse_data(ctx, NULL, in, format, CFG_PARSE_OPTS, 0, tree))
    {
        printf("INVALID  %-8s %s does not match the schema:\n", label, path);
        print_ly_errors(ctx);
        ly_in_free(in, 0);
        return EXIT_INVALID;
    }
    ly_in_free(in, 0);
    return EXIT_VALID;
}

/* returns EXIT_VALID, EXIT_INVALID or EXIT_ERROR */
static int
validate_ds(sr_conn_ctx_t *conn, sr_datastore_t ds, const char *name)
{
    sr_session_ctx_t *sess = NULL;
    sr_data_t *data = NULL;
    const struct ly_ctx *ctx = NULL;
    struct timespec t0;
    int rc, ret = EXIT_ERROR;

    rc = sr_session_start(conn, ds, &sess);
    if (rc)
    {
        fprintf(stderr, "%s: session failed: %s\n", name, sr_strerror(rc));
        return EXIT_ERROR;
    }
    ctx = sr_acquire_context(conn);

    /* the whole config of every module, a copy that is validated and then freed */
    rc = sr_get_data(sess, "/*", 0, 0, 0, &data);
    if (rc)
    {
        fprintf(stderr, "%s: reading data failed: %s\n", name, sr_strerror(rc));
        goto cleanup;
    }

    ly_err_clean((struct ly_ctx *)ctx, NULL);
    clock_gettime(CLOCK_MONOTONIC, &t0);
    rc = (data && data->tree) ? lyd_validate_all(&data->tree, NULL, CFG_VAL_OPTS, NULL) : LY_SUCCESS;

    if (rc == LY_SUCCESS)
    {
        printf("VALID    %-8s full validation, %.2f s\n", name, elapsed(&t0));
        ret = EXIT_VALID;
    }
    else
    {
        printf("INVALID  %-8s full validation failed:\n", name);
        print_ly_errors(ctx);
        ret = EXIT_INVALID;
    }

cleanup:
    sr_release_data(data);
    sr_release_context(conn);
    sr_session_stop(sess);
    return ret;
}

/* dry run of an edit-config content on one datastore; returns EXIT_VALID, EXIT_INVALID or EXIT_ERROR */
static int
validate_edit(sr_conn_ctx_t *conn, sr_datastore_t ds, const char *name, const char *path)
{
    sr_session_ctx_t *sess = NULL;
    const struct ly_ctx *ctx = NULL;
    struct lyd_node *edit = NULL;
    struct timespec t0;
    int rc, ret;

    rc = sr_session_start(conn, ds, &sess);
    if (rc)
    {
        fprintf(stderr, "%s: session failed: %s\n", name, sr_strerror(rc));
        return EXIT_ERROR;
    }
    ctx = sr_acquire_context(conn);

    ret = parse_file(ctx, name, path, &edit);
    if (ret != EXIT_VALID)
    {
        goto cleanup;
    }
    if (!edit)
    {
        fprintf(stderr, "%s: \"%s\" holds no data\n", name, path);
        ret = EXIT_ERROR;
        goto cleanup;
    }

    clock_gettime(CLOCK_MONOTONIC, &t0);
    rc = sr_edit_batch(sess, edit, "merge");
    if (!rc)
    {
        /* applies the edit to a copy only, the session edit is discarded below */
        rc = sr_validate(sess, NULL, 0);
    }

    switch (rc)
    {
    case SR_ERR_OK:
        printf("VALID    %-8s edit %s, full validation, %.2f s\n", name, path, elapsed(&t0));
        ret = EXIT_VALID;
        break;
    case SR_ERR_SYS:
    case SR_ERR_NO_MEMORY:
    case SR_ERR_INTERNAL:
    case SR_ERR_TIME_OUT:
    case SR_ERR_LOCKED:
        fprintf(stderr, "%s: edit check failed: %s\n", name, sr_strerror(rc));
        print_sr_errors(sess);
        ret = EXIT_ERROR;
        break;
    default:
        printf("INVALID  %-8s edit %s rejected (%s):\n", name, path, sr_strerror(rc));
        print_sr_errors(sess);
        ret = EXIT_INVALID;
        break;
    }
    sr_discard_changes(sess);

cleanup:
    lyd_free_all(edit);
    sr_release_context(conn);
    sr_session_stop(sess);
    return ret;
}

/* full validation of a copy-config source; returns EXIT_VALID, EXIT_INVALID or EXIT_ERROR */
static int
validate_file(sr_conn_ctx_t *conn, const char *path)
{
    const struct ly_ctx *ctx = sr_acquire_context(conn);
    struct lyd_node *tree = NULL;
    struct timespec t0;
    int ret;

    ret = parse_file(ctx, "file", path, &tree);
    if (ret == EXIT_VALID)
    {
        /* every module of the context is checked, a module missing from the file counts as empty */
        ly_err_clean((struct ly_ctx *)ctx, NULL);
        clock_gettime(CLOCK_MONOTONIC, &t0);
        if (lyd_validate_all(&tree, ctx, CFG_VAL_OPTS, NULL) == LY_SUCCESS)
        {
            printf("VALID    %-8s %s, full validation, %.2f s\n", "file", path, elapsed(&t0));
        }
        else
        {
            printf("INVALID  %-8s %s full validation failed:\n", "file", path);
            print_ly_errors(ctx);
            ret = EXIT_INVALID;
        }
    }

    lyd_free_all(tree);
    sr_release_context(conn);
    return ret;
}

int
main(int argc, char *argv[])
{
    sr_conn_ctx_t *conn = NULL;
    const char *edit_path = NULL, *file_path = NULL;
    int want_running = 1, want_startup = 1;
    int i, rc, ret = EXIT_VALID, r;

    for (i = 1; i < argc; ++i)
    {
        if (strcmp(argv[i], "-d") == 0 && (i + 1 < argc))
        {
            ++i;
            want_running = (strcmp(argv[i], "running") == 0 || strcmp(argv[i], "both") == 0);
            want_startup = (strcmp(argv[i], "startup") == 0 || strcmp(argv[i], "both") == 0);
            if (!want_running && !want_startup)
            {
                usage();
                return EXIT_ERROR;
            }
        }
        else if (strcmp(argv[i], "-e") == 0 && (i + 1 < argc))
        {
            edit_path = argv[++i];
        }
        else if (strcmp(argv[i], "-f") == 0 && (i + 1 < argc))
        {
            file_path = argv[++i];
        }
        else if (strcmp(argv[i], "-v") == 0)
        {
            sr_log_stderr(SR_LL_INF);
        }
        else
        {
            usage();
            return EXIT_ERROR;
        }
    }
    if (edit_path && file_path)
    {
        usage();
        return EXIT_ERROR;
    }

    /* keep every validation error and print it once ourselves (default: log all, store only the last) */
    ly_log_options(LY_LOSTORE);

    rc = sr_connect(0, &conn);
    if (rc)
    {
        fprintf(stderr, "connect failed: %s\n", sr_strerror(rc));
        return EXIT_ERROR;
    }
    if (file_path)
    {
        ret = validate_file(conn, file_path);
    }
    else
    {
        if (want_running)
        {
            r = edit_path ? validate_edit(conn, SR_DS_RUNNING, "running", edit_path) :
                validate_ds(conn, SR_DS_RUNNING, "running");
            ret = (r > ret) ? r : ret;
        }
        if (want_startup)
        {
            r = edit_path ? validate_edit(conn, SR_DS_STARTUP, "startup", edit_path) :
                validate_ds(conn, SR_DS_STARTUP, "startup");
            ret = (r > ret) ? r : ret;
        }
    }
    sr_disconnect(conn);
    return ret;
}
