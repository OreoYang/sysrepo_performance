/**
 * @file sr_setup.c
 * @brief Install the production modules into a fresh sysrepo repository and load a dataset into it.
 *
 * usage: SYSREPO_REPOSITORY_PATH=... sr_setup YANG_DIR MODULES_TXT DATASET_XML
 *
 * MODULES_TXT has one line per module, "name revision features" (features comma separated or "-"). DATASET_XML is
 * the merged starting configuration written by sweep with SWEEP_DUMP_DATASET, it becomes the startup and running data.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <sysrepo.h>

int
main(int argc, char **argv)
{
    sr_conn_ctx_t *conn = NULL;
    sr_install_mod_t *mods = NULL;
    char (*paths)[1024] = NULL;
    char (*feats)[768] = NULL;
    const char *(*flist)[65] = NULL;
    uint32_t n = 0, cap = 0;
    char line[2048], name[256], rev[64], feat[768];
    FILE *f;
    int rc;

    if (argc != 4) {
        fprintf(stderr, "usage: %s YANG_DIR MODULES_TXT DATASET_XML\n", argv[0]);
        return 1;
    }
    f = fopen(argv[2], "r");
    if (!f) {
        fprintf(stderr, "cannot open %s\n", argv[2]);
        return 1;
    }
    while (fgets(line, sizeof line, f)) {
        if (sscanf(line, "%255s %63s %767s", name, rev, feat) != 3) {
            continue;
        }
        if (n == cap) {
            cap = cap ? cap * 2 : 256;
            mods = realloc(mods, cap * sizeof *mods);
            paths = realloc(paths, cap * sizeof *paths);
            feats = realloc(feats, cap * sizeof *feats);
            flist = realloc(flist, cap * sizeof *flist);
        }
        memset(&mods[n], 0, sizeof *mods);
        snprintf(paths[n], sizeof *paths, "%s/%s%s%s.yang", argv[1], name, strcmp(rev, "-") ? "@" : "",
                strcmp(rev, "-") ? rev : "");
        if (access(paths[n], R_OK)) {
            snprintf(paths[n], sizeof *paths, "%s/%s.yang", argv[1], name);
        }
        if (access(paths[n], R_OK)) {
            continue;   /* built into libyang, nothing to install */
        }
        mods[n].schema_path = paths[n];
        snprintf(feats[n], sizeof *feats, "%s", feat);
        {
            uint32_t k = 0;
            char *tok, *save = NULL;

            if (strcmp(feat, "-")) {
                for (tok = strtok_r(feats[n], ",", &save); tok && (k < 63); tok = strtok_r(NULL, ",", &save)) {
                    flist[n][k++] = tok;
                }
            }
            flist[n][k] = NULL;
        }
        mods[n].features = flist[n];
        ++n;
    }
    fclose(f);

    if ((rc = sr_connect(0, &conn))) {
        fprintf(stderr, "sr_connect: %s\n", sr_strerror(rc));
        return 1;
    }
    rc = sr_install_modules2(conn, mods, n, argv[1], NULL, argv[3], LYD_XML);
    if (rc) {
        fprintf(stderr, "sr_install_modules2: %s\n", sr_strerror(rc));
    } else {
        printf("installed %u modules\n", n);
    }
    sr_disconnect(conn);
    return rc ? 1 : 0;
}
