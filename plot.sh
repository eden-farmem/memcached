#!/bin/bash

# Fastswap plots

PLOTEXT=png
SCRIPT_PATH=`realpath $0`
SCRIPT_DIR=`dirname ${SCRIPT_PATH}`
ROOTDIR="${SCRIPT_DIR}/../../"
ROOT_SCRIPTS_DIR="${ROOTDIR}/scripts/"
PLOTDIR=${SCRIPT_DIR}/plots
DATADIR=${SCRIPT_DIR}/data
TMP_FILE_PFX=tmp_mcached_plot_

source ${ROOT_SCRIPTS_DIR}/utils.sh

usage="\n
-f, --force \t\t force re-summarize data and re-generate plots\n
-fp, --force-plots \t force re-generate just the plots\n
-id, --plotid \t pick one of the many charts this script can generate\n
-h, --help \t\t this usage information message\n"

for i in "$@"
do
case $i in
    -f|--force)
    FORCE=1
    FORCE_PLOTS=1
    FORCE_FLAG=" -f "
    ;;
    
    -fp|--force-plots)
    FORCE_PLOTS=1
    FORCEP_FLAG=" -fp "
    ;;

    -id=*|--fig=*|--plotid=*)
    PLOTID="${i#*=}"
    ;;

    *)                      # unknown option
    echo "Unkown Option: $i"
    echo -e $usage
    exit
    ;;
esac
done

# point to last chart if not provided
if [ -z "$PLOTID" ]; then 
    PLOTID=`grep '"$PLOTID" == "."' $0 | wc -l`
    PLOTID=$((PLOTID-1))
fi

mkdir -p $PLOTDIR

# performance of async page faults (with multiple runs for each data point)
## FOR PAPER
if [ "$PLOTID" == "1" ]; then
    plotdir=$PLOTDIR/$PLOTID
    mkdir -p $plotdir
    LMEMCOL=1
    XPUTCOL=2
    PLOTEXT=pdf

    ## data
    # pattern="07-0[34]"; bkend=kona; zipfs=1; cores=4; desc="zipfreal";
    pattern="07-0[56]"; bkend=kona; zipfs=1; cores=4; desc="paper";

    cfg=${cores}cores_be${bkend}_zs${zipfs}_${desc}
    if [[ $desc ]]; then descopt="-d=$desc"; fi

    pgf=none    #baseline
    basefile=$plotdir/data_${cores}cores_pgf${pgf}_${cfg}
    if [[ $FORCE ]] || [ ! -f "$basefile" ]; then
        echo "lmemfr,Xput,XputErr,Faults,FaultsErr,Backend,PFType,CPU,Zipfs" > $basefile
        for mem in `seq 800 200 2000`; do 
            tmpfile=${TMP_FILE_PFX}data
            rm -f ${tmpfile}
            bash ${SCRIPT_DIR}/show.sh -cs="$pattern" -be=$bkend -pf=$pgf -lm=${mem} \
                -c=$cores -of=$tmpfile -zs=${zipfs} ${descopt}
            cat $tmpfile
            memf=$(echo $mem | awk '{ printf "%.2f", $0*1.0/2000 }' )
            xmean=$(csv_column_mean $tmpfile "Achieved")
            xstd=$(csv_column_stdev $tmpfile "Achieved")
            fmean=$(csv_column_mean $tmpfile "Faults")
            fstd=$(csv_column_stdev $tmpfile "Faults")
            # NOTE: changing this ordering may require updating LMEMCOL, XPUTCOL, etc. 
            echo ${memf},${xmean},${xstd},${fmean},${fstd},${bkend},${pgf},${cores},${zipfs} >> ${basefile}
        done
    fi
    cat $basefile | awk -F, '{ print $'$XPUTCOL' }' > ${TMP_FILE_PFX}_baseline_xput
    cat $basefile

    pgf=ASYNC    #upcalls
    upcallfile=$plotdir/data_${cores}cores_pgf${pgf}_${cfg}
    if [[ $FORCE ]] || [ ! -f "$upcallfile" ]; then
        echo "lmemfr,Xput,XputErr,Faults,FaultsErr,Backend,PFType,CPU,Threads,Zipfs" > $upcallfile
        for mem in `seq 800 200 2000`; do 
            tmpfile=${TMP_FILE_PFX}data
            rm -f ${tmpfile}
            bash ${SCRIPT_DIR}/show.sh -cs="$pattern" -be=$backend -pf=$pgf -lm=${mem} \
                -c=$cores -of=$tmpfile -t=${thr} -zs=${zipfs} ${descopt}
            cat $tmpfile
            memf=$(echo $mem | awk '{ printf "%.2f", $0*1.0/2000 }' )
            xmean=$(csv_column_mean $tmpfile "Achieved")
            xstd=$(csv_column_stdev $tmpfile "Achieved")
            fmean=$(csv_column_mean $tmpfile "Faults")
            fstd=$(csv_column_stdev $tmpfile "Faults")
            # NOTE: changing this ordering may require updating LMEMCOL, XPUTCOL, etc. 
            echo ${memf},${xmean},${xstd},${fmean},${fstd},${bkend},${pgf},${cores},${zipfs} >> ${upcallfile}
        done
    fi
    cat $upcallfile | awk -F, '{ print $'$XPUTCOL' }' > ${TMP_FILE_PFX}_upcall_xput
    cat $upcallfile

    # speedup
    speedup=$plotdir/data_speedup_${cores}cores_${cfg}
    cat $basefile | awk -F, '{ print $'$LMEMCOL' }' > ${TMP_FILE_PFX}_lmem
    paste ${TMP_FILE_PFX}_baseline_xput ${TMP_FILE_PFX}_upcall_xput     \
        | awk  'BEGIN  { print "speedup" }; 
                NR>1   { if ($1 && $2)  print ($2-$1)*100/$1 
                        else            print ""    }' > ${TMP_FILE_PFX}_speedup
    paste -d, ${TMP_FILE_PFX}_lmem ${TMP_FILE_PFX}_speedup > ${speedup}
    speedplots="$speedplots -d ${speedup} -l $cores"
    cat $speedup

    # plot xput & speedup
    YLIMS="--ymin 0 --ymax 3500"
    plotname=${plotdir}/xput_${cfg}.${PLOTEXT}
    if [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
        python3 ${ROOT_SCRIPTS_DIR}/plot.py                             \
            -dyce ${basefile} Xput XputErr -ls dashed -l "Original"     \
            -dyce ${upcallfile} Xput XputErr -ls solid -l "Annotated"   \
            -dyce ${speedup} speedup "" -ls dashdot -l "Speedup"        \
            -yl "KOPS" --ymul 1e-3  ${YLIMS}                \
            --twin 3 -tyl "Gain (%)"                        \
            -xc lmemfr -xl "Local Memory Fraction"          \
            --size 5 3.5 -fs 15 -of $PLOTEXT -o $plotname
    fi
    display ${plotname} &

    #plot faults
    YLIMS="--ymin 0 --ymax 150"
    plotname=${plotdir}/faults_$cfg.${PLOTEXT}
    if [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
        python3 ${ROOT_SCRIPTS_DIR}/plot.py                                 \
            -dyce ${basefile} Faults FaultsErr -ls dashed -l "Original"     \
            -dyce ${upcallfile} Faults FaultsErr -ls solid -l "Annotated"   \
            -yl "KFPS" --ymul 1e-3 ${YLIMS}                     \
            -xc lmemfr -xl "Local Memory Fraction"              \
            --size 5 3.5 -fs 15 -of $PLOTEXT -o $plotname
    fi   
    display ${plotname} &
fi

# cleanup
rm -f ${TMP_FILE_PFX}*