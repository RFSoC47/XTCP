"""Configure the XTCP reference application around one native Linux throughput measurement."""
import argparse
import contextlib
import json
from pathlib import Path
import subprocess
from xtcp_client import Control

def measure(host, bind, tcp, udp, mode, count, binary, output, seconds=45, rate=None):
    if count < 1 or seconds < 1 or seconds > 180:
        raise ValueError("Specify a positive byte count and a 1..180 second timeout")
    if output.exists() or Path(str(output)+".progress.jsonl").exists():
        raise FileExistsError(output)
    with contextlib.closing(Control(host, udp, bind)) as ctl:
        identity=ctl.identity()
        if (identity["ip"],identity["tcp"],identity["udp"])!=(host,tcp,udp):
            raise ValueError("Compiled network identity differs from command line")
        if ctl.read(0x105,1)[0]&1:
            raise RuntimeError("Endpoint already has an active TCP session")
        saved=[(a,ctl.read(a,n)) for a,n in ((4,1),(16,1),(24,8))]
        before=ctl.snapshot()
        try:
            ctl.write(24,count.to_bytes(8,"big"))
            maximum=100 if identity["profile"]==0 else 250
            selected=maximum if rate is None else rate
            if not 1<=selected<=maximum:raise ValueError(f"Rate must be in 1..{maximum}")
            ctl.write(16,bytes([selected]))
            ctl.write(4,bytes([{"send":0,"receive":1,"echo":64}[mode]]))
            run=subprocess.run([str(binary.resolve()),mode,host,bind,str(tcp),str(count),
                                str(seconds),str(output.resolve()),"0"],timeout=seconds+12)
            if run.returncode:
                raise RuntimeError(f"Native measurement failed with exit {run.returncode}")
            ctl.wait_idle()
            after=ctl.snapshot()
            report=json.loads(output.read_text())
            sent=(after["tx"]-before["tx"])%(1<<64)
            received=(after["rx"]-before["rx"])%(1<<64)
            if report["status"]!="PASS" or (sent,received)!=(count if mode!="send" else 0,count if mode!="receive" else 0):
                raise ValueError("FPGA snapshot and native TCP data disagree")
            t=report["completion_seconds"]
            return dict(identity=identity,mode=mode,bytes=count,seconds=t,payload_Gbps=count*8/t/1e9,
                        process_cpu_one_core_pct=100*(report["cpu_user_seconds"]+report["cpu_system_seconds"])/t,
                        fpga_tx=sent,fpga_rx=received,native_output=str(output))
        finally:
            ctl.wait_idle()
            for a,data in reversed(saved):
                ctl.write(a,data)

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("mode",choices=("send","receive","echo"));p.add_argument("host")
    p.add_argument("--bind",required=True);p.add_argument("--tcp",type=int,default=24)
    p.add_argument("--udp",type=int,default=4660);p.add_argument("--bytes",type=int,default=1073741841)
    p.add_argument("--binary",type=Path,required=True);p.add_argument("--output",type=Path,required=True)
    p.add_argument("--rate",type=int,help="Source target in units of 100 Mb/s")
    a=p.parse_args()
    print(json.dumps(measure(a.host,a.bind,a.tcp,a.udp,a.mode,a.bytes,a.binary,a.output,rate=a.rate),indent=2))
if __name__=="__main__":main()
