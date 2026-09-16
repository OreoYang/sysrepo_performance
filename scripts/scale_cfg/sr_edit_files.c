/**
 * @file sr_edit_files.c
 * @brief Apply one or more XML edits via sysrepo (per-file apply, or one batched apply).
 *
 * Usage:
 *   sr_edit_files [--batch|--replace] [--jobs N] [--timeout-ms N] file.xml ...
 *
 * Environment: SYSREPO_REPOSITORY_PATH, SYSREPO_SHM_DIR, SR_PROFILE_EDIT, SR_DS_FORMAT
 */

#define _GNU_SOURCE

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

static void
usage(const char *argv0)
{
    fprintf(stderr,
            "Usage: %s [--batch|--replace] [--jobs N] [--timeout-ms N] file.xml [file.xml ...]\n"
            "  --batch       sr_edit_batch all files, then one sr_apply_changes\n"
            "  --replace     merge each file into running, then sr_replace_config (copy-config)\n"
            "  --jobs N      concurrent applies (N connections; default 1). Not with --batch/--replace\n"
            "  default       apply each file (same as serial sysrepocfg --edit)\n",
            argv0);
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
    if (batch && replace) {
        fprintf(stderr, "--batch and --replace cannot be used together\n");
        sr_release_context(conn);
        sr_session_stop(sess);
        sr_disconnect(conn);
        return 2;
    }
    if (replace) {
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
