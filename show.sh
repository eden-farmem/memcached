#!/bin/bash
# set -e
#
# Show info on past (good) runs
# For previous data, activate "data" repo in git submodules (.gitmodules)
#

usage="\n
-s, --suffix \t\t a plain suffix defining the set of runs to show\n
-cs, --csuffix \t\t same as suffix but a more complex one (with regexp pattern)\n"

HOST="sc2-hs2-b1630"
CLIENT="sc2-hs2-b1632"
SCRIPT_DIR=`dirname "$0"`

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

OUT=`echo Exp,Dir,Kona Mem,EvThr,EvDThr,EvBSz,Cores,Mpps,Prot,Comments`
for exp in $LS_CMD; do
    # Data from config.json
    echo $exp
    f="$exp/config.json"
    dirname=$(basename `dirname $f`)
    name=`jq '.name' $f | tr -d '"'`
    desc=`jq '.desc' $f | tr -d '"'`
    konamem=`jq '.apps."'$HOST'" | .[] | select(.name=="memcached") | .kona.mlimit' $f`
    if [ $konamem == "null" ]; then    konamem_mb="-";
    else    konamem_mb=`echo $konamem | awk '{ printf "%-4d MB", $1/1000000 }'`;     fi
    konaet=`jq '.apps."'$HOST'" | .[] | select(.name=="memcached") | .kona.evict_thr' $f`
    konaedt=`jq '.apps."'$HOST'" | .[] | select(.name=="memcached") | .kona.evict_done_thr' $f`
    konaebs=`jq '.apps."'$HOST'" | .[] | select(.name=="memcached") | .kona.evict_batch_sz' $f`
    sthreads=`jq '.apps."'$HOST'" | .[] | select(.name=="memcached") | .threads' $f`
    prot=`jq -r '.clients[][0] | select(.app=="synthetic") | .transport' $f`
    nconns=`jq '.clients[][0] | select(.app=="synthetic") | .client_threads' $f`
    mpps=`jq '.clients[][0] | select(.app=="synthetic") | .mpps' $f`
    desc=`jq '.desc' $f` 

    # Print all
    LINE=`echo $name,$dirname,$konamem_mb,$konaet,$konaedt,$konaebs,$sthreads,$mpps,$prot,$desc`
    OUT=`echo -e "${OUT}\n${LINE}"`
done

echo "$OUT" | column -s, -t