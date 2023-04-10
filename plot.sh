#!/bin/bash
# set -e

# Fastswap plots

PLOTEXT=pdf
SCRIPT_PATH=`realpath $0`
SCRIPT_DIR=`dirname ${SCRIPT_PATH}`
ROOTDIR="${SCRIPT_DIR}/../../"
ROOT_SCRIPTS_DIR="${ROOTDIR}/scripts/"
PLOTDIR=${SCRIPT_DIR}/plots
DATADIR=${SCRIPT_DIR}/data
TMP_FILE_PFX=tmp_syn_plot_

source ${ROOT_SCRIPTS_DIR}/utils.sh

usage="\n
-f, --force \t\t force re-summarize data and re-generate plots\n
-fp, --force-plots \t force re-generate just the plots\n
-id, --plotid \t pick one of the many charts this script can generate\n
-r, --run \t run id if focusing on a single run\n
-h, --help \t\t this usage information message\n"

for i in "$@"
do
case $i in
    -f|--force)
    FORCE=1
    FORCE_PLOTS=1
    FORCE_FLAG="-f"
    ;;
    
    -fp|--force-plots)
    FORCE_PLOTS=1
    FORCEP_FLAG="-fp"
    ;;

    -id=*|--fig=*|--plotid=*)
    PLOTID="${i#*=}"
    ;;

    -r=*|--run=*)
    RUNID="${i#*=}"
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

add_plot_group() {
    # filters
    pattern=$1
    backend=$2
    pgfaults=$3
    zparams=$4
    tperc=$5
    cores=$6
    if [[ $7 ]]; then descopt="-d=$7"; fi

    datafile=$plotdir/data_${cores}cores_be${backend}_pgf${pgfaults}_zs${zparams}_tperc${tperc}
    thr=$((cores*tperc))
    if [[ $FORCE ]] || [ ! -f "$datafile" ]; then
        bash ${SCRIPT_DIR}/show.sh -cs="$pattern" -be=$backend -pf=$pgfaults \
            -c=$cores -of=$datafile -t=${thr} -zs=${zparams} ${descopt}
    fi
    plots="$plots -d $datafile"
}

# overall performance
if [ "$PLOTID" == "1" ]; then
    plotdir=$PLOTDIR/$PLOTID
    mkdir -p $plotdir
    plots=
    files=
    NORMALIZE=1
    CORES=5
    NODIRTY=1

    ## data
    plotgroup="fswap-eden"
    for runcfg in "fswap" "eden+bh" "eden" "eden+prio"; do
        LABEL=
        LS=
        CMI=

        case $runcfg in
        # eden vs fastswap
        "fswap")                pattern="03-25"; rmem=fastswap; backend=rdma; cores=5; zipfs=1; desc="newhint"; LS=solid; CMI=1; LABEL="Fastswap";;
        "eden+bh")              pattern="04-01"; rmem=eden-bh; backend=rdma; cores=5; zipfs=1; evp=SC; evprio=no; evb=32; desc="paper"; LS=dashed; CMI=0; LABEL="Eden(BH)";;
        "eden")                 pattern="04-01"; rmem=eden; backend=rdma; cores=5; zipfs=1; evp=SC; evprio=no; evb=32; desc="paper"; LS=solid; CMI=1; LABEL="Eden";;
        "eden+prio")            pattern="04-01"; rmem=eden; backend=rdma; cores=5; zipfs=1; evp=SC; evprio=yes; evb=32; desc="paper"; LS=dashed; CMI=0; LABEL="Eden(Prio)";;
        *)                      echo "Unknown config"; exit;;
        esac

        # filter results
        cfg=be${bkend}_cores${cores}_zs${zipfs}_nod${NODIRTY}
        label=$runcfg
        datafile=$plotdir/data_${LABEL}
        opts=
        if [[ $desc ]]; then opts="$opts -d=$desc";    fi
        if [[ $evb ]];  then opts="$opts -evb=$evb";    fi
        if [[ $evp ]];  then opts="$opts -evp=$evp";    fi
        if [[ $evprio ]]; then opts="$opts --evprio=$evprio";    fi
        if [[ $evprtype ]]; then opts="$opts --evprtype=$evprtype";    fi
        if [[ $lruthr ]]; then opts="$opts --lruthr=$lruthr";    fi
        if [[ $rmem ]];  then opts="$opts -r=$rmem";   fi
        if [[ $NODIRTY ]]; then opts="$opts -nod=${NODIRTY}"; fi
        if [[ $FORCE ]] || [ ! -f "$datafile" ]; then
            echo "LMem%,Xput,XputErr,Faults,FaultsErr,NetReads,NetReadsErr,HitR,Count,System,Backend,EvP,EvB,CPU,Zipfs" > $datafile
            for memp in `seq 10 10 100`; do
                tmpfile=${TMP_FILE_PFX}data
                rm -f ${tmpfile}
                bash ${SCRIPT_DIR}/show.sh -cs="$pattern" -be=$backend -c=$cores -of=$tmpfile   \
                    -zs=${zipfs} -be=${bkend} ${opts} -lmp=${memp}
                cat $tmpfile
                xmean=$(csv_column_mean $tmpfile "Achieved")
                xstd=$(csv_column_stdev $tmpfile "Achieved")
                xnum=$(csv_column_count $tmpfile "Achieved")
                fmean=$(csv_column_mean $tmpfile "Faults")
                fstd=$(csv_column_stdev $tmpfile "Faults")
                netrmean=$(csv_column_mean $tmpfile "NetReads")
                netrstd=$(csv_column_stdev $tmpfile "NetReads")
                hitrmean=$(csv_column_mean $tmpfile "HitR")
                echo ${memp},${xmean},${xstd},${fmean},${fstd},${netrmean},${netrstd},${hitrmean},${xnum},${rmem},${bkend},${evp},${evb},${cores},${zipfs} >> ${datafile}
            done

            # compute and add normalized throughput column
            maxput=$(csv_column_max "$datafile" "Xput")
            echo $maxput
            xputnorm=$(csv_column "$datafile" "Xput" | awk '{ if($1) print $1/'$maxput'; else print ""; }')
            xputerrnorm=$(csv_column "$datafile" "XputErr" | awk '{ if($1) print $1/'$maxput'; else print ""; }')
            echo -e "XputNorm\n${xputnorm}" > ${TMP_FILE_PFX}normxput
            echo -e "XputErrNorm\n${xputerrnorm}" > ${TMP_FILE_PFX}normxputerr
            paste -d, $datafile ${TMP_FILE_PFX}normxput ${TMP_FILE_PFX}normxputerr > ${TMP_FILE_PFX}normdata
            mv ${TMP_FILE_PFX}normdata $datafile
        fi

        label=${LABEL:-$runcfg}
        ls=${LS:-solid}
        cmi=${CMI:-1}
        plots="$plots -d $datafile -l $label -ls $ls -cmi $cmi"
        cat $datafile
    done

    #plot xput
    XPUTCOL="Xput"
    XPUTERR="XputErr"
    YLIMS="--ymin 0 --ymax 4.5"
    YLABEL="MOPS"
    YMUL="--ymul 1e-6"
    XLIMS="--xmin 0 --xmax 110"
    if [[ $NORMALIZE ]]; then
        XPUTCOL="XputNorm"
        XPUTERR="XputErrNorm"
        YLIMS="--ymin 0 --ymax 1.1"
        YLABEL="Normalized Throughput"
        YMUL=
    fi
    plotname=${plotdir}/mcached_xput.${PLOTEXT}
    if [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
        python3 ${ROOTDIR}/scripts/plot.py ${plots}                         \
            -yce ${XPUTCOL} ${XPUTERR} -yl "${YLABEL}" ${YMUL} ${YLIMS}     \
            -xc "LMem%" -xl "Local Memory (%)" ${XLIMS}                     \
            --size 4.5 3 -fs 11 -of $PLOTEXT -o $plotname
    fi
    files="$files $plotname"

    #plot faults
    YLIMS="--ymin 0 --ymax 850"
    plotname=${plotdir}/mcached_netreads.${PLOTEXT}
    if [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
        python3 ${ROOTDIR}/scripts/plot.py ${plots}                     \
            -yce "NetReads" "NetReadsErr" -yl "Remote Page Fetches(KOPS)" --ymul 1e-3 ${YLIMS}   \
            -xc "LMem%" -xl "Local Mem (%)" ${XLIMS}                    \
            --size 4.5 3 -fs 11 -of $PLOTEXT -o $plotname
    fi
    files="$files $plotname"

    # Hit ratio
    YLIMS="--ymin 0 --ymax 100"
    plotname=${plotdir}/mcached_hitrate.${PLOTEXT}
    if [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
        python3 ${ROOTDIR}/scripts/plot.py ${plots}                     \
            -yc "HitR" -yl "Hit Ratio %" ${YLIMS}                       \
            -xc "LMem%" -xl "Local Mem (%)" ${XLIMS}                    \
            --size 4.5 3 -fs 11 -of $PLOTEXT -o $plotname
    fi
    files="$files $plotname"

    # Combine
    plotname=${plotdir}/memcached_all_${plotgroup}.$PLOTEXT
    montage -tile 3x0 -geometry +5+5 -border 5 $files ${plotname}
    display ${plotname} &
fi

# debugging performance with xput time series
if [ "$PLOTID" == "2" ]; then
    PLOTEXT=png
    plotdir=$PLOTDIR/$PLOTID
    mkdir -p $plotdir
    plots=
    files=

    # runs (need all samples parsed beforehand)
    # runs=$(bash show.sh 12-07-1[34] -b -lmp=40 | awk '{ print $1 }' | tail -n+2)
    # runs=$(bash show.sh 12-07-16 -r=none -b | awk '{ print $1 }' | tail -n+2)
    # runs=$(bash show.sh 12-07-17-05 -b -lmp=40 | awk '{ print $1 }' | tail -n+2)
    # runs=$(bash show.sh 12-07 -b -d=small | awk '{ print $1 }' | tail -n+2)
    # runs="run-12-07-23-46-08"
    # runs="run-12-08-02-29-00"
    # runs="run-12-08-12-05-48"
    # runs="run-12-08-05-16-53"
    # runs="run-12-08-13-23-39"
    # runs="run-12-08-14-15-56"
    # runs="run-12-09-19-35-28"
    # runs="run-12-09-19-46-50"
    # runs="run-12-09-19-58-20"
    # runs="run-12-10-00-58-46"
    # runs="run-12-10-01-28-16"
    # runs="run-12-10-15-08-12"
    # runs="run-12-10-15-48-41"
    # runs="run-12-10-16-47-12"
    # runs="run-12-10-17-31-08"
    # runs="run-12-11-12-39-24"
    # runs="run-12-11-13-42-24"
    # runs="run-12-12-10-52-07"
    # runs="run-12-12-10-43-27"
    # runs="run-12-12-11-30-42"
    # runs="run-12-12-11-18-24"
    # runs="run-12-12-12-13-47"
    # runs="run-12-12-12-24-48"
    # runs="run-12-12-12-31-43"
    # runs="run-12-12-14-57-59"
    # runs="run-12-12-15-12-00"
    # runs="run-12-12-15-24-27"
    # runs="run-12-12-15-57-58"
    # runs="run-12-12-16-08-41"
    # runs="run-12-12-16-41-10"
    # runs="run-12-12-16-45-07"
    # runs="run-12-12-17-40-53"
    # runs="run-12-12-17-55-41"
    # runs="run-12-12-18-51-50"
    # runs="run-12-12-18-48-20"
    # runs="run-12-12-20-12-13"
    # runs="run-12-12-20-22-35"
    # runs="run-12-12-20-53-29"
    # runs="run-12-12-20-59-48"
    # runs="run-12-12-21-06-38"
    runs="run-12-12-22-45-29"

    
    # statistic
    COLNAME=TX_PULLED; LABEL="Xput"
    # COLNAME=RX_PULLED

    # for each run
    for exp in `echo "$runs"`; do
        plots=

        samples=$(cat ${DATADIR}/$exp/settings | grep "samples:" | awk -F: '{ print $2 }')
        for sid in `seq 1 1 "$samples"`; do
        # for sid in `seq 0 1 "$samples"`; do
            iokin=${DATADIR}/${exp}/iokernel.log
            iokout=${DATADIR}/${exp}/iokstats_parsed_s${sid}
            rstart=$(cat ${DATADIR}/$exp/sample${sid}_start_time 2>/dev/null)
            rend=$(cat ${DATADIR}/$exp/sample${sid}_end_time 2>/dev/null)
            echo $rstart $rend
            if [ ! -f "$f" ]; then
                python ${ROOT_SCRIPTS_DIR}/parse_shenango_iok.py -i ${iokin} -o ${iokout}   \
                    -st=${rstart} -et ${rend} 
            fi

            # echo $f, $sid
            plots="$plots -d $iokout -l $sid"
        done

        #plot time series
        YLIMS="--ymin 0 --ymax 4"
        YLABEL="${LABEL} MOPS"
        YMUL="--ymul 1e-6"
        plotname=${plotdir}/${COLNAME}_tseries_${exp}.${PLOTEXT}
        if [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
            python3 ${ROOTDIR}/scripts/plot.py ${plots}                 \
                -yc "${COLNAME}" -yl "${YLABEL}" ${YMUL} ${YLIMS}       \
                -xc "time" -xl "Time (s)"                               \
                --size 6 3 -fs 12 -of $PLOTEXT -o $plotname
        fi

        files="$files $plotname"
    done

    # Combine
    plotname=${plotdir}/${COLNAME}_tseries_runs.$PLOTEXT
    montage -tile 0x3 -geometry +5+5 -border 5 $files ${plotname}
    display ${plotname} &
fi

# debugging performance with faults time series
if [ "$PLOTID" == "3" ]; then
    plotdir=$PLOTDIR/$PLOTID
    mkdir -p $plotdir
    plots=
    files=

    # runs (need all samples parsed beforehand)
    runs=$(bash show.sh 12-07-1[34] -b -lmp=40 | awk '{ print $1 }' | tail -n+2)

    # statistic
    COLNAME=faults
    # COLNAME=evict_pages_done

    # for each run
    for exp in `echo "$runs"`; do
        plots=
        for f in `ls ${DATADIR}/${exp}/eden_rmem_parsed_s*`; do 
            sid=$(basename $f | cut -d_ -f4)
            # echo $f, $sid
            plots="$plots -d $f -l $sid"
        done

        #plot time series
        YLIMS="--ymin 0 --ymax 200"
        YLABEL="${COLNAME} KOPS"
        YMUL="--ymul 1e-3"
        plotname=${plotdir}/${COLNAME}_tseries_${exp}.${PLOTEXT}
        if [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
            python3 ${ROOTDIR}/scripts/plot.py ${plots}                 \
                -yc "${COLNAME}" -yl "${YLABEL}" ${YMUL} ${YLIMS}       \
                -xc "time" -xl "Time (s)"                               \
                --size 6 2 -fs 12 -of $PLOTEXT -o $plotname
        fi

        files="$files $plotname"
    done

    # Combine
    plotname=${plotdir}/${COLNAME}_tseries_runs.$PLOTEXT
    montage -tile 0x4 -geometry +5+5 -border 5 $files ${plotname}
    display ${plotname} &
fi

if [ "$PLOTID" == "4" ]; then
    plotdir=$PLOTDIR/$PLOTID
    mkdir -p $plotdir
    plots=
    files=

    plotname=${plotdir}/bar.${PLOTEXT}
    python3 ${ROOTDIR}/scripts/plot.py -z bar -d bar        \
        -yc "Throughput" -yl "Tnroughput (MOPS)" -ym 1e-6   \
        -xc "System" -xl " " --xstr --ylog                  \
        --size 5 5 -fs 12 -of $PLOTEXT -o $plotname
    display ${plotname} &
fi

# cleanup
rm -f ${TMP_FILE_PFX}*