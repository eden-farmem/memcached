#!/bin/bash

#
# Run Memcached
#

usage="\n
-n, --name \t optional exp name (becomes folder name)\n
-d, --readme \t optional exp description\n
-f, --force \t force recompile everything\n
-e, --eden \t run with Eden's remote memory\n
-h, --hints \t enable Eden's remote memory hints\n
-fs, --fastswap \t enable remote memory with fastswap\n
-fl,--cflags \t C flags passed to gcc when compiling the app/test\n
-c, --cores \t number of CPU cores (defaults to 1)\n
-zs, --zipfs \t S param of zipf workload\n
-lm, --localmem \t local memory (in bytes)\n
-lmp, --lmemper \t local memory percentage compared to max rss (only for logging)\n
-ld, --load \t offered load at client in million packets/sec (mpps)\n
-w, --warmup \t run warmup for a few seconds before taking measurement\n
-o, --out \t output file for any results\n
-s, --safemode \t build eden with safe mode on\n
-c, --clean \t run only the cleanup part\n
-d, --debug \t build debug\n
-g, --gdb \t run with a gdb server (on port :1234) to attach to\n
-np, --nopie \t\t build without PIE/address randomization\n
-bo, --buildonly \t just recompile everything; do not run\n
-h, --help \t this usage information message\n"

# Paths
APPNAME="memcached"
SCRIPT_PATH=`realpath $0`
SCRIPT_DIR=`dirname ${SCRIPT_PATH}`
DATADIR="${SCRIPT_DIR}/data/"
ROOT_DIR="${SCRIPT_DIR}/../../"
ROOT_SCRIPTS_DIR="${ROOT_DIR}/scripts/"
FASTSWAP_DIR="${ROOT_DIR}/fastswap"
BINFILE="${SCRIPT_DIR}/main.out"
SHENANGO_DIR="${ROOT_DIR}/eden"
EXPNAME=run-$(date '+%m-%d-%H-%M-%S')  #unique id
TMP_FILE_PFX="tmp_mcached_"
CFGFILE="shenango.config"
SHENANGO=1

# network topology
RCNTRL_SSH="sc07"
RCNTRL_IP="192.168.100.81"
RCNTRL_MAC="50:6b:4b:23:a8:24"
RCNTRL_PORT="9202"
MEMSERVER_SSH=$RCNTRL_SSH
MEMSERVER_IP=$RCNTRL_IP
MEMSERVER_PORT="9200"
# CLIENT_SSH="sc40"
# CLIENT_IP="192.168.100.116"
# CLIENT_MAC="50:6b:4b:23:a8:a5"
# CLIENT_NIC_PCI="0000:d8:00.1"
CLIENT_SSH="sc32"
CLIENT_IP="192.168.100.108"
CLIENT_MAC="50:6b:4b:23:a8:1c"
CLIENT_NIC_PCI="0000:d8:00.0"

CLIENT_NUMA_NODE=1
HOST_SSH="sc30"
HOST_IP="192.168.100.106"
HOST_MAC="50:6b:4b:23:a8:2c"
HOST_NIC_PCI="0000:d8:00.0"
HOST_NUMA_NODE=1

if [ "`hostname`" == "sc2-hs2-b1640" ];
then
    # fastswap
    HOST_SSH="sc40"
    HOST_IP="192.168.100.116"
    FSWAP_HOST_IP="192.168.0.40"    #FIXME
    HOST_NIC_PCI="0000:d8:00.1"
    RCNTRL_IP="192.168.0.7"
    MEMSERVER_IP=$RCNTRL_IP
fi

NO_HYPERTHREADING="-noht"
EDEN=
HINTS=
BACKEND=local
EVICT_THRESHOLD=100     # no handler eviction
EVICT_BATCH_SIZE=1
EXPECTED_PTI=off
SCHEDULER=pthreads
RMEM=none
RDAHEAD=no
EVICT_GENS=1

# settings
MCACHED_SERVER_IP="192.168.0.100"
MCACHED_SERVER_PORT="5130"
MCACHED_SERVER_MAC="02:e2:54:ef:94:7b"
SYNTHETIC_SERVER_IP="192.168.0.101"
SYNTHETIC_SERVER_PORT="5131"
SYNTHETIC_SERVER_MAC="02:74:bb:ac:4f:21"
RUNTIME=20
NCORES=1
LMEM=$((1024*1024*1024))
CONNS=100
MPPS=2
NKEYS=10000000
ZIPFS=0.1
START_MPPS=1

# save settings
CFGSTORE=
save_cfg() {
    name=$1
    value=$2
    CFGSTORE="${CFGSTORE}$name:$value\n"
}

# parse cli
for i in "$@"
do
case $i in
    -n=*|--name=*)
    EXPNAME="${i#*=}"
    ;;

    -d=*|--readme=*)
    README="${i#*=}"
    ;;

    -d|--debug) # debug config
    # DEBUG="DEBUG=1"
    # DEBUG_FLAG="--debug"
    # CFLAGS="$CFLAGS -DDEBUG"
    CONNS=5
    START_MPPS=1e-2
    MPPS=1e-2
    LMEM=500000     # 500 KB
    NKEYS=10K
    ;;

    -k=*|--nkeys=*)
    NKEYS="${i#*=}"
    ;;

    -fl=*|--cflags=*)
    CFLAGS="$CFLAGS ${i#*=}"
    ;;

    -e|--eden)
    EDEN=1
    SHENANGO=1
    ;;
    
    -h|--hints)
    EDEN=1
    HINTS=1
    SHENANGO=1
    ;;

    -bh|--bhints)
    EDEN=1
    HINTS=1
    BHINTS=1
    SHENANGO=1
    ;;

    -fs|--fastswap)
    FASTSWAP=1
    #SHENANGO=1
    ;;

    -be=*|--batchevict=*)
    EVICT_BATCH_SIZE="${i#*=}"
    SHEN_CFLAGS="$SHEN_CFLAGS -DVECTORED_MADVISE -DVECTORED_MPROTECT"
    ;;

    -ep=*|--evictpolicy=*)
    EVICT_POLICY=${i#*=}
    ;;

    -eg=*|--evictgens=*)
    EVICT_GENS=${i#*=}
    ;;

    -se|--sampleepochs)
    SHEN_CFLAGS="$SHEN_CFLAGS -DEPOCH_SAMPLER"
    ;;

    -b=*|--bkend=*)
    BACKEND=${i#*=}
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

    -lmp=*|--lmemper=*)
    LMEMPER=${i#*=}
    ;;

    -ld=*|--load=*)
    MPPS=${i#*=}
    ;;

    -nd|--nodirty)
    NO_DIRTY=1
    ;;

    -w|--warmup)
    WARMUP=yes
    WMFLAG="--warmup"
    ;;

    -o=*|--out=*)
    OUTFILE=${i#*=}
    ;;

    -sf|--safemode)
    SAFEMODE=1
    ;;

    -g|--gdb)
    GDB=1
    CFLAGS="$CFLAGS -g -ggdb"
    GDBFLAG="GDB=1"
    GDBFLAG2="--enable-gdb"
    ;;

    -bo|--buildonly)
    BUILD_ONLY=1
    ;;

    -h | --help)
    echo -e $usage
    exit
    ;;

    *)                      # unknown option
    echo "Unknown Option: $i"
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
BASECORE=14
RMEM_HANDLER_CORE=55
FASTSWAP_RECLAIM_CPU=55
SHENANGO_STATS_CORE=54
SHENANGO_EXCLUDE=${SHENANGO_STATS_CORE},${FASTSWAP_RECLAIM_CPU}

# helpers
start_sar() {
    int=$1
    outdir=$2
    cpustr=${3:-ALL}
    nohup sar -P ${cpustr} ${int} | ts %s > ${outdir}/cpu.sar   2>&1 &
    # nohup sar -r ${int}     | ts %s > ${outdir}/memory.sar  2>&1 &
    # nohup sar -b ${int}     | ts %s > ${outdir}/diskio.sar  2>&1 &
    # nohup sar -n DEV ${int} | ts %s > ${outdir}/network.sar 2>&1 &
    nohup sar -B ${int}     | ts %s > ${outdir}/pgfaults.sar 2>&1 &
}
stop_sar() {
    pkill sar || true
}
start_memory_stat() {
    rm -f memory-stat.out
    nohup bash ${ROOT_SCRIPTS_DIR}/memory-stat.sh ${APPNAME} 2>&1 &
}
stop_memory_stat() {
    local pid
    pid=$(pgrep -f "[m]emory-stat.sh" || true)
    if [[ $pid ]]; then  kill ${pid}; fi
}
start_vmstat() {
    rm -f vmstat.out
    nohup bash ${ROOT_SCRIPTS_DIR}/vmstat.sh ${APPNAME} > vmstat.out &
}
stop_vmstat() {
    local pid
    pid=$(pgrep -f "[v]mstat.sh" || true)
    if [[ $pid ]]; then  kill ${pid}; fi
}
start_fsstat() {
    rm -f fstat.out
    nohup sudo bash ${ROOT_SCRIPTS_DIR}/fswap-stat.sh ${APPNAME} > fstat.out &
}
stop_fsstat() {
    local pid
    pid=$(pgrep -f "[f]swap-stat.sh" || true)
    if [[ $pid ]]; then  sudo kill ${pid}; fi
}
kill_remnants() {
    sudo pkill iokerneld || true
    ssh ${RCNTRL_SSH} "pkill rcntrl; rm -f ~/scratch/rcntrl"                # eden memcontrol
    ssh ${MEMSERVER_SSH} "pkill memserver; rm -f ~/scratch/memserver"       # eden memserver
    # ssh ${MEMSERVER_SSH} "pkill rmserver; rm -f ~/scratch/rmserver"       # fastswap server
    ssh ${CLIENT_SSH} "sudo pkill iokerneld"   # shenango client iok
    ssh ${CLIENT_SSH} "sudo pkill synthetic"   # shenango synthetic client
    rm -f eden_rdma_server_error
}
cleanup() {
    rm -f ${TMP_FILE_PFX}*
    kill_remnants
    stop_memory_stat
    stop_vmstat
    stop_fsstat
    stop_sar
}
cleanup     #start clean
if [[ $CLEANUP ]]; then
    exit 0
fi

# check pti state
# PTI status
PTI=on
pti_msg=$(sudo dmesg | grep 'page tables isolation: enabled' || true)
if [ -z "$pti_msg" ]; then  PTI=off; fi
if [ "$EXPECTED_PTI" != "$PTI" ]; then
    echo "Warning! Page table isolation feature is not in expected state"
    echo "Expected: ${EXPECTED_PTI}, Found: ${PTI}"
fi

# eden flags
if [[ $EDEN ]]; then
    RMEM="eden-nh"
    CFLAGS="$CFLAGS -DEDEN -DREMOTE_MEMORY"

    # hints
    if [[ $HINTS ]]; then
        RMEM="eden"
        CFLAGS="$CFLAGS -DREMOTE_MEMORY_HINTS"
    fi

    if [[ $BHINTS ]]; then
        RMEM="eden-bh"
        SHEN_CFLAGS="$SHEN_CFLAGS -DBLOCKING_HINTS"
    fi

    # eviction policy
    if [[ $EVICT_POLICY ]]; then
        if [[ $EVICT_POLICY != "SC" ]] && [[ $EVICT_POLICY != "LRU" ]]; then
            echo "ERROR! invalid evict policy. Allowed values: SC, LRU"
            exit 1
        fi
        # we need to set c-flags for both app and shenango cflags 
        # because eviction-specific hints are defined in a header file 
        CFLAGS="$CFLAGS -D${EVICT_POLICY}_EVICTION"
        SHEN_CFLAGS="$SHEN_CFLAGS -D${EVICT_POLICY}_EVICTION"
    fi
fi

# Fastswap
if [[ $FASTSWAP ]]; then
    RMEM="fastswap"
    CFLAGS="$CFLAGS -DFASTSWAP"

    if [[ $EDEN ]] || [[ $RHINTS ]]; then
        echo "ERROR! Eden or hints can't be enabled with fastswap"
        exit 1
    fi

    if [[ $EVICT_POLICY ]]; then
        echo "ERROR! evict policy can't be set with fastswap"
        exit 1
    fi

    # setup fastswap
    if [[ $FORCE ]]; then
        bash ${FASTSWAP_DIR}/setup.sh           \
            --memserver-ssh=${MEMSERVER_SSH}    \
            --memserver-ip=${MEMSERVER_IP}      \
            --memserver-port=${MEMSERVER_PORT}  \
            --host-ip=${FSWAP_HOST_IP}          \
            --host-ssh=${HOST_SSH}              \
            --backend=${BACKEND}
    fi

    # setup cgroups
    pushd ${FASTSWAP_DIR}
    sudo mkdir -p /cgroup2
    sudo ./init_bench_cgroups.sh
    sudo mkdir -p /cgroup2/benchmarks/$APPNAME/
    popd
fi

# rebuild shenango
if [[ $FORCE ]] && [[ $SHENANGO ]]; then
    pushd ${SHENANGO_DIR} 
    if [[ $FORCE ]];        then    make clean;                         fi
    if [[ $EDEN ]];         then    OPTS="$OPTS REMOTE_MEMORY=1";       fi
    if [[ $HINTS ]];        then    OPTS="$OPTS REMOTE_MEMORY_HINTS=1"; fi
    if [[ $SAFEMODE ]];     then    OPTS="$OPTS SAFEMODE=1";            fi
    if [[ $GDB ]];          then    OPTS="$OPTS GDB=1";                 fi
    if ! [[ $NO_STATS ]];   then    OPTS="$OPTS STATS_CORE=${SHENANGO_STATS_CORE}"; fi
    OPTS="$OPTS NUMA_NODE=${NUMA_NODE} EXCLUDE_CORES=${SHENANGO_EXCLUDE}"
    make all -j ${DEBUG} ${OPTS} PROVIDED_CFLAGS="""$SHEN_CFLAGS"""
    popd
fi

# rebuild memcached
if [[ $FORCE ]]; then
    ./autogen.sh 
    if [[ $EDEN ]];     then EDEN_OPT="--enable-eden";      fi
    if [[ $HINTS ]];    then HINTS_OPT="--enable-hints";    fi
    if [[ $NO_DIRTY ]]; then NOD_OPT="--enable-nodirty";    fi
    if [ "$EVICT_POLICY" == "SC" ];     then EVP_OPT="--enable-sc";      fi
    if [ "$EVICT_POLICY" == "LRU" ];    then EVP_OPT="--enable-lru";     fi
    
    ./configure --with-shenango=${SHENANGO_DIR} ${EDEN_OPT} \
        ${EVP_OPT} ${HINTS_OPT} ${NOD_OPT} ${GDBFLAG2}
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
save_cfg "cores"        $NCORES
save_cfg "keys"         $NKEYS
save_cfg "zipfs"        $ZIPFS
save_cfg "warmup"       $WARMUP
save_cfg "rmem"         $RMEM
save_cfg "backend"      $BACKEND
save_cfg "offered"      $MPPS
save_cfg "localmem"     $LMEM
save_cfg "lmemper"      $LMEMPER
save_cfg "evictbatch"   $EVICT_BATCH_SIZE
save_cfg "evictpolicy"  $EVICT_POLICY
save_cfg "evictgens"    $EVICT_GENS
save_cfg "nodirty"      $NO_DIRTY
save_cfg "desc"         $README
echo -e "$CFGSTORE" > settings

# write shenango config
__RMEM_OPT=0
__HINTS_OPT=0
if [[ $EDEN ]]; then    __RMEM_OPT=1;   fi
if [[ $HINTS ]]; then   __HINTS_OPT=1;  fi
shenango_cfg="""
host_addr ${MCACHED_SERVER_IP}
host_netmask 255.255.255.0
host_gateway 192.168.0.1
runtime_kthreads ${NCORES}
runtime_guaranteed_kthreads ${NCORES}
runtime_spinning_kthreads ${NCORES}
host_mac ${MCACHED_SERVER_MAC}
disable_watchdog 1
static_arp ${HOST_IP} ${HOST_MAC}
static_arp ${CLIENT_IP} ${CLIENT_MAC}
static_arp ${SYNTHETIC_SERVER_IP} ${SYNTHETIC_SERVER_MAC}
remote_memory ${__RMEM_OPT}
rmem_hints ${__HINTS_OPT}
rmem_backend ${BACKEND}
rmem_local_memory ${LMEM}
rmem_evict_threshold ${EVICT_THRESHOLD}
rmem_evict_batch_size ${EVICT_BATCH_SIZE}
rmem_evict_ngens ${EVICT_GENS}"""
echo "$shenango_cfg" > $CFGFILE
popd

# run machine setup
sudo bash ${ROOT_SCRIPTS_DIR}/machine_config.sh

# set localmem for fastswap
if [[ $FASTSWAP ]]; then
    sudo mkdir -p /cgroup2/benchmarks/$APPNAME/
    LOCALMEM=${LOCALMEM:-max}
    sudo bash -c "echo ${LMEM} > /cgroup2/benchmarks/$APPNAME/memory.high"
fi

# NKEYS is not automatically configurable
echo "ACTION: make sure the client is configured with ${NKEYS} keys"

# sync times on servers
echo "Syncing clocks with sc30 (ntp root)"
ssh $HOST_SSH "sudo systemctl stop ntp; sudo ntpd -gq; sudo systemctl start ntp;"
ssh $CLIENT_SSH "sudo systemctl stop ntp; sudo ntpd -gq; sudo systemctl start ntp;"

# for retry in {1..3}; do
for retry in 1; do
    # prepare for run
    kill_remnants

    # prepare remote memory servers for the run
    if [[ $EDEN ]] && [ "$BACKEND" == "rdma" ]; then
        echo "starting rmem servers"
        # starting controller
        scp ${SHENANGO_DIR}/rcntrl ${RCNTRL_SSH}:~/scratch
        ssh ${RCNTRL_SSH} "nohup ~/scratch/rcntrl -s $RCNTRL_IP -p $RCNTRL_PORT" < /dev/null &
        sleep 2
        # starting mem server
        scp ${SHENANGO_DIR}/memserver ${MEMSERVER_SSH}:~/scratch
        ssh ${MEMSERVER_SSH} "nohup ~/scratch/memserver -s $MEMSERVER_IP -p $MEMSERVER_PORT -c $RCNTRL_IP -r $RCNTRL_PORT" < /dev/null &
        sleep 40
    fi

    # setup shenango runtime
    if [[ $SHENANGO ]]; then
        start_iokernel() {
            echo "starting iokerneld"
            sudo ${SHENANGO_DIR}/scripts/setup_machine.sh || true
            binary=${SHENANGO_DIR}/iokerneld${NO_HYPERTHREADING}
            sudo $binary $HOST_NIC_PCI 2>&1 | ts %s > ${expdir}/iokernel.log &
            echo "waiting on iokerneld"
            sleep 5    #for iokernel to be ready
        }
        start_iokernel
    fi

    # env
    pushd $expdir
    if [[ $EDEN ]] && [ "$BACKEND" == "rdma" ]; then
        env="RDMA_RACK_CNTRL_IP=$RCNTRL_IP"
        env="$env RDMA_RACK_CNTRL_PORT=$RCNTRL_PORT"
        wrapper="$wrapper $env"
    fi

    if [[ $SHENANGO ]]; then 
        # shenango takes care of scheduling but we still want 
        # to know what cores it runs to kick off sar
        # currently, iokernel takes the first core on the node 
        # and shenango provides the following cores to app
        CPUSTR="$((BASECORE+1))-$((BASECORE+NCORES))"
        start_sar 1 "." ${CPUSTR}
    else 
        # pin the app to required number of cores ourselves
        # use cores 14-27 for non-hyperthreaded setting
        if [ $NCORES -gt 14 ];   then echo "WARNING! hyperthreading enabled"; fi
        CPUSTR="$BASECORE-$((BASECORE+NCORES-1))"
        wrapper="$wrapper taskset -a -c ${CPUSTR}"
        start_sar 1 "." ${CPUSTR}
    fi 

    # run in gdb server if requested
    if [[ $GDB ]]; then
        if [ -z "$wrapper" ]; then
            wrapper="gdbserver :1234 "
        else
            wrapper="gdbserver --wrapper $wrapper -- :1234 "
        fi
    fi

    # start memory stats for fastswap
    if [[ $FASTSWAP ]]; then
        start_memory_stat
        start_vmstat
        start_fsstat
    fi

    # run memcached
    # # sudo RDMA_RACK_CNTRL_IP=192.168.0.7 RDMA_RACK_CNTRL_PORT=9202 MEMORY_LIMIT=1000000000 
    # # EVICTION_THRESHOLD=0.99 EVICTION_DONE_THRESHOLD=0.99 EVICTION_BATCH_SIZE=1  numactl -N 1 
    # # -m 1  /home/ayelam/rmem-scheduler/apps/memcached/memcached memcached.config -u ayelam -t 4 
    # # -U 5208 -p 5208 -c 32768 -m 32000 -b 32768 -P memcached_pid -r -o 
    # # hashpower=28,no_hashexpand,no_lru_crawler,no_lru_maintainer,idle_timeout=0 2>&1 | ts %s  > memcached.out
    wrapper="$wrapper numactl -N ${NUMA_NODE} -m ${NUMA_NODE}"
    lruopts="lru_crawler,lru_maintainer";
    if [[ $NO_DIRTY ]]; then lruopts="no_lru_crawler,no_lru_maintainer"; fi
    args="${CFGFILE} -u `whoami` -t ${NCORES} -U ${MCACHED_SERVER_PORT} -p ${MCACHED_SERVER_PORT}"
    args="${args} -c 32768 -m 48000 -b 32768 -P main_pid  -r -o hashpower=28,no_hashexpand,${lruopts},idle_timeout=0"
    echo sudo ${wrapper} ${SCRIPT_DIR}/memcached ${args}
    sudo ${wrapper} ${SCRIPT_DIR}/memcached ${args} 2>&1 | tee app.out &

    # wait for memcached to start
    tries=0
    while [ ! -f main_pid ] && [ $tries -lt 10 ]; do
        sleep 1
        tries=$((tries+1))
        echo "waiting for main_pid for $tries seconds"
    done
    pid=`cat main_pid`
    if [[ $pid ]]; then

        if [[ $FASTSWAP ]]; then
            #enforce localmem
            CGROUP_PROCS=/cgroup2/benchmarks/$APPNAME/cgroup.procs
            sudo bash -c "echo $pid > $CGROUP_PROCS"
            echo "added proc $(cat $CGROUP_PROCS) to cgroup"
        fi

        # run iokernel on the client
        CLIENT_SHENANGO_DIR=$(realpath ${SHENANGO_DIR})
        start_iokernel_client() {
            echo "starting iokerneld on client ${CLIENT_SSH}"
            echo "ACTION: make sure iokerneld is built on the ${CLIENT_SSH} at $CLIENT_SHENANGO_DIR"
            ssh ${CLIENT_SSH} "sudo ${CLIENT_SHENANGO_DIR}/scripts/setup_machine.sh || true"
            ssh ${CLIENT_SSH} "nohup sudo ${CLIENT_SHENANGO_DIR}/iokerneld ${CLIENT_NIC_PCI} 2>&1" < /dev/null &> client_iok.log &
            echo "waiting on client iokerneld"
            sleep 10    #for iokernel to be ready
        }
        start_iokernel_client 

        # run synthetic client
        echo "ACTION: make sure synthetic is built on the ${CLIENT_SSH} (use apps/synthetic/build.sh)"
        CLIENT_EXPDIR=~/scratch/${expdir}
        CLIENT_SYNTHETIC_APP=${CLIENT_SHENANGO_DIR}/apps/synthetic/target/release/synthetic
        synthetic_cfg="""
host_addr ${SYNTHETIC_SERVER_IP}
host_netmask 255.255.255.0
host_gateway 192.168.0.1
runtime_kthreads 24
runtime_guaranteed_kthreads 24
runtime_spinning_kthreads 24
host_mac ${SYNTHETIC_SERVER_MAC}
disable_watchdog 1
static_arp ${HOST_IP} ${HOST_MAC}
static_arp ${CLIENT_IP} ${CLIENT_MAC}
static_arp ${MCACHED_SERVER_IP} ${MCACHED_SERVER_MAC}"""
        echo "$synthetic_cfg" > synthetic.config
        ssh ${CLIENT_SSH} "mkdir -p ${CLIENT_EXPDIR}"           # make dir on client
        scp synthetic.config ${CLIENT_SSH}:${CLIENT_EXPDIR}/    # copy client shenango config
        wrapper="numactl -N ${CLIENT_NUMA_NODE} -m ${CLIENT_NUMA_NODE}"
        args="--config ${CLIENT_EXPDIR}/synthetic.config ${MCACHED_SERVER_IP}:${MCACHED_SERVER_PORT}"
        args="$args ${WMFLAG} --output=normal --protocol memcached --mode runtime-client --threads 100"
        args="$args --runtime ${RUNTIME} --mean=842 --distribution=zero --mpps=${MPPS} --samples=1 "
        args="$args --transport udp --start_mpps ${START_MPPS} --zipfs ${ZIPFS}"
        echo sudo ${wrapper} ${CLIENT_SYNTHETIC_APP} ${args}
        ssh ${CLIENT_SSH} "cd ${CLIENT_EXPDIR} && sudo ${wrapper} ${CLIENT_SYNTHETIC_APP} ${args}" > client.out < /dev/null
        popd

        # copy client files back
        scp ${CLIENT_SSH}:${CLIENT_EXPDIR}/* ${expdir}/
        ssh ${CLIENT_SSH} "rm -rf ${CLIENT_EXPDIR}"

        # kill memcached
        echo "stopping memcached"
        sudo kill $pid

        # if we're here, the run has mostly succeeded
        # only retry if we have silenty failed because of rmem server
        if [ ! -f eden_rdma_server_error ] || [ `cat eden_rdma_server_error` != $main_pid ]; then
            echo "no error; moving on"
            mv ${expdir} $DATADIR/
            echo "final results at $DATADIR/${expdir}"
            break
        fi
    else
        echo "memcached process failed to write pid; try again or exit"
        popd
    fi
done

# cleanup
echo "final cleanup"
cleanup