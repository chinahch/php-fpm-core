#!/usr/bin/env python3
"""Read opt-in destination audit logs on a node as an authorized administrator."""
import argparse
import collections
import datetime as dt
import json
from pathlib import Path

def main():
    p=argparse.ArgumentParser(description="Query XBoard per-user destination audit")
    p.add_argument("--user",type=int,required=True)
    p.add_argument("--days",type=int,default=1)
    p.add_argument("--top",type=int,default=20)
    p.add_argument("--dir",default="/var/log/caddy/domain-audit")
    p.add_argument("--network",choices=("tcp","udp"))
    p.add_argument("--show-events",action="store_true")
    p.add_argument("--utc", action="store_true", help="Display timestamps in UTC instead of server local time")
    p.add_argument("--limit",type=int,default=20)
    a=p.parse_args()
    if a.user<=0 or not 1<=a.days<=365 or not 1<=a.top<=500 or not 1<=a.limit<=100:
        p.error("invalid query parameter")
    directory=Path(a.dir)
    if not directory.is_dir():
        p.error(f"log directory does not exist: {directory}")
    now=dt.datetime.now(dt.timezone.utc)
    since=now-dt.timedelta(days=a.days)
    counts=collections.Counter()
    events=[]
    for offset in range(a.days+1):
        day=(now-dt.timedelta(days=offset)).date().isoformat()
        path=directory/f"audit-{day}.jsonl"
        if not path.is_file():
            continue
        with path.open(encoding="utf-8") as stream:
            for line in stream:
                try:
                    event=json.loads(line)
                    if event.get("user_id")!=a.user: continue
                    if a.network and event.get("network")!=a.network: continue
                    stamp=dt.datetime.fromisoformat(event["time"].replace("Z","+00:00"))
                    if not since<=stamp<=now: continue
                    target=event.get("target")
                    if not target: continue
                    counts[target]+=1
                    if a.show_events: events.append((stamp,event))
                except (ValueError,TypeError,KeyError):
                    continue
    print(f"user_id={a.user} days={a.days} connections={sum(counts.values())}")
    print("count\ttarget")
    for target,count in counts.most_common(a.top):
        print(f"{count}\t{target}")
    if a.show_events:
        # Audit events are stored in UTC; only output is converted.
        display_tz = dt.timezone.utc if a.utc else dt.datetime.now().astimezone().tzinfo
        display_label = "UTC" if a.utc else "server local time"
        print(f"\nrecent connections ({display_label})")
        for stamp,event in sorted(events,reverse=True,key=lambda item:item[0])[:a.limit]:
            output_time = stamp.astimezone(display_tz).isoformat(timespec="seconds")
            print(f"{output_time}\t{event.get('network','')}\t{event.get('target','')}:{event.get('port','')}")

if __name__=="__main__":
    main()
