#!/bin/bash
# set -e

# Fastswap plots

PLOTEXT=png
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
    # for runcfg in "eden" "eden+evb" "eden+evb+nbh" "eden+evb+nbh+sc"; do
    for runcfg in "fswap"; do

        case $runcfg in
        "fswap")            pattern="12-06"; rmem=fastswap; backend=rdma; cores=5; zipfs=1; desc="herobaseline";;
        "eden")             pattern="12-04"; rmem=eden-bh; backend=rdma; cores=5; zipfs=1; evp=NONE; evb=1; desc="smallhero";;
        "eden+evb")         pattern="12-04"; rmem=eden-bh; backend=rdma; cores=5; zipfs=1; evp=NONE; evb=8; desc="smallhero";;
        "eden+evb+nbh")     pattern="12-04"; rmem=eden; backend=rdma; cores=5; zipfs=1; evp=NONE; evb=8; desc="smallhero";;
        "eden+evb+nbh+sc")  pattern="12-04"; rmem=eden; backend=rdma; cores=5; zipfs=1; evp=SC; evb=8; desc="smallhero";;
        *)                  echo "Unknown config"; exit;;
        esac

        # filter results
        cfg=be${bkend}_cores${cores}_zs${zipfs}_nod${NODIRTY}
        label=$runcfg
        datafile=$plotdir/data_${cfg}_${runcfg}
        descopt=
        evbopt=
        rmemopt=
        evpopt=
        nodopt=
        if [[ $desc ]]; then descopt="-d=$desc";    fi
        if [[ $evb ]];  then evbopt="-evb=$evb";    fi
        if [[ $evp ]];  then evpopt="-evp=$evp";    fi
        if [[ $rmem ]];  then rmemopt="-r=$rmem";   fi
        if [[ $NODIRTY ]]; then nodopt="-nod=${NODIRTY}"; fi
        if [[ $FORCE ]] || [ ! -f "$datafile" ]; then
            bash ${SCRIPT_DIR}/show.sh -cs="$pattern" -be=$backend -c=$cores -of=$datafile  \
                -zs=${zipfs} -be=${bkend} ${descopt} ${evbopt} ${rmemopt} ${evpopt} ${nodopt}
        fi

        # compute and add normalized throughput column
        if [[ $NORMALIZE ]]; then
            maxput=$(csv_column_max "$datafile" "Achieved")
            echo $maxput
            xputnorm=$(csv_column "$datafile" "Achieved" | awk '{ if($1) print $1/'$maxput'; else print ""; }')
            echo -e "XputNorm\n${xputnorm}" > ${TMP_FILE_PFX}normxput
            paste -d, $datafile ${TMP_FILE_PFX}normxput > ${TMP_FILE_PFX}normdata
            mv ${TMP_FILE_PFX}normdata $datafile
        fi

        plots="$plots -d $datafile -l $label"
        cat $datafile
    done

    #plot xput
    XPUTCOL="Achieved"
    YLIMS="--ymin 0 --ymax 3.5"
    YLABEL="Xput MOPS"
    YMUL="--ymul 1e-6"
    if [[ $NORMALIZE ]]; then
        XPUTCOL="XputNorm"
        YLIMS="--ymin 0 --ymax 1.2"
        YLABEL="Normalized Xput"
        YMUL=
    fi
    plotname=${plotdir}/xput_${cfg}.${PLOTEXT}
    if [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
        python3 ${ROOTDIR}/scripts/plot.py ${plots}             \
            -yc ${XPUTCOL} -yl "${YLABEL}" ${YMUL} ${YLIMS}     \
            -xc "LMem%" -xl "Local Mem (%)"                     \
            --size 4.5 3 -fs 12 -of $PLOTEXT -o $plotname
    fi
    files="$files $plotname"

    #plot faults
    YLIMS="--ymin 0 --ymax $((100*cores))"
    plotname=${plotdir}/rfaults_${cfg}.${PLOTEXT}
    if [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
        python3 ${ROOTDIR}/scripts/plot.py ${plots}                     \
            -yc "Faults" -yl "Faults KOPS" --ymul 1e-3 ${YLIMS}         \
            -xc "LMem%" -xl "Local Mem (%)"                             \
            --size 4.5 3 -fs 12 -of $PLOTEXT -o $plotname
    fi
    files="$files $plotname"

    # Hit ratio
    YLIMS="--ymin 0 --ymax 100"
    plotname=${plotdir}/hitr_${cfg}.${PLOTEXT}
    if [[ $FORCE_PLOTS ]] || [ ! -f "$plotname" ]; then
        python3 ${ROOTDIR}/scripts/plot.py ${plots}                     \
            -yc "HitR" -yl "Hit Ratio %" ${YLIMS}                       \
            -xc "LMem%" -xl "Local Mem (%)"                             \
            --size 4.5 3 -fs 12 -of $PLOTEXT -o $plotname
    fi
    files="$files $plotname"

    # Combine
    plotname=${plotdir}/${cfg}.$PLOTEXT
    montage -tile 3x0 -geometry +5+5 -border 5 $files ${plotname}
    display ${plotname} &
fi

# debugging performance with xput time series
if [ "$PLOTID" == "2" ]; then
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
    runs="run-12-10-00-58-46"
    
    # statistic
    COLNAME=TX_PULLED; LABEL="Xput"
    # COLNAME=RX_PULLED

    # for each run
    for exp in `echo "$runs"`; do
        plots=

        samples=$(cat ${DATADIR}/$exp/settings | grep "samples:" | awk -F: '{ print $2 }')
        for sid in `seq 0 1 "$samples"`; do
            iokin=${DATADIR}/${exp}/iokernel.log
            iokout=${DATADIR}/${exp}/iokstats_parsed_s${sid}
            rstart=$(cat ${DATADIR}/$exp/sample${sid}_start_time 2>/dev/null)
            rend=$(cat ${DATADIR}/$exp/sample${sid}_end_time 2>/dev/null)
            if [ ! -f "$f" ]; then
                python ${ROOT_SCRIPTS_DIR}/parse_shenango_iok.py -i ${iokin} -o ${iokout}   \
                    -st=${rstart} -et ${rend} 
            fi

            # echo $f, $sid
            plots="$plots -d $iokout -l $sid"
        done

        #plot time series
        YLIMS="--ymin 0 --ymax 2"
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
        -xc "System" -xl " " --xstr                         \
        --size 5 5 -fs 12 -of $PLOTEXT -o $plotname
    display ${plotname} &
fi

# cleanup
rm -f ${TMP_FILE_PFX}*