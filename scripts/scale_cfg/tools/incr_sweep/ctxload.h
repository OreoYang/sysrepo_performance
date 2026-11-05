/**
 * @file ctxload.h
 * @brief Build the libyang context of the production schema set without a sysrepo repository.
 *
 * modules.txt has one line per module the product has installed: "name revision features" where features is a
 * comma separated list or "-". It is generated from the startup datastore of the sysrepo repository, so the
 * implemented modules and the enabled features are the ones the product runs with.
 */
#ifndef CTXLOAD_H_
#define CTXLOAD_H_

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libyang/libyang.h>

static struct ly_ctx *
ctxload(const char *yang_dir, const char *modules_txt)
{
    struct ly_ctx *ctx = NULL;
    FILE *f;
    char line[1024], name[256], rev[64], feat[768];
    int failed = 0, n = 0;

    if (ly_ctx_new(yang_dir, LY_CTX_NO_YANGLIBRARY | LY_CTX_DISABLE_SEARCHDIR_CWD | LY_CTX_REF_IMPLEMENTED |
            LY_CTX_EXPLICIT_COMPILE, &ctx)) {
        fprintf(stderr, "ly_ctx_new failed\n");
        return NULL;
    }
    f = fopen(modules_txt, "r");
    if (!f) {
        fprintf(stderr, "cannot open %s\n", modules_txt);
        ly_ctx_destroy(ctx);
        return NULL;
    }
    while (fgets(line, sizeof line, f)) {
        const char *features[64];
        char *tok, *save = NULL;
        uint32_t nf = 0;

        if (sscanf(line, "%255s %63s %767s", name, rev, feat) != 3) {
            continue;
        }
        if (strcmp(feat, "-")) {
            for (tok = strtok_r(feat, ",", &save); tok && (nf < 63); tok = strtok_r(NULL, ",", &save)) {
                features[nf++] = tok;
            }
        }
        features[nf] = NULL;
        if (!ly_ctx_load_module(ctx, name, strcmp(rev, "-") ? rev : NULL, features)) {
            fprintf(stderr, "cannot load %s@%s\n", name, rev);
            ++failed;
        }
        ++n;
    }
    fclose(f);
    if (failed || ly_ctx_compile(ctx)) {
        fprintf(stderr, "context build failed (%d of %d modules): %s\n", failed, n,
                ly_err_last(ctx) ? ly_err_last(ctx)->msg : "-");
        ly_ctx_destroy(ctx);
        return NULL;
    }
    return ctx;
}

#endif /* CTXLOAD_H_ */
