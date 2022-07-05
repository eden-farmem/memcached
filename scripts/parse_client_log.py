
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

    return experiment

def arrange_2d_results(experiment):
    # per start time: the 1 background app of choice, aggregate throughtput,  
    # 1 line per start time per server application
    apps = [a for host in experiment['apps'] for a in experiment['apps'][host]]
    by_time_point = zip(*(app['loadgen']['samples'] for app in apps if 'loadgen' in app))
    bgs = [app for app in apps if app['output']]
    # TODO support multiple bg apps
    assert len(bgs) <= 1
    bg = bgs[0] if bgs else None

    header1 = ["system", "app", "background", "transport", "spin", "nconns", "threads"]         # parameters
    header2 = ["offered", "achieved", "p50", "p90", "p99", "p999", "p9999", "distribution"]     # app
    header = header1 + header2
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
        if len(times) == 1: 
            assert abs(times.pop() - time) <= 1
        else:   assert len(times) == 0
        for point in time_point:
            # Client-side numbers
            out = [experiment['system'], point['app']['app'], bg['app'] if bg else None, 
                point['app'].get('transport', None), point['app']['spin'] > 1, ncons, 
                point['app']['threads']]
            out += [point[k] for k in header2]
            lines.append(out)
    return lines

def rotate(output_lines):
    resdict = {}
    headers = output_lines[0]
    for i, h in enumerate(headers):
        resdict[h] = [l[i] for l in output_lines[1:]]
    return resdict

def parse_and_write(dirname, outfile=None):
    exp = parse_dir(dirname)
    stats = arrange_2d_results(exp)
    # print(stats)

    # write result
    f = open(outfile, "w") if outfile else sys.stdout
    for line in stats:
        x = ",".join([str(x) for x in line])
        f.write(x + '\n')

def main():
    parser = argparse.ArgumentParser("Summarizes exp results")
    parser.add_argument('-n', '--name', action='store', help='Exp (directory) name')
    parser.add_argument('-d', '--dir', action='store', help='Path to data dir', default="./data")
    parser.add_argument('-o', '--out', action='store', help='Output file to write to')
    args = parser.parse_args()

    expname = args.name
    if not expname:  
        subfolders = glob.glob(args.dir + "/*/")
        latest = max(subfolders, key=os.path.getctime)
        expname = os.path.basename(os.path.split(latest)[0])
    dirname = os.path.join(args.dir, expname)
    parse_and_write(dirname, outfile=args.out)

if __name__ == '__main__':
    main()
