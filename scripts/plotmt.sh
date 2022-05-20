#!/bin/bash
set -e 
#
# Plot stats against time-series for each run 
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
SCRIPT_DIR=`dirname "$0"`
LTITLE="Runs"
TMPFILE_PFX=temp

usage="\n
-s, --suffix \t\t\t a plain suffix defining the set of runs to consider\n
-cs, --csuffix \t\t same as suffix but a more complex one (with regexp pattern)\n
-vm, --vary-mem \t\t hint that the runs differ by kona memory\n
-vc, --vary-cores \t\t hint that the runs differ by server cores\n
-veth, --vary-evict-high \t hint that the runs differ by evict high watermark\n
-vetl, --vary-evict-low \t hint that the runs differ by evict low watermark\n
-d, --display \t\t\t display individal plots\n
-f, --force \t\t\t force re-summarize results\n
-fp,  --force-plots \t\t force re-generate just the plots\n"

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

    -fp|--force-plots)
    FORCE_PLOTS=1
    ;;

    -vm|--vary-mem)
    LABEL=konamem
    LTITLE='Local Mem (MB)'
    ;;

    -vc|--vary-cores)
    LABEL=scores
    LTITLE='Server Cores'
    ;;

    -veth|--vary-evict-high)
    LABEL=konaet
    LTITLE='Eviction High Mark'
    ;;

    -vetl|--vary-evict-low)
    LABEL=konaedt
    LTITLE='Eviction Low Mark'
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

annotations=${TMPFILE_PFX}_cpts
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
    
    # NOTE: LABEL, if defined, must name one of the variables above
    if [[ $LABEL ]] && [ ! ${!LABEL} ]; then    
        echo "ERROR! LABEL should point to a valid variable"
    elif [[ $LABEL ]]; then label=${!LABEL}
    else                    label=$name; fi
    iokdata="$iokdata -d $statsdir/iokstats -l $label"
    konadata="$konadata -d $statsdir/konastats -l $label"
    konaextdata="$konaextdata -d $statsdir/konastats_extended -l $label"

    checkpts=${statsdir}/checkpoints
    if [ -f $checkpts ]; then 
        cat $checkpts >> $annotations 
        VLINES="--vlinesfile $annotations"
    fi
done

XCOL=time
XLABEL="Time (secs)"
NOMARKER="--nomarker"

# Plot Xput
# TODO: Client does not emit time-series xput data 

plotname=${PLOTDIR}/iokstats_${fsuffix}.$PLOTEXT
ycol="TX_PULLED"     # options: "RX_PULLED" 
ydesc="Throughput (Mpps)"
if [[ $FORCE ]] || [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
    python3 ${SCRIPT_DIR}/plot.py ${iokdata}    \
        -yc $ycol -ls solid -yl "$ydesc"        \
        --ymul 1e-6 --ymin 0 --ymax 2           \
        -xc $XCOL -xl "$XLABEL" $XMUL           \
        ${VLINES} ${NOMARKER} --size 6 3 -fs 11 \
        -of $PLOTEXT -o $plotname -lt "$LTITLE" 
    if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
fi
files="$files $plotname"

# Plot kona 
plotname=${PLOTDIR}/konastats_${fsuffix}.$PLOTEXT
ycol="n_faults_r"     # options: "malloc_size" "n_net_page_in" "n_net_page_out" "outstanding"
ydesc="Kilo Read Faults / sec"
if [[ $FORCE ]] || [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
    python3 ${SCRIPT_DIR}/plot.py ${konadata}                       \
        -yc $ycol -ls solid -yl "$ydesc" --ymul 1e-3                \
        -xc $XCOL -xl "$XLABEL" $XMUL                               \
        ${VLINES} ${NOMARKER} --size 6 3 -fs 11                     \
        -of $PLOTEXT -o $plotname -lt "$LTITLE" 
    if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
fi
files="$files $plotname"

plotname=${PLOTDIR}/konastats1_${fsuffix}.$PLOTEXT
ycol="mem_pressure"     # options: "malloc_size" "n_net_page_in" "n_net_page_out" "outstanding"
ydesc="Mem Pressure (GB)"
if [[ $FORCE ]] || [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
    python3 ${SCRIPT_DIR}/plot.py ${konadata}                   \
        -yc $ycol -ls solid -yl "$ydesc" --ymul 1e-9            \
        -xc $XCOL -xl "$XLABEL" $XMUL                           \
        ${VLINES} ${NOMARKER} --size 6 3 -fs 11                 \
        -of $PLOTEXT -o $plotname -lt "$LTITLE" ${NOMARKER}
    if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
fi
files="$files $plotname"

plotname=${PLOTDIR}/konastats2_${fsuffix}.$PLOTEXT
ycol="n_faults_w"     # options: "malloc_size" "n_net_page_in" "n_net_page_out" "outstanding"
ydesc="Kilo Write Faults / sec"
if [[ $FORCE ]] || [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
    python3 ${SCRIPT_DIR}/plot.py ${konadata}                       \
        -yc $ycol -ls solid -yl "$ydesc" --ymul 1e-3                \
        -xc $XCOL -xl "$XLABEL" $XMUL                               \
        ${VLINES} ${NOMARKER} --size 6 3 -fs 11                     \
        -of $PLOTEXT -o $plotname -lt "$LTITLE"
    if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
fi
files="$files $plotname"

# plotname=${PLOTDIR}/konastats_extended_${fsuffix}.$PLOTEXT
# ycol="PERF_HANDLER_FAULT_Q"     # options: "PERF_EVICT_MADVISE", "PERF_EVICT_TOTAL"
# ydesc="Fault Wait Time (µs)"
# if [[ $FORCE ]] || [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
#     python3 ${SCRIPT_DIR}/plot.py ${plots}              \
#         -yc $ycol -yl "$ydesc"  --ymul 454e-6           \
#         -xc $XCOL -xl "$XLABEL" $XMUL                   \
#          --size 6 3 -fs 11 -of $PLOTEXT -o $plotname -lt "$LTITLE" 
#     if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
# fi
# files="$files $plotname"

# # Combine
# echo $files
plotname=${PLOTDIR}/all_${SUFFIX}.$PLOTEXT
montage -tile 2x0 -geometry +5+5 -border 5 $files ${plotname}
display ${plotname} &
rm ${TMPFILE_PFX}*