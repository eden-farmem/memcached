#!/bin/bash
set -e 
#
# Plot/compare stats across multiple groups of runs
# (Requires Imagemagick)
#

# Milestone Runs
# run-10-28-1[23]   : Base run
# run-10-28-11      : Got rid of Madvise notif
# run-11-23-12      : No Dirtying (refcount); --take 8

PLOTEXT=png
DATADIR=data
PLOTDIR=plots/
HOST_CORES_PER_NODE=28
HOST="sc2-hs2-b1630"
CLIENT="sc2-hs2-b1632"
SAMPLE=0
SOME_BIG_NUMBER=100000000000
SCRIPT_DIR=`dirname "$0"`
TMPFILE_PFX="temp_plotg_"

usage="\n
-s1,  --suffix1 \t\t a plain suffix defining the first group of runs\n
-cs1, --csuffix1  \t\t same as -s1 but a more complex one (with regexp pattern)\n
-l1,  --label1    \t\t\t plot label for first group of runs\n
-s[23456],  --suffix[23456] \t a plain suffix defining the group [23456] of runs (optional)\n
-cs[23456], --csuffix[23456] \t same as -s[23456] but a more complex one (with regexp pattern)\n
-l[23456],  --label[23456]    \t plot label for second group of runs\n
-lt, --label-title  \t\t title for the legend\n
-vm,  --vary-mem  \t\t hint to use kona memory on x-axis (default)\n
-vc,  --vary-cores \t\t hint to use server cores on x-axis\n
-d,   --display   \t\t\t display individal plots\n
-f,   --force     \t\t\t force re-summarize data and re-generate plots\n
-fp,  --force-plots \t\t force re-generate just the plots\n
-h,  --head \t\t\t consider first specified number of rows while plotting \n
-t,  --tail \t\t\t consider last specified number of rows while plotting \n
-of,  --outfile \t\t write collected data for each group to file named outfile+label.dat\n"

# Defaults
XCOL=konamem
XLABEL='Local Mem (MB)'
COLIDX=3
LTITLE=""

# XLABEL='Local Mem Ratio'  # For ratio
# XMUL="--xmul 5e-4"

# Read parameters
for i in "$@"
do
case $i in
    -s1=*|--suffix1=*)
    SUFFIX1="${i#*=}"
    ;;

    -cs1=*|--csuffix1=*)
    CSUFFIX1="${i#*=}"
    ;;
    
    -l1=*|--label1=*)
    LABEL1="${i#*=}"
    ;;

    -s2=*|--suffix2=*)
    SUFFIX2="${i#*=}"
    ;;

    -l2=*|--label2=*)
    LABEL2="${i#*=}"
    ;;

    -cs2=*|--csuffix2=*)
    CSUFFIX2="${i#*=}"
    ;;
    
    -s3=*|--suffix3=*)
    SUFFIX3="${i#*=}"
    ;;

    -l3=*|--label3=*)
    LABEL3="${i#*=}"
    ;;

    -cs3=*|--csuffix3=*)
    CSUFFIX3="${i#*=}"
    ;;

    -s4=*|--suffix4=*)
    SUFFIX4="${i#*=}"
    ;;

    -l4=*|--label4=*)
    LABEL4="${i#*=}"
    ;;

    -cs4=*|--csuffix4=*)
    CSUFFIX4="${i#*=}"
    ;;

    -s5=*|--suffix5=*)
    SUFFIX5="${i#*=}"
    ;;

    -l5=*|--label5=*)
    LABEL5="${i#*=}"
    ;;

    -cs5=*|--csuffix5=*)
    CSUFFIX5="${i#*=}"
    ;;

    -s6=*|--suffix6=*)
    SUFFIX6="${i#*=}"
    ;;

    -l6=*|--label6=*)
    LABEL6="${i#*=}"
    ;;

    -cs6=*|--csuffix6=*)
    CSUFFIX6="${i#*=}"
    ;;

    -lt=*|--label-title=*)
    LTITLE="${i#*=}"
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

    -t=*|--take=*|-h=*|--head=*)
    HEAD="${i#*=}"
    ;;

    -tl=*|--tail=*)
    TAIL="${i#*=}"
    ;;

    -vm|--vary-mem)
    XCOL=konamem
    XLABEL='Local Mem (MB)'
    COLIDX=3
    XLABEL='Local Memory %'  # For mem ratio
    XMUL="--xmul 5e-2"
    ;;

    -vc|--vary-cores)
    XCOL=scores
    XLABEL='Server Cores'
    COLIDX=4
    ;;

    -of=*|--outfile=*)
    OUTDATAFILE="${i#*=}"
    ;;

    *)                      # unknown option
    echo "Unkown Option: $i"
    echo -e $usage
    exit
    ;;
esac
done

if [[ ! $SUFFIX1 ]] && [[ ! $CSUFFIX1 ]]; then echo "must provide -s1/-cs1"; echo -e $usage; exit 1; fi
LABEL1=${LABEL1:-$SUFFIX1};  LABEL1=${LABEL1:-$CSUFFIX1}
LABEL2=${LABEL2:-$SUFFIX2};  LABEL2=${LABEL2:-$CSUFFIX2}
LABEL3=${LABEL3:-$SUFFIX3};  LABEL3=${LABEL3:-$CSUFFIX3}
LABEL4=${LABEL4:-$SUFFIX4};  LABEL4=${LABEL4:-$CSUFFIX4}
LABEL5=${LABEL5:-$SUFFIX5};  LABEL5=${LABEL5:-$CSUFFIX5}
LABEL6=${LABEL6:-$SUFFIX6};  LABEL6=${LABEL6:-$CSUFFIX6}

# Prepare data for each group
parse_runs_prepare_data() {
    SUFFIX=$1
    CSUFFIX=$2
    OUTFILE=$3
    LABEL=$4
    FORCE=$5

    if [[ $SUFFIX ]]; then 
        LS_CMD=`ls -d1 data/run-${SUFFIX}*/`
        SUFFIX=$SUFFIX
    elif [[ $CSUFFIX ]]; then
        LS_CMD=`ls -d1 data/*/ | grep -e "$CSUFFIX"`
        SUFFIX=$CSUFFIX
    fi

    stats=
    for exp in $LS_CMD; do
        echo "Parsing $exp"
        name=`basename $exp`
        cfg="$exp/config.json"
        sthreads=`jq '.apps."'$HOST'" | .[] | select(.name=="memcached") | .threads' $cfg`
        konamem=`jq '.apps."'$HOST'" | .[] | select(.name=="memcached") | .kona.mlimit' $cfg`
        if [ $konamem == "null" ]; then    klabel="No_Kona";    konamem_mb=$SOME_BIG_NUMBER;
        else    konamem_mb=`echo $konamem | awk '{ print $1/1000000 }'`;     fi
        label=$klabel
        konaet=`jq '.apps."'$HOST'" | .[] | select(.name=="memcached") | .kona.evict_thr' $cfg`
        konaedt=`jq '.apps."'$HOST'" | .[] | select(.name=="memcached") | .kona.evict_done_thr' $cfg`
        prot=`jq -r '.clients[][0] | select(.app=="synthetic") | .transport' $cfg`
        nconns=`jq '.clients[][0] | select(.app=="synthetic") | .client_threads' $cfg`
        mpps=`jq '.clients[][0] | select(.app=="synthetic") | .mpps' $cfg`
        desc=`jq '.desc' $cfg`

        # summarize results
        statsdir=$exp/stats
        statfile=$statsdir/stat.csv``
        if [[ $FORCE ]] || [ ! -d $statsdir ]; then
            python ${SCRIPT_DIR}/summary.py -n $name --kona --app --iok --suppresswarn     #--lat
        fi
        
        # aggregate across runs
        header=nconns,mpps,konamem,scores,`cat $statfile | awk 'NR==1'`
        curstats=`cat $statfile | awk 'NR==2'`
        # if ! [[ $curstats ]]; then    curstats=$prevstats;  fi      #HACK!
        stats="$stats\n$nconns,$mpps,$konamem_mb,$sthreads,$curstats"
        prevstats=$curstats
    done

    # Data in one file
    # echo ${OUTFILE}
    echo -e "$stats" > $OUTFILE
    sort -k${COLIDX} -n -t, $OUTFILE -o $OUTFILE
    if [[ $HEAD ]]; then
        out=$(head -n $HEAD $OUTFILE)
        echo "$out" > $OUTFILE
    elif [[ $TAIL ]]; then
        out=$(tail -n $TAIL $OUTFILE)
        echo "$out" > $OUTFILE
    fi
    sed -i "1s/^/$header/" $OUTFILE
    sed -i "s/$SOME_BIG_NUMBER/NoKona/" $OUTFILE
    cat $OUTFILE
    if [[ $OUTDATAFILE ]]; then     
        cat $OUTFILE > ${OUTDATAFILE}_${LABEL}.dat
    fi
}

# Group 1
tmpfile1=${TMPFILE_PFX}1
parse_runs_prepare_data "$SUFFIX1" "$CSUFFIX1" "$tmpfile1" "$LABEL1" "$FORCE"
datapoints1=$(wc -l < $tmpfile1)
plots="$plots -d $tmpfile1 -l """""$LABEL1""""
fsuffix=${SUFFIX1:-$CSUFFIX1}

# Add other groups
add_plot_group() {
    local GID=$1
    local SUFFIX=$2
    local CSUFFIX=$3
    local LABEL=$4
    local FORCE=$5
    local tmpfile=${TMPFILE_PFX}${GID}
    if [[ $SUFFIX ]] || [[ $CSUFFIX ]]; then
        parse_runs_prepare_data "$SUFFIX" "$CSUFFIX" "$tmpfile" "$LABEL" "$FORCE"
        local dps=$(wc -l < $tmpfile)
        if [ $datapoints1 != $dps ]; then 
            echo "ERROR! group ${GID} has different number of runs/data points"; 
            exit 1; 
        fi
        plots="$plots -d $tmpfile -l """""$LABEL""""
        fsuffix="${fsuffix}__${SUFFIX:-$CSUFFIX}"
    fi
}

add_plot_group 2 "$SUFFIX2" "$CSUFFIX2" "$LABEL2" "$FORCE" 
add_plot_group 3 "$SUFFIX3" "$CSUFFIX3" "$LABEL3" "$FORCE"
add_plot_group 4 "$SUFFIX4" "$CSUFFIX4" "$LABEL4" "$FORCE"
add_plot_group 5 "$SUFFIX5" "$CSUFFIX5" "$LABEL5" "$FORCE"
add_plot_group 6 "$SUFFIX6" "$CSUFFIX6" "$LABEL6" "$FORCE"

# Plot memcached
plotname=${PLOTDIR}/memcached_xput_${fsuffix}.$PLOTEXT
if [[ $FORCE ]] || [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
    python3 ${SCRIPT_DIR}/plot.py ${plots}                              \
        -yc achieved -ls solid -yl "Throughput (MOPS)" --ymul 1e-6  \
        -xc $XCOL -xl "$XLABEL" $XMUL                                   \
         --size 4.5 3 -fs 11 -of $PLOTEXT -o $plotname -lt "$LTITLE"
    if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
fi
files="$files $plotname"

# # Plot memcached (normalized)
# plotname=${PLOTDIR}/memcached_xput_norm_${fsuffix}.$PLOTEXT
# if [[ $FORCE ]] || [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
#     python3 ${SCRIPT_DIR}/plot.py ${plots}                              \
#         -yc achieved -ls solid -yl "Throughput (Normalized)" --ymul 1e-6  \
#         -xc $XCOL -xl "$XLABEL" $XMUL                                   \
#          --size 4.5 3 -fs 11 -of $PLOTEXT -o $plotname -lt "$LTITLE" --ynorm
#     if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
# fi
# files="$files $plotname"

# Plot kona 
ycol="n_faults"     # options: "malloc_size" "n_net_page_in" "n_net_page_out" "outstanding"
ydesc="Page Faults (KOPS)"
plotname=${PLOTDIR}/konastats_${ycol}_${fsuffix}.$PLOTEXT
if [[ $FORCE ]] || [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
    # sed '/NoKona/d' $datafile > $datafile_kona      #remove nokona run
    python3 ${SCRIPT_DIR}/plot.py ${plots}                          \
        -yc $ycol -ls solid -yl "$ydesc" --ymul 1e-3                \
        -xc $XCOL -xl "$XLABEL" $XMUL                               \
         --size 4.5 3 -fs 11 -of $PLOTEXT -o $plotname -ll none
    if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
fi
files="$files $plotname"

ycol="n_afaults"     # options: "malloc_size" "n_net_page_in" "n_net_page_out" "outstanding"
ydesc="Scheduler Faults (KOPS)"
plotname=${PLOTDIR}/konastats_${ycol}_${fsuffix}.$PLOTEXT
if [[ $FORCE ]] || [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
    # sed '/NoKona/d' $datafile > $datafile_kona      #remove nokona run
    python3 ${SCRIPT_DIR}/plot.py ${plots}                          \
        -yc $ycol -ls solid -yl "$ydesc" --ymul 1e-3                \
        -xc $XCOL -xl "$XLABEL" $XMUL                               \
         --size 4.5 3 -fs 11 -of $PLOTEXT -o $plotname -ll none
    if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
fi
files="$files $plotname"

# ycol="n_faults_r"     # options: "malloc_size" "n_net_page_in" "n_net_page_out" "outstanding"
# ydesc="Kilo Read Faults / sec"
# plotname=${PLOTDIR}/konastats_${ycol}_${fsuffix}.$PLOTEXT
# if [[ $FORCE ]] || [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
#     # sed '/NoKona/d' $datafile > $datafile_kona      #remove nokona run
#     python3 ${SCRIPT_DIR}/plot.py ${plots}                          \
#         -yc $ycol -ls solid -yl "$ydesc" --ymul 1e-3                \
#         -xc $XCOL -xl "$XLABEL" $XMUL                               \
#          --size 4.5 3 -fs 11 -of $PLOTEXT -o $plotname -ll none
#     if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
# fi
# files="$files $plotname"

ycol="n_evictions"     # options: "malloc_size" "n_net_page_in" "n_net_page_out" "outstanding"
ydesc="Evictions (KOPS)"
plotname=${PLOTDIR}/konastats_${ycol}_${fsuffix}.$PLOTEXT
if [[ $FORCE ]] || [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
    # sed '/NoKona/d' $datafile > $datafile_kona      #remove nokona run
    python3 ${SCRIPT_DIR}/plot.py ${plots}                          \
        -yc $ycol -ls solid -yl "$ydesc" --ymul 1e-3                \
        -xc $XCOL -xl "$XLABEL" $XMUL                               \
         --size 4.5 3 -fs 11 -of $PLOTEXT -o $plotname -ll none
    if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
fi
files="$files $plotname"

# ycol="n_faults_w"     # options: "malloc_size" "n_net_page_in" "n_net_page_out" "outstanding"
# ydesc="Kilo Write Faults / sec"
# plotname=${PLOTDIR}/konastats_${ycol}_${fsuffix}.$PLOTEXT
# if [[ $FORCE ]] || [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
#     # sed '/NoKona/d' $datafile > $datafile_kona      #remove nokona run
#     python3 ${SCRIPT_DIR}/plot.py ${plots}                          \
#         -yc $ycol -ls solid -yl "$ydesc" --ymul 1e-3                \
#         -xc $XCOL -xl "$XLABEL" $XMUL                               \
#          --size 4.5 3 -fs 11 -of $PLOTEXT -o $plotname -ll none
#     if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
# fi
# files="$files $plotname"

# ycol="mem_pressure"     # options: "malloc_size" "n_net_page_in" "n_net_page_out" "outstanding"
# ydesc="Mem Usage (GB)"
# plotname=${PLOTDIR}/konastats_${ycol}_${fsuffix}.$PLOTEXT
# if [[ $FORCE ]] || [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
#     # sed '/NoKona/d' $datafile > $datafile_kona      #remove nokona run
#     python3 ${SCRIPT_DIR}/plot.py ${plots}                      \
#         -yc $ycol -ls solid -yl "$ydesc" --ymul 1e-9            \
#         -xc $XCOL -xl "$XLABEL" $XMUL                           \
#          --size 4.5 3 -fs 11 -of $PLOTEXT -o $plotname -ll none
#     if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
# fi
# files="$files $plotname"

ycol="PERF_PAGE_READ"     # options: "PERF_EVICT_MADVISE", "PERF_EVICT_TOTAL"
plotname=${PLOTDIR}/konastats_${ycol}_${fsuffix}.$PLOTEXT
ydesc="RDMA Read Wait (µs)"
if [[ $FORCE ]] || [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
    python3 ${SCRIPT_DIR}/plot.py ${plots}              \
        -yc $ycol -yl "$ydesc"  --ymul 454e-6           \
        -xc $XCOL -xl "$XLABEL" $XMUL                   \
         --size 4.5 3 -fs 11 -of $PLOTEXT -o $plotname -ll none 
    if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
fi
files="$files $plotname"

ycol="PERF_HANDLER_FAULT_Q"     # options: "PERF_EVICT_MADVISE", "PERF_EVICT_TOTAL"
plotname=${PLOTDIR}/konastats_${ycol}_${fsuffix}.$PLOTEXT
ydesc="Fault Wait Time (µs)"
if [[ $FORCE ]] || [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
    python3 ${SCRIPT_DIR}/plot.py ${plots}              \
        -yc $ycol -yl "$ydesc"  --ymul 454e-6           \
        -xc $XCOL -xl "$XLABEL" $XMUL                   \
         --size 4.5 3 -fs 11 -of $PLOTEXT -o $plotname -ll none 
    if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
fi
files="$files $plotname" 

# ycol="PERF_EVICT_TOTAL"     # options: "PERF_EVICT_MADVISE", "PERF_EVICT_TOTAL"
# plotname=${PLOTDIR}/konastats_${ycol}_${fsuffix}.$PLOTEXT
# ydesc="Eviction Time (µs)"
# if [[ $FORCE ]] || [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
#     python3 ${SCRIPT_DIR}/plot.py ${plots}                  \
#         -yc $ycol -yl "$ydesc"  --ymul 454e-6               \
#         -xc $XCOL -xl "$XLABEL" $XMUL                       \
#          --size 4.5 3 -fs 11 -of $PLOTEXT -o $plotname -ll none
#     if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
# fi
# files="$files $plotname"

# plotname=${PLOTDIR}/iokstats_${fsuffix}.$PLOTEXT
# ycol="RX_PULLED"     # options: "TX_PULLED" 
# ydesc="Offered Load (Mpps)"
# if [[ $FORCE ]] || [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
#     python3 ${SCRIPT_DIR}/plot.py ${plots}      \
#         -yc $ycol -ls solid -yl "$ydesc"        \
#         --ymul 1e-6 --ymin 0 --ymax 2           \
#         -xc $XCOL -xl "$XLABEL" $XMUL           \
#          --size 4.5 3 -fs 11 -of $PLOTEXT -o $plotname -ll none
#     if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
# fi
# files="$files $plotname"

# # Plot iok stats
# plotname=${PLOTDIR}/iokstats_${SUFFIX}.$PLOTEXT
# if [[ $FORCE ]] || [ ! -f "$plotname" ]; then
#     python3 ${SCRIPT_DIR}/plot.py -d ${datafile}                        \
#         -yc "TX_PULLED" -l "From Runtime" -ls solid                     \
#         -yc "RX_PULLED" -l "To Runtime" -ls solid                       \
#         -yc "RX_UNICAST_FAIL" -l "To Runtime (Failed)" -ls solid        \
#         -yc "IOK_SATURATION" -l "Core Saturation" -ls dashed            \
#         -xc $XCOL -xl "$XLABEL" $XMUL                             \
#         -yl "Million pkts/sec" --ymul 1e-6 --ymin 0                     \
#         --twin 4  -tyl "Saturation %" --tymul 100 --tymin 0 --tymax 110 \
#          --size 4.5 3 -fs 11 -of $PLOTEXT  -o $plotname -lt "Shenango I/O Core"
#     if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
# fi
# files="$files $plotname"

# # Plot runtime stats
# plotname=${PLOTDIR}/${name}_runtime.$PLOTEXT
# if [[ $FORCE ]] || [ ! -f "$plotname" ]; then
#     python3 ${SCRIPT_DIR}/plot.py -d ${datafile}                \
#         -yc "rxpkt" -l "From I/O Core" -ls solid                \
#         -yc "txpkt" -l "To I/O Core" -ls solid                  \
#         -yc "drops" -l "Pkt drops" -ls solid                    \
#         -yc "cpupct" -l "CPU Utilization" -ls dashed            \
#         -xc $XCOL -xl "$XLABEL" $XMUL                     \
#         -yl "Million pkts/sec" --ymul 1e-6 --ymin 0             \
#         --twin 4  -tyl "CPU Cores" --tymul 1e-2 --tymin 0       \
#          --size 4.5 3 -fs 11  -of $PLOTEXT  -o $plotname -lt "Shenango Resources"
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
#         -xc $XCOL -xl "$XLABEL" $XMUL                     \
#         -yl "Percent" --ymin 0 --ymax 110                       \
#         --twin 4  -tyl "Million Times" --tymul 1e-6 --tymin 0   \
#          --size 4.5 3 -fs 11  -of $PLOTEXT  -o $plotname -lt "Shenango Scheduler" 
#     if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
# fi
# files="$files $plotname"

# # Combine
# echo $files
plotname=${PLOTDIR}/all_${fsuffix}.$PLOTEXT
montage -tile 3x0 -geometry +5+5 -border 5 $files ${plotname}
display ${plotname} &
rm ${TMPFILE_PFX}*
