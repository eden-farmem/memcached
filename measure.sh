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
# WARMUP="--warmup"

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

desc="nopie"
for tries in 1; do 
    for cores in 4; do
        # for zs in 0.1 0.5 1; do 
        for zs in 1; do 
            # for cfg in "kona" "apf-sync" "apf-async"; do
            for cfg in "kona"; do
                OPTS=
                OPTS="$OPTS --nopie"    #no ASLR

                case $cfg in
                "vanilla")          OPTS=;;
                "kona")             OPTS="$OPTS --kona";;
                "apf-sync")         OPTS="$OPTS --kona -pf=SYNC";;
                "apf-async")        OPTS="$OPTS --kona -pf=ASYNC";;
                *)                  echo "Unknown fault kind"; exit;;
                esac

                bash run.sh ${OPTS} --force --buildonly #rebuild
                # for mem in `seq 600 200 2000`; do
                for mem in 1000; do
                    check_for_stop
                    
                    #determine mpps
                    mpps=1
                    if [ $mem -gt 1000 ]; then   mpps=1.5;  fi
                    if [ $mem -gt 1200 ]; then   mpps=2;    fi
                    if [ $mem -gt 1400 ]; then   mpps=2.5;  fi
                    if [ $mem -gt 1600 ]; then   mpps=3;    fi
                    if [ $mem -gt 1800 ]; then   mpps=4;    fi
                    # if [ $mem -eq 500 ]; then
                    #     mpps=0.5
                    #     if [ $cores -gt 8 ]; then   mpps=0.75;  fi
                    #     if [ $cores -gt 8 ]; then   mpps=1;     fi
                    # fi 
                    # if [ $mem -eq 1000 ]; then
                    #     mpps=1
                    #     if [ $cores -gt 8 ]; then   mpps=1.5;   fi
                    #     if [ $cores -gt 8 ]; then   mpps=2;     fi
                    # fi 
                    lmem=$((mem*1000000))

                    echo "Running ${cores} cores, ${mem} mem, zipfs ${zs}, mpps ${mpps}"
                    bash run.sh ${OPTS} ${FFLAG} -c=$cores -lm=${lmem} ${WARMUP} \
                        -d="""${desc}""" -fl="""${CFLAGS}""" -zs=${zs} -ld=${mpps}
                    echo "return code: $?"
                    sleep 30
                done
            done
        done
    done
done

# desc="paper-cores"
# for tries in 1; do 
#     # for cores in 1 2 3 4 5; do
#     for cores in 5; do
#         # for zs in 0.1 0.5 1; do 
#         for zs in 1; do 
#             # for cfg in "kona" "apf-sync" "apf-async"; do
#             for cfg in "kona"; do
#                 OPTS=
#                 # OPTS="$OPTS --nopie"    #no ASLR

#                 case $cfg in
#                 "vanilla")          OPTS=;;
#                 "kona")             OPTS="$OPTS --kona";;
#                 "apf-sync")         OPTS="$OPTS --kona -pf=SYNC";;
#                 "apf-async")        OPTS="$OPTS --kona -pf=ASYNC";;
#                 *)                  echo "Unknown fault kind"; exit;;
#                 esac

#                 bash run.sh ${OPTS} --force --buildonly #rebuild
#                 # for mem in `seq 400 200 2000`; do
#                 for mem in 500 1000; do
#                     check_for_stop
                    
#                     #determine mpps
#                     mpps=1
#                     if [ $mem -gt 500 ]; then    mpps=1;     fi
#                     if [ $mem -gt 1000 ]; then   mpps=1.5;  fi
#                     if [ $mem -gt 1200 ]; then   mpps=2;    fi
#                     if [ $mem -gt 1400 ]; then   mpps=2.5;  fi
#                     if [ $mem -gt 1600 ]; then   mpps=3;    fi
#                     if [ $mem -gt 1800 ]; then   mpps=4;    fi
#                     lmem=$((mem*1000000))

#                     echo "Running ${cores} cores, ${mem} mem, zipfs ${zs}, mpps ${mpps}"
#                     bash run.sh ${OPTS} ${FFLAG} -c=$cores -lm=${lmem} ${WARMUP} \
#                         -d="""${desc}""" -fl="""${CFLAGS}""" -zs=${zs} -ld=${mpps}
#                     echo "return code: $?"
#                     sleep 30
#                 done
#             done
#         done
#     done
# done

# cleanup
rm -f ${TMP_PFX}*
rm -f __running__