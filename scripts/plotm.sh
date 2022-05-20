#!/bin/bash
set -e 
#
# Plot all stats for multiple runs 
# (Requires Imagemagick)
#

PLOTEXT=png
DATADIR=data
PLOTDIR=plots/
HOST_CORES_PER_NODE=28
HOST="sc2-hs2-b1630"
CLIENT="sc2-hs2-b1632"
SAMPLE=0
SOME_BIG_NUMBER=100000000000

usage="\n
-s, --suffix \t\t a plain suffix defining the set of runs to consider\n
-cs, --csuffix \t\t same as suffix but a more complex one (with regexp pattern)\n
-vm, --vary-mem \t\t hint to use kona memory on x-axis (default)\n
-vc, --vary-cores \t\t hint to use server cores on x-axis\n
-d, --display \t\t display individal plots\n
-f, --force \t\t force re-summarize results\n"

# Defaults
XCOL=konamem
XLABEL='Local Mem (MB)'
COLIDX=3

# Read parameters
for i in "$@"
do
case $i in
    -s=*|--suffix=*)
    SUFFIX="${i#*=}"
    ;;

    -cs=*|--csuffix=*)
    CSUFFIX="${i#*=}"
    ;;

    -d|--display)
    DISPLAY_EACH=1
    ;;

    -f|--force)
    FORCE=1
    ;;

    -vm|--vary-mem)
    XCOL=konamem
    XLABEL='Local Mem (MB)'
    COLIDX=3
    # XLABEL='Local Mem Ratio'  # For mem ratio
    # XMUL="--xmul 5e-4"
    ;;

    -vc|--vary-cores)
    XCOL=scores
    XLABEL='Server Cores'
    COLIDX=4
    ;;

    -vebs|--vary-evict-batch-size)
    XCOL=konaebs
    XLABEL='Eviction Batch Size'
    COLIDX=5
    ;;

    *)                      # unknown option
    echo "Unkown Option: $i"
    echo -e $usage
    exit
    ;;
esac
done

if [[ $SUFFIX ]]; then 
    LS_CMD=`ls -d1 data/run-${SUFFIX}*/`
    SUFFIX=$SUFFIX
elif [[ $CSUFFIX ]]; then
    LS_CMD=`ls -d1 data/*/ | grep -e "$CSUFFIX"`
    SUFFIX=$CSUFFIX
fi

SCRIPT_DIR=`dirname "$0"`
numplots=0
for exp in $LS_CMD; do
    echo "Parsing $exp"
    name=`basename $exp`
    cfg="$exp/config.json"
    sthreads=`jq '.apps."'$HOST'" | .[] | select(.name=="memcached") | .threads' $cfg`
    konamem=`jq '.apps."'$HOST'" | .[] | select(.name=="memcached") | .kona.mlimit' $cfg`
    if [ $konamem == "null" ]; then konamem_mb=$SOME_BIG_NUMBER;
    else    konamem_mb=`echo $konamem | awk '{ print $1/1000000 }'`;     fi
    konaet=`jq '.apps."'$HOST'" | .[] | select(.name=="memcached") | .kona.evict_thr' $cfg`
    konaedt=`jq '.apps."'$HOST'" | .[] | select(.name=="memcached") | .kona.evict_done_thr' $cfg`
    konaebs=`jq '.apps."'$HOST'" | .[] | select(.name=="memcached") | .kona.evict_batch_sz' $cfg`
    prot=`jq -r '.clients."'$CLIENT'" | .[] | select(.app=="synthetic") | .transport' $cfg`
    nconns=`jq '.clients."'$CLIENT'" | .[] | select(.app=="synthetic") | .client_threads' $cfg`
    mpps=`jq '.clients."'$CLIENT'" | .[] | select(.app=="synthetic") | .mpps' $cfg`
    desc=`jq '.desc' $cfg`

    # summarize results
    statsdir=$exp/stats
    statfile=$statsdir/stat.csv
    if [[ $FORCE ]] || [ ! -d $statsdir ]; then
        python ${SCRIPT_DIR}/summary.py -n $name --lat --kona --app --iok
    fi
    
    # aggregate across runs
    header=nconns,mpps,konamem,scores,konaebs,`cat $statfile | awk 'NR==1'`
    curstats=`cat $statfile | awk 'NR==2'`
    # if ! [[ $curstats ]]; then    curstats=$prevstats;  fi      #HACK!
    stats="$stats\n$nconns,$mpps,$konamem_mb,$sthreads,$konaebs,$curstats"
    prevstats=$curstats
done

# Data in one file
tmpfile=temp_xput_$curlabel
echo -e "$stats" > $tmpfile
sort -k${COLIDX} -n -t, $tmpfile -o $tmpfile
sed -i "1s/^/$header/" $tmpfile
sed -i "s/$SOME_BIG_NUMBER/NoKona/" $tmpfile
plots="$plots -d $tmpfile"
cat $tmpfile
datafile=$tmpfile

# Plot memcached
plotname=${PLOTDIR}/memcached_xput_${SUFFIX}.$PLOTEXT
if [[ $FORCE ]] || [ ! -f "$plotname" ]; then
    python3 ${SCRIPT_DIR}/plot.py -d ${datafile}        \
        -yc achieved -l "Throughput" -ls solid          \
        -xc $XCOL -xl "$XLABEL" --xstr $XMUL            \
        -yl "Million Ops/sec" --ymul 1e-6               \
        --size 6 3 -fs 12 -of $PLOTEXT -o $plotname
    if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
fi
files="$files $plotname"

# Plot kona 
plotname=${PLOTDIR}/konastats_${SUFFIX}.$PLOTEXT
if [[ $FORCE ]] || [ ! -f "$plotname" ]; then
    datafile_kona="temp_kona"
    sed '/NoKona/d' $datafile > $datafile_kona      #remove nokona run
    python3 ${SCRIPT_DIR}/plot.py -d ${datafile_kona}               \
        -yc "n_faults" -l "Total Faults" -ls solid                  \
        -yc "n_net_page_in" -l "Net Pages Read" -ls solid           \
        -yc "n_net_page_out" -l "Net Pages Write" -ls solid         \
        -yc "malloc_size" -l "Mallocd Mem" -ls dashed               \
        -yc "mem_pressure" -l "Mem pressure" -ls dashed             \
        -xc $XCOL -xl "$XLABEL" --xstr $XMUL                        \
        -yl "Count (x1000)" --ymul 1e-3 --ymin 0                    \
        --twin 6  -tyl "GB" --tymin 0  --tymul 1e-9                 \
        --size 6 3 -fs 12  -of $PLOTEXT  -o $plotname -lt "Kona Activity"    
    if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
fi
files="$files $plotname"
        # -yc "outstanding"   -l "Max Concurrent Reads" -ls dashed    \
        # -yc "n_madvise"     -l "Madvise Calls"  -ls solid           \
        # -yc "n_madvise_fail" -l "Madvise Fails" -ls solid           \

plotname=${PLOTDIR}/konastats_extended_${SUFFIX}.$PLOTEXT
if [[ $FORCE ]] || [ ! -f "$plotname" ]; then
    python3 ${SCRIPT_DIR}/plot.py -d ${datafile}                            \
        -yc "PERF_HANDLER_FAULT_Q" -l "1.0 Fault Queue Wait"                \
        -yc "PERF_HANDLER_RW" -l "1.1 Handle Fault" -ls solid               \
        -yc "PERF_PAGE_READ" -l "1.2 RDMA Read" -ls dashed                  \
        -yc "PERF_HANDLER_MADV_NOTIF" -l "1.3 Handle Notif " -ls dashed     \
        -yc "PERF_POLLER_READ" -l "2   Handle Read" -ls solid               \
        -yc "PERF_POLLER_UFFD_COPY" -l "2.1 UFFD Copy" -ls dashed           \
        -yc "PERF_EVICT_TOTAL" -l "3   Evict Total" -ls solid               \
        -yc "PERF_EVICT_WP" -l "3.1 Evict WP" -ls dashed                    \
        -yc "PERF_EVICT_WRITE" -l "3.2 Issue Write" -ls dashed              \
        -yc "PERF_EVICT_MADVISE" -l "3.3 Madvise" -ls dashed                \
        -xc $XCOL -xl "$XLABEL" --xstr $XMUL                                \
        -yl "Micro-secs" --ymin 0 --ymax 300 --ymul 454e-6                  \
        --size 6 3 -fs 10  -of $PLOTEXT  -o $plotname -lt "Kona Latencies"
    # display $plotname &  
fi
files="$files $plotname"

# Plot iok stats
plotname=${PLOTDIR}/iokstats_${SUFFIX}.$PLOTEXT
if [[ $FORCE ]] || [ ! -f "$plotname" ]; then
    python3 ${SCRIPT_DIR}/plot.py -d ${datafile}                        \
        -yc "TX_PULLED" -l "From Runtime" -ls solid                     \
        -yc "RX_PULLED" -l "To Runtime" -ls solid                       \
        -yc "RX_UNICAST_FAIL" -l "To Runtime (Failed)" -ls solid        \
        -yc "IOK_SATURATION" -l "Core Saturation" -ls dashed            \
        -xc $XCOL -xl "$XLABEL" --xstr $XMUL                            \
        -yl "Million pkts/sec" --ymul 1e-6 --ymin 0                     \
        --twin 4  -tyl "Saturation %" --tymul 100 --tymin 0 --tymax 110 \
        --size 6 3 -fs 12 -of $PLOTEXT  -o $plotname -lt "Shenango I/O Core"
    if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
fi
files="$files $plotname"

# # Plot runtime stats
# plotname=${PLOTDIR}/${name}_runtime.$PLOTEXT
# if [[ $FORCE ]] || [ ! -f "$plotname" ]; then
#     python3 ${SCRIPT_DIR}/plot.py -d ${datafile}                \
#         -yc "rxpkt" -l "From I/O Core" -ls solid                \
#         -yc "txpkt" -l "To I/O Core" -ls solid                  \
#         -yc "drops" -l "Pkt drops" -ls solid                    \
#         -yc "cpupct" -l "CPU Utilization" -ls dashed            \
#         -xc $XCOL -xl "$XLABEL" --xstr $XMUL                    \
#         -yl "Million pkts/sec" --ymul 1e-6 --ymin 0             \
#         --twin 4  -tyl "CPU Cores" --tymul 1e-2 --tymin 0       \
#         --size 6 3 -fs 12  -of $PLOTEXT  -o $plotname -lt "Shenango Resources"
#     if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
# fi
# files="$files $plotname"

# plotname=${PLOTDIR}/${name}_scheduler.$PLOTEXT
# if [[ $FORCE ]] || [ ! -f "$plotname" ]; then
#     python3 ${SCRIPT_DIR}/plot.py -d ${datafile}                        \
#         -yc "stolenpct" -l "Stolen Work %" -ls solid            \
#         -yc "migratedpct" -l "Core Migration %" -ls solid       \
#         -yc "localschedpct" -l "Core Local Work %" -ls solid    \
#         -yc "rescheds" -l "Reschedules" -ls dashed              \
#         -yc "parks" -l "KThread Parks" -ls dashed               \
#         -xc $XCOL -xl "$XLABEL" --xstr $XMUL                    \
#         -yl "Percent" --ymin 0 --ymax 110                       \
#         --twin 4  -tyl "Million Times" --tymul 1e-6 --tymin 0   \
#         --size 6 3 -fs 12  -of $PLOTEXT  -o $plotname -lt "Shenango Scheduler" 
#     if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
# fi
# files="$files $plotname"

# Write config params 
echo "text 3,6 \"" > temp_cfg 
echo "        INFO" >> temp_cfg 
echo "        $XLABEL: $sthreads" >> temp_cfg 
echo "        Offered Load: $mpps MOps" >> temp_cfg 
echo "\"" >> temp_cfg 
convert -size 360x120 xc:white -font "DejaVu-Sans" -pointsize 20 -fill black -draw @temp_cfg temp_image.png
files="$files temp_image.png"

# # Combine
# echo $files
plotname=${PLOTDIR}/all_${SUFFIX}.$PLOTEXT
montage -tile 2x0 -geometry +5+5 -border 5 $files ${plotname}
display ${plotname} &
rm $datafile
rm temp_*
