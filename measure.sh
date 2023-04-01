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
CLIENT_SSH=sc32

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
## Very small
# NKEYS=10000
# CORES=5
# START_MPPS=0.5
# END_MPPS=0.5
# SAMPLES=1
# EDEN_MAX=717
# FASTSWAP_MAX=950
# WARMUP=
# RUNTIME=1

## Small
NKEYS=10000000
CORES=5
SAMPLES=1
EDEN_MAX=9350   # (9258+1%EvTh)
FASTSWAP_MAX=9258
WARMUP=1
RUNTIME=30
# SAFEMODE=1        ##UNDO

## Large
# NKEYS=30000000
# CORES=10
# START_MPPS=0.5        # TODO
# END_MPPS=2            # TODO
# SAMPLES=5
# EDEN_MAX=21522
# FASTSWAP_MAX=
# WARMUP=1
# RUNTIME=30

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
    # for Small dataset
    local memp=$1
    if [ $memp -le 20 ]; then       START_MPPS=0.5;     END_MPPS=2;
    elif [ $memp -le 40 ]; then     START_MPPS=1;       END_MPPS=2.5;
    elif [ $memp -le 60 ]; then     START_MPPS=1;       END_MPPS=3.5;
    elif [ $memp -le 80 ]; then     START_MPPS=1;       END_MPPS=4;
    else                            START_MPPS=2;       END_MPPS=5;
    fi
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
    bash run.sh ${OPTS} ${WFLAG} --force --buildonly ${NOPIE}
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
    local evprio=$9
    local evprtype=${10}
    local lruthr=${11}

    # build 
    CFLAGS=
    OPTS=
    configure_for_fault_kind "$kind"
    configure_for_backend "$bkend"
    configure_for_evict_policy "$evp"
    if [[ $evictbs ]];  then  OPTS="$OPTS --batchevict=${evictbs}"; fi
    if [[ $evgens ]];   then  OPTS="$OPTS --evictgens=${evgens}"; fi
    if [[ $evprio ]];   then  OPTS="$OPTS --prio"; fi
    if [[ $evprtype ]]; then  OPTS="$OPTS --priotype=${evprtype}"; fi
    if [[ $lruthr ]];   then  OPTS="$OPTS --lrubumpthr=${lruthr}";  fi
    if [[ $nodirty ]];  then  OPTS="$OPTS --nodirty"; fi
    if [[ $WARMUP ]];   then  OPTS="$OPTS --warmup"; fi
    if [[ $SAFEMODE ]]; then  OPTS="$OPTS --safemode"; fi
    # OPTS="$OPTS --sampleepochs"
    # OPTS="$OPTS --gdb"
    # OPTS="$OPTS --pfsamples"
    rebuild_with_current_config
    echo $OPTS

    # sync times on servers
    echo "Syncing clocks on host and client"
    sudo systemctl stop ntp; sudo ntpdate -s time.nist.gov; sudo systemctl start ntp
    ssh $CLIENT_SSH "sudo systemctl stop ntp; sudo ntpdate -s time.nist.gov; sudo systemctl start ntp"
    
    # run
    configure_max_local_mem "$kind" "$cores"
    # for memp in `seq 10 10 100`; do
    for memp in 10; do
        check_for_stop

        # determine load
        configure_max_load "$memp"

        # determine local mem
        lmemopt=
        if [[ $MAXRSS ]]; then 
            lmem_mb=$(percentof "$MAXRSS" "$memp" | ftoi)
            lmem=$((lmem_mb*1024*1024))
            lmemopt="-lm=${lmem} -lmp=${memp}"
        fi
        
        # run
        echo "Running ${cores} cores, ${lmem} mem, zipfs ${zs}, mpps ${START_MPPS} to ${END_MPPS}"
        bash run.sh ${OPTS} ${FFLAG} -c=${cores} ${lmemopt} ${WFLAG} -d="""${desc}""" \
            -zs=${zparams} -lds=${START_MPPS} -lde=${END_MPPS} -k=${NKEYS} -sm=${SAMPLES} -rd=${RUNTIME}
    done
}

# eden runs
ebs=        # set eviction batch size
evp=        # set eviction policy
evg=4       # set eviction gens
prio=1      # enable eviction priority
prtype=     # set eviction priority type
lruthr=     # set eviction lru bump threshold
nod=1       # set nodirty
for zs in 1; do
    for c in $CORES; do
        for nod in 1; do 
            desc="newhints"
            # run_vary_lmem "uthr"    "local" "$c" "$zs" "$ebs" "$evp" "$evg" "$nod" "$prio" "$prtype" "$lruthr"
            # run_vary_lmem "eden-nh" "local" "$c" "$zs" "$ebs" "$evp" "$evg" "$nod" "$prio" "$prtype" "$lruthr"
            # run_vary_lmem "eden-bh" "local" "$c" "$zs" "$ebs" "$evp" "$evg" "$nod" "$prio" "$prtype" "$lruthr"
            # run_vary_lmem "eden"    "local" "$c" "$zs" "$ebs" "NONE" "$evg" "$nod" "$prio" "$prtype" "$lruthr"
            # run_vary_lmem "eden"    "local" "$c" "$zs" "$ebs" "NONE" "$evg" "$nod" "$prio" "$prtype" "$lruthr"
            # run_vary_lmem "eden-bh" "local" "$c" "$zs" "8"    "SC"   "$evg" "$nod" "$prio" "$prtype" "$lruthr"
            # run_vary_lmem "eden"    "local" "$c" "$zs" "8"    "SC"   "$evg" "$nod" "$prio" "$prtype" "$lruthr"

            # best runs
            # run_vary_lmem "eden-bh" "rdma"  "$c" "$zs" "32"   "SC"   "$evg" "$nod" "$prio" "$prtype" "$lruthr"
            # run_vary_lmem "eden"    "rdma"  "$c" "$zs" "32"   "SC"   "$evg" "$nod" "$prio" "$prtype" "$lruthr"
            # run_vary_lmem "eden-bh" "rdma"  "$c" "$zs" "32"   "NONE" "$evg" "$nod" "$prio" "$prtype" "$lruthr"
            # run_vary_lmem "eden"    "rdma"  "$c" "$zs" "32"   "NONE" "$evg" "$nod" "$prio" "$prtype" "$lruthr"

            ## prio testing
            # for rmem in "eden"; do
            # for rmem in "eden-bh" "eden"; do
            # run_vary_lmem "$rmem"   "rdma"  "$c" "$zs" "32"   "NONE" "$evg" "$nod" ""      "$prtype"     "$lruthr"
            # run_vary_lmem "$rmem"   "rdma"  "$c" "$zs" "32"   "SC"   "$evg" "$nod" ""      "$prtype"     "$lruthr"
            # run_vary_lmem "$rmem"   "rdma"  "$c" "$zs" "32"   "NONE" "$evg" "$nod" "$prio" "$prtype"     "$lruthr"
            # run_vary_lmem "$rmem"   "rdma"  "$c" "$zs" "32"   "SC"   "$evg" "$nod" "$prio" "$prtype"     "$lruthr"
            # run_vary_lmem "$rmem"   "rdma"  "$c" "$zs" "32"   "NONE" "$evg" "$nod" "$prio" "LINEAR"      "$lruthr"
            # run_vary_lmem "$rmem"   "rdma"  "$c" "$zs" "32"   "SC"   "$evg" "$nod" "$prio" "LINEAR"      "$lruthr"
            # run_vary_lmem "$rmem"   "rdma"  "$c" "$zs" "32"   "NONE" "$evg" "$nod" "$prio" "EXPONENTIAL" "$lruthr"
            # run_vary_lmem "$rmem"   "rdma"  "$c" "$zs" "32"   "SC"   "$evg" "$nod" "$prio" "EXPONENTIAL" "$lruthr"
            # run_vary_lmem "$rmem"   "rdma"  "$c" "$zs" "32"   "LRU"  "$evg" "$nod" "$prio" "$prtype"     "0.8"
            # done

            ## LRU threshold
            # for lruthr in 0.2 0.4 0.6 0.8; do
            # run_vary_lmem "eden-bh" "rdma"  "$c" "$zs" "32"   "LRU" "$evg" "$nod" "" "$prtype" "$lruthr"
            # run_vary_lmem "eden"    "rdma"  "$c" "$zs" "32"   "LRU" "$evg" "$nod" "$prio" "$prtype" "$lruthr"
            # done

            ## bug debug
            # run_vary_lmem "eden-bh" "local"  "$c" "$zs" "32"    "SC"   "$evg" "$nod" "$prio" "$prtype"
            # run_vary_lmem "eden"    "local"  "$c" "$zs" "32"    "SC"   "$evg" "$nod" "$prio" "$prtype"
        done
    done
done

# cleanup
rm -f ${TMP_PFX}*
rm -f __running__