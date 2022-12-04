#!/bin/bash
# set -e

#
# Run Memcached in different settings
# 

usage="\n
-w, --warmup \t run warmup for a few seconds before taking measurement\n
-d, --debug \t\t build debug\n
-h, --help \t\t this usage information message\n"

#Defaults
SCRIPT_DIR=`dirname "$0"`
ROOTDIR=${SCRIPT_DIR}/../..
TMP_PFX=tmp_mcached_
WARMUP=1
WFLAG="--warmup"

source ${ROOTDIR}/scripts/utils.sh

# parse cli
for i in "$@"
do
case $i in
    -f|--force)
    FORCE=1
    FFLAG="--force"
    ;;

    -d|--debug)
    CFLAGS="$CFLAGS -DDEBUG"
    ;;
    
    -w|--warmup)
    WARMUP=1
    WFLAG="--warmup"
    ;;

    -h | --help)
    echo -e $usage
    exit
    ;;

    *)                      # unknown option
    echo "Unkown Option: $i"
    echo -e $usage
    exit
    ;;
esac
done

## Configs
# Small
# NKEYS=10000000
# CORES=5
# MPPS=2
# EDEN_MAX=7174
# FASTSWAP_MAX=8000

# Large
NKEYS=30000000
CORES=10
MPPS=5
EDEN_MAX=21522
FASTSWAP_MAX=

# create a stop button
touch __running__
check_for_stop() {
    # stop if the fd is removed
    if [ ! -f __running__ ]; then
        echo "stop requested"   
        exit 0
    fi
}

configure_for_fault_kind() {
    local kind=$1
    case $kind in
    "uthr")             OPTS="$OPTS";;
    "eden-nh")          OPTS="$OPTS --eden";;
    "eden-bh")          OPTS="$OPTS --eden --bhints";;
    "eden")             OPTS="$OPTS --eden --hints";;
    "fswap")            OPTS="$OPTS --fastswap";;
    *)                  echo "Unknown fault kind"; exit;;
    esac
}

configure_for_backend() {
    local bkend=$1
    case $bkend in
    "")                 ;;
    "local")            OPTS="$OPTS --bkend=local";;
    "rdma")             OPTS="$OPTS --bkend=rdma";;
    *)                  echo "Unknown backend"; exit;;
    esac
}

configure_max_load() {
    local kind=$1
    local cores=$2
    local lmem=$3
    MPPS=
    case $kind in
    "uthr")             MPPS=$((2+cores));;
    "eden-nh")          MPPS=2;;
    "eden-bh")          MPPS=2;;
    "eden")             MPPS=2;;
    "fswap")            MPPS=2;;
    *)                  echo "Unknown fault kind"; exit;;
    esac
}

configure_max_local_mem() {
    local kind=$1
    local cores=$2
    MAXRSS=
    case $kind in
    "uthr")             MAXRSS=;;
    "eden-nh")          MAXRSS=${EDEN_MAX};;
    "eden-bh")          MAXRSS=${EDEN_MAX};;
    "eden")             MAXRSS=${EDEN_MAX};;
    "fswap")            MAXRSS=${FASTSWAP_MAX};;
    *)                  echo "Unknown fault kind"; exit;;
    esac
}

configure_for_evict_policy() {
    local evp=$1
    case $evp in
    "")                 ;;
    "NONE")             ;;
    "LRU")              OPTS="$OPTS --evictpolicy=LRU";;
    "SC")               OPTS="$OPTS --evictpolicy=SC";;
    *)                  echo "Unknown evict policy"; exit;;
    esac
}

rebuild_with_current_config() {
    bash run.sh ${OPTS} -fl="""$CFLAGS""" ${WFLAG} --force --buildonly ${NOPIE}
}

run_vary_lmem() {
    local kind=$1
    local bkend=$2
    local cores=$3
    local zparams=$4
    local evictbs=$5
    local evp=$6
    local evgens=$7
    local nodirty=$8

    # build 
    CFLAGS=
    OPTS=
    configure_for_fault_kind "$kind"
    configure_for_backend "$bkend"
    configure_for_evict_policy "$evp"
    if [[ $evictbs ]];          then  OPTS="$OPTS --batchevict=${evictbs}"; fi
    if [[ $evgens ]];           then  OPTS="$OPTS --evictgens=${evgens}"; fi
    if [[ $nodirty ]];          then  OPTS="$OPTS --nodirty"; fi
    # OPTS="$OPTS --sampleepochs"
    # OPTS="$OPTS --safemode"
    rebuild_with_current_config
    echo $OPTS
    
    # run
    configure_max_local_mem "$kind" "$cores"
    # for memp in `seq 20 10 100`; do
    for memp in 50; do
        check_for_stop

        # determine local mem
        lmemopt=
        if [[ $MAXRSS ]]; then 
            lmem_mb=$(percentof "$MAXRSS" "$memp" | ftoi)
            lmem=$((lmem_mb*1024*1024))
            lmemopt="-lm=${lmem} -lmp=${memp}"
        fi

        #determine mpps
        configure_max_load "$kind" "$cores" "$memp"
        
        # run
        echo "Running ${cores} cores, ${mem} mem, zipfs ${zs}, mpps ${mpps}"
        bash run.sh ${OPTS} ${FFLAG} -c=${cores} -lm=${lmem} -lmp=${memp} ${WFLAG}   \
            -d="""${desc}""" -fl="""${CFLAGS}""" -zs=${zparams} -ld=${MPPS} -k=${NKEYS}
    done
}

# eden runs
ebs=        # set eviction batch size
evp=        # set eviction policy
evg=4       # set eviction gens
nod=        # set nodirty
for zs in 1; do
    for c in $CORES; do
        desc="hints"
        # run_vary_lmem "uthr"    "local" "$c" "$zs" "$ebs" "$evp" "$evg" "$nod"
        # run_vary_lmem "eden-nh" "local" "$c" "$zs" "$ebs" "$evp" "$evg" "$nod"
        # run_vary_lmem "eden"    "local" "$c" "$zs" "$ebs" "NONE" "$evg" "$nod"
        # run_vary_lmem "eden"    "local" "$c" "$zs" "$ebs" "NONE" "$evg" "$nod"
        # run_vary_lmem "eden"    "local" "$c" "$zs" "$ebs" "SC"   "$evg" "$nod"
        # run_vary_lmem "eden"    "local" "$c" "$zs" "$ebs" "LRU"  "$evg" "$nod"
        # run_vary_lmem "eden-nh" "rdma"  "$c" "$zs" "$ebs" "$evp" "$evg" "$nod"
        # run_vary_lmem "eden"    "rdma"  "$c" "$zs" "$ebs" "NONE" "$evg" "$nod"
        # run_vary_lmem "eden"    "rdma"  "$c" "$zs" "$ebs" "NONE" "$evg" "$nod"
        # run_vary_lmem "eden"    "rdma"  "$c" "$zs" "$ebs" "NONE" "$evg" "$nod"
        # run_vary_lmem "fswap"   "local" "$c" "$zs" "$ebs" "$evp" "$evg" "$nod"
        # run_vary_lmem "fswap"   "rdma"  "$c" "$zs" "$ebs" "$evp" "$evg" "$nod"
        run_vary_lmem "eden-bh" "rdma"  "$c" "$zs" "$ebs" "$evp" "$evg" "$nod"
        run_vary_lmem "eden-bh" "rdma"  "$c" "$zs" "8"    "$evp" "$evg" "$nod"
        run_vary_lmem "eden"    "rdma"  "$c" "$zs" "8"    "$evp" "$evg" "$nod"
        run_vary_lmem "eden"    "rdma"  "$c" "$zs" "8"    "SC"   "$evg" "$nod"
        run_vary_lmem "eden"    "rdma"  "$c" "$zs" "8"    "LRU"  "$evg" "$nod"
    done
done

# cleanup
rm -f ${TMP_PFX}*
rm -f __running__