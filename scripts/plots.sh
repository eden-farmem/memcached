#!/bin/bash
set -e 
#
# Plot all stats for a single run
#

PLOTEXT=png
DATADIR=data
HOST_CORES_PER_NODE=28
HOST="sc2-hs2-b1630"
CLIENT="sc2-hs2-b1632"
ANNOTATE=1  #Default

usage="\n
-n, --name \t\t experiment to consider\n
-f, --force \t\t force re-summarize results\n
-v, --verbose \t\t show all plots/metrics we have\n
-d, --display \t\t display individal plots\n
-fp,  --force-plots \t force re-generate just the plots\n
-a, --annotate \t mark charts with relevant text annotations\n
-s, --sample \t\t chart just the sample, not the entire run\n
-sw, --suppresswarn \t ignore warnings raised by data anomalies\n"

for i in "$@"
do
case $i in
    -n=*|--name=*)
    NAME="${i#*=}"
    ;;

    -f|--force)
    FORCE=1
    ;;

    -d|--display)
    DISPLAY_EACH=1
    ;;

    -fp|--force-plots)
    FORCE_PLOTS=1
    ;;

    -v|--verbose)
    VERBOSE=1
    ;;

    -a|--annotate)
    ANNOTATE=1
    ;;

    -s=*|--sample=*)
    SAMPLE="${i#*=}"
    SAMPLE_ARG="--sample $SAMPLE"
    ;;
    
    -sw|--suppresswarn)
    SUPPRESS_WARN="--suppresswarn"
    ;;

    *)                      # unknown option
    echo "Unkown Option: $i"
    echo -e $usage
    exit
    ;;
esac
done

# Exp run, pick latest by default
latest_dir_path=$(ls -td -- $DATADIR/*/ | head -n 1)
name=${NAME:-$(basename $latest_dir_path)}
echo "Working on experiment:" $name
exp=$DATADIR/$name
SCRIPT_DIR=`dirname "$0"`

PLOTDIR=$exp/plots
mkdir -p ${PLOTDIR}

# summarize results
statsdir=$exp/stats
statfile=$statsdir/stat.csv
if [[ $FORCE ]] || [ ! -d $statsdir ]; then
    python ${SCRIPT_DIR}/summary.py -n $name ${SAMPLE_ARG} \
        --kona --iok --app ${SUPPRESS_WARN}
fi
ls $statsdir

checkpts=$statsdir/checkpoints
if [[ $ANNOTATE ]] && [ -f $checkpts ]; then 
    VLINES="--vlinesfile $checkpts"
fi

# Plot Xput
datafile=$statsdir/stat.csv
# TODO: Client does not emit time-series xput data 

# Plot iok stats
datafile=$statsdir/iokstats
plotname=${PLOTDIR}/${name}_iokstats.$PLOTEXT
if [[ $FORCE ]] || [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then 
    python3 ${SCRIPT_DIR}/plot.py -d ${datafile} ${VLINES}      \
        -yc "TX_PULLED" -l "Acheived" -ls solid                 \
        -yc "RX_PULLED" -l "Offered" -ls solid                  \
        -xc "time" -xl  "Time (secs)" -yl "Million pkts/sec"    \
        --ymin 0 --ymax 2.1 --ymul 1e-6 -lt "Xput (I/O Core)"   \
        --size 6 3 -fs 12 -of $PLOTEXT  -o $plotname 
    if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
        # --twin 3  -tyl "Saturation %" --tymul 100  --tymax 110 --tymin 0     \
        # -yc "IOK_SATURATION" -l "Core Saturation" -ls dashed    \
fi
files="$files $plotname"


# Plot kona 
datafile=$statsdir/konastats
plotname=${PLOTDIR}/${name}_konastats.$PLOTEXT
if [[ $FORCE ]] || [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then 
    if [[ $VERBOSE ]]; then 
        python3 ${SCRIPT_DIR}/plot.py -d ${datafile} ${VLINES}  \
            -yc "n_faults" -l "Total Faults" -ls solid          \
            -yc "n_faults_r" -l "Read Faults" -ls solid         \
            -yc "n_faults_w" -l "Write Faults" -ls solid        \
            -yc "n_faults_wp" -l "Remove WP" -ls solid          \
            -yc "n_evictions" -l "Evictions" -ls solid          \
            -yc "n_madvise"     -l "Madvise Calls"  -ls solid   \
            -yc "n_madvise_fail" -l "Madvise Fails" -ls solid   \
            -yc "mem_pressure" -l "Mem pressure" -ls dashed     \
            -xc "time" -xl  "Time (secs)" -yl "Count (x 1000)"  \
            --twin 8  -tyl "Size (MB)" --tymul 1e-6             \
            -lt "Kona Faults"  --ymul 1e-3                      \
            --size 6 3 -fs 11  -of $PLOTEXT  -o $plotname
    else 
        python3 ${SCRIPT_DIR}/plot.py -d ${datafile} ${VLINES}  \
            -yc "n_faults_r" -l "Read Faults" -ls solid         \
            -yc "n_faults_w" -l "Write Faults" -ls solid        \
            -yc "n_afaults_r" -l "Read App Faults" -ls solid    \
            -yc "n_afaults_w" -l "Write App Faults" -ls solid   \
            -yc "n_faults_wp" -l "WP Faults" -ls solid          \
            -yc "n_evictions" -l "Evictions" -ls solid          \
            -xc "time" -xl  "Time (secs)" -yl "Count (x 1000)"  \
            --twin 5  -tyl "Size (MB)" --tymul 1e-6             \
            -lt "Kona Faults"  --ymul 1e-3                      \
            --size 6 3 -fs 11  -of $PLOTEXT  -o $plotname
    fi 
    if [[ $DISPLAY_EACH ]]; then display $plotname &    fi 
    files="$files $plotname"
fi

if [[ $VERBOSE ]]; then
    datafile=$statsdir/konastats_extended
    plotname=${PLOTDIR}/${name}_konastats_extended.$PLOTEXT
    if [[ $FORCE ]] || [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then 
        python3 ${SCRIPT_DIR}/plot.py -d ${datafile} ${VLINES}          \
            -yc "PERF_EVICT_TOTAL" -l "Evict Total" -ls solid           \
            -yc "PERF_EVICT_WP" -l "Eviction WP" -ls solid              \
            -yc "PERF_RDMA_WRITE" -l "Evict Write RDMA" -ls solid       \
            -yc "PERF_POLLER_READ" -l "Poller Total" -ls dashed         \
            -yc "PERF_POLLER_UFFD_COPY" -l "Poller UFFD Copy" -ls dashed \
            -yc "PERF_HANDLER_RW" -l "Handler RW" -ls dashed            \
            -yc "PERF_PAGE_READ" -l "RDMA Read" -ls dashed              \
            -yc "PERF_EVICT_WRITE" -l "Evict Write Total" -ls dashed    \
            -yc "PERF_HANDLER_FAULT" -l "Handler Total" -ls dashed      \
            -yc "PERF_EVICT_MADVISE" -l "Evict Madvise" -ls dashed      \
            -xc "time" -xl "Time (secs)"                                \
            -yl "Micro-secs" --ymin 0 --ymax 10 --ymul 454e-6           \
            --size 6 3 -fs 10 -of $PLOTEXT  -o $plotname -lt "Kona Latencies"
        if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
        files="$files $plotname"
    fi


    # Plot runtime stats
    datafile=$statsdir/rstat_memcached
    plotname=${PLOTDIR}/${name}_runtime.$PLOTEXT
    if [[ $FORCE ]] || [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then 
        # python3 ${SCRIPT_DIR}/plot.py -d ${datafile} ${VLINES}      \
        #     -yc "rxpkt" -l "From I/O Core" -ls solid                \
        #     -yc "txpkt" -l "To I/O Core" -ls solid                  \
        #     -yc "drops" -l "Pkt drops" -ls solid                    \
        #     -yc "cpupct" -l "CPU Utilization" -ls dashed            \
        #     -xc "time" -xl  "Time (secs)" -yl "Million pkts/sec"    \
        #     --twin 4  -tyl "CPU Cores" --tymul 1e-2 --ymul 1e-6     \
        #     --tymin 0 --ymin 0 -lt "Shenango Runtime"               \
        #     --size 6 3 -fs 11  -of $PLOTEXT  -o $plotname
        # display $plotname & 
        # files="$files $plotname"

        plotname=${PLOTDIR}/${name}_scheduler.$PLOTEXT
        python3 ${SCRIPT_DIR}/plot.py -d ${datafile} ${VLINES}      \
            -yc "stolenpct" -l "Stolen Work %" -ls solid            \
            -yc "migratedpct" -l "Core Migration %" -ls solid       \
            -yc "localschedpct" -l "Core Local Work %" -ls solid    \
            -yc "rescheds" -l "Reschedules" -ls dashed              \
            -yc "parks" -l "KThread Parks" -ls dashed               \
            -yc "pf_retries" -l "PF retries" -ls dashed             \
            -xc "time" -xl  "Time (secs)" -yl "Percent"             \
            --twin 4  -tyl "Million Times" --tymul 1e-6             \
            --tymin 0 --ymin 0 --ymax 110 -t "Shenango Health"      \
            --size 6 3 -fs 12  -of $PLOTEXT  -o $plotname
        display $plotname & 
        files="$files $plotname"
    fi
fi

# Combine
echo $files
plotname=${PLOTDIR}/all_${name}.$PLOTEXT
montage -tile 2x0 -geometry +5+5 -border 5 $files ${plotname}
display ${plotname} &
