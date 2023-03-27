import argparse
import os
import matplotlib.pyplot as plt
import numpy as np
from collections import defaultdict

# time filter
# START = 140     #for 512B vals
# END = 170
START = 90      #for 2kB vals
END = 130

def print_stats(dict, label=None):
    """dict with time as key and list of values as value"""
    print("=== {} stats ===".format(label))

    # uniq count
    count = defaultdict(int)
    nvals = 0
    for time, vals in dict.items():
        # time filter
        if time < START or time > END:
            continue
        for val in vals:
            count[val] += 1
        nvals += len(vals)

    uniq = count.keys()
    print("total: {}, min:{}, max:{}, range:{}, uniq:{}".format(    \
        nvals, min(uniq), max(uniq), max(uniq)-min(uniq), len(uniq)))

    # sort & group into buckets 
    BUCKETS = 100
    freq = sorted(count.values(), reverse=True)
    sums = [sum(arr) for arr in np.array_split(freq, BUCKETS)]
    pdf = np.array(sums) * 100 / nvals
    cdf = np.cumsum(pdf)
    print("pdf: {}".format(pdf))
    print("cdf: {}".format(cdf))


def main():
    parser = argparse.ArgumentParser("Parse and plot recorded memcached access data")
    parser.add_argument('-i', '--input', action='store', help="path to the data file", required=True)
    args = parser.parse_args()

    # read in
    keys = {}
    pages = {}
    nread = 0
    assert os.path.exists(args.input)
    with open(args.input) as f:
        rawdata = f.read().splitlines()
        print("read {} lines".format(len(rawdata)))
        for line in rawdata:
            # example format: time:key,page
            assert(line)
            time = int(line.split(":")[0])
            (key, page) = tuple(line.split(":")[1].split(","))
            if time not in keys:
                keys[time] = []
            if time not in pages:
                pages[time] = []
            keys[time].append(int(key))
            pages[time].append(int(page))
            nread += 1
            if nread % 1000000 == 0:
                print("parsed {} lines".format(nread))
            # if nread > 1000000:
            #     break

    # print stats
    print("total seconds: {}".format(len(keys)))
    print("records every sec: {}".format({t:len(keys[t]) for t in keys}))
    print_stats(keys, "keys")
    print_stats(pages, "pages")


if __name__ == '__main__':
    main()
