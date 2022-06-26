#!/bin/bash
# set -e

#
# Run Memcached in different settings
# 

usage="\n
-f, --force \t\t force re-run experiments\n
-d, --debug \t\t build debug\n
-h, --help \t\t this usage information message\n"

#Defaults
SCRIPT_DIR=`dirname "$0"`
TMP_PFX=tmp_mcached_
WARMUP="--warmup"

# parse cli
for i in "$@"
do
case $i in
    -f|--force)
    FORCE=1
    FFLAG="--force"
    ;;

    -h | --help)
    echo -e $usage
    exit
    ;;

    *)                      # unknown option
    echo "Unkown Option: $i"
    echo -e $usage
    exit
    ;;
esac
done

# settings
CORES=4
MEM=1000

# create a stop button
touch __running__
check_for_stop() {
    # stop if the fd is removed
    if [ ! -f __running__ ]; then 
        echo "stop requested"   
        exit 0
    fi
}

desc="real"
for cfg in "kona" "apf-sync" "apf-async"; do
    OPTS=
    # OPTS="$OPTS --nopie"    #no ASLR

    case $cfg in
    "kona")             OPTS="$OPTS --kona";;
    "apf-sync")         OPTS="$OPTS --kona -pf=SYNC";;
    "apf-async")        OPTS="$OPTS --kona -pf=ASYNC";;
    *)                  echo "Unknown fault kind"; exit;;
    esac

    bash run.sh ${OPTS} --force --buildonly #rebuild
    for cores in 1; do
        # for mem in `seq 1000 200 2000`; do
        for mem in $MEM; do
            check_for_stop
            lmem=$((mem*1000000))
            echo "Running ${cores} cores, ${mem} mem"
            bash run.sh ${OPTS} ${FFLAG} -c=$cores -lm=${lmem} ${WARMUP} \
                -d="""${desc}""" -fl="""${CFLAGS}""" 
            echo "return code: $?"
            sleep 30
        done
    done
done

# cleanup
rm -f ${TMP_PFX}*
rm -f __running__