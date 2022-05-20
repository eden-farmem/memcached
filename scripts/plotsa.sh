#!/bin/bash
set -e 
#
# Plot fault/eviction addresses for a single run
#

PLOTEXT=png
DATADIR=data
GLOBALPLOTDIR=plots
HOST_CORES_PER_NODE=28
HOST="sc2-hs2-b1630"
CLIENT="sc2-hs2-b1632"

usage="\n
-n, --name \t\t\t experiment to consider\n
-f, --force \t\t\t force re-summarize results\n
-a, --annotate \t\t mark charts with relevant text annotations\n
-d, --display \t\t\t display individal plots\n
-fp,  --force-plots \t\t force re-generate just the plots\n
-ppo, --plot-page-offset \t plot addresses' offset in page\n
-pg, --plot-gap \t\t plot gap between successive addrs\n
-pio, --plot-item-offset \t plot addresses' offset in a KV item if item addrs are available\n,
-piot, --plot-item-offset2 \t same as -pio but item addrs are estimated from slab addrs\n,
-cdf \t\t\t\t plot CDF instead of scatter plot over time"

# Defaults
YCOL="addr"
YLABEL="Faulted Pages"
XLIMS="--xmin 0 --xmax 110"
# XLIMS="--xmin 0"
# YLIMS="--ymin 0 --ymax 2e9"
TYPE="scatter"


for i in "$@"
do
case $i in
    -n=*|--name=*)
    NAME="${i#*=}"
    ;;

    -f|--force)
    FORCE=1
    ;;

    -a|--annotate)
    ANNOTATE=1
    ;;

    -d|--display)
    DISPLAY_EACH=1
    ;;

    -fp|--force-plots)
    FORCE_PLOTS=1
    ;;

    -ppo|--plot-page-offset)
    YCOL="pgofst"
    YLABEL="Page Offset"
    ;;
    
    -pg|--plot-gap) 
    YCOL="gap"
    YLABEL="Gap"
    ;;
    
    -pio|--plot-item-offset)
    YCOL="itofst"
    YLABEL="Item Offset"
    ;;

    -piot|--plot-item-offset-tentative)
    YCOL="itofst2"
    YLABEL="Item Offset (Tentative)"
    ;;

    -cdf)
    CDF=1
    TYPE="cdf"
    ;;

    -or|--onlyrun)
    ARGS="--onlyrun"
    ;;

    *)                      # unknown option
    echo "Unkown Option: $i"
    echo -e $usage
    exit
    ;;
esac
done

# Prev runs
# # expname="run-10-17-21-19"     # .001 Mpps
# # expname="run-10-19-13-22"       # 2 Mpps
# # expname="run-10-23-22-50"       # 2 mpps, with evict addrs
# # expname="run-11-13-12-12"       # 0.001 Mpps, no workload
# # expname="run-11-13-12-20"       # 2 Mpps, ET=0.99
# # expname="run-11-13-13-19"       # 2 Mpps, ET=0.8
# # expname="run-11-13-14-00"       # .1 Mpps

# Exp run, pick latest by default
latest_dir_path=$(ls -td -- $DATADIR/*/ | head -n 1)
name=${NAME:-$(basename $latest_dir_path)}
echo "Working on experiment:" $name
exp=$DATADIR/$name
SCRIPT_DIR=`dirname "$0"`

# summarize results
datadir=$exp/addrs
if [[ $FORCE ]] || [ ! -d $datadir ]; then
    python ${SCRIPT_DIR}/parse_addr_data.py -n ${name} --offset ${ARGS}
fi

ANNOTATE=1      #Default
checkpts=$datadir/checkpoints
if [[ $ANNOTATE ]] && [ -f $checkpts ]; then 
    VLINES="--vlinesfile $checkpts"
fi

PLOTDIR=$exp/plots
mkdir -p ${PLOTDIR}

files=
datafile=${datadir}/rfaults
plotname=${PLOTDIR}/rfaults.${PLOTEXT}
if [[ $FORCE ]] || [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
    if [[ $CDF ]]; then         
        python3 ${SCRIPT_DIR}/plot.py -z cdf -d ${datafile}         \
            -yc ${YCOL} -xl "Read $YLABEL"                          \
            --size 6 3 -of $PLOTEXT -o $plotname -fs 11 -nm
    else
        python3 ${SCRIPT_DIR}/plot.py -z scatter -d ${datafile}     \
            -yc ${YCOL} -yl "Read $YLABEL" ${YLIMS}                 \
            -xc "time" ${XLIMS}             $VLINES                 \
            --size 6 3 -of $PLOTEXT -o $plotname -fs 11
    fi
    if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
fi
files="$files $plotname"

datafile=${datadir}/wfaults
plotname=${PLOTDIR}/wfaults.${PLOTEXT}
if [[ $FORCE ]] || [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
    if [[ $CDF ]]; then         
        python3 ${SCRIPT_DIR}/plot.py -z cdf -d ${datafile}         \
            -yc ${YCOL} -xl "Write $YLABEL"                         \
            --size 6 3 -of $PLOTEXT -o $plotname -fs 11 -nm
    else
        python3 ${SCRIPT_DIR}/plot.py -z scatter -d ${datafile}     \
            -yc ${YCOL} -yl "Write $YLABEL" ${YLIMS}                \
            -xc "time" ${XLIMS}             $VLINES                 \
            --size 6 3 -of $PLOTEXT -o $plotname -fs 11
    fi
    if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
fi
files="$files $plotname"

datafile=${datadir}/wpfaults
plotname=${PLOTDIR}/wpfaults.${PLOTEXT}
if [[ $FORCE ]] || [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
    if [[ $CDF ]]; then         
        python3 ${SCRIPT_DIR}/plot.py -z cdf -d ${datafile}         \
            -yc ${YCOL} -xl "WProtect $YLABEL"                      \
            --size 6 3 -of $PLOTEXT -o $plotname -fs 11 -nm
    else
        python3 ${SCRIPT_DIR}/plot.py -z scatter -d ${datafile}     \
            -yc ${YCOL} -yl "WProtect $YLABEL" ${YLIMS}             \
            -xc "time" ${XLIMS}             $VLINES                 \
            --size 6 3 -of $PLOTEXT -o $plotname -fs 11
    fi
    if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
fi
files="$files $plotname"

# datafile=${datadir}/evictions
# plotname=${PLOTDIR}/evictions.${PLOTEXT}
# if [[ $FORCE ]] || [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
#     if [[ $CDF ]]; then         
#         python3 ${SCRIPT_DIR}/plot.py -z cdf -d ${datafile}         \
#             -yc ${YCOL} -xl "Eviction $YLABEL"                      \
#             --size 6 3 -of $PLOTEXT -o $plotname -fs 11 -nm
#     else
#         python3 ${SCRIPT_DIR}/plot.py -z scatter -d ${datafile}     \
#             -yc ${YCOL} -yl "Eviction $YLABEL" ${YLIMS}             \
#             -xc "time" ${XLIMS}             $VLINES                 \
#             --size 6 3 -of $PLOTEXT -o $plotname -fs 11
#     fi
#     if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
# fi
# files="$files $plotname"

datafile=${datadir}/counts
plotname=${PLOTDIR}/counts.${PLOTEXT}
if [[ $FORCE ]] || [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
    python3 ${SCRIPT_DIR}/plot.py -d ${datafile}            \
        -yc rfaults -yc wfaults -yc evictions -yc wpfaults -yl "Count"   \
        -xc "time" ${XLIMS}             $VLINES             \
        --size 6 3 -of $PLOTEXT -fs 11 -o $plotname
    if [[ $DISPLAY_EACH ]]; then display $plotname &    fi
fi
files="$files $plotname"


# Combine
plotname=${PLOTDIR}/all_${name}_${YCOL}_.$PLOTEXT
if [[ $FORCE ]] || [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
    montage -tile 2x0 -geometry +5+5 -border 5 $files ${plotname}
    cp $plotname $GLOBALPLOTDIR/
fi
display ${plotname} &
