
# usage: python summary.py <experiment directory>

import enum
import json
import os
import sys
from collections import defaultdict
import re
import argparse
import glob
import numpy as np

NUMA_NODE = 1
IOK_DISPLAY_FIELDS = ["TX_PULLED", "RX_PULLED", "IOK_SATURATION", "RX_UNICAST_FAIL"]
KONA_FIELDS_ACCUMULATED = ["n_faults", "n_faults_r", "n_faults_w", "n_net_page_in", 
    "n_net_page_out", "n_madvise", "n_madvise_fail", "n_rw_fault_q", "n_page_dirty", 
    "n_faults_wp", "n_flush_fail", "n_evictions", "n_afaults_r", "n_afaults_w", "n_afaults"]                            
KONA_DISPLAY_FIELDS = KONA_FIELDS_ACCUMULATED + ["malloc_size", "mem_pressure"]
KONA_DISPLAY_FIELDS_EXTENDED = ["PERF_EVICT_TOTAL", "PERF_EVICT_WP", "PERF_RDMA_WRITE", 
    "PERF_POLLER_READ", "PERF_POLLER_UFFD_COPY", "PERF_HANDLER_RW", "PERF_PAGE_READ", 
    "PERF_EVICT_WRITE", "PERF_HANDLER_FAULT", "PERF_EVICT_MADVISE", 
    "PERF_HANDLER_MADV_NOTIF", "PERF_HANDLER_FAULT_Q"]
RSTAT_DISPLAY_FIELDS = ["rxpkt", "txpkt", "drops", "cpupct", "stolenpct", "migratedpct", 
    "localschedpct", "parks", "rescheds", "pf_retries"]

suppress_warn = False

def parse_int(s):
    try: 
        return int(s)
    except ValueError:
        return None

def percentile(latd, target):
    # latd: ({microseconds: count}, number_dropped)
    # target: percentile target, ie 0.99
    latd, dropped = latd
    count = sum([latd[k] for k in latd]) + dropped
    target_idx = int(float(count) * target)
    curIdx = 0
    for k in sorted(latd.keys()):
        curIdx += latd[k]
        if curIdx >= target_idx:
            return k
    return float("inf")

def read_lat_line(line):
    #line = line.split(" ", 1)[1]
    if line.startswith("Latencies: "):
        line = line[len("Latencies: "):]
    d = {}
    for l in line.strip().split():
        micros, count = l.split(":")
        d[int(micros)] = int(count)
    return d

def read_trace_line(line):
    if line.startswith("Trace: "):
        line = line[len("Trace: "):]
    points = []
    lats = defaultdict(int)
    for l in line.strip().split():
        start, delay, latency = l.split(":")
        if latency != "-1":
            lats[int(latency) // 1000] += 1
        if delay != "-1":
            points.append((int(start), int(latency)))
    return lats, points


# list_of_tuples: [({microseconds: count}, number_dropped)...]
def merge_lat(list_of_tuples):
    dropped = 0
    c = defaultdict(int)
    for s in list_of_tuples:
        for k in s[0]:
            c[k] += s[0][k]
        dropped += s[1]
    return c, dropped


def parse_client_output(filename):
    with open(filename) as f:
        dat = f.read()

    checkpoints = {}
    samples = []
    line_starts = ["Latencies: ", "Trace: ", "zero, ","exponential, ",
                   "bimodal1, ", "constant, ", "Checkpoint "]

    def get_line_start(line):
        for l in line_starts:
            # if line.startswith(l): return l
            if l in line:   return l
        return None

    """Distribution, Target, Actual, Dropped, Never Sent, Median, 90th, 99th, 99.9th, 99.99th, Start"""
    header_line = None
    for line in dat.splitlines():
	#line = line.split(" ", 1)[1]
        line_start = get_line_start(line)
        if not line_start: continue
        if not line.startswith(line_start): line = line[line.find(line_start):]
        if line_start == "Latencies: ":
            samples.append({
                'distribution': header_line[0],
                'offered': int(header_line[1]),
                'achieved': int(header_line[2]),
                'missed': int(header_line[4]),
                'latencies': (read_lat_line(line), int(header_line[3])),
                'time': int(header_line[10]),
            })
        elif line_start == "Trace: ":
            lats, tracepoints = read_trace_line(line)
            samples.append({
                'distribution': header_line[0],
                'offered': int(header_line[1]),
                'achieved': int(header_line[2]),
                'missed': int(header_line[4]),
                'latencies': (lats, int(header_line[3])),
                'tracepoints': tracepoints,
                'time': int(header_line[10]),
            })
        elif line_start == "Checkpoint ":
            match = re.match("Checkpoint (\S+):([0-9]+)", line)
            assert match is not None
            label = match.group(1)
            time = int(match.group(2))
            checkpoints[label] = time
        else:
            # print(header_line)
            header_line = line.strip().split(", ")
            assert len(header_line) > 10 or len(header_line) == 6, line
            if len(header_line) == 6:
                 samples.append({
                 'distribution': header_line[0],
                 'offered': int(header_line[1]),
                 'achieved': 0,
                 'missed': int(header_line[4]),
                 'latencies': ({}, int(header_line[3])),
                 'time': int(header_line[5]),
            })
    if len(samples) == 0 and header_line:
        # If no latencies, just record xput
        samples.append({
            'distribution': header_line[0],
            'offered': int(header_line[1]),
            'achieved': int(header_line[2]),
            'missed': int(header_line[4]),
            'latencies': ({}, int(header_line[3])),
            'time': int(header_line[10]),
        })

    return {"checkpts": checkpoints, "samples": samples}


def merge_sample_sets(a, b):
    samples = []
    # print(len(a),len(b))
    for ea, eb in zip(a, b):
        assert set(ea.keys()) == set(eb.keys())
        assert ea['distribution'] == eb['distribution']
        # assert ea['app'] == eb['app']
        if abs(ea['time'] - eb['time']) >= 2:   print(ea['time'], eb['time'])
        assert abs(ea['time'] - eb['time']) < 2
        newexp = {
            'distribution': ea['distribution'],
            'offered': ea['offered'] + eb['offered'],
            'achieved': ea['achieved'] + eb['achieved'],
            'missed': ea['missed'] + eb['missed'],
            'latencies': merge_lat([ea['latencies'], eb['latencies']]),
            # 'app': ea['app'],
            'time': min(ea['time'], eb['time']),
        }
        if 'tracepoints' in ea:
            newexp['tracepoints'] = ea['tracepoints'] + eb['tracepoints']
        samples.append(newexp)
        assert set(ea.keys()) == set(newexp.keys())
    # print(len(samples))
    return samples

def except_none(func):
	def e(*args, **kwargs):
		try:
			return func(*args, **kwargs)
		except:
			return None
	return e

@except_none
def load_app_output(app, directory, first_sample_time):

    parse_bg_key = {
        'swaptions': ("Swaption per second: ", None),
        'x264': ("/512 frames, ", " fps"),
        'stress': ("fakework rate: ", None)
    }
    #fixme
    if app['app'] not in parse_bg_key.keys():
        return None

    filename = "{}/{}.out".format(directory, app['name'])
    assert os.access(filename, os.F_OK)
    with open(filename) as f:
        bgdata = f.read()

    token_l, token_r = parse_bg_key.get(app['app'])

    lines = filter(lambda l: token_l in l, bgdata.splitlines())
    lines = map(lambda l: l.split(" ", 1), lines)

    datapoints = []
    for timestamp, line in lines:
        rate = line
        if token_l:
            rate = rate.split(token_l)[1]
        if token_r:
            rate = rate.split(token_r)[0]
        datapoints.append((int(timestamp), float(rate)))

    # baseline from first ten entries:
    x = datapoints[1:11]

    baseline = None
    if all([l[0] < first_sample_time for l in x]):
        baseline = sum([l[1] for l in x]) / len(x)

    return {
        'recorded_baseline': baseline,
        'recorded_samples': datapoints
    }

def parse_kona_accounting_log(dirn, experiment):
    fname = "{dirn}/memcached.out".format(dirn=dirn, **experiment)
    with open(fname) as f:
        data = f.read().splitlines()

    header_list_v0 = ("counters,n_faults_r,n_faults_w,n_faults_wp,n_wp_rm_upgrade_write,n_"
    "wp_rm_fail,n_rw_fault_q,n_r_from_w_q,n_r_from_w_q_fail,n_madvise,n_"
    "page_dirty,n_wp_install_fail,n_cl_dirty_try,n_cl_dirty_success,n_"
    "flush_try,n_flush_success,n_madvise_try,n_poller_copy_fail,n_net_"
    "page_in,n_net_page_out,n_net_writes,n_net_write_comp,page_lifetime_"
    "sum,net_read_sum,n_zp_fail,n_uffd_wake,malloc_size,munmap_size,"
    "madvise_size,mem_pressure,n_kapi_fetch_succ").split(",")
    header_list_v1 = ("counters,n_faults_r,n_faults_w,n_faults_wp,n_wp_rm_upgrade_write,n_"
    "wp_rm_fail,n_rw_fault_q,n_r_from_w_q,n_r_from_w_q_fail,n_evictions,n_evictable,"
    "n_eviction_batches,n_madvise,n_"
    "page_dirty,n_wp_install_fail,n_cl_dirty_try,n_cl_dirty_success,n_"
    "flush_try,n_flush_success,n_madvise_try,n_poller_copy_fail,n_net_"
    "page_in,n_net_page_out,n_net_writes,n_net_write_comp,page_lifetime_"
    "sum,net_read_sum,n_zp_fail,n_uffd_wake,malloc_size,munmap_size,"
    "madvise_size,mem_pressure,n_kapi_fetch_succ").split(",")   # eviction changes
    header_list_v2 = ("counters,n_faults_r,n_faults_w,n_faults_wp,n_wp_rm_upgrade_write,n_"
    "wp_rm_fail,n_rw_fault_q,n_r_from_w_q,n_r_from_w_q_fail,n_evictions,n_evictable,"
    "n_eviction_batches,n_madvise,n_"
    "page_dirty,n_wp_install_fail,n_cl_dirty_try,n_cl_dirty_success,n_"
    "flush_try,n_flush_success,n_madvise_try,n_poller_copy_fail,n_net_"
    "page_in,n_net_page_out,n_net_writes,n_net_write_comp,page_lifetime_"
    "sum,net_read_sum,n_zp_fail,n_uffd_wake,malloc_size,munmap_size,"
    "madvise_size,mem_pressure,n_kapi_fetch_succ,n_afaults_r,n_afaults_w,"
    "n_af_waitq,n_af_transitq").split(",")   # app fault changes
    header_list_v3 = ("counters,n_faults_r,n_faults_w,n_faults_wp,n_wp_rm_upgrade_write,n_"
    "wp_rm_fail,n_rw_fault_q,n_r_from_w_q,n_r_from_w_q_fail,n_evictions,n_evictable,"
    "n_eviction_batches,n_madvise,n_"
    "page_dirty,n_wp_install_fail,n_cl_dirty_try,n_cl_dirty_success,n_"
    "flush_try,n_flush_success,n_madvise_try,n_poller_copy_fail,n_net_"
    "page_in,n_net_page_out,n_net_writes,n_net_write_comp,page_lifetime_"
    "sum,net_read_sum,n_zp_fail,n_uffd_wake,malloc_size,munmap_size,"
    "madvise_size,mem_pressure,n_kapi_fetch_succ,n_afaults,n_afaults_r,n_afaults_w,"
    "n_afaults_done,n_af_waitq,n_af_waitq_done,n_af_transitq,n_af_transitq_done,n_af_readyq,"
    "n_af_readyq_done,n_kfaults,n_kfaults_done,n_kfaults_concur").split(",")   # debugging
    
    header_list = None
    COL_IDX = None

    stats = defaultdict(list)
    for line in data:
        if "counters," in line:
            dats = line.split()
            time = int(dats[0])
            values = dats[1].split(",")
            if not header_list:
                if len(values) == len(header_list_v3):
                    header_list = header_list_v3
                if len(values) == len(header_list_v2):
                    header_list = header_list_v2
                if len(values) == len(header_list_v1):
                    header_list = header_list_v1
                elif len(values) == len(header_list_v0):
                    header_list = header_list_v0
                assert header_list is not None
                COL_IDX = {k: v for v, k in enumerate(header_list)}
            assert len(values) == len(header_list), "unexpected kona log format"
            if header_list[1] == values[1]:     continue    #header
            for c in header_list[1:]:  stats[c].append((time, int(values[COL_IDX[c]])))            
            stats['n_faults'].append((time, int(values[COL_IDX['n_faults_r']]) + int(values[COL_IDX['n_faults_w']]) + int(values[COL_IDX['n_faults_wp']])))
            stats['n_flush_fail'].append((time, int(values[COL_IDX['n_flush_try']]) - int(values[COL_IDX['n_flush_success']])))
            stats['n_madvise_fail'].append((time, int(values[COL_IDX['n_madvise_try']]) - int(values[COL_IDX['n_madvise']])))
            if header_list == header_list_v0:
                # Before v1, we were not printing n_evictions, it was same as pages written out
                stats['n_evictions'].append((time, int(values[COL_IDX['n_net_page_out']])))

    # Correct timestamps: A bunch of logs may get the same timestamp 
    # due to stdout flushing at irregular intervals. Assume that the 
    # last log with a particular timestamp has the correct one and work backwards
    for data in stats.values():
        oldts = None
        for i, (ts, val) in reversed(list(enumerate(data))):
            if oldts and ts >= oldts:   ts = oldts - 1
            data[i] = (ts, val)
            oldts = ts

    return dict(stats)

def parse_kona_profiler_log(dirn, experiment):
    fname = "{dirn}/memcached.out".format(dirn=dirn, **experiment)
    with open(fname) as f:
        data = f.read().splitlines()

    header_list = ("profiler,PERF_HANDLER_FAULT,PERF_HANDLER_MADV_NOTIF,PERF_HANDLER_UFFD_WP,"
        "PERF_HANDLER_RW,PERF_HANDLER_UFFD_COPY,PERF_HANDLER_UFFD_WP_Q,PERF_HANDLER_FAULT_Q,"
        "PERF_RDMA_WRITE,PERF_EVICT_TOTAL,PERF_EVICT_WP,PERF_EVICT_CL_DIFF,PERF_EVICT_MEMCPY,"
        "PERF_EVICT_WRITE,PERF_EVICT_CLEAN_CPY,PERF_EVICT_MADVISE,PERF_POLLER_ZP,PERF_POLLER_READ,"
        "PERF_POLLER_UFFD_COPY,PERF_POLLER_CLEAN_CPY,PERF_PAGE_READ").split(",")
    COL_IDX = {k: v for v, k in enumerate(header_list)}

    stats = defaultdict(list)
    for line in data:
        if "profiler," in line:
            dats = line.split()
            time = int(dats[0])
            values = dats[1].split(",")
            assert len(values) == len(header_list), "unexpected kona profiler log format"
            if header_list[1] == values[1]:     continue    #header
            for c in header_list[1:]:  stats[c].append((time, int(values[COL_IDX[c]])))            

    # Correct timestamps: A bunch of logs may get the same timestamp 
    # due to stdout flushing at irregular intervals. Assume that the 
    # last log with a particular timestamp has the correct one and work backwards
    for data in stats.values():
        oldts = None
        for i, (ts, val) in reversed(list(enumerate(data))):
            if oldts and ts >= oldts:   ts = oldts - 1
            data[i] = (ts, val)
            oldts = ts

    return dict(stats)

@except_none
def parse_utilization(dirn, experiment):
    fname = "{dirn}/mpstat.{server_hostname}.log".format(
        dirn=dirn, **experiment)
    try:
        with open(fname) as f:
            data = f.read().splitlines()
        int(data[0].split()[0])
    except:
        return None

    cpuln = next(l for l in data if "_x86_64_" in l)
    ncpu = int(re.match(".*\((\d+) CPU.*", cpuln).group(1))
    headerln = next(l for l in data if "iowait" in l).split()
    # assume max 2 nodes
    assert "CPU" in headerln or "NODE" in headerln

    cols = {h: pos for pos, h in enumerate(headerln)}
    data = map(lambda l: l.split(), data)
    data = filter(lambda l: "%iowait" not in l and len(l) > 1, data[4:])

    if "NODE" in headerln:
        data = filter(lambda l: int(l[cols['NODE']]) == NUMA_NODE, data)
    else:
        assert all(lambda l: l[cols['CPU']] == 'all', data)

# % usr 100.0 - %idle
    data = map(lambda l: (int(l[0]), 100. - float(l[-1])), data)
    if not "NODE" in headerln:
        data = map(lambda a, b: a, 2 * b, data)
    return data

def parse_iokernel_log(dirn, experiment):
    fname = "{dirn}/iokernel.{server_hostname}.log".format(
        dirn=dirn, **experiment)
    with open(fname) as f:
        data = f.read()
        int(data.split()[0])

    stats = defaultdict(list)
    data = data.split(" Stats:")[1:]
    for d in data:
        RX_P = None
        for line in d.strip().splitlines():
            if "eth stats for port" in line: continue
            if "rx:" in line: continue
            dats = line.split()
            tm = int(dats[0])
            for stat_name, stat_val in zip(dats[1::2], dats[2::2]):
                if not stat_name.endswith(":") or parse_int(stat_val) is None:
                    # not an effective filter but works for now
                    continue   
                stats[stat_name.replace(":", "")].append((tm, int(stat_val)))
                if stat_name == "RX_PULLED:": RX_P = float(stat_val)
                if stat_name == "BATCH_TOTAL:": stats['IOK_SATURATION'].append((tm, RX_P / float(stat_val)))
    
    # Correct timestamps: A bunch of logs may get the same timestamp 
    # due to stdout flushing at irregular intervals. Assume that the 
    # last log with a particular timestamp has the correct one and work backwards
    for data in stats.values():
        oldts = None
        for i, (ts, val) in reversed(list(enumerate(data))):
            if oldts and ts >= oldts:   ts = oldts - 1
            data[i] = (ts, val)
            oldts = ts

    return stats

def parse_runtime_log(app, dirn):
    if app['name'] != 'memcached':
        return None

    fname = "{dirn}/{name}.out".format(dirn=dirn, **app)
    with open(fname) as f:
        data = f.read().splitlines()

    pattern_old = ("(\d+).*STATS>reschedules:(\d+),sched_cycles:(\d+),program_cycles:(\d+),"
    "threads_stolen:(\d+),softirqs_stolen:(\d+),softirqs_local:(\d+),parks:(\d+),"
    "preemptions:(\d+),preemptions_stolen:(\d+),core_migrations:(\d+),rx_bytes:(\d+),"
    "rx_packets:(\d+),tx_bytes:(\d+),tx_packets:(\d+),drops:(\d+),rx_tcp_in_order:(\d+),"
    "rx_tcp_out_of_order:(\d+),rx_tcp_text_cycles:(\d+),cycles_per_us:(\d+)")
    pattern_new = ("(\d+).*STATS>reschedules:(\d+),sched_cycles:(\d+),program_cycles:(\d+),"
    "threads_stolen:(\d+),softirqs_stolen:(\d+),softirqs_local:(\d+),parks:(\d+),"
    "preemptions:(\d+),preemptions_stolen:(\d+),core_migrations:(\d+),rx_bytes:(\d+),"
    "rx_packets:(\d+),tx_bytes:(\d+),tx_packets:(\d+),drops:(\d+),rx_tcp_in_order:(\d+),"
    "rx_tcp_out_of_order:(\d+),rx_tcp_text_cycles:(\d+),pf_posted:(\d+),"
    "pf_returned:(\d+),pf_retries:(\d+),pf_failed:(\d+),cycles_per_us:(\d+)")
    pattern = None

    stat_vec = defaultdict(list)
    values_old = None
    for line in data:
        if "STATS>" not in line:    continue
        match = re.match(pattern_old, line)
        if not match:   match = re.match(pattern_new, line)
        if match:
            assert len(match.groups()) == 20 or len(match.groups()) == 24
            values = [int(match.group(i+1)) for i in range(len(match.groups()))]
            if not values_old:
                values_old = values
                continue        #ignore first value
            diff = [x - y for x, y in zip(values, values_old)] 
            values_old = values

            ts = int(values[0])
            reschedules = diff[1]
            sched_cycles = diff[2]
            program_cycles = diff[3]
            threads_stolen = diff[4]
            softirqs_stolen = diff[5]
            softirqs_local = diff[6]
            parks = diff[7]
            preemptions = diff[8]
            preemptions_stolen = diff[9]
            core_migrations = diff[10]
            rx_bytes = diff[11]
            rx_packets = diff[12]
            tx_bytes = diff[13]
            tx_packets = diff[14]
            drops = diff[15]
            rx_tcp_in_order = diff[16]
            rx_tcp_out_of_order = diff[17]
            rx_tcp_text_cycles = diff[18]
            cycles_per_us = values[19] 
            if len(match.groups()) == 24:
                pf_posted = diff[19]
                pf_returned = diff[20]
                pf_retries = diff[21]
                pf_failed = diff[22]
                cycles_per_us = values[23] 

            # print(values)
            # print(diff)

            stat_vec['rescheds'].append((ts, reschedules))
            stat_vec['schedtimepct'].append((ts, sched_cycles / (sched_cycles + program_cycles) * 100 
                if (sched_cycles + program_cycles) else 0))
            stat_vec['localschedpct'].append((ts, (1 - threads_stolen / reschedules) * 100 if reschedules else 0))
            stat_vec['softirqs'].append((ts, softirqs_local + softirqs_stolen))
            stat_vec['stolenirqpct'].append((ts, (softirqs_stolen / (softirqs_local + softirqs_stolen)) * 100 
                if (softirqs_local + softirqs_stolen) else 0))
            stat_vec['cpupct'].append((ts, (sched_cycles + program_cycles) * 100 /(float(cycles_per_us) * 1000000)))
            stat_vec['parks'].append((ts, parks))
            stat_vec['migratedpct'].append((ts, core_migrations * 100 / parks if parks else 0))
            stat_vec['preempts'].append((ts, preemptions))
            stat_vec['stolenpct'].append((ts, preemptions_stolen))
            stat_vec['rxpkt'].append((ts, rx_packets))
            stat_vec['rxbytes'].append((ts, rx_bytes))
            stat_vec['txpkt'].append((ts, tx_packets))
            stat_vec['txbytes'].append((ts,tx_bytes ))
            stat_vec['drops'].append((ts, drops))
            stat_vec['p_rx_ooo'].append((ts, rx_tcp_out_of_order / (rx_tcp_in_order + rx_tcp_out_of_order) * 100
                if (rx_tcp_in_order + rx_tcp_out_of_order) else 0))
            stat_vec['p_reorder_time'].append((ts, rx_tcp_text_cycles / (sched_cycles + program_cycles) * 100
                if (sched_cycles + program_cycles) else 0))
            stat_vec['pf_posted'].append((ts, pf_posted))
            stat_vec['pf_returned'].append((ts, pf_returned))
            stat_vec['pf_retries'].append((ts, pf_retries))
            stat_vec['pf_failed'].append((ts, pf_retries))
            continue
        assert False, line
    
    # FIX: Correct timestamps: A bunch of logs may get the same timestamp 
    # due to stdout flushing at irregular intervals. Assume that the 
    # last log with a particular timestamp has the correct one and work backwards
    for data in stat_vec.values():
        oldts = None
        for i, (ts, val) in reversed(list(enumerate(data))):
            if oldts and ts >= oldts:   ts = oldts - 1
            data[i] = (ts, val)
            oldts = ts

    return stat_vec

def extract_window_seq(datapoints, wct_start, duration_sec, accumulated=False, trim=0.0):
    window_start = wct_start + int(duration_sec * trim)
    window_end = wct_start + duration_sec - int(duration_sec * trim)
    datapoints = filter(lambda l: l[0] >= window_start and l[0] <= window_end, datapoints)
    if accumulated and len(datapoints) > 0:
        return [(x[0], (x[1] - datapoints[i - 1][1]) / (x[0] - datapoints[i - 1][0])) 
                for i, x in enumerate(datapoints)][1:]
    return datapoints

def extract_window(datapoints, wct_start, duration_sec, accumulated=False):
    datapoints = extract_window_seq(datapoints, wct_start, duration_sec, accumulated)
    # Weight any gaps in reporting
    try:
        total = 0
        nsecs = 0
        for idx, (tm, rate) in enumerate(datapoints[1:]):
            nsec = tm - datapoints[idx][0]
            total += rate * nsec
            nsecs += nsec
        avgmids = total / nsecs
    except:
        avgmids = None
    return avgmids

def extract_window_diff(datapoints, wct_start, duration_sec, accumulated=False):
    datapoints = extract_window_seq(datapoints, wct_start, duration_sec, accumulated)
    data = [v for k,v in datapoints]
    return max(data) - min(data)

def extract_window_max(datapoints, wct_start, duration_sec, accumulated=False):
    datapoints = extract_window_seq(datapoints, wct_start, duration_sec, accumulated)
    data = [v for k,v in datapoints]
    return max(data)

def load_loadgen_results(experiment, dirname):
    clients = [i for host in experiment['clients'] for i in experiment['clients'][host]]
    apps = [a for host in experiment['apps'] for a in experiment['apps'][host]]

    if not clients:
        print(clients)
        clients = [i for i in apps if i.get('protocol') == 'synthetic']   # local client;
        experiment['clients'][experiment['server_hostname']] = clients

    for client in clients:
        filename = "{}/{}.out".format(dirname, client['name'])
        assert os.access(filename, os.F_OK)
        print("Parsing " + filename)
        output = parse_client_output(filename)
        assert len(output["samples"]) == client['samples'], filename
        client["output"] = output

        # Find server app
        if client['name'] != "localsynth":
            server_handle = client['name'].split(".")[1] 
            app = next(app for app in apps if app['name'] == server_handle)
        else:
            app = client #local

        if not 'loadgen' in app:
            app['loadgen'] = output
        else:
            data = app['loadgen']
            assert 'checkpts' not in data, "Yet to implement merging checkpt data for multiple clients!"
            data['samples'] = merge_sample_sets(data['samples'], output['samples'])
        # print(len(app["loadgen"]))

    for app in apps:
        if not 'loadgen' in app: continue
        for sample in app['loadgen']['samples']:
            latd = sample['latencies']
            sample['p50'] = percentile(latd, 0.5)
            sample['p90'] = percentile(latd, 0.9)
            sample['p99'] = percentile(latd, 0.99)
            sample['p999'] = percentile(latd, 0.999)
            sample['p9999'] = percentile(latd, 0.9999)
            # del sample['latencies']
            sample['app'] = app


def parse_dir(dirname):
    files = os.listdir(dirname)
    assert "config.json" in files
    with open(dirname + "/config.json") as f:
        experiment = json.loads(f.read())

    load_loadgen_results(experiment, dirname)

    apps = [a for host in experiment['apps'] for a in experiment['apps'][host]]
    samples = [sample['time'] for app in apps \
                for sample in (app['loadgen']['samples'] \
                if 'loadgen' in app else [])]
    start_time = min(samples) if samples else 0

    for app in apps:
        app['output'] = load_app_output(app, dirname, start_time)
        app['rstat'] = parse_runtime_log(app, dirname)

    experiment['mpstat'] = parse_utilization(dirname, experiment)
    experiment['ioklog'] = parse_iokernel_log(dirname, experiment)
    experiment['konalog'] = parse_kona_accounting_log(dirname, experiment)
    experiment['konalogext'] = parse_kona_profiler_log(dirname, experiment)
    return experiment


def arrange_2d_results(experiment):
    global suppress_warn
    # per start time: the 1 background app of choice, aggregate throughtput,  
    # 1 line per start time per server application
    apps = [a for host in experiment['apps'] for a in experiment['apps'][host]]
    by_time_point = zip(*(app['loadgen']['samples'] for app in apps if 'loadgen' in app))
    bgs = [app for app in apps if app['output']]
    # TODO support multiple bg apps
    assert len(bgs) <= 1
    bg = bgs[0] if bgs else None

    runtime = experiment['clients'].itervalues().next()[0]['runtime']

    header1 = ["system", "app", "background", "transport", "spin", "nconns", "threads"]         # parameters
    header2 = ["offered", "achieved", "p50", "p90", "p99", "p999", "p9999", "distribution"]     # app
    # header3 = ["tput", "baseline", "totaloffered", "totalachieved", "totalcpu"] #, "localcpu", "ioksaturation"]

    header = header1 + header2 + IOK_DISPLAY_FIELDS + KONA_DISPLAY_FIELDS + ["outstanding"] + \
                KONA_DISPLAY_FIELDS_EXTENDED + RSTAT_DISPLAY_FIELDS
    lines = [header]
    ncons = 0
    for list_pm in experiment['clients'].itervalues():
        for i in list_pm: 
            ncons += i['client_threads']

    for time_point in by_time_point:
        times = set(t['time'] for t in time_point)
        # print(times)
        #assert len(times) == 1 # all start times are the same
        time = times.pop()
        if len(times) == 1: assert abs(times.pop() - time) <= 1
        else:   assert len(times) == 0
        bgbaseline = bg['output']['recorded_baseline'] if bg else 0
        bgtput = extract_window(bg['output']['recorded_samples'], time, runtime) if bg else 0
        if bgtput is None:  bgtput = 0
        cpu = extract_window(experiment['mpstat'], time, runtime) if experiment['mpstat'] else None
        total_offered = sum(t['offered'] for t in time_point)
        total_achieved = sum(t['achieved'] for t in time_point)
        for point in time_point:
            # Client-side numbers
            out = [experiment['system'], point['app']['app'], bg['app'] if bg else None, 
                    point['app'].get('transport', None), point['app']['spin'] > 1, ncons, 
                    point['app']['threads']]
            out += [point[k] for k in header2]

            # Stats at Shenango I/O Core
            for field in IOK_DISPLAY_FIELDS:
                if experiment['ioklog']:   
                    out.append(extract_window(experiment['ioklog'][field], time, runtime))
                else:   out.append(None)

            # Stats from Kona
            for field in KONA_DISPLAY_FIELDS:
                if experiment['konalog'] and field in experiment['konalog']:   
                    out.append(extract_window(experiment['konalog'][field], time, runtime, 
                        accumulated=(field in KONA_FIELDS_ACCUMULATED)))
                else:  out.append(None)
            field = "n_poller_copy_fail"
            if experiment['konalog'] and field in experiment['konalog']:
                out.append(extract_window_max(experiment['konalog'][field], time, runtime))
            else: out.append(None)
            for field in KONA_DISPLAY_FIELDS_EXTENDED:
                if experiment['konalogext'] and field in experiment['konalogext']:   
                    out.append(extract_window(experiment['konalogext'][field], time, runtime, 
                        accumulated=(field in KONA_FIELDS_ACCUMULATED)))
                else:   out.append(None)

            # Stats from Shenango runtime
            for field in RSTAT_DISPLAY_FIELDS:
                if point['app']['rstat']:   
                    out.append(extract_window(point['app']['rstat'][field], time, runtime))
                else:   out.append(None)
            lines.append(out)

            # Detecting soft crashes by looking at anomalies in acheived throughput
            # Only Shenango spits out second-by-second throughput numbers, the client just writes 
            # aggregate throughput, so we look at the packet rate received at the I/O core.
            if experiment['ioklog'] and experiment['ioklog']["TX_PULLED"]:
                xput_series = extract_window_seq(experiment['ioklog']["TX_PULLED"], time, runtime, trim=0.1)
                mean = None
                for i, (_, val) in enumerate(xput_series):
                    if mean:
                        if val < mean / 2.0:
                            print("WARNING! drastic throughput drop detected, possible soft crash")
                            if not suppress_warn:
                                sys.exit(1)
                        mean = (mean * i + val) / (i + 1)
                    else:
                        mean = val

        # Numbers for background apps, if any
        for bgl in bgs:
            continue; out = [experiment['system'], bgl['app'], bg['app'] if bg else None, 
                    None, bgl['spin'] > 1]
            out += [0]*7 + [None]
            out.append(extract_window(bgl['output']['recorded_samples'], time, runtime))
            out.append(bgl['output']['recorded_baseline'])
            out += [total_offered, total_achieved, cpu]
            """if bgl['rstat']:
                out.append(extract_window(bgl['rstat']['cpupct'], time, runtime))
            else:
                out.append(None)
            out.append(iok_saturation)"""
            for field in DISPLAYED_RSTAT_FIELDS:
                if point['app']['rstat']:
                        out.append(extract_window(point['app']['rstat'][field], time, runtime))
                else:
                        out.append(None)
            lines.append(out)
    return lines


def rotate(output_lines):
    resdict = {}
    headers = output_lines[0]
    for i, h in enumerate(headers):
        resdict[h] = [l[i] for l in output_lines[1:]]
    return resdict


def print_res(res):
    for line in res:
        print(",".join([str(x) for x in line]))


def do_it_all(dirname, save_lat=False, save_kona=False, 
    save_iok=False, save_rstat=False, sample_id=None):
    exp = parse_dir(dirname)
    stats = arrange_2d_results(exp)
    print(stats)
    bycol = rotate(stats)
    runtime = exp['clients'].itervalues().next()[0]['runtime']

    main_apps = [a for host in exp['apps'] for a in exp['apps'][host] if 'loadgen' in a]
    assert len(main_apps) == 1, "Only expecting memcached for now"
    app = next(iter(main_apps))
    samples = app['loadgen']['samples']
    sduration = exp['clients'].itervalues().next()[0]['runtime']
    sid = sample_id - 1 if sample_id else None
    checkpts = app['loadgen']['checkpts']

    if sid is not None:
        assert 0 <= sid < len(samples), "Invalid sample id"
        start = samples[sid]['time']
        runtime = sduration
    else:
        # If sample is not specified, write metrics for entire run
        if "PreloadStart" in checkpts:  start = checkpts['PreloadStart']
        else:   start = min([s['time'] for s in samples]) if samples else 0
        runtime = max([s['time'] for s in samples]) + sduration + 10 - start
    print(start, runtime)

    STAT_F = "{}/stats/".format(dirname)
    os.system("mkdir -p " + STAT_F)
    with open(STAT_F + "stat.csv", "w") as f:
        for line in stats:
            x = ",".join([str(x) for x in line])
            print(x)
            f.write(x + '\n')

    if checkpts:    
        with open(STAT_F + "checkpoints", "w") as f:
            print("Writing checkpoints to " + STAT_F + "checkpoints")
            # f.write("label,time")
            print(checkpts)
            for pt,time in checkpts.items():
                if start <= time <= start + runtime:
                    f.write("{},{}\n".format(pt, time-start))

    # Write latencies too
    if save_lat:
        for i, sample in enumerate(samples):
            latfile = STAT_F + "latencies_{}".format(i+1)
            print("Writing latencies to " + latfile)
            with open(latfile, "w") as f:
                f.write("Latencies\n")
                for k,v in sample['latencies'][0].items():
                    f.writelines([str(k) + "\n"] * v)
            print("OFFERED: {}, ACHIEVED: {}".format(sample['offered'], sample['achieved']))

    if save_rstat:
        if app['rstat']:
            rstatfile = STAT_F + "rstat_{}".format(app['name'])
            print("Writing runtime stats to " + rstatfile)
            with open(rstatfile, "w") as f:
                trimmed = { k:extract_window_seq(v, start, runtime) for k,v in app['rstat'].items()}
                # print(trimmed.keys())
                f.write("time," + ",".join(trimmed.keys()) + "\n")
                for i, (time, _) in enumerate(trimmed.values()[0]):
                    values = [str(time - start)] + [str(trimmed[k][i][1]) for k in trimmed.keys()]
                    f.write(",".join(values) + "\n")
    
    if save_iok and exp['ioklog']:
        iokfile = STAT_F + "iokstats"
        print("Writing iok stats to " + iokfile)
        with open(iokfile, "w") as f:
            trimmed = { k:extract_window_seq(v, start, runtime) for k,v in exp['ioklog'].items()}
            # print(trimmed['TX_PULLED'])
            f.write("time," + ",".join(trimmed.keys()) + "\n")
            for i, (time, _) in enumerate(trimmed.values()[0]):
                values = [str(time - start)] + [str(trimmed[k][i][1]) for k in trimmed.keys()]
                f.write(",".join(values) + "\n")

    if save_kona and exp['konalog']:
        konafile = STAT_F + "konastats"
        print("Writing kona stats to " + konafile)
        with open(konafile, "w") as f:
            # FIXME: Some columns might not be cumulative
            trimmed = {}
            for k,v in exp['konalog'].items():
                trimmed[k] = extract_window_seq(v, start, runtime, accumulated=(k in KONA_FIELDS_ACCUMULATED)) 
                # ignore first row for non-accumulated ones
                if k not in KONA_FIELDS_ACCUMULATED:
                    trimmed[k] = trimmed[k][1:] 
            # print(trimmed)

            f.write("time," + ",".join(trimmed.keys()) + "\n")
            for i, (time, _) in enumerate(trimmed.values()[0]):
                values = [str(time - start)] + [str(trimmed[k][i][1]) for k in trimmed.keys()]
                f.write(",".join(values) + "\n")
                
            # Write kona extended stats
            trimmed = {}
            for k,v in exp['konalogext'].items():
                trimmed[k] = extract_window_seq(v, start, runtime, accumulated=(k in KONA_FIELDS_ACCUMULATED)) 
                # ignore first row for non-accumulated ones
                if k not in KONA_FIELDS_ACCUMULATED:
                    trimmed[k] = trimmed[k][1:] 
            # print(trimmed)

        konafile = STAT_F + "konastats_extended"
        print("Writing kona extended stats to " + konafile)
        with open(konafile, "w") as f:                
            f.write("time," + ",".join(trimmed.keys()) + "\n")
            for i, (time, _) in enumerate(trimmed.values()[0]):
                values = [str(time - start)] + [str(trimmed[k][i][1]) for k in trimmed.keys()]
                f.write(",".join(values) + "\n")

        konafile = STAT_F + "konastats_extended_aggregated"
        print("Writing kona aggregated extended stats to " + konafile)
        trimmed_avg = {}
        for k, values in trimmed.items():
            nonzero = [val for (_, val) in values if val != 0]
            trimmed_avg[k] = np.mean(nonzero) if nonzero else 0
        with open(konafile, "w") as f:
            json.dump(trimmed_avg, f, sort_keys=True,indent=4)

    return bycol


def main():
    global suppress_warn

    parser = argparse.ArgumentParser("Summarizes exp results")
    parser.add_argument('-n', '--name', action='store', help='Exp (directory) name')
    parser.add_argument('-d', '--dir', action='store', help='Path to data dir', default="./data")
    parser.add_argument('-s', '--sample', action='store', type=int, help='Sample ID to filter stats for')
    parser.add_argument('-sl', '--lat', action='store_true', help='save latencies to file', default=False)
    parser.add_argument('-sk', '--kona', action='store_true', help='save kona stats to file', default=False)
    parser.add_argument('-si', '--iok', action='store_true', help='save iok stats to file', default=False)
    parser.add_argument('-sa', '--app', action='store_true', help='save app runtime stats to file', default=False)
    parser.add_argument('-sw', '--suppresswarn', action='store_true', help='suppress warnings and continue the program')
    args = parser.parse_args()

    expname = args.name
    if not expname:  
        subfolders = glob.glob(args.dir + "/*/")
        latest = max(subfolders, key=os.path.getctime)
        expname = os.path.basename(os.path.split(latest)[0])
    dirname = os.path.join(args.dir, expname)
    suppress_warn = args.suppresswarn

    print("Summarizing exp run: " + expname)
    do_it_all(dirname, save_lat=args.lat, save_kona=args.kona, 
        save_iok=args.iok, save_rstat=args.app, sample_id=args.sample)

if __name__ == '__main__':
    main()
