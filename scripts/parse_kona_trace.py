#
# Parses userfaultfd addresses raw output data
# and cleans it for charts
#

import os
import argparse
import glob
from enum import Enum

class Fault:
    page = None
    seqid = None
    type = None 
    stage = None 
    flags = None
    channel = None
    location = None

class FaultStage(Enum):
    READ = "read"
    STARTED = "start"
    TRANSITED = "transit"
    FINISHED = "done"
    def __str__(self):  return self.value
def parse_stage(stage):
    if stage == 0:      return FaultStage.READ
    elif stage == 1:    return FaultStage.STARTED
    elif stage == 50:   return FaultStage.TRANSITED
    elif stage == 255:  return FaultStage.FINISHED
    else:               raise 

def main():
    parser = argparse.ArgumentParser("Visualize kona fault trace")
    parser.add_argument('-n', '--name', action='store', help='Exp (directory) name')
    parser.add_argument('-d', '--dir', action='store', help='Path to data dir', default="./data")
    args = parser.parse_args()
    
    expname = args.name
    if not expname:  
        subfolders = glob.glob(args.dir + "/*/")
        latest = max(subfolders, key=os.path.getctime)
        expname = os.path.basename(os.path.split(latest)[0])
    dirname = os.path.join(args.dir, expname)

    faults = []
    pages = {}
    channels = {}
    header = ("trace,page,type,stage,flags,channel,location").split(",")
    COL_IDX = {k: v for v, k in enumerate(header)}
    seqid = 0
    with open("{}/memcached.out".format(dirname), 'r') as f:
        lines = f.read().splitlines()
        for line in lines:
            (time, log) = line.split(" ", 1)
            if "trace," not in log: 
                continue
            values = log.split(",")
            if values[1] == header[1]:  # header
                continue    
            page = values[COL_IDX["page"]]
            fault = Fault() 
            fault.seqid = seqid
            fault.page = page
            fault.type = "scheduler" if int(values[COL_IDX["type"]]) else "kernel"
            fault.stage = parse_stage(int(values[COL_IDX["stage"]]))
            fault.flags = int(values[COL_IDX["flags"]])
            fault.channel = int(values[COL_IDX["channel"]])
            fault.location = int(values[COL_IDX["location"]])
            seqid += 1
            if page not in pages:
                pages[page] = []
            pages[page].append(fault)
            faults.append(fault)
            # break
    # print(len(pages), len(faults))

    # # 1. print tail of the trace
    # i = len(faults) - 100
    # while i < len(faults):
    #     print("{},{},{},{},{},{}".format(faults[i].page, faults[i].type, faults[i].stage, 
    #         faults[i].flags, faults[i].channel, faults[i].location))
    #     i += 1

    # 2. make sure no fault is left hanging
    outstanding = set()
    for f in faults:
        key = f.page + ":" + f.type + ":" + str(f.flags) 
                # (str(f.channel) if f.type == "scheduler" else "0")
        print(key)
        if f.stage == FaultStage.STARTED:
            # assert key not in outstanding
            outstanding.add(key)
        if f.stage == FaultStage.FINISHED and f.location != 7:
            assert key in outstanding
            outstanding.remove(key)
    print(len(outstanding))

    # outfile = os.path.join(outdir, "counts")
    # with open(outfile, "w") as f:
    #     f.write("time,rfaults,wfaults,wpfaults,evictions\n")
    #     for time, rcount, wcount, wpcount, ecount in counts:
    #         f.write("{},{},{},{},{}\n".format(time, rcount, wcount, wpcount, ecount))

if __name__ == '__main__':
    main()
