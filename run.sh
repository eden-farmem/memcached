#!/bin/bash

#
# Run Memcached
#

# Paths
SCRIPT_PATH=`realpath $0`
SCRIPT_DIR=`dirname ${SCRIPT_PATH}`
DATADIR="${SCRIPT_DIR}/data/"
ROOT_DIR="${SCRIPT_DIR}/../../"
SHENANGO_DIR="${ROOT_DIR}/scheduler"
KONA_DIR="${ROOT_DIR}/backends/kona"
KONA_BIN="${KONA_DIR}/pbmem"

# SSH
KONA_RCNTRL_SSH="sc07"
KONA_RCNTRL_IP="192.168.0.7"
KONA_RCNTRL_PORT="9202"
KONA_MEMSERVER_SSH=$KONA_RCNTRL_SSH
KONA_MEMSERVER_IP=$KONA_RCNTRL_IP
KONA_MEMSERVER_PORT="9200"
CLIENT_SSH="sc32"

# Settings
RUNTIME=20
NCORES=1
LMEM=1600
PAGE_FAULTS=
CONNS=100
MPPS=2
NKEYS=10M
NOHT_FLAG="--noht"
ZIPFS=0.1

EXPNAME=run-$(date '+%m-%d-%H-%M-%S')  #unique id
TMP_FILE_PFX="tmp_mcached_"
README=none

# Kona
KONA_CFG="PBMEM_CONFIG=CONFIG_WP"
# KFLAGS="-DNO_ZEROPAGE_OPT"
# KFLAGS="-DPRINT_FAULT_ADDRS"
# KFLAGS="-DREGISTER_MADVISE_NOTIF"
# KFLAGS="-DBATCH_EVICTION"
# KFLAGS="-DSAFE_MODE"
# KFLAGS="-DDNE_QUEUE_SIZE=256"
# KFLAGS="-DENABLE_TRACE"
# KFLAGS="-DSAMPLE_KERNEL_FAULTS"
EVICT_THR=.99
EVICT_DONE_THR=.99
EVICT_BATCH_SIZE=1

# save settings
CFGSTORE=
save_cfg() {
    name=$1
    value=$2
    CFGSTORE="${CFGSTORE}$name:$value\n"
}

usage="\n
-n, --name \t optional exp name (becomes folder name)\n
-d, --readme \t optional exp description\n
-f, --force \t force recompile everything\n
-k, --kona \t run with kona backend\n
-kc,--kconfig \t kona build configuration (CONFIG_NO_DIRTY_TRACK/CONFIG_WP)\n
-ko,--kopts \t C flags passed to gcc when compiling kona\n
-fl,--cflags \t C flags passed to gcc when compiling the app/test\n
-pf,--pgfaults \t build shenango with page faults feature. allowed values: SYNC, ASYNC\n
-c, --cores \t number of CPU cores (defaults to 1)\n
-zs, --zipfs \t S param of zipf workload\n
-lm, --localmem \t local memory with kona (in bytes)\n
-w, --warmup \t run warmup for a few seconds before taking measurement\n
-o, --out \t output file for any results\n
-s, --safemode \t build kona with safe mode on\n
-c, --clean \t run only the cleanup part\n
-g, --gdb \t run with a gdb server (on port :1234) to attach to\n
-d, --debug \t\t build debug and run with debug client load\n
-np, --nopie \t\t build without PIE/address randomization\n
-bo, --buildonly \t just recompile everything; do not run\n
-h, --help \t this usage information message\n"

# Parse command line arguments
for i in "$@"
do
case $i in
    -n=*|--name=*)
    EXPNAME="${i#*=}"
    ;;

    -d=*|--readme=*)
    README="${i#*=}"
    ;;

    -fl=*|--cflags=*)
    CFLAGS="$CFLAGS ${i#*=}"
    ;;

    -k|--kona)
    WITH_KONA=1
    BACKEND="kona"
    CFLAGS="$CFLAGS -DWITH_KONA"
    ;;

    -kc=*|--kconfig=*)
    KONA_CFG="PBMEM_CONFIG=${i#*=}"
    ;;

    -ko=*|--kopts=*)
    KFLAGS="$KFLAGS ${i#*=}"
    ;;
        
    -pf=*|--pgfaults=*)
    PAGE_FAULTS="${i#*=}"
    BACKEND="kona"
    WITH_KONA=1
    CFLAGS="$CFLAGS -DWITH_KONA -DANNOTATE_FAULTS"
    ;;

    -f|--force)
    FORCE=1
    ;;
    
    -c|--clean)
    CLEANUP=1
    ;;

    -c=*|--cores=*)
    NCORES=${i#*=}
    ;;

    -zs=*|--zipfs=*)
    ZIPFS=${i#*=}
    ;;

    -lm=*|--localmem=*)
    LMEM=${i#*=}
    ;;

    -w|--warmup)
    WARMUP=yes
    WMFLAG="--warmup"
    ;;

    -o=*|--out=*)
    OUTFILE=${i#*=}
    ;;

    -s|--safemode)
    kona_cflags="$kona_cflags -DSAFE_MODE"
    ;;

    -g|--gdb)
    GDB=1
    DEBUG="DEBUG=1"
    CFLAGS="$CFLAGS -DDEBUG -g -ggdb"
    GDBFLAG="GDB=1"
    GDBFLAG2="--enable-gdb"
    ;;

    -np|--nopie)
    CFLAGS="$CFLAGS -g"                 #for symbols
    CFLAGS="$CFLAGS -no-pie -fno-pie"   #no PIE
    echo 0 | sudo tee /proc/sys/kernel/randomize_va_space #no ASLR
    KFLAGS="$KFLAGS -DSAMPLE_KERNEL_FAULTS"  #turn on logging in kona
    ;;

    -bo|--buildonly)
    BUILD_ONLY=1
    ;;

    -d|--debug) # debug config
    # DEBUG="DEBUG=1"
    # DEBUG_FLAG="--debug"
    # CFLAGS="$CFLAGS -DDEBUG"
    CONNS=5
    MPPS=1e-2
    LMEM=500000     # 500 KB
    NKEYS=10K
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

# Initial CPU allocation
# NUMA node0 CPU(s):   0-13,28-41
# NUMA node1 CPU(s):   14-27,42-55
# RNIC NUMA node = 1
NUMA_NODE=1
KONA_POLLER_CORE=53
KONA_EVICTION_CORE=54
KONA_FAULT_HANDLER_CORE=55
KONA_ACCOUNTING_CORE=52
SHENANGO_STATS_CORE=51
SHENANGO_EXCLUDE=${KONA_POLLER_CORE},${KONA_EVICTION_CORE},\
${KONA_FAULT_HANDLER_CORE},${KONA_ACCOUNTING_CORE},${SHENANGO_STATS_CORE}
NIC_PCI_SLOT="0000:d8:00.1"

kill_remnants() {
    sudo pkill iokerneld || true
    ssh ${KONA_RCNTRL_SSH} "pkill rcntrl" || true
    ssh ${KONA_MEMSERVER_SSH} "pkill memserver" || true
    ssh ${CLIENT_SSH} "sudo pkill iokerneld" || true
}
cleanup() {
    rm -f ${TMP_FILE_PFX}*
    kill_remnants
}
cleanup     #start clean
if [[ $CLEANUP ]]; then
    exit 0
fi

echo ${SCRIPT_DIR}

# build kona
if [[ $FORCE ]] && [[ $WITH_KONA ]]; then 
    pushd ${KONA_BIN}
    # make je_clean
    make je_jemalloc
    make clean
    OPTS=
    OPTS="$OPTS POLLER_CORE=$KONA_POLLER_CORE"
    OPTS="$OPTS FAULT_HANDLER_CORE=$KONA_FAULT_HANDLER_CORE"
    OPTS="$OPTS EVICTION_CORE=$KONA_EVICTION_CORE"
    OPTS="$OPTS ACCOUNTING_CORE=${KONA_ACCOUNTING_CORE}"
    KFLAGS="-DSERVE_APP_FAULTS $KFLAGS"
    make all -j $KONA_CFG $OPTS PROVIDED_CFLAGS="""$KFLAGS""" ${DEBUG}
    sudo sysctl -w vm.unprivileged_userfaultfd=1   
    echo 0 | sudo tee /proc/sys/kernel/numa_balancing   # to avoid numa hint faults 
    popd
fi

# rebuild shenango
if [[ $FORCE ]]; then 
    pushd ${SHENANGO_DIR}
    make clean    
    if [[ $DPDK ]]; then    ./dpdk.sh;  fi
    if [[ $WITH_KONA ]]; then KONA_OPT="WITH_KONA=1";    fi
    if [[ $PAGE_FAULTS ]]; then PGFAULT_OPT="PAGE_FAULTS=$PAGE_FAULTS"; fi
    STATS_CORE_OPT="STATS_CORE=${SHENANGO_STATS_CORE}"    # for runtime stats
    make all-but-tests -j ${DEBUG} ${KONA_OPT} ${PGFAULT_OPT}       \
        NUMA_NODE=${NUMA_NODE} EXCLUDE_CORES=${SHENANGO_EXCLUDE}    \
        ${STATS_CORE_OPT}
    popd
    # TODO: Also build synthetic app
fi 

# rebuild memcached
if [[ $FORCE ]]; then
    ./autogen.sh 
    if [[ $WITH_KONA ]]; then KONA_OPT="--with-kona=${KONA_DIR}"; fi
    ./configure --with-shenango=${SHENANGO_DIR} ${KONA_OPT} ${GDBFLAG2}
    make clean
    make -j
fi

if [[ $BUILD_ONLY ]]; then 
    exit 0
fi

# initialize run
expdir=$EXPNAME
mkdir -p $expdir

pushd $expdir
echo "running ${EXPNAME}"
save_cfg "cores"    $NCORES
save_cfg "keys"     $NKEYS
save_cfg "zipfs"    $ZIPFS
save_cfg "warmup"   $WARMUP
save_cfg "backend"  $BACKEND
save_cfg "localmem" $LMEM
save_cfg "pgfaults" $PAGE_FAULTS
save_cfg "desc"     $README
echo -e "$CFGSTORE" > settings
popd

set +e 

# NKEYS is not automatically configurable
echo "Make sure the client is configured with ${NKEYS} keys"

# sync times on servers
echo "Syncing clocks"
ssh $KONA_RCNTRL_SSH "sudo systemctl stop ntp; sudo ntpd -gq; sudo systemctl start ntp;"
ssh $CLIENT_SSH "sudo systemctl stop ntp; sudo ntpd -gq; sudo systemctl start ntp;"

# run
KOPTS="--nokona"
if [[ $WITH_KONA ]]; then 
    KOPTS="--konamem ${LMEM}"
    KOPTS="$KOPTS --konaet ${EVICT_THR} --konaedt ${EVICT_DONE_THR} --konaebs ${EVICT_BATCH_SIZE}"
fi
# STOPAT="--stopat 4";    # for debugging
ZFLAG="--zipfs ${ZIPFS}"
python ${SCRIPT_DIR}/scripts/experiment.py --name ${EXPNAME}    \
    -p udp -nc $CONNS --scores ${NCORES} ${KOPTS} ${NOHT_FLAG}  \
    --time $RUNTIME --start $MPPS --finish $MPPS  ${WMFLAG}     \
    ${ZFLAG} ${STOPAT} ${GDBFLAG} -d "$README"
echo "return code: $?"

# cleanup
cleanup