#include <dlfcn.h>
#include <stdio.h>

typedef int (*extract_fn_t)(const char *cache_path, const char *out_dir,
                            void (^progress)(unsigned current, unsigned total));

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <dyld_shared_cache> <output_dir>\n", argv[0]);
        return 2;
    }

    void *handle = dlopen("/usr/lib/dsc_extractor.bundle", RTLD_NOW);
    if (handle == NULL) {
        fprintf(stderr, "dlopen failed: %s\n", dlerror());
        return 1;
    }

    extract_fn_t extract = (extract_fn_t)dlsym(handle, "dyld_shared_cache_extract_dylibs_progress");
    if (extract == NULL) {
        fprintf(stderr, "dlsym failed: %s\n", dlerror());
        dlclose(handle);
        return 1;
    }

    int rc = extract(argv[1], argv[2], ^(unsigned current, unsigned total) {
        if (total != 0 && (current == total || current % 250 == 0)) {
            fprintf(stderr, "extract progress: %u/%u\n", current, total);
        }
    });

    dlclose(handle);
    return rc;
}
