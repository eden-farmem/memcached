import sys
import os
import subprocess
import time
import json
import atexit
import random
from datetime import datetime
from enum import Enum
import argparse
import signal

# Requires password-less sudo and ssh
# ts requires moreutils to be installed
# Pip install: enum34, argparse, paramiko, 

# BASE_DIR = os.getcwd()
BASE_DIR = "/home/ayelam/rmem-scheduler"
SDIR = "{}/scheduler/".format(BASE_DIR)
RSTAT = "{}/scripts/rstat.go".format(SDIR)
THISHOST = subprocess.check_output("hostname -s", shell=True).strip()

# Network
def IP(node):
    assert node > 0 and node < 255
    return "{}.{}".format(NETPFX, node)
NETPFX = "192.168.0"
NETMASK = "255.255.255.0"
GATEWAY = IP(1)
IP_MAP = {
    'sc2-hs2-b1607': IP(7),
    'sc2-hs2-b1630': IP(30),
    'sc2-hs2-b1640': IP(40),
    'sc2-hs2-b1632': IP(32),
}
MAC_MAP = {
    'sc2-hs2-b1607': '50:6b:4b:23:a8:25',
    'sc2-hs2-b1630': '50:6b:4b:23:a8:2d',
    'sc2-hs2-b1640': '50:6b:4b:23:a8:a4',
    'sc2-hs2-b1632': '50:6b:4b:23:a8:1d',
}
NIC_PCIE_MAP = {
    'sc2-hs2-b1607': '0000:d8:00.1',
    'sc2-hs2-b1630': '0000:d8:00.1',
    'sc2-hs2-b1640': '0000:d8:00.0',
    'sc2-hs2-b1632': '0000:d8:00.1',
}
IFNAME_MAP = {
    'sc2-hs2-b1607': 'enp216s0f1',
    'sc2-hs2-b1630': 'enp216s0f1',
    'sc2-hs2-b1640': 'enp216s0f0',
    'sc2-hs2-b1632': 'enp216s0f1',
}

# Memcached host settings
SERVER = "sc2-hs2-b1630"
# CLIENT_SET = ["sc2-hs2-b1607", "sc2-hs2-b1640"]
# CLIENT_SET = ["sc2-hs2-b1607"]
CLIENT_SET = ["sc2-hs2-b1632"]
CLIENT_MACHINE_NCORES = 12
SERVER_CORES = 4
NEXT_CLIENT_ASSIGN = 0
NIC_NUMA_NODE = 1
NIC_PCI = NIC_PCIE_MAP[THISHOST]
NIC_IFNAME = IFNAME_MAP[THISHOST]

OBSERVER = "sc2-hs2-b1630"
OBSERVER_IP = IP_MAP[OBSERVER]
OBSERVER_MAC = MAC_MAP[OBSERVER]

# Kona host settings
KONA_RACK_CONTROLLER = "sc2-hs2-b1607"
KONA_RACK_CONTROLLER_PORT = 9202
KONA_MEM_SERVERS = ["sc2-hs2-b1607"]
KONA_MEM_SERVER_PORT = 9200

# Defaults
DEFAULT_START_MPPS = 0
DEFAULT_MPPS = 1
DEFAULT_SAMPLES = 1
DEFAULT_RUNTIME_SECS = 20
DEFAULT_KONA_MEM = 1E9
DEFAULT_KONA_EVICT_THR = 0.8
DEFAULT_KONA_EVICT_DONE_THR = 0.8
DEFAULT_EVICTION_BATCH_SIZE = 1

class Role(Enum):
    host = "host"           # where memcached server and the experiment is hosted
    app = 'app'             # where related apps (e.g., kona) are hosted
    client = 'client'       # clients generating workload
    observer = 'observer'   # observer to co-ordinate runs across machines
    def __str__(self):
        return self.value
role = None
stopat = 0
gdb = False

binaries = {
    'iokerneld': {
        'ht': "{}/iokerneld".format(SDIR),
        'noht': "{}/iokerneld-noht".format(SDIR),
    },
    'memcached': "{}/apps/memcached/memcached".format(BASE_DIR),
    'synthetic': "{}/apps/synthetic/target/release/synthetic".format(SDIR),
    'kona-controller': "{}/backends/kona/pbmem/rcntrl".format(BASE_DIR),
    'kona-server': "{}/backends/kona/pbmem/memserver".format(BASE_DIR)
}

def is_server():
    return THISHOST == SERVER

def new_experiment(system, **kwargs):
    name = "run-{}".format(datetime.now().strftime('%m-%d-%H-%M'))
    return {
        'name': kwargs.get('name') if kwargs.get('name') else name,
        'desc': kwargs.get('desc'),
        'system': system,
        'clients': {},
        'server_hostname': SERVER,
        'app_files': [__file__],
        'client_files': [__file__],
        'apps': {},
        'nextip': 100,
        'nextport': 5000 + random.randint(0,255),
        'start_time': time.time(),
    }

def gen_random_mac():
    return ":".join(["02"] + ["%02x" % random.randint(0, 255) for i in range(5)])

def alloc_ip(experiment, is_shenango_client=False):
    if experiment["system"] == "shenango" or is_shenango_client:
        ip = IP(experiment['nextip'])
        experiment['nextip'] += 1
        return ip
    return IP_MAP[THISHOST]

def alloc_port(experiment):
    port = experiment['nextport']
    experiment['nextport'] += 1
    return port

def new_memcached_server(threads, experiment, name="memcached", transport="tcp", dump_core=False):
    x = {
        'name': name,
        'ip': alloc_ip(experiment),
        'port': alloc_port(experiment),
        'threads': threads,
        'guaranteed': threads,
        'spin': 0,
        'app': 'memcached',
        'nice': -20,
        'meml': 32000,
        # 'meml': 4096,     # preallocate memory
        'hashpower': 28,
        'mac': gen_random_mac(),
        'protocol': 'memcached',
        'transport': transport,
        'host': THISHOST,
        'dump': dump_core,
        'pidfile': name + '_pid'
    }

    args = "-U {port} -p {port} -c 32768 -m {meml} -b 32768 -P {pidfile}"
    args += " -r"       # dump core on seg fault or when terminated with SIGQUIT
    args += " -o hashpower={hashpower}"

    args += {
        'shenango': ",no_hashexpand,no_lru_crawler,no_lru_maintainer,idle_timeout=0",
    }.get(experiment['system'])

    x['args'] = "-t {threads} " + args

    # Requires SO_REUSEPORT hack for memcached
    if experiment['system'] in ["arachne", "linux"] and transport == "udp":
        x['args'] += " -l " + ",".join(["{ip}:{port}" for i in range(4 * threads)])

    if not THISHOST in experiment['apps']:
        experiment['apps'][THISHOST] = []
    experiment['apps'][THISHOST].append(x)
    return x


def add_kona_apps(experiment, server_handle, kona_mem, kona_evict_thr, kona_evict_done_thr):
    # App for rack controller
    app = "kona-controller"
    host = KONA_RACK_CONTROLLER
    instance = "{}.{}".format(host, app)
    if not host in experiment['apps']:
        experiment['apps'][host] = []
    x = {
        'name': instance,
        'ip': IP_MAP[KONA_RACK_CONTROLLER],
        'port': KONA_RACK_CONTROLLER_PORT,
        'mac': MAC_MAP[host],
        'host': host,
        'binary': "./rcntrl",
        'app': app,
        'args': "-s {ip} -p {port}",
        'nice': -20,
        'after': [ 'sleep_5' ],
        'system': 'linux'       #override global system
    }
    server_handle["dependson"] = instance
    experiment['apps'][host].append(x)
    experiment['app_files'].append(binaries[app])

    # Apps for memory servers
    app = "kona-server"
    for host in KONA_MEM_SERVERS:
        if not host in experiment['apps']:
            experiment['apps'][host] = []
        x = {
            'name': "{}.{}".format(host, app),
            'ip': IP_MAP[host],
            'mac': MAC_MAP[host],
            'port': KONA_MEM_SERVER_PORT,
            'rcntrl_ip': IP_MAP[KONA_RACK_CONTROLLER],
            'rcntrl_port': KONA_RACK_CONTROLLER_PORT,
            'host': host,
            'binary': "./memserver",
            'app': app,
            'args': "-s {ip} -p {port} -c {rcntrl_ip} -r {rcntrl_port}",
            'nice': -20,
            'after': [ 'sleep_5' ],
            'system': 'linux'       #override global system
        }
        experiment['apps'][host].append(x)
    experiment['app_files'].append(binaries[app])

def new_measurement_instances(count, server_handle, mpps, experiment, mean=842, nconns=300, **kwargs):
    global NEXT_CLIENT_ASSIGN
    all_instances = []
    for i in range(count):
        client = CLIENT_SET[(NEXT_CLIENT_ASSIGN + i) % len(CLIENT_SET)]
        if not client in experiment['clients']:
            experiment['clients'][client] = []
        x = {
            'ip': alloc_ip(experiment, is_shenango_client=True),
            'port': None,
            'mac': gen_random_mac(),
            'host': client,
            'name': "{}-{}.{}".format(i, client, server_handle['name']),
            'binary': "{} --config".format(binaries["synthetic"]),
            # 'binary': "./synthetic --config",
            'app': 'synthetic',
            'serverip': server_handle['ip'],
            'serverport': server_handle['port'],
            # 'output': kwargs.get('output', "buckets"),
            'output': kwargs.get('output', "normal"),       # don't print latencies
            'mpps': float(mpps) / count,
            'protocol': server_handle['protocol'],
            'transport': server_handle['transport'],
            'distribution': kwargs.get('distribution', "zero"),
            'mean': mean,
            'client_threads': nconns // count,
            'start_mpps': float(kwargs.get('start_mpps', 0)) / count,
            'args': "{serverip}:{serverport} {warmup} --output={output} --protocol {protocol} --mode runtime-client --threads {client_threads} --runtime {runtime} --barrier-peers {npeers} --barrier-leader {leader}  --mean={mean} --distribution={distribution} --mpps={mpps} --samples={samples} --transport {transport} --start_mpps {start_mpps}"
        }
        warmup = kwargs.get('warmup')
        x["warmup"] = "--warmup" if warmup else ""
        if kwargs.get('rampup', False):
            x['args'] += " --rampup={rampup}"
            x['rampup'] = kwargs.get('rampup') / count
        experiment['clients'][client].append(x)
        all_instances.append(x)
    NEXT_CLIENT_ASSIGN += count
    return all_instances

def sleep_5(cfg, experiment):
    time.sleep(5)

def finalize_measurement_cohort(experiment, samples, runtime):
    all_clients = [c for j in experiment['clients']
                   for c in experiment['clients'][j]]
    all_clients.sort(key=lambda c: c['host'])
    max_client_permachine = max(
        len(experiment['clients'][c]) for c in experiment['clients'])
    assert max_client_permachine <= CLIENT_MACHINE_NCORES
    threads_per_client = CLIENT_MACHINE_NCORES // max_client_permachine
    assert threads_per_client % 2 == 0
    # Apps must have unique names
    # assert len(set(app['name'] for app in experiment['apps'][THISHOST])) == len(experiment['apps'])
    for i, cfg in enumerate(all_clients):
        cfg['threads'] = threads_per_client
        cfg['guaranteed'] = threads_per_client
        cfg['spin'] = threads_per_client
        cfg['runtime'] = runtime
        cfg['npeers'] = len(all_clients)
        cfg['samples'] = samples
        cfg['leader'] = cfg['host']
        if i > 0:   cfg['before'] = ['sleep_5']
    # TODO: No need to copy the client binary. In my current setup, we use the binary 
    # compiled on the client directly. Otherwise, this requires the client binary be 
    # built on the main server (with a different kernel) as well which is superflous.
    # experiment['client_files'].append(binaries['synthetic'])


def bench_memcached(system, thr, spin=False, bg=None, samples=55, time=10, mpps=6.0, 
        noht=False, transport="tcp", nconns=1200, start_mpps=0.0, warmup=False,
        kona=False, kona_mem=None, kona_evict_thr=DEFAULT_KONA_EVICT_THR, 
        kona_evict_done_thr=DEFAULT_KONA_EVICT_DONE_THR, kona_evict_batch_sz=DEFAULT_EVICTION_BATCH_SIZE, 
        name=None, desc=None, dump_core=False):
    x = new_experiment(system, name=name, desc=desc)
    # x['name'] += "-memcached" + "-" + transport
    # x['name'] += "-spin" if spin else ""
    # if bg: x['name'] += '-' + bg
    if noht:
        assert system == "shenango"
        x['noht'] = True

    memcached_handle = new_memcached_server(thr, x, transport=transport, dump_core=dump_core)
    if spin:
        memcached_handle['spin'] = thr

    if kona:
        memcached_handle['kona'] = {}
        memcached_handle['kona']['mlimit'] = kona_mem
        memcached_handle['kona']['evict_thr'] = kona_evict_thr
        memcached_handle['kona']['evict_done_thr'] = kona_evict_done_thr
        memcached_handle['kona']['evict_batch_sz'] = kona_evict_batch_sz
        add_kona_apps(x, memcached_handle, kona_mem, kona_evict_thr, kona_evict_done_thr)

    new_measurement_instances(len(CLIENT_SET), memcached_handle, mpps, x, nconns=nconns, start_mpps=start_mpps, warmup=warmup)
    finalize_measurement_cohort(x, samples, time)
    return x


# try different thread configurations with memcached
def try_thr_memcached(system, thread_range, mpps_start, mpps_end, samples, transport, bg=False, time=20):
    assert system in ["shenango", "linux"]
    for i in thread_range:
        x = new_experiment(system)
        x['name'] += "-memcached-{}-{}threads".format(transport, i)
        memcached_handle = new_memcached_server(i, x, transport=transport)
        new_measurement_instances(len(CLIENT_SET), memcached_handle, mpps_end, x, start_mpps=mpps_start,  nconns=200*len(CLIENT_SET))
        finalize_measurement_cohort(x, samples, time)
        execute_experiment(x)

def cleanup(pre=False):
    print("Pre-cleanup" if pre else "Cleaning up")
    procs = ["iokerneld", "cstate", "memcached",
            "swaptions", "mpstat", "synthetic", 
            "rcntrl", "memserver"]
    for j in procs:
        os.system("sudo pkill " + j)
    for j in procs:
        os.system("sudo pkill -9 " + j)

    global role
    if role == Role.host:
        # TODO: KONA CLEANUP (remove if not needed)
        # ipcs -mp | grep $(whoami) |  grep -v grep  | awk '{ print $1 }' | xargs ipcrm -m
        # ipcs -m | grep root |  grep -v grep  | awk '$6 == "0" { print $2 }' | sudo xargs ipcrm -m
        # sleep 2
        # ipcs -mp
        pass

def runcmd(cmdstr, **kwargs):
    print("running command: " + cmdstr)
    return subprocess.check_output(cmdstr, shell=True, **kwargs)

def runpara(cmd, inputs, die_on_failure=False, **kwargs):
    fail = "--halt now,fail=1" if die_on_failure else ""
    return runcmd("parallel {} \"{}\" ::: {}".format(fail, cmd, " ".join(inputs)))

def runremote(cmd, hosts, **kwargs):
    return runpara("ssh -t -t {{}} '{cmd}'".format(cmd=cmd), hosts, kwargs)

############################# APPLICATIONS ###########################

def start_iokerneld(experiment):
    binary = binaries['iokerneld']['ht']
    if 'noht' in experiment and THISHOST == experiment['server_hostname']:
        binary = binaries['iokerneld']['noht']
    runcmd("sudo {}/scripts/setup_machine.sh || true".format(SDIR))
    cmd = "sudo {} {} 2>&1 | ts %s > iokernel.{}.log".format(binary, NIC_PCI, THISHOST)
    print("iokernel cmd: " + cmd)
    proc = subprocess.Popen(cmd, shell=True, cwd=experiment['name'])
    time.sleep(10)
    proc.poll()
    assert proc.returncode is None
    return proc

def start_cstate():
    return subprocess.Popen("sudo {}/scripts/cstate 0".format(SDIR), shell=True)

def gen_conf(filename, experiment, mac=None, **kwargs):
    conf = [
        "host_addr {ip}",
        "host_netmask {netmask}",
        "host_gateway {gw}",
        "runtime_kthreads {threads}",
        "runtime_guaranteed_kthreads {guaranteed}",
        "runtime_spinning_kthreads {spin}"
    ]
    if mac: conf.append("host_mac {mac}")
    if kwargs['guaranteed'] > 0:    conf.append("disable_watchdog true")    #HACK

    if experiment['system'] == "shenango":
        for host in experiment['apps']:
            for cfg in experiment['apps'][host]:
                if cfg['ip'] == kwargs['ip']:   continue
                conf.append("static_arp {ip} {mac}".format(**cfg))
    else:
        for host in MAC_MAP:
            conf.append("static_arp {ip} {mac}".format(ip=IP_MAP[host], mac=MAC_MAP[host]))
    for client in experiment['clients']:
        for cfg in experiment['clients'][client]:
            if cfg['ip'] == kwargs['ip']:
                continue
            conf.append("static_arp {ip} {mac}".format(**cfg))
    if OBSERVER:
        conf.append("static_arp {} {}".format(OBSERVER_IP, OBSERVER_MAC))
    with open(filename, "w") as f:
        f.write("\n".join(conf).format(
            netmask=NETMASK, gw=GATEWAY, mac=mac, **kwargs) + "\n")


def launch_shenango_program(cfg, experiment):
    assert 'args' in cfg

    if not 'binary' in cfg:
        cfg['binary'] = binaries[cfg['app']]

    cwd = os.getcwd()
    os.chdir(experiment['name'])
    assert os.access(cfg['binary'].split()[0], os.F_OK), cfg['binary'].split()[0]
    os.chdir(cwd)

    gen_conf( "{}/{}.config".format(experiment['name'], cfg['name']), experiment, **cfg)
    args = cfg['args'].format(**cfg)
    # print(args)

    if "kona" in cfg:
        print("Wait some time for kona controller and server to be properly setup")
        time.sleep(30)
        params = "RDMA_RACK_CNTRL_IP={} RDMA_RACK_CNTRL_PORT={} ".format(IP_MAP[KONA_RACK_CONTROLLER], KONA_RACK_CONTROLLER_PORT)
        params += "MEMORY_LIMIT={mlimit} EVICTION_THRESHOLD={evict_thr} EVICTION_DONE_THRESHOLD={evict_done_thr} ".format(**cfg["kona"])
        params += "EVICTION_BATCH_SIZE={evict_batch_sz} ".format(**cfg["kona"])
        gdbcmd = "gdb --args" if gdb else ""
        fullcmd = "sudo {params} numactl -N {numa} -m {numa} {gdb} {bin} {name}.config -u ayelam {args} 2>&1 | ts %s  > {name}.out".format(
            params=params, numa=NIC_NUMA_NODE, bin=cfg['binary'], name=cfg['name'], gdb=gdbcmd, args=args) 
    elif cfg['name'] == 'memcached':    # HACK: Need ts for memcached but not synthetic app!
        fullcmd = "numactl -N {numa} -m {numa} {bin} {name}.config {args} 2>&1 | ts %s  > {name}.out".format(
            numa=NIC_NUMA_NODE, bin=cfg['binary'], name=cfg['name'], args=args)  
    else:
        fullcmd = "numactl -N {numa} -m {numa} {bin} {name}.config {args} > {name}.out 2> {name}.err".format(
            numa=NIC_NUMA_NODE, bin=cfg['binary'], name=cfg['name'], args=args)
    print("Running " + fullcmd)
    if stopat == 2:
        print("Stopped for debugging at {}".format(stopat)) 
        time.sleep(300)

    ### HACK
    # if THISHOST.startswith("pd") or THISHOST == "sc2-hs2-b1640":
    #     fullcmd = "export RUST_BACKTRACE=1; " + fullcmd

    # If GDB, prompt for manual start and wait
    if gdb and "kona" in cfg:
        proc = None
        print("Waiting 2 min to start memcached with gdb!")  
        print("Run 'handle SIG33 nostop' to avoid stopping at timer? events!")  
        time.sleep(120)
        return proc
        
    proc = subprocess.Popen(fullcmd, shell=True, cwd=experiment['name'])
    time.sleep(3)
    proc.poll()
    print(str(proc.pid) + " returns code: " + str(proc.returncode))  
    assert not proc.returncode
    return proc


def launch_linux_program(cfg, experiment):
    assert 'args' in cfg
    assert 'nice' in cfg
    assert cfg['ip'] == IP_MAP[THISHOST]

    cwd = os.getcwd()
    os.chdir(experiment['name'])
    binary = cfg.get('binary', binaries[cfg['app']])
    assert os.access(binary, os.F_OK), binary
    os.chdir(cwd)
    name = cfg['name']

    prio = ""
    if cfg['nice'] >= 0:
        prio = "chrt --idle 0"
        #prio = "nice -n {}".format(cfg['nice'])

    args = cfg['args'].format(**cfg)
    fullcmd = "numactl -N {numa} -m {numa} {prio} {bin} {args} > {name}.out 2>&1"
    fullcmd = fullcmd.format(numa=NIC_NUMA_NODE, bin=binary, name=name, args=args, prio=prio)
    print("Running", fullcmd)
    proc = subprocess.Popen(fullcmd, shell=True, cwd=experiment['name'])
    time.sleep(3)

    if cfg['nice'] < 0:
        time.sleep(2)
        pid = proc.pid
        with open("/proc/{pid}/task/{pid}/children".format(pid=pid)) as f:
            for line in f:
                runcmd("sudo renice -n {} -p $(ls /proc/{}/task)".format(cfg['nice'], line.strip()))
    proc.poll()
    assert proc.returncode is None
    return proc

def launch_apps(experiment):
    procs = []
    for cfg in experiment['apps'][THISHOST]:
        print(cfg)
        if 'before' in cfg:
            for cmd in cfg['before']:
                eval(cmd)(cfg, experiment)
        launcher = {
            'shenango': launch_shenango_program,
            'linux': launch_linux_program,
        }.get(cfg['system'] if 'system' in cfg else experiment['system'])
        procs.append(launcher(cfg, experiment))
        if 'after' in cfg:
            for cmd in cfg['after']:
                eval(cmd)(cfg, experiment)
    return procs

def go_app(experiment_directory):
    assert os.access(experiment_directory, os.F_OK)
    with open(experiment_directory + "/config.json") as f:
        experiment = json.loads(f.read())
    if not "apps" in experiment or not THISHOST in experiment["apps"]:
        print("No apps found for this host!")
        return
    apps = experiment["apps"][THISHOST]
    if any([a['system'] == 'shenango' for a in apps]):
        iokerneld = start_iokerneld(experiment)
        cs = start_cstate()
    procs = launch_apps(experiment)
    for p in procs:
        p.wait()
    return 

def go_client(experiment_directory):
    assert os.access(experiment_directory, os.F_OK)
    with open(experiment_directory + "/config.json") as f:
        experiment = json.loads(f.read())
    iokerneld = start_iokerneld(experiment)
    cs = start_cstate()
    procs = []
    for cfg in experiment['clients'][THISHOST]:
        procs.append(launch_shenango_program(cfg, experiment))
    for p in procs:
        p.wait()
    return

def go_observer(experiment_directory):
    assert os.access(experiment_directory, os.F_OK)
    with open(experiment_directory + "/config.json") as f:
        experiment = json.loads(f.read())
    procs = []
    apps = [app for host in experiment['apps'] for app in experiment['apps'][host]]
    clients = [app for host in experiment['clients'] for app in experiment['clients'][host]]
    # for app in apps + clients:
    for app in clients:
        fullcmd = "sudo arp -d {ip} || true; "
        fullcmd += "go run rstat.go {ip} 1 "
        fullcmd += "| ts %s > rstat.{name}.log"
        procs.append(subprocess.Popen(fullcmd.format(**app), shell=True,cwd=experiment['name']))
    for p in procs:
        p.wait()

def go_server(experiment):
    procs = []
    procs.append(subprocess.Popen("mpstat 1 -N 0,1 2>&1| ts %s > mpstat.{}.log".format(
        THISHOST), shell=True, cwd=experiment['name']))
    procs.append(start_cstate())
    procs.append(start_iokerneld(experiment))   # iokernel
    procs += launch_apps(experiment)            # run apps
    return procs

def verify_dates(host_list):
    # TIP: Use ntp to sync times
    for i in range(3): # try a few extra times
        while True:
            dates = set(runremote("date +%s", host_list).splitlines())
            if dates:   break
            else:       print("retrying verify dates")
        if len(dates) == 1: return
        # Not more than one second off
        if len(dates) == 2:
            d1 = int(dates.pop())
            d2 = int(dates.pop())
            print(d1, d2)
            if (d1 - d2)**2 == 1:   return
        time.sleep(1)
    assert False

def setup_and_run_apps(experiment):
    print("Setting up apps on other servers")
    procs = []
    servers = [s for s in experiment['apps'].keys() if s != THISHOST]
    verify_dates(servers + [OBSERVER])
    if servers:
        runremote("mkdir -p {}".format(experiment['name']), servers)
        conf_fn = experiment['name'] + "/config.json"
        for i in experiment['app_files'] + [conf_fn, RSTAT]:
            runpara("scp {binary} {{}}:{dest}/".format(binary=i,dest=experiment['name']), servers)
        try: 
            for host in servers:
                outfile = "{dir}/py.{host}.log".format(dir=experiment['name'], host=host)
                cmd = "exec ssh -t -t {host} 'python {dir}/{script} -r app -n {dir} > {out} 2>&1'".format(
                    host=host, dir=experiment['name'], script=os.path.basename(__file__), out=outfile)
                print(cmd)
                if stopat == 1:
                    print("Stopped for debugging at {}".format(stopat)) 
                    time.sleep(3000)
                proc = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                time.sleep(10)
                # TODO: Returncode doesn't seem to be working without ssh -t -t. CHECK!
                assert not proc.returncode, "Apps on {} failed, check {}".format(host, outfile)

                # If any of the apps are linux-based on the remote server, set an arp entry
                if any([a['system'] == 'linux' for a in experiment['apps'][host]]):
                    runcmd("sudo arp -s {ip} {mac}".format(ip=IP_MAP[host], mac=MAC_MAP[host]))
                procs.append(proc)
        except:
            for p in procs:
                p.terminate()
                p.wait()
            raise
    return procs

def setup_clients(experiment):
    print("Setting up clients")
    servers = experiment['clients'].keys()
    verify_dates(servers + [OBSERVER])
    runremote("mkdir -p {}".format(
        experiment['name']), servers + [OBSERVER])
    conf_fn = experiment['name'] + "/config.json"
    for i in experiment['client_files'] + [conf_fn, RSTAT]:
        runpara("scp {binary} {{}}:{dest}/".format(
            binary=i,dest=experiment['name']), servers + [OBSERVER])

def setup_observer(experiment):
    observer = None
    observer_cmd = "exec ssh -t -t {observer} 'python {dir}/{script} -r observer -n {dir} > {dir}/py.{observer}.log 2>&1'".format(
        observer=OBSERVER, dir=experiment['name'], script=os.path.basename(__file__))
    print(observer_cmd)
    observer = subprocess.Popen(observer_cmd, shell=True)
    time.sleep(3)
    assert not observer.returncode, "Observer process failed, check {dir}/py.{observer}.log".format(
        observer=OBSERVER, dir=experiment['name'])
    return observer

def collect_logs(experiment, success):
    servers = list(set(experiment['clients'].keys() + experiment['apps'].keys()))
    runpara("scp {{}}:{exp}/*.log {exp}/ || true".format(exp=experiment['name']), servers + [OBSERVER])
    runpara("scp {{}}:{exp}/*.out {exp}/ || true".format(exp=experiment['name']), servers)
    runpara("scp {{}}:{exp}/*.err {exp}/ || true".format(exp=experiment['name']), servers)
    runpara("scp {{}}:{exp}/*_time {exp}/ || true".format(exp=experiment['name']), servers)
    runremote("rm -rf {}".format(experiment['name']), servers + [OBSERVER])
    if success: 
        if not os.path.exists('data'):  os.makedirs('data')
        runcmd("mv {exp} data/".format(exp=experiment['name']))
    return

def dump_cores_if_asked(experiment):
    try:
        for cfg in experiment['apps'][THISHOST]:
            if not cfg['dump']:
                continue
            # Issue SIGQUIT to the targeted process
            pidfile = os.path.join(experiment['name'], cfg['pidfile'])
            if not os.path.exists(pidfile):
                print("No pid file found, skipping process dump")
                continue
            pid = int(open(pidfile, 'r').read())
            # os.kill(pid, signal.SIGQUIT)
            os.system("sudo kill -3 " + str(pid))
    except Exception as ex:
        # Don't let an error here affect the run, ok to supress
        print("Error dumping the process." + str(ex))

def execute_experiment(experiment):
    if not os.path.exists(experiment['name']):    os.mkdir(experiment['name'])
    runcmd("cp {} {}/".format(__file__, experiment['name']))    # save a copy of this file
    conf_fn = experiment['name'] + "/config.json"
    with open(conf_fn, "w") as f:
        f.write(json.dumps(experiment))
    
    procs = []
    servers = None
    error = False
    try:
        procs += setup_and_run_apps(experiment)
        servers = go_server(experiment)
        procs += servers
        setup_clients(experiment)
        time.sleep(10)              # WHY?
        if OBSERVER: procs.append(setup_observer(experiment)) 
        if stopat == 3:
            print("Stopped for debugging at {}".format(stopat))   
            time.sleep(3000)
        runremote("ulimit -S -c unlimited; python {dir}/{script} -r client -n {dir} > {dir}/py.{{}}.log 2>&1".format(
            dir=experiment['name'], script=os.path.basename(__file__)), experiment['clients'].keys(), die_on_failure=True)
        if stopat == 4:
            print("Stopped for debugging at {}".format(stopat))  
            time.sleep(3000)
        # time.sleep(300) #UNDO: Wait some time to look at background numbers
    except:
        error = True
        raise
    finally:
        # if not error:
        #     dump_cores_if_asked(experiment)
        collect_logs(experiment, not error)
        for p in procs:
            if p is not None:
                p.terminate()
                p.wait()
            del p
        cleanup()
    return experiment

def go_replay(exp_folder):
    assert is_server()
    try:
        with open(exp_folder) as f:
            exp = json.loads(f.read())
    except:
        with open("{}/config.json".format(exp_folder)) as f:
            exp = json.loads(f.read())
    exp['client_files'] = filter(lambda l: "experiment.py" not in l, exp['client_files'])
    exp['client_files'].append(__file__)
    exp['name'] += "-replay"
    execute_experiment(exp)

def main():
    atexit.register(cleanup)

    parser = argparse.ArgumentParser("Makes concurrent requests to lambda URLs")
    parser.add_argument('-r', '--role', action='store', help='role', type=Role, choices=list(Role), default=Role.host)
    parser.add_argument('-n', '--name', action='store', help='Custom name for this experiment, defaults to datetime')
    parser.add_argument('-d', '--desc', action='store', help='Description/comments for this run', default="")
    parser.add_argument('-p', '--prot', action='store', help='Transport protocol (tcp/udp), default to tcp', default="tcp")
    parser.add_argument('-nc', '--nconns', action='store', help='Number of client TCP connections, defaults to 100',type=int, default=100)
    parser.add_argument('-sc', '--scores', action='store', help='Number of server cores, defaults to 4',type=int, default=SERVER_CORES)
    parser.add_argument('-w', '--warmup', action='store_true', help='Warm up the server before the experiment', default=False)
    parser.add_argument('--start', action='store', help='starting rate (mpps) (exclusive)', type=float, default=DEFAULT_START_MPPS)
    parser.add_argument('--finish', action='store', help='finish rate (mpps)', type=float, default=DEFAULT_MPPS)
    parser.add_argument('--steps', action='store', help='steps from start to finish', type=int, default=DEFAULT_SAMPLES)
    parser.add_argument('--time', action='store', help='duration for each step in secs', type=int, default=DEFAULT_RUNTIME_SECS)
    parser.add_argument('-nk', '--nokona', action='store_true', help='Run without Kona', default=False)
    parser.add_argument('-km', '--konamem', action='store', help='local mem for kona', type=int, default=DEFAULT_KONA_MEM)
    parser.add_argument('-ket', '--konaet', action='store', help='kona evict threshold', type=float, default=DEFAULT_KONA_EVICT_THR)
    parser.add_argument('-kedt', '--konaedt', action='store', help='kona evict done threshold', type=float, default=DEFAULT_KONA_EVICT_DONE_THR)
    parser.add_argument('-kebs', '--konaebs', action='store', help='kona evict batch size', type=int, default=DEFAULT_EVICTION_BATCH_SIZE)
    parser.add_argument('--gdb', action='store_true', help="wait to attach the main process to gdb (for debugging)", default=False)
    parser.add_argument('--noht', action='store_true', help="run without hyperthreading", default=False)
    parser.add_argument('--stopat', action='store', help="stop program at a certain point (for debugging)", type=int, default=0)

    args = parser.parse_args()

    global role, stopat, gdb
    stopat = args.stopat
    gdb = args.gdb
    role = args.role
    if role == Role.host:
        assert is_server()
        execute_experiment(bench_memcached(
            "shenango", args.scores, 
            name=args.name, desc=args.desc,
            start_mpps=args.start, mpps=args.finish, samples=args.steps, time=args.time,
            kona=not args.nokona, kona_mem=args.konamem, kona_evict_thr=args.konaet, 
            kona_evict_done_thr=args.konaedt, kona_evict_batch_sz=args.konaebs, 
            transport=args.prot, nconns=args.nconns, warmup=args.warmup, dump_core=False,
            noht=args.noht
        ))

    elif role == role.app:
        assert args.name
        cleanup(pre=True)    # HACK for kona cleanup.
        time.sleep(5)
        go_app(args.name)
    elif role == role.client:
        assert args.name
        go_client(args.name)
    elif role == Role.observer:
        assert args.name
        go_observer(args.name)

if __name__ == '__main__':
    main()