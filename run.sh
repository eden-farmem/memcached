#
# Run experiments
#
RUNTIME=20
KONA_RCNTRL_SSH="sc07"
KONA_MEMSERVER_SSH=$KONA_RCNTRL_SSH
CLIENT_SSH="sc32"

# Default Server Params
SCORES=4
MEM=1600
# PAGE_FAULTS=ASYNC

# # Kona Params
# KCFG=CONFIG_NO_DIRTY_TRACK
KCFG=CONFIG_WP
# KCFG=NO_KONA
# KFLAGS="-DPRINT_FAULT_ADDRS"
# KFLAGS="-DREGISTER_MADVISE_NOTIF"
# KFLAGS="-DBATCH_EVICTION"
# KFLAGS="-DSAFE_MODE"
# KFLAGS="-DDNE_QUEUE_SIZE=256"
# KFLAGS="-DENABLE_TRACE"


EVICT_THR=.99
EVICT_DONE_THR=.99
EVICT_BATCH_SIZE=1

# Default client settings
CONNS=100
MPPS=4              #undo
KEYSPACE=10M        #not configurable yet

usage="\n
-d, --debug \t\t build debug and run with debug client load\n
-spf,--spgfaults \t build shenango with page faults feature. allowed values: SYNC, ASYNC\n
-kc,--kona-config \t kona build configuration (NO_KONA/CONFIG_NO_DIRTY_TRACK/CONFIG_WP)\n
-g, --gdb \t\t build with symbols\n
-h, --help \t\t this usage information message\n"

# Parse command line arguments
for i in "$@"
do
case $i in
    -d|--debug) # debug config
    DEBUG=1
    CONNS=5
    MPPS=1e-2
    MEM=.5
    KEYSPACE=10K  #not configurable yet, 10MB remote mem?
    DEBUG_FLAG="--debug"
    ;;

    -spf=*|--spgfaults=*)
    PAGE_FAULTS="${i#*=}"
    ;;

    -kc=*|--kona-config=*)
    KCFG=${i#*=}
    ;;

    -g|--gdb)
    GDB=1
    GDBFLAG="--gdb"
    ;;

    -sb|--skipbuild)
    SKIP_BUILD=1
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


# # Build
if ! [[ $SKIP_BUILD ]]; then
    set -e
    if [[ "$KCFG" == "NO_KONA" ]]; then
        bash build.sh --shenango --memcached
    else
        if [[ ${PAGE_FAULTS} ]]; then   SPFLAG="-spf=${PAGE_FAULTS}";  fi
        bash build.sh ${DEBUG_FLAG} --shenango --memcached --kona   \
            -wk --kona-config=$KCFG --kona-cflags=${KFLAGS} ${SPFLAG} ${GDBFLAG}
    fi
    set +e
fi


cleanup() {
    sudo pkill iokerneld
    ssh ${KONA_RCNTRL_SSH} "pkill rcntrl; rm -f ~/scratch/rcntrl" 
    ssh ${KONA_MEMSERVER_SSH} "pkill memserver; rm -f ~/scratch/memserver"
    ssh ${CLIENT_SSH} "sudo pkill iokerneld"
}

# # Run
# for warmup in "--warmup"; do 
# for KFLAGS in ""; do
# for KFLAGS in "" "-DREGISTER_MADVISE_NOTIF"; do
    # for EVICT_THR in 0.9; do
    # for EVICT_DONE_THR in 0.92 0.94 0.96; do
    # for EVICT_BATCH_SIZE in 2 4; do
    for scores in $SCORES; do
    # for scores in 1 2 3 4 5; do
        # for mem in `seq 1000 200 2000`; do
        for mem in $MEM; do
            cleanup

            echo "Syncing clocks"
            ssh $KONA_RCNTRL_SSH "sudo systemctl stop ntp; sudo ntpd -gq; sudo systemctl start ntp;"
            ssh $CLIENT_SSH "sudo systemctl stop ntp; sudo ntpd -gq; sudo systemctl start ntp;"

            DESC="shenango + memcached base xput"
            # DESC="running SYNC vs ASYNC"
            kona_evict="--konaet ${EVICT_THR} --konaedt ${EVICT_DONE_THR} --konaebs ${EVICT_BATCH_SIZE}"
            kona_mem_bytes=`echo $mem | awk '{ print $1*1000000 }'`
            GDBFLAG=
            if [[ $GDB ]]; then  STOPAT="--stopat 4";     fi   # to allow debugging
            # debugging
            if [[ "$KCFG" == "NO_KONA" ]]; then
                python scripts/experiment.py --nokona -p udp -nc $CONNS --time $RUNTIME $GDBFLAG    \
                    --start $MPPS --finish $MPPS --scores $scores ${warmup} ${STOPAT}               \
                    -d "$KEYSPACE keys; No Kona; $DESC"
            else
                python scripts/experiment.py -km ${kona_mem_bytes} -p udp -nc $CONNS --time $RUNTIME    \
                    --start $MPPS --finish $MPPS --scores $scores ${warmup} ${STOPAT} ${kona_evict}     \
                    ${GDBFLAG} -d "$KEYSPACE keys; PBMEM=${KCFG}; KonaFlags=${KFLAGS}; PF: ${PAGE_FAULTS}; $DESC"
            fi

            sleep 5
        done
    done
# done


############# ARCHIVED #################

# Sync times on machines before the run
# Requires ntp setup with sc30 as root server
# echo "Syncing clocks"
# ssh sc40 "sudo systemctl stop ntp; sudo ntpd -gq; sudo systemctl start ntp;"
# ssh sc07 "sudo systemctl stop ntp; sudo ntpd -gq; sudo systemctl start ntp;"

# # Best of UDP Xput
# conns=1000
# for mpps in `seq 1 0.5 6`; do
#     python experiment.py --nokona -p udp -nc 1000 --start $mpps --finish $mpps \
#         -d "no kona; 10M keys; udp; ${conns} conns; $mpps Mpps offered; 18 scores; 18 ccores; with lat"
#     sleep 5
# done

# # Vary no of tcp connections
# for conns in 200 600 1000 1400 2000; do
#     for mpps in `seq 1 0.5 6`; do
#         python experiment.py --nokona -p tcp -nc $conns --start $mpps --finish $mpps \
#             -d "no kona; 10M keys; tcp; ${conns} conns; $mpps Mpps offered; 18 scores; 18 ccores"
#         sleep 5
#     done
# done

# # Vary local memory
# for mem in `seq 1000 100 2000`; do
#     python experiment.py -km ${mem}000000 -p tcp -nc $conns --start $mpps --finish $mpps \
#         -d "with kona ${mem} MB; 10M keys; tcp; ${conns} conns; $mpps Mpps offered; 12 scores, 18 ccores"
#     sleep 5
# done