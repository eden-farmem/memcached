#include <stdio.h>
#include <stddef.h>

#include "memcached.h"

static void display(const char *name, size_t size) {
    printf("%s\t%d\n", name, (int)size);
}

int main(int argc, char **argv) {

    display("Slab Stats", sizeof(struct slab_stats));
    display("Thread stats",
            sizeof(struct thread_stats)
            - (200 * sizeof(struct slab_stats)));
    display("Global stats", sizeof(struct stats));
    display("Settings", sizeof(struct settings));
    display("Item (no cas)", sizeof(item));
    printf("Item Offsets: h_next=%ld; nbytes=%ld; nsuffix=%ld data=%ld\n",
               (long) offsetof(item, h_next),
               (long) offsetof(item, nbytes),
               (long) offsetof(item, nsuffix),
               (long) offsetof(item, data));
    display("Item (cas)", sizeof(item) + sizeof(uint64_t));
#ifdef EXTSTORE
    display("extstore header", sizeof(item_hdr));
#endif
    display("Libevent thread",
            sizeof(PHYS_THREAD) - sizeof(struct thread_stats));
    display("Connection", sizeof(conn));

    printf("----------------------------------------\n");

    display("libevent thread cumulative", sizeof(PHYS_THREAD));
    display("Thread stats cumulative\t", sizeof(struct thread_stats));

    return 0;
}
