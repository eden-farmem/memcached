#!/bin/bash
# set -e
#
# Show info on past (good) runs
# For previous data, activate "data" repo in git submodules (.gitmodules)
#

usage="\n
-s, --suffix \t\t a plain suffix defining the set of runs to show\n
-cs, --csuffix \t\t same as suffix but a more complex one (with regexp pattern)\n
-c, --cores \t\t results filter: == cores\n
-nk, --nkeys \t\t results filter: == nkeys\n
-lm, --lmem \t\t results filter: == localmem\n
-be, --backend \t results filter: == backend\n
-pf, --pgfaults \t results filter: == pgfaults\n
-d, --desc \t\t results filter: contains desc\n
-f, --force \t\t remove any cached data and parse from scratch\n"

HOST="sc2-hs2-b1630"
CLIENT="sc2-hs2-b1632"
SCRIPT_PATH=`realpath $0`
SCRIPT_DIR=`dirname ${SCRIPT_PATH}`
DATADIR="${SCRIPT_DIR}/data"
ROOT_DIR="${SCRIPT_DIR}/../../"
ROOT_SCRIPTS_DIR="${ROOT_DIR}/scripts/"
TRASH="${DATADIR}/trash"
RAMPUP_SECS=4

source ${ROOT_SCRIPTS_DIR}/utils.sh

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

    -of=*|--outfile=*)
    OUTFILE="${i#*=}"
    ;;

    -rm|--remove)
    DELETE=1
    ;;

    -f|--force)
    FORCE=1
    ;;

    # OUTPUT FILTERS
    -c=*|--cores=*)
    CORES="${i#*=}"
    ;;

    -t=*|--threads=*)
    THREADS="${i#*=}"
    ;;

    -lm=*|--lmem=*)
    LOCALMEM="${i#*=}"
    ;;

    -be=*|--backend=*)
    BACKEND="${i#*=}"
    ;;

    -pf=*|--pgfaults=*)
    PGFAULTS="${i#*=}"
    ;;

    -zs=*|--zipfs=*)
    ZIPFS="${i#*=}"
    ;;

    -d=*|--desc=*)
    DESC="${i#*=}"
    ;;

    -*|--*)     # unknown option
    echo "Unknown Option: $i"
    echo -e $usage
    exit
    ;;

    *)          # take any other option as simple suffix     
    SUFFIX="${i}"
    ;;

esac
done

if [[ $SUFFIX ]]; then 
    LS_CMD=`ls -d1 data/run-${SUFFIX}*/`
    SUFFIX=$SUFFIX
elif [[ $CSUFFIX ]]; then
    LS_CMD=`ls -d1 data/*/ | grep -e "$CSUFFIX"`
    SUFFIX=$CSUFFIX
else 
    SUFFIX=$(date +"%m-%d")     # default to today
    LS_CMD=`ls -d1 data/run-${SUFFIX}*/`
fi
# echo $LS_CMD

for exp in $LS_CMD; do
    # echo $exp
    f="$exp/config.json"
    dirname=$(basename `dirname $f`)
    name=`jq '.name' $f | tr -d '"'`
    desc=`jq '.desc' $f | tr -d '"'`
    localmem=`jq '.apps."'$HOST'" | .[] | select(.name=="memcached") | .kona.mlimit' $f | awk '{ printf $1/1000000 }'`
    konaet=`jq '.apps."'$HOST'" | .[] | select(.name=="memcached") | .kona.evict_thr' $f`
    konaedt=`jq '.apps."'$HOST'" | .[] | select(.name=="memcached") | .kona.evict_done_thr' $f`
    konaebs=`jq '.apps."'$HOST'" | .[] | select(.name=="memcached") | .kona.evict_batch_sz' $f`
    cores=`jq '.apps."'$HOST'" | .[] | select(.name=="memcached") | .threads' $f`
    transport=`jq -r '.clients[][0] | select(.app=="synthetic") | .transport' $f`
    nconns=`jq '.clients[][0] | select(.app=="synthetic") | .client_threads' $f`
    offered=`jq '.clients[][0] | select(.app=="synthetic") | .mpps' $f`

    backend=$(cat $exp/settings | grep "backend" | awk -F: '{ print $2 }')
    pgfaults=$(cat $exp/settings | grep "pgfaults" | awk -F: '{ print $2 }')
    desc=$(cat $exp/settings | grep "desc" | awk -F: '{ print $2 }')
    backend=${backend:-none}
    pgfaults=${pgfaults:-none}

    # apply filters
    if [[ $CORES ]] && [ "$CORES" != "$cores" ];            then    continue;   fi
    if [[ $LOCALMEM ]] && [ "$LOCALMEM" != "$localmem" ];   then    continue;   fi
    if [[ $BACKEND ]] && [ "$BACKEND" != "$backend" ];      then    continue;   fi
    if [[ $PGFAULTS ]] && [ "$PGFAULTS" != "$pgfaults" ];   then    continue;   fi
    if [[ $ZIPFS ]] && [ "$ZIPFS" != "$zipfs" ];            then    continue;   fi
    if [[ $DESC ]] && [[ "$desc" != "$DESC"  ]];            then    continue;   fi

    # gather numbers kona + iok
    preload_start=$(cat $exp/preload_start_time 2>/dev/null)
    preload_end=$(cat $exp/preload_end_time 2>/dev/null)
    ptime=$((preload_end-preload_start))

    rstart=$(cat $exp/sample1_start_time 2>/dev/null)
    if [[ $rstart ]]; then rstart=$((rstart+RAMPUP_SECS));  fi
    rend=$(cat $exp/sample1_end_time 2>/dev/null)
    if [[ $rend ]]; then  rend=$((rend-1)); fi
    rtime=$((rend-rstart))

    if [[ $FORCE ]]; then 
        # remove any cached data
        rm -f ${exp}/kona_counters_parsed
        rm -f ${exp}/kona_profiler_parsed
        rm -f ${exp}/iokstats_parsed
    fi

    # kona counters
    konastatsout=${exp}/kona_counters_parsed
    konastatsin=${exp}/kona_counters.out 
    if [ ! -f $konastatsout ] && [ -f $konastatsin ] && [[ $rstart ]] && [[ $rend ]]; then 
        python ${ROOT_SCRIPTS_DIR}/parse_kona_counters.py -i ${konastatsin} \
            -st=${rstart} -et ${rend} -o ${konastatsout}
    fi
    faultsr=$(csv_column_mean "$konastatsout" "n_faults_r")
    faultsw=$(csv_column_mean "$konastatsout" "n_faults_w")
    faultswp=$(csv_column_mean "$konastatsout" "n_faults_wp")
    afaultsr=$(csv_column_mean "$konastatsout" "n_afaults_r")
    faults=$((faultsr+faultsw+faultswp))

    # kona profiler
    konaprofout=${exp}/kona_profiler_parsed
    konaprofin=${exp}/kona_profiler.out 
    if [ ! -f $konaprofout ] && [ -f $konaprofin ] && [[ $rstart ]] && [[ $rend ]]; then 
        python ${ROOT_SCRIPTS_DIR}/parse_kona_profiler.py -i ${konaprofin} \
            -st=${rstart} -et ${rend} -o ${konaprofout}
    fi

    # iok counters
    iokin=${exp}/iokernel.$HOST.log
    iokout=${exp}/iokstats_parsed
    if [ ! -f $iokout ] && [ -f $iokin ] && [[ $rstart ]] && [[ $rend ]]; then 
        python ${ROOT_SCRIPTS_DIR}/parse_shenango_iok.py -i ${iokin} -o ${iokout}   \
            -st=${rstart} -et ${rend} 
    fi
    iokoffered=$(csv_column_mean "$iokout" "RX_PULLED")
    iokachieved=$(csv_column_mean "$iokout" "TX_PULLED")
    iokcpu=$(csv_column_mean "$iokout" "IOK_SATURATION")

    # write
    HEADER="Exp";                   LINE="$name";
    HEADER="$HEADER,Backend";       LINE="$LINE,${backend}";
    HEADER="$HEADER,PFType";        LINE="$LINE,${pgfaults}";
    HEADER="$HEADER,CPU";           LINE="$LINE,${cores}";
    HEADER="$HEADER,LocalMem";      LINE="$LINE,${localmem}";
    # HEADER="$HEADER,ZipfS";         LINE="$LINE,${zipfs}";
    HEADER="$HEADER,PreloadTime";   LINE="$LINE,${ptime}";
    HEADER="$HEADER,Runtime";       LINE="$LINE,${rtime}";
    # HEADER="$HEADER,Xput";          LINE="$LINE,${xput:-}";
    # HEADER="$HEADER,XputPerCore";   LINE="$LINE,${xputpercore}";

    # KONA
    HEADER="$HEADER,Faults";        LINE="$LINE,${faults}";
    HEADER="$HEADER,ReadPF";        LINE="$LINE,${faultsr}";
    HEADER="$HEADER,ReadAPF";       LINE="$LINE,${afaultsr}";
    HEADER="$HEADER,WritePF";       LINE="$LINE,${faultsw}";
    HEADER="$HEADER,WPFaults";      LINE="$LINE,${faultswp}";

    # IOK
    HEADER="$HEADER,IOK_RX";        LINE="$LINE,${iokoffered}";
    HEADER="$HEADER,IOK_TX";        LINE="$LINE,${iokachieved}";
    HEADER="$HEADER,IOK_CPU";       LINE="$LINE,${iokcpu}";

    HEADER="$HEADER,Desc";          LINE="$LINE,${desc:0:30}";    
    OUT=`echo -e "${OUT}\n${LINE}"`

    if [[ $DELETE ]]; then 
        mkdir -p ${TRASH}
        mv ${exp} ${TRASH}/
    fi
done

if [[ $OUTFILE ]]; then 
    echo "${HEADER}${OUT}" > $OUTFILE
    echo "wrote results to $OUTFILE"
else
    echo "${HEADER}${OUT}" | column -s, -t -n
fi

if [[ $DELETE ]]; then 
    echo "trashed these runs at ${TRASH}; clean it up if needed"
fi