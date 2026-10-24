/**
 * @file sr_edit_files.c
 * @brief Apply one or more XML edits via sysrepo (per-file apply, or one batched apply).
 *
 * Usage:
 *   sr_edit_files [--batch|--replace] [--jobs N] [--timeout-ms N] file.xml ...
 *   sr_edit_files --delete-phase service|provision --prov-count K prov.xml... svc.xml...
 *
 * The delete mode undoes the per-ONU files given (the first K are the provision files, the rest the service files,
 * paired by file name), one apply per file. Every list entry is deleted where it first belongs to a single ONU, an
 * entry that the files of several ONUs share is descended into instead. The service phase leaves alone what the
 * same ONU's provision file holds, the provision phase deletes that.
 *
 * Environment: SYSREPO_REPOSITORY_PATH, SYSREPO_SHM_DIR, SR_PROFILE_EDIT, SR_DS_FORMAT
 */

#define _GNU_SOURCE

#include <libgen.h>
#include <search.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <libyang/libyang.h>
#include <sysrepo.h>

static double
now_s(void)
{
    struct timespec ts;

    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static int
load_edit_xml(const struct ly_ctx *ctx, const char *path, struct lyd_node **data)
{
    struct ly_in *in = NULL;
    LY_ERR lyrc;
    uint32_t flags = LYD_PARSE_NO_STATE | LYD_PARSE_ONLY | LYD_PARSE_STORE_ONLY;

    lyrc = ly_in_new_filepath(path, 0, &in);
    if (lyrc) {
        fprintf(stderr, "error: open %s (%d)\n", path, lyrc);
        return -1;
    }
    lyrc = lyd_parse_data(ctx, NULL, in, LYD_XML, flags, 0, data);
    ly_in_free(in, 1);
    if (lyrc) {
        fprintf(stderr, "error: parse %s: %s\n", path, ly_last_logmsg());
        return -1;
    }
    return 0;
}

/** @brief Who holds one list entry path among the files of the delete mode. */
struct del_owner {
    const char *onu;    /**< file name of the first file holding it, the ONU it belongs to */
    int shared;         /**< held by the files of more than one ONU */
    int in_prov;        /**< held by a provision file */
};

static int
is_list_entry(const struct lyd_node *node)
{
    return node->schema && (node->schema->nodetype & (LYS_LIST | LYS_LEAFLIST));
}

/**
 * @brief Record every list entry of @p first and its siblings, at any depth.
 */
static int
del_register(const struct lyd_node *first, const char *onu, int prov)
{
    const struct lyd_node *node;
    struct del_owner *own;
    ENTRY e, *found;
    char *path;

    LY_LIST_FOR(first, node) {
        if (is_list_entry(node)) {
            path = lyd_path(node, LYD_PATH_STD, NULL, 0);
            if (!path) {
                return -1;
            }
            e.key = path;
            found = hsearch(e, FIND);
            if (found) {
                own = found->data;
                free(path);
                if (strcmp(own->onu, onu)) {
                    own->shared = 1;
                }
            } else {
                own = calloc(1, sizeof *own);
                if (!own) {
                    free(path);
                    return -1;
                }
                own->onu = onu;
                e.data = own;
                if (!hsearch(e, ENTER)) {
                    free(path);
                    free(own);
                    return -1;
                }
            }
            if (prov) {
                own->in_prov = 1;
            }
        }
        if (del_register(lyd_child(node), onu, prov)) {
            return -1;
        }
    }
    return 0;
}

/**
 * @brief Queue the deletion of the entries of @p first and its siblings that this phase owns.
 */
static int
del_queue(sr_session_ctx_t *sess, const struct lyd_node *first, int service, int *count)
{
    const struct lyd_node *node;
    struct del_owner *own;
    ENTRY e, *found;
    char *path;
    int r;

    LY_LIST_FOR(first, node) {
        if (is_list_entry(node)) {
            path = lyd_path(node, LYD_PATH_STD, NULL, 0);
            if (!path) {
                return -1;
            }
            e.key = path;
            found = hsearch(e, FIND);
            own = found ? found->data : NULL;
            if (own && !own->shared) {
                if (!service || !own->in_prov) {
                    r = sr_delete_item(sess, path, 0);
                    if (r) {
                        fprintf(stderr, "sr_delete_item %s failed: %s\n", path, sr_strerror(r));
                        free(path);
                        return -1;
                    }
                    ++*count;
                }
                /* the whole subtree goes with it, or belongs to the provision phase */
                free(path);
                continue;
            }
            free(path);
        }
        if (del_queue(sess, lyd_child(node), service, count)) {
            return -1;
        }
    }
    return 0;
}

static int
run_delete(sr_session_ctx_t *sess, const struct ly_ctx *ctx, char **files, int nfiles, int prov_count,
        int service, uint32_t timeout_ms)
{
    struct lyd_node **trees;
    char **onus;
    double t0, t_all, dt;
    int i, from, to, count, nfail = 0, ndone = 0, r;

    trees = calloc((size_t)nfiles, sizeof *trees);
    onus = calloc((size_t)nfiles, sizeof *onus);
    if (!trees || !onus || !hcreate((size_t)nfiles * 256)) {
        fprintf(stderr, "out of memory\n");
        return 1;
    }

    for (i = 0; i < nfiles; ++i) {
        char *tmp = strdup(files[i]);

        onus[i] = strdup(basename(tmp));
        free(tmp);
        if (load_edit_xml(ctx, files[i], &trees[i]) || del_register(trees[i], onus[i], i < prov_count)) {
            fprintf(stderr, "error: delete plan failed on %s\n", files[i]);
            return 1;
        }
    }

    from = service ? prov_count : 0;
    to = service ? nfiles : prov_count;
    t_all = now_s();
    for (i = from; i < to; ++i) {
        count = 0;
        if (del_queue(sess, trees[i], service, &count)) {
            sr_discard_changes(sess);
            nfail++;
            continue;
        }
        ++ndone;
        if (!count) {
            continue;
        }
        t0 = now_s();
        r = sr_apply_changes(sess, timeout_ms);
        dt = now_s() - t0;
        if (r) {
            fprintf(stderr, "sr_apply_changes failed on delete of %s (%.3fs): %s\n", files[i], dt, sr_strerror(r));
            sr_discard_changes(sess);
            nfail++;
        } else {
            fprintf(stderr, "SR_EDIT idx=%d apply=%.4fs file=%s deletes=%d\n", ndone, dt, files[i], count);
        }
    }
    fprintf(stderr, "SR_SERIAL apply nfiles=%d fail=%d jobs=1 total=%.3fs\n", to - from, nfail, now_s() - t_all);

    for (i = 0; i < nfiles; ++i) {
        lyd_free_all(trees[i]);
    }
    free(trees);
    /* the hash table keys and owners live until exit, the process ends right after */
    return nfail ? 1 : 0;
}

static void
usage(const char *argv0)
{
    fprintf(stderr,
            "Usage: %s [--batch|--replace] [--jobs N] [--timeout-ms N] file.xml [file.xml ...]\n"
            "       %s --delete-phase service|provision --prov-count K prov.xml... svc.xml...\n"
            "  --batch       sr_edit_batch all files, then one sr_apply_changes\n"
            "  --replace     merge each file into running, then sr_replace_config (copy-config)\n"
            "  --jobs N      concurrent applies (N connections; default 1). Not with --batch/--replace\n"
            "  default       apply each file (same as serial sysrepocfg --edit)\n"
            "  --delete-phase  undo the per-ONU files, one apply per file (see the file header)\n",
            argv0, argv0);
}

static int
apply_one_edit(sr_session_ctx_t *sess, const struct ly_ctx *ctx, const char *path,
        uint32_t timeout_ms, int idx, pthread_mutex_t *log_lock)
{
    struct lyd_node *data = NULL;
    double t0, dt;
    int r;

    if (load_edit_xml(ctx, path, &data)) {
        return 1;
    }
    if (!data) {
        if (log_lock) {
            pthread_mutex_lock(log_lock);
        }
        fprintf(stderr, "warning: empty edit %s\n", path);
        if (log_lock) {
            pthread_mutex_unlock(log_lock);
        }
        return 0;
    }
    r = sr_edit_batch(sess, data, "merge");
    lyd_free_all(data);
    if (r) {
        if (log_lock) {
            pthread_mutex_lock(log_lock);
        }
        fprintf(stderr, "sr_edit_batch failed on %s: %s\n", path, sr_strerror(r));
        if (log_lock) {
            pthread_mutex_unlock(log_lock);
        }
        sr_discard_changes(sess);
        return 1;
    }
    t0 = now_s();
    r = sr_apply_changes(sess, timeout_ms);
    dt = now_s() - t0;
    if (log_lock) {
        pthread_mutex_lock(log_lock);
    }
    if (r) {
        fprintf(stderr, "sr_apply_changes failed on %s (%.3fs): %s\n",
                path, dt, sr_strerror(r));
        sr_discard_changes(sess);
    } else {
        fprintf(stderr, "SR_EDIT idx=%d apply=%.4fs file=%s\n", idx, dt, path);
    }
    if (log_lock) {
        pthread_mutex_unlock(log_lock);
    }
    return r ? 1 : 0;
}

struct jobs_ctx {
    char **files;
    int nfiles;
    uint32_t timeout_ms;
    atomic_int next;
    atomic_int nfail;
    pthread_mutex_t log_lock;
};

static void *
jobs_worker(void *arg)
{
    struct jobs_ctx *j = arg;
    sr_conn_ctx_t *conn = NULL;
    sr_session_ctx_t *sess = NULL;
    const struct ly_ctx *ctx;
    int r, i;

    r = sr_connect(0, &conn);
    if (r) {
        pthread_mutex_lock(&j->log_lock);
        fprintf(stderr, "sr_connect failed: %s\n", sr_strerror(r));
        pthread_mutex_unlock(&j->log_lock);
        atomic_fetch_add(&j->nfail, 1);
        return NULL;
    }
    r = sr_session_start(conn, SR_DS_RUNNING, &sess);
    if (r) {
        pthread_mutex_lock(&j->log_lock);
        fprintf(stderr, "sr_session_start failed: %s\n", sr_strerror(r));
        pthread_mutex_unlock(&j->log_lock);
        sr_disconnect(conn);
        atomic_fetch_add(&j->nfail, 1);
        return NULL;
    }
    ctx = sr_acquire_context(conn);
    for (;;) {
        i = atomic_fetch_add(&j->next, 1);
        if (i >= j->nfiles) {
            break;
        }
        if (apply_one_edit(sess, ctx, j->files[i], j->timeout_ms, i + 1, &j->log_lock)) {
            atomic_fetch_add(&j->nfail, 1);
        }
    }
    sr_release_context(conn);
    sr_session_stop(sess);
    sr_disconnect(conn);
    return NULL;
}

static int
run_jobs(char **files, int nfiles, int jobs, uint32_t timeout_ms)
{
    struct jobs_ctx j = {
        .files = files,
        .nfiles = nfiles,
        .timeout_ms = timeout_ms,
    };
    pthread_t *th;
    int i, rc = 0;
    double t0;

    if (jobs > nfiles) {
        jobs = nfiles;
    }
    atomic_init(&j.next, 0);
    atomic_init(&j.nfail, 0);
    pthread_mutex_init(&j.log_lock, NULL);
    th = calloc((size_t)jobs, sizeof *th);
    if (!th) {
        pthread_mutex_destroy(&j.log_lock);
        return 1;
    }
    fprintf(stderr, "SR_JOBS jobs=%d nfiles=%d\n", jobs, nfiles);
    t0 = now_s();
    for (i = 0; i < jobs; ++i) {
        if (pthread_create(&th[i], NULL, jobs_worker, &j)) {
            fprintf(stderr, "pthread_create failed\n");
            jobs = i;
            atomic_store(&j.next, nfiles);
            rc = 1;
            break;
        }
    }
    for (i = 0; i < jobs; ++i) {
        pthread_join(th[i], NULL);
    }
    free(th);
    pthread_mutex_destroy(&j.log_lock);
    fprintf(stderr, "SR_SERIAL apply nfiles=%d fail=%d jobs=%d total=%.3fs\n",
            nfiles, atomic_load(&j.nfail), jobs, now_s() - t0);
    return rc || atomic_load(&j.nfail);
}

int
main(int argc, char **argv)
{
    sr_conn_ctx_t *conn = NULL;
    sr_session_ctx_t *sess = NULL;
    const struct ly_ctx *ctx;
    int batch = 0, replace = 0, jobs = 1, i, first_file, rc = 1, r;
    int del_phase = -1, prov_count = -1;
    uint32_t timeout_ms = 600000;
    double t0, t_all;
    int nfiles = 0, nfail = 0;

    first_file = 1;
    for (i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--batch")) {
            batch = 1;
            first_file = i + 1;
        } else if (!strcmp(argv[i], "--replace")) {
            replace = 1;
            first_file = i + 1;
        } else if (!strcmp(argv[i], "--jobs") && (i + 1 < argc)) {
            jobs = (int)strtol(argv[++i], NULL, 10);
            first_file = i + 1;
        } else if (!strcmp(argv[i], "--delete-phase") && (i + 1 < argc)) {
            ++i;
            if (!strcmp(argv[i], "service")) {
                del_phase = 1;
            } else if (!strcmp(argv[i], "provision")) {
                del_phase = 0;
            } else {
                fprintf(stderr, "--delete-phase takes service or provision\n");
                return 2;
            }
            first_file = i + 1;
        } else if (!strcmp(argv[i], "--prov-count") && (i + 1 < argc)) {
            prov_count = (int)strtol(argv[++i], NULL, 10);
            first_file = i + 1;
        } else if (!strcmp(argv[i], "--timeout-ms") && (i + 1 < argc)) {
            timeout_ms = (uint32_t)strtoul(argv[++i], NULL, 10);
            first_file = i + 1;
        } else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            usage(argv[0]);
            return 0;
        } else if (argv[i][0] == '-') {
            fprintf(stderr, "unknown option %s\n", argv[i]);
            usage(argv[0]);
            return 2;
        } else {
            first_file = i;
            break;
        }
    }

    if (first_file >= argc) {
        usage(argv[0]);
        return 2;
    }
    if (jobs < 1) {
        fprintf(stderr, "--jobs must be >= 1\n");
        return 2;
    }
    if ((jobs > 1) && (batch || replace)) {
        fprintf(stderr, "--jobs cannot be used with --batch or --replace\n");
        return 2;
    }
    if ((del_phase != -1) && ((prov_count < 0) || (prov_count > argc - first_file) || batch || replace ||
            (jobs > 1))) {
        fprintf(stderr, "--delete-phase needs a valid --prov-count and no other mode\n");
        return 2;
    }

    if (jobs > 1) {
        nfiles = argc - first_file;
        rc = run_jobs(&argv[first_file], nfiles, jobs, timeout_ms);
        {
            uint64_t calls = 0, fallbacks = 0, evals = 0, skips = 0;

            lyd_validate_incr_stats(NULL, &calls, &fallbacks);
            if (calls) {
                fprintf(stderr, "SR_INCR calls=%" PRIu64 " fallbacks=%" PRIu64 " rate=%.1f%%\n",
                        calls, fallbacks, (100.0 * (double)fallbacks) / (double)calls);
            }
            lyd_validate_incr_must_stats(NULL, &evals, &skips);
            if (evals || skips) {
                fprintf(stderr, "SR_INCR_MUST evals=%" PRIu64 " skips=%" PRIu64 "\n", evals, skips);
            }
        }
        return rc ? 1 : 0;
    }

    r = sr_connect(0, &conn);
    if (r) {
        fprintf(stderr, "sr_connect failed: %s\n", sr_strerror(r));
        return 1;
    }
    r = sr_session_start(conn, SR_DS_RUNNING, &sess);
    if (r) {
        fprintf(stderr, "sr_session_start failed: %s\n", sr_strerror(r));
        sr_disconnect(conn);
        return 1;
    }
    ctx = sr_acquire_context(conn);

    t_all = now_s();
    if (del_phase != -1) {
        nfail = run_delete(sess, ctx, &argv[first_file], argc - first_file, prov_count, del_phase, timeout_ms);
    } else if (batch && replace) {
        fprintf(stderr, "--batch and --replace cannot be used together\n");
        sr_release_context(conn);
        sr_session_stop(sess);
        sr_disconnect(conn);
        return 2;
    } else if (replace) {
        for (i = first_file; i < argc; ++i) {
            sr_data_t *cur = NULL;
            struct lyd_node *running = NULL, *edit = NULL;

            nfiles++;
            if (load_edit_xml(ctx, argv[i], &edit)) {
                nfail++;
                continue;
            }
            if (!edit) {
                fprintf(stderr, "warning: empty edit %s\n", argv[i]);
                continue;
            }
            r = sr_get_data(sess, "/*", 0, timeout_ms, 0, &cur);
            if (r && (r != SR_ERR_NOT_FOUND)) {
                fprintf(stderr, "sr_get_data failed on %s: %s\n", argv[i], sr_strerror(r));
                lyd_free_all(edit);
                nfail++;
                continue;
            }
            if (cur) {
                running = cur->tree;
                cur->tree = NULL;
                sr_release_data(cur);
            }
            if (running) {
                if (lyd_merge_siblings(&running, edit, LYD_MERGE_DESTRUCT) != LY_SUCCESS) {
                    fprintf(stderr, "lyd_merge_siblings failed on %s: %s\n", argv[i], ly_last_logmsg());
                    lyd_free_all(edit);
                    lyd_free_all(running);
                    nfail++;
                    continue;
                }
            } else {
                running = edit;
            }
            t0 = now_s();
            r = sr_replace_config(sess, NULL, running, timeout_ms);
            {
                double dt = now_s() - t0;

                if (r) {
                    fprintf(stderr, "sr_replace_config failed on %s (%.3fs): %s\n",
                            argv[i], dt, sr_strerror(r));
                    nfail++;
                } else {
                    fprintf(stderr, "SR_EDIT idx=%d apply=%.4fs file=%s\n",
                            nfiles, dt, argv[i]);
                }
            }
        }
        fprintf(stderr, "SR_SERIAL apply nfiles=%d fail=%d total=%.3fs\n",
                nfiles, nfail, now_s() - t_all);
    } else if (batch) {
        struct lyd_node *acc = NULL;

        for (i = first_file; i < argc; ++i) {
            struct lyd_node *data = NULL;

            nfiles++;
            if (load_edit_xml(ctx, argv[i], &data)) {
                nfail++;
                continue;
            }
            if (!data) {
                continue;
            }
            if (!acc) {
                acc = data;
            } else if (lyd_merge_siblings(&acc, data, LYD_MERGE_DESTRUCT) != LY_SUCCESS) {
                fprintf(stderr, "lyd_merge_siblings failed on %s: %s\n", argv[i], ly_last_logmsg());
                lyd_free_all(data);
                nfail++;
            }
        }
        if (acc) {
            r = sr_edit_batch(sess, acc, "merge");
            lyd_free_all(acc);
            if (r) {
                fprintf(stderr, "sr_edit_batch failed: %s\n", sr_strerror(r));
                nfail++;
            } else {
                t0 = now_s();
                r = sr_apply_changes(sess, timeout_ms);
                fprintf(stderr, "SR_BATCH apply nfiles=%d fail=%d apply=%.3fs total=%.3fs\n",
                        nfiles, nfail, now_s() - t0, now_s() - t_all);
                if (r) {
                    fprintf(stderr, "sr_apply_changes batch failed: %s\n", sr_strerror(r));
                    sr_discard_changes(sess);
                    nfail++;
                }
            }
        }
    } else {
        for (i = first_file; i < argc; ++i) {
            nfiles++;
            if (apply_one_edit(sess, ctx, argv[i], timeout_ms, nfiles, NULL)) {
                nfail++;
            }
        }
        fprintf(stderr, "SR_SERIAL apply nfiles=%d fail=%d jobs=1 total=%.3fs\n",
                nfiles, nfail, now_s() - t_all);
    }

    {
        uint64_t calls = 0, fallbacks = 0, evals = 0, skips = 0;

        lyd_validate_incr_stats(NULL, &calls, &fallbacks);
        if (calls) {
            fprintf(stderr, "SR_INCR calls=%" PRIu64 " fallbacks=%" PRIu64 " rate=%.1f%%\n",
                    calls, fallbacks, (100.0 * (double)fallbacks) / (double)calls);
        }
        lyd_validate_incr_must_stats(NULL, &evals, &skips);
        if (evals || skips) {
            fprintf(stderr, "SR_INCR_MUST evals=%" PRIu64 " skips=%" PRIu64 "\n", evals, skips);
        }
    }

    sr_release_context(conn);
    sr_session_stop(sess);
    sr_disconnect(conn);
    rc = nfail ? 1 : 0;
    return rc;
}
