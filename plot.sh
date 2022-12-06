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

# performance with kona/page faults
if [ "$PLOTID" == "1" ]; then
    plotdir=$PLOTDIR/$PLOTID
    mkdir -p $plotdir
    plots=
    files=
    NORMALIZE=
    CORES=5
    NODIRTY=0

    ## data
    for runcfg in "eden" "eden+evb" "eden+evb+nbh" "eden+evb+nbh+sc"; do

        case $runcfg in
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
    YLIMS="--ymin 0 --ymax 2.5"
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

# cleanup
rm -f ${TMP_FILE_PFX}*