#
# Parses userfaultfd addresses raw output data
# and cleans it for charts
#

import os
import argparse
import re
import glob
from collections import defaultdict
import bisect

CLIENT="sc2-hs2-b1632"
PAGE_OFFSET = 12
ADDR_PATTERN = "^(read|write|eviction|writep) fault at ([a-z0-9]+)$"
CHECKPT_PATTERN = "Checkpoint (\S+):([0-9]+)"
ITEM_PATTERN = "SET new item at 0x([a-z0-9]+)"
CLIENT_LOG = "0-{}.memcached.out".format(CLIENT)
SLAB_CLASS_PATTERN = "slab class\s+([0-9]+): chunk size\s+([0-9]+) perslab\s+([0-9]+)"
NEW_SLAB_PATTERN = "new slab at 0x([a-z0-9]+) for class ([0-9]+)"
ITEM_SLAB_SIZE = 192 #MAGIC

class SlabClass:
    size = None
    per_slab = None

def main():
    parser = argparse.ArgumentParser("Visualize mem access patterns")
    parser.add_argument('-n', '--name', action='store', help='Exp (directory) name')
    parser.add_argument('-d', '--dir', action='store', help='Path to data dir', default="./data")
    parser.add_argument('-of', '--offset', action='store_true', help='Offset addresses', default=False)
    parser.add_argument('-or', '--onlyrun', action='store_true', help='Limit values to only the run duration', default=False)
    args = parser.parse_args()
    
    expname = args.name
    if not expname:  
        subfolders = glob.glob(args.dir + "/*/")
        latest = max(subfolders, key=os.path.getctime)
        expname = os.path.basename(os.path.split(latest)[0])
    dirname = os.path.join(args.dir, expname)

    start = None
    end = None
    kv_slab_class = None
    times = []
    addrs = []
    types = []
    item_addrs = []
    slab_classes = {}
    slabs_addrs = []
    item_addrs_tentative = False
    with open("{}/memcached.out".format(dirname), 'r') as f:
        lines = f.read().splitlines()
        for line in lines:
            (time, log) = line.split(" ", 1)
            
            # Check for printed address
            match = re.search(ADDR_PATTERN, log)
            if not start:   start = int(time)
            if match:
                type_ = match.group(1)
                addr = int(match.group(2), 16)
                page = addr >> PAGE_OFFSET
                times.append(int(time))
                addrs.append(addr)
                types.append(type_)
                end = int(time)

            # Check for KV item addrs
            match = re.search(ITEM_PATTERN, log)
            if match:
                type_ = "item"
                addr = int(match.group(1), 16)
                times.append(int(time))
                addrs.append(addr)
                types.append(type_)
                item_addrs.append(addr)

            match = re.search(SLAB_CLASS_PATTERN, log)
            if match:
                id = int(match.group(1))
                slab_classes[id] = SlabClass()
                slab_classes[id].size = int(match.group(2))
                slab_classes[id].per_slab = int(match.group(3))
                if slab_classes[id].size == ITEM_SLAB_SIZE:
                    kv_slab_class = id

            match = re.search(NEW_SLAB_PATTERN, log)
            if match:
                addr = int(match.group(1), 16)
                id = int(match.group(2))
                assert kv_slab_class is not None, "should have parsed slab classes by now"
                if kv_slab_class == id:
                    slabs_addrs.append(addr)
            
    # Check for checkpoints
    checkpoints = {}
    with open("{}/{}".format(dirname, CLIENT_LOG), 'r') as f:
        lines = f.read().splitlines()
        for line in lines:     
            match = re.match(CHECKPT_PATTERN, line)
            if match:
                label = match.group(1)
                time = int(match.group(2))
                checkpoints[label] = time
    if "PreloadStart" in checkpoints:   start = checkpoints["PreloadStart"]
    if args.onlyrun:
        assert checkpoints and                  \
            "Sample1Start" in checkpoints and   \
            "Sample1End" in checkpoints,       \
            "Could not find start and end times of the run to limit values"
        start = checkpoints["Sample1Start"]
        end = checkpoints["Sample1End"]

    # In a normal run with high load, printing addr of each item is not possible. 
    # So we print slab addrs (less frequent) of KV slab class and estimate item 
    # addrs in those slabs. (We assume that all and only KV items use this 
    # particular slab, which may not be entirely correct.) Also, slabs may be 
    # reassigned between classes but again, just assuming simple case.
    # if slabs_addrs and not item_addrs:
    if slabs_addrs:
        item_addrs = []
        for slab in slabs_addrs:
            offset = 0
            item_size = slab_classes[kv_slab_class].size 
            item_count = slab_classes[kv_slab_class].per_slab
            for _ in range(item_count):
                item_addrs.append(slab + offset)
                offset += ITEM_SLAB_SIZE
            assert offset < 1024*1024, "sanity check! new slab page size is 1 MB"
        item_addrs_tentative = True
    
    print(start, end - start)
    times = [t - start for t in times]
    samples_per_sec = {t:times.count(t) for t in range(max(times))}
    if args.offset:
        min_addr = (min(addrs) >> PAGE_OFFSET) << PAGE_OFFSET
        addrs = [x - min_addr for x in addrs]
        item_addrs = sorted([x - min_addr for x in item_addrs])

    outdir = "{}/addrs/".format(dirname)
    if not os.path.exists(outdir):
        os.makedirs(outdir)
    
    if checkpoints:
        # print(checkpoints)
        with open(os.path.join(outdir, "checkpoints"), "w") as f:
            for pt,time in checkpoints.items():
                if start - 2 <= time <= end + 2:
                    f.write("{},{}\n".format(pt, time-start))
    
    # Write addresses to file
    wfaults = os.path.join(outdir, "wfaults")
    wpfaults = os.path.join(outdir, "wpfaults")
    rfaults = os.path.join(outdir, "rfaults")
    evicts = os.path.join(outdir, "evictions")
    items = os.path.join(outdir, "items")
    header = "time,addr,page,pgofst,gap,itofst{}\n".format("2" if item_addrs_tentative else "")
    last_write = last_writep = last_read = last_evict = last_set = None
    with open(wfaults, "w") as wf, open(wpfaults, "w") as wpf, open(rfaults, "w") as rf, \
            open(evicts, "w") as ef, open(items, "w") as s:
        wf.write(header);   rf.write(header);  wpf.write(header); 
        ef.write(header);   s.write(header);
        step = 0.0
        prev_time = -1
        for time, addr, type_ in zip(times, addrs, types):
            if time in samples_per_sec and samples_per_sec[time]: 
                step += 1.0 / samples_per_sec[time]
            if time != prev_time:   step = 0.0

            # Check if the addr falls in any KV item
            idx = bisect.bisect_right(item_addrs, addr)
            item_offset = (addr - item_addrs[idx - 1])  \
                            if idx and (addr - item_addrs[idx - 1]) <= ITEM_SLAB_SIZE  \
                            else 2 * ITEM_SLAB_SIZE

            if type_ == "read":
                rf.write("{},{},{},{},{},{}\n".format(float(time)+step, addr, 
                    addr >> PAGE_OFFSET, addr & ((1<<PAGE_OFFSET)-1), 
                    addr - last_read if last_read else 0, item_offset))
                last_read = addr
            elif type_ == "write":
                wf.write("{},{},{},{},{},{}\n".format(float(time)+step, addr, 
                    addr >> PAGE_OFFSET, addr & ((1<<PAGE_OFFSET)-1),
                    addr - last_write if last_write else 0, item_offset))
                last_write = addr
            elif type_ == "writep":
                wpf.write("{},{},{},{},{},{}\n".format(float(time)+step, addr, 
                    addr >> PAGE_OFFSET, addr & ((1<<PAGE_OFFSET)-1),
                    addr - last_write if last_write else 0, item_offset))
                last_writep = addr
            elif type_ == "eviction":
                ef.write("{},{},{},{},{},{}\n".format(float(time)+step, addr, 
                    addr >> PAGE_OFFSET, addr & ((1<<PAGE_OFFSET)-1),
                    addr - last_evict if last_evict else 0, item_offset))
                last_evict = addr
            elif type_ == "item":
                s.write("{},{},{},{},{},{}\n".format(float(time)+step, addr, 
                    addr >> PAGE_OFFSET, addr & ((1<<PAGE_OFFSET)-1),
                    addr - last_set if last_set else 0, item_offset))
                last_set = addr
            prev_time = time

    # Count and write stats
    tidx = min(times)
    rcount = wcount = wpcount = ecount = 0
    counts = []
    for t1, type_ in zip(times, types):
        if tidx < t1:
            counts.append((tidx, rcount, wcount, wpcount, ecount))
            rcount = wcount = wpcount = ecount = 0
            tidx += 1
            while tidx < t1:
                counts.append((tidx, 0, 0, 0, 0))
                tidx += 1
        if tidx == t1:
            if type_ == "read":         rcount += 1
            elif type_ == "write":      wcount += 1
            elif type_ == "writep":     wpcount += 1
            elif type_ == "eviction":   ecount += 1
            continue
        assert tidx > t1, "Shouldn't be the case!"

    outfile = os.path.join(outdir, "counts")
    with open(outfile, "w") as f:
        f.write("time,rfaults,wfaults,wpfaults,evictions\n")
        for time, rcount, wcount, wpcount, ecount in counts:
            f.write("{},{},{},{},{}\n".format(time, rcount, wcount, wpcount, ecount))

if __name__ == '__main__':
    main()
