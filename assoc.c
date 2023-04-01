/* -*- Mode: C; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil -*- */
/*
 * Hash table
 *
 * The hash function used here is by Bob Jenkins, 1996:
 *    <http://burtleburtle.net/bob/hash/doobs.html>
 *       "By Bob Jenkins, 1996.  bob_jenkins@burtleburtle.net.
 *       You may use this code any way you wish, private, educational,
 *       or commercial.  It's free."
 *
 * The rest of the file is licensed under the BSD license.  See LICENSE.
 */

#include "memcached.h"
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/resource.h>
#include <signal.h>
#include <fcntl.h>
#include <errno.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <runtime/pgfault.h>
#include <rmem/api.h>

// #define RECORD_PAGE_ACCESS
#ifdef RECORD_PAGE_ACCESS
#include <ctype.h>
#include <string.h>
#endif

static condvar_t maintenance_cond;
static mutex_t maintenance_lock;

typedef  unsigned long  int  ub4;   /* unsigned 4-byte quantities */
typedef  unsigned       char ub1;   /* unsigned 1-byte quantities */

/* how many powers of 2's worth of buckets we use */
unsigned int hashpower = HASHPOWER_DEFAULT;

#define hashsize(n) ((ub4)1<<(n))
#define hashmask(n) (hashsize(n)-1)

/* Main hash table. This is where we look except during expansion. */
static item** primary_hashtable = 0;

/*
 * Previous hash table. During expansion, we look here for keys that haven't
 * been moved over to the primary yet.
 */
static item** old_hashtable = 0;

/* Flag: Are we in the middle of expanding now? */
static bool expanding = false;
static bool started_expanding = false;

/*
 * During expansion we migrate values with bucket granularity; this is how
 * far we've gotten so far. Ranges from 0 .. hashsize(hashpower - 1) - 1.
 */
static unsigned int expand_bucket = 0;

void assoc_init(const int hashtable_init) {
    condvar_init(&maintenance_cond);
    mutex_init(&maintenance_lock);
    if (hashtable_init) {
        hashpower = hashtable_init;
    }
    primary_hashtable = rmalloc(hashsize(hashpower) * sizeof(void *));
    if (! primary_hashtable) {
        fprintf(stderr, "Failed to init hashtable.\n");
        exit(EXIT_FAILURE);
    }
    STATS_LOCK();
    stats_state.hash_power_level = hashpower;
    stats_state.hash_bytes = hashsize(hashpower) * sizeof(void *);
    STATS_UNLOCK();
}

#ifdef RECORD_PAGE_ACCESS
/*******************************************************/
/*********** QUICK DATA RECORDING LOGIC ****************/
const int max_record_secs = 175;            /* how long to record */
const int max_records = 5000000 * 30;       /* max records that I can expect */
const int stop_at_record = max_records-1;   /* stop recording at this point */
const int record_len = 100;             /* max len in chars of each record */
static pthread_mutex_t record_lock = PTHREAD_MUTEX_INITIALIZER;
static long record_start_time = -1;
static int record_current_sec = 0;
static char* record_buf = NULL;
static size_t nrecords = 0;
static size_t nrecords_seen = 0;
static char* record_buf_ptr = NULL;
static bool dumped_records = false;

void record(char* record_str);
void record(char* record_str)
{
    long now;
    bool stop = false;
    bool dump = false;
    int len;

    now = time(NULL);
    pthread_mutex_lock(&record_lock);

    /* init data structures if first time*/
    if (record_buf == NULL) {
        record_buf = calloc((size_t) max_records * record_len, sizeof(char));
        if (record_buf == NULL) {
            perror("calloc");
            exit(1);
        }
        record_buf_ptr = record_buf;
    }
    if (record_start_time == -1)
        record_start_time = now;

    /* printing some info regardless of recording or not */
    nrecords_seen++;
    if (now - record_start_time > record_current_sec) {
        record_current_sec = (now - record_start_time);
        log_err("seen %ld records in %d secs, recorded: %ld", 
            nrecords_seen, record_current_sec, nrecords);
    }
    
    /* if we're over the limit, stop */
    if (nrecords == stop_at_record || now - record_start_time > max_record_secs)
        stop = true;

    if (stop) {
        if (!dumped_records) {
            dump = true;
            dumped_records = true;
        }
    }
    else {
        /* add the record */
        len = snprintf(record_buf_ptr, record_len, "%ld:%s\n",
            now - record_start_time, record_str);
        record_buf_ptr += len;
        nrecords++;
    }

    /* unlock */
    pthread_mutex_unlock(&record_lock);

    /* dump records to file */
    if (dump) {
        FILE *fp = fopen("output.txt", "w");
        if (fp == NULL) {
            log_err("error opening record file");
            exit(1);
        }
        fwrite(record_buf, sizeof(char), (record_buf_ptr - record_buf), fp);
        fclose(fp);
        log_err("dumped %ld records", nrecords);
    }
}

/*******************************************************/
#endif

item *assoc_find(const char *key, const size_t nkey, const uint32_t hv) {
    item *it;
    unsigned int oldbucket;
    uint32_t idx;
    void *it_start, *it_end, *it_key;

#ifdef RECORD_PAGE_ACCESS
    /* recording code */
    char buf[record_len+1];
    char keyprefix[33];
    int i;
    for(i = 0; isdigit(key[i]); i++) keyprefix[i] = key[i];
    keyprefix[i] = '\0';
#endif

    if (expanding &&
        (oldbucket = (hv & hashmask(hashpower - 1))) >= expand_bucket)
    {
        it = old_hashtable[oldbucket];
    } else {
        idx = hv & hashmask(hashpower);
#ifdef RECORD_PAGE_ACCESS
        // snprintf(buf, record_len, "%s,%ld", keyprefix, 
        //     (unsigned long) (&primary_hashtable[idx]) & ~(4096 - 1));
        // record(buf);
#endif
        hint_read_fault(&primary_hashtable[idx]);
        it = primary_hashtable[idx];
    }

    item *ret = NULL;
    int depth = 0;
    while (it) {
#ifdef RECORD_PAGE_ACCESS
        snprintf(buf, record_len, "%s,%ld", keyprefix, 
            (unsigned long) (&it->nkey) & ~(4096 - 1));
        record(buf);
#endif

/* set low priority for item faults */
#ifdef SET_PRIORITY
#define hint_item_fault(addr) hint_read_fault_prio(addr, 1)
#else
#define hint_item_fault(addr) hint_read_fault(addr)
#endif

        hint_item_fault(&it->nkey);
        if (nkey == it->nkey) {
            /* making sure we have the entire item even if it spans two pages */
            it_start = it;
            it_key = &it->nkey;
            it_end = ITEM_data(it) + it->nbytes - 4;
            #define PG_OFST(addr) (((unsigned long) addr) & 0xFFF)
            if (PG_OFST(it_start) > PG_OFST(it_key)) hint_item_fault(it_start);
            if (PG_OFST(it_end) < PG_OFST(it_key))   hint_item_fault(it_end);
            // hint_item_fault(ITEM_data(it) + it->nbytes - 4);
            if (memcmp(key, ITEM_key(it), nkey) == 0) {
                ret = it;
                break;
            }
        }
        it = it->h_next;
        ++depth;
    }
    MEMCACHED_ASSOC_FIND(key, nkey, depth);
    return ret;
}

/* returns the address of the item pointer before the key.  if *item == 0,
   the item wasn't found */

static item** _hashitem_before (const char *key, const size_t nkey, const uint32_t hv) {
    item **pos;
    unsigned int oldbucket;

    if (expanding &&
        (oldbucket = (hv & hashmask(hashpower - 1))) >= expand_bucket)
    {
        pos = &old_hashtable[oldbucket];
    } else {
        pos = &primary_hashtable[hv & hashmask(hashpower)];
    }

    while (*pos && ((nkey != (*pos)->nkey) || memcmp(key, ITEM_key(*pos), nkey))) {
        pos = &(*pos)->h_next;
    }
    return pos;
}

/* grows the hashtable to the next power of 2. */
static void assoc_expand(void) {
    old_hashtable = primary_hashtable;

    primary_hashtable = calloc(hashsize(hashpower + 1), sizeof(void *));
    if (primary_hashtable) {
        if (settings.verbose > 1)
            fprintf(stderr, "Hash table expansion starting\n");
        hashpower++;
        expanding = true;
        expand_bucket = 0;
        STATS_LOCK();
        stats_state.hash_power_level = hashpower;
        stats_state.hash_bytes += hashsize(hashpower) * sizeof(void *);
        stats_state.hash_is_expanding = true;
        STATS_UNLOCK();
    } else {
        primary_hashtable = old_hashtable;
        /* Bad news, but we can keep running. */
    }
}

void assoc_start_expand(uint64_t curr_items) {
    if (started_expanding)
        return;

    if (curr_items > (hashsize(hashpower) * 3) / 2 &&
          hashpower < HASHPOWER_MAX) {
        started_expanding = true;
        condvar_signal(&maintenance_cond);
    }
}

/* Note: this isn't an assoc_update.  The key must not already exist to call this */
int assoc_insert(item *it, const uint32_t hv) {
    unsigned int oldbucket;

//    assert(assoc_find(ITEM_key(it), it->nkey) == 0);  /* shouldn't have duplicately named things defined */

    if (expanding &&
        (oldbucket = (hv & hashmask(hashpower - 1))) >= expand_bucket)
    {
        it->h_next = old_hashtable[oldbucket];
        old_hashtable[oldbucket] = it;
    } else {
        it->h_next = primary_hashtable[hv & hashmask(hashpower)];
        primary_hashtable[hv & hashmask(hashpower)] = it;
    }

    MEMCACHED_ASSOC_INSERT(ITEM_key(it), it->nkey);
    return 1;
}

void assoc_delete(const char *key, const size_t nkey, const uint32_t hv) {
    item **before = _hashitem_before(key, nkey, hv);

    if (*before) {
        item *nxt;
        /* The DTrace probe cannot be triggered as the last instruction
         * due to possible tail-optimization by the compiler
         */
        MEMCACHED_ASSOC_DELETE(key, nkey);
        nxt = (*before)->h_next;
        (*before)->h_next = 0;   /* probably pointless, but whatever. */
        *before = nxt;
        return;
    }
    /* Note:  we never actually get here.  the callers don't delete things
       they can't find. */
    assert(*before != 0);
}


static waitgroup_t assoc_maintenance_thread_wg;
static volatile int do_run_maintenance_thread = 1;

#define DEFAULT_HASH_BULK_MOVE 1
int hash_bulk_move = DEFAULT_HASH_BULK_MOVE;

static void assoc_maintenance_thread(void *arg) {
    mutex_lock(&maintenance_lock);
    while (do_run_maintenance_thread) {
        int ii = 0;

        /* There is only one expansion thread, so no need to global lock. */
        for (ii = 0; ii < hash_bulk_move && expanding; ++ii) {
            item *it, *next;
            unsigned int bucket;
            void *item_lock = NULL;

            /* bucket = hv & hashmask(hashpower) =>the bucket of hash table
             * is the lowest N bits of the hv, and the bucket of item_locks is
             *  also the lowest M bits of hv, and N is greater than M.
             *  So we can process expanding with only one item_lock. cool! */
            if ((item_lock = item_trylock(expand_bucket))) {
                    for (it = old_hashtable[expand_bucket]; NULL != it; it = next) {
                        next = it->h_next;
                        bucket = hash(ITEM_key(it), it->nkey) & hashmask(hashpower);
                        it->h_next = primary_hashtable[bucket];
                        primary_hashtable[bucket] = it;
                    }

                    old_hashtable[expand_bucket] = NULL;

                    expand_bucket++;
                    if (expand_bucket == hashsize(hashpower - 1)) {
                        expanding = false;
                        free(old_hashtable);
                        STATS_LOCK();
                        stats_state.hash_bytes -= hashsize(hashpower - 1) * sizeof(void *);
                        stats_state.hash_is_expanding = false;
                        STATS_UNLOCK();
                        if (settings.verbose > 1)
                            fprintf(stderr, "Hash table expansion done\n");
                    }

            } else {
                timer_sleep(10*1000);
            }

            if (item_lock) {
                item_trylock_unlock(item_lock);
                item_lock = NULL;
            }
        }

        if (!expanding) {
            /* We are done expanding.. just wait for next invocation */
            started_expanding = false;
            condvar_wait(&maintenance_cond, &maintenance_lock);
            /* assoc_expand() swaps out the hash table entirely, so we need
             * all threads to not hold any references related to the hash
             * table while this happens.
             * This is instead of a more complex, possibly slower algorithm to
             * allow dynamic hash table expansion without causing significant
             * wait times.
             */
            pause_threads(PAUSE_ALL_THREADS);
            assoc_expand();
            pause_threads(RESUME_ALL_THREADS);
        }
    }
    waitgroup_done(&assoc_maintenance_thread_wg);
}


int start_assoc_maintenance_thread() {
    int ret;
    char *env = getenv("MEMCACHED_HASH_BULK_MOVE");
    if (env != NULL) {
        hash_bulk_move = atoi(env);
        if (hash_bulk_move == 0) {
            hash_bulk_move = DEFAULT_HASH_BULK_MOVE;
        }
    }
    waitgroup_init(&assoc_maintenance_thread_wg);
    waitgroup_add(&assoc_maintenance_thread_wg, 1);
    mutex_init(&maintenance_lock);
    if ((ret = thread_spawn(assoc_maintenance_thread, NULL)) != 0) {
        fprintf(stderr, "Can't create thread: %s\n", strerror(ret));
        waitgroup_done(&assoc_maintenance_thread_wg);
        return -1;
    }
    return 0;
}

void stop_assoc_maintenance_thread() {
    mutex_lock(&maintenance_lock);
    do_run_maintenance_thread = 0;
    condvar_signal(&maintenance_cond);
    mutex_unlock(&maintenance_lock);

    /* Wait for the maintenance thread to stop */
    waitgroup_wait(&assoc_maintenance_thread_wg);
}

