#!/usr/bin/env python3
import json, os, subprocess, urllib.request, urllib.error, datetime, time, re, sys
ENV="/etc/freeap-notify.env"; STATE="/var/lib/freeap-notify/state.json"
LEASES="/var/lib/misc/freeap.leases"
DESTROY="/var/lib/freeap-notify/destroy.log"
DNSLOG="/var/log/freeap-dns.log"
JST=datetime.timezone(datetime.timedelta(hours=9))
DISCORD_LIMIT=2000
FL=re.compile(r"src=(\S+) dst=(\S+) .*?dport=(\d+) .*?bytes=(\d+) .*?bytes=(\d+).*?id=(\d+)")
DHCPACK=re.compile(r"DHCPACK\(freeap0\) (\S+) (\S+)(?: (\S+))?")
DNSREPLY=re.compile(r"(?:reply|cached) (\S+) is (\d+\.\d+\.\d+\.\d+)")
SVC=[("chatgpt.com","ChatGPT"),("openai.com","OpenAI"),("oaiusercontent","ChatGPT"),("youtube","YouTube"),("googlevideo","YouTube"),("ytimg","YouTube"),
 ("playstore","Play Store"),("gvt1.com","Google DL"),("googlezip","Chrome Lite"),("googleapis","Google API"),("google","Google"),("gstatic","Google"),
 ("windowsupdate","Win Update"),("xboxlive","Xbox"),("aadg","Microsoft"),("azure","Microsoft"),("msedge.net","Microsoft"),("azurefd","Microsoft"),("windows.net","Microsoft"),("microsoft","Microsoft"),("office","Microsoft"),("live.com","Microsoft"),
 ("icloud","Apple"),("apple","Apple"),("instagram","Instagram"),("fbcdn","Meta"),("facebook","Meta"),("whatsapp","WhatsApp"),("tiktok","TikTok"),("byteoversea","TikTok"),
 ("twitter","X"),("twimg","X"),("x.com","X"),("discord","Discord"),("line-apps","LINE"),("line.me","LINE"),("amazonaws","AWS"),("cloudfront","AWS"),("akamai","Akamai"),("cloudflare","Cloudflare"),
 ("netflix","Netflix"),("nflxvideo","Netflix"),("spotify","Spotify"),("steam","Steam"),("hoyoverse","HoYoverse"),("mihoyo","HoYoverse")]

def webhook():
    for l in open(ENV):
        if l.startswith("WEBHOOK="): return l.strip().split("=",1)[1]

def req(method,url,body):
    r=urllib.request.Request(url,data=json.dumps(body).encode(),method=method,
        headers={"Content-Type":"application/json","User-Agent":"freeap-notify/1.0"})
    with urllib.request.urlopen(r,timeout=15) as f:
        t=f.read(); return json.loads(t) if t else {}

def rd(path):
    try: return int(open(path).read())
    except Exception: return 0

def fmt(b):
    for u in ["B","KB","MB","GB","TB"]:
        if b<1024 or u=="TB": return f"{b:.1f}{u}" if u!="B" else f"{int(b)}B"
        b/=1024

def fmt_dur(sec):
    try: sec=int(sec)
    except Exception: return "-"
    if sec<60: return f"{sec}秒"
    m,s=divmod(sec,60)
    if m<60: return f"{m}分"
    h,m=divmod(m,60)
    return f"{h}:{m:02d}"

def fmt_min(minutes):
    try: minutes=int(minutes)
    except Exception: return "-"
    if minutes<=0: return "-"
    if minutes<60: return f"{minutes}分"
    h,m=divmod(minutes,60)
    return f"{h}:{m:02d}"

def tunnel():
    a=subprocess.run(["systemctl","is-active","usque"],capture_output=True,text=True).stdout.strip()
    t=subprocess.run(["curl","-s","-m","8","--interface","usque0","https://1.1.1.1/cdn-cgi/trace"],capture_output=True,text=True).stdout
    kv=dict(l.split("=",1) for l in t.splitlines() if "=" in l)
    return a, kv.get("warp","失敗"), kv.get("colo","-")

def reconnects():
    out=subprocess.run(["journalctl","-u","usque","--since","today","--no-pager","-q"],capture_output=True,text=True).stdout
    return out.count("Tunnel connection lost")

def random_mac(mac):
    try: return bool(int(mac.split(":")[0],16)&0x02)
    except Exception: return False

def short_mac(mac):
    p=mac.split(":")
    return ":".join(p[-3:]) if len(p)>=3 else mac

def clean_name(n):
    n=re.sub(r"[\x00-\x1f`]+","", (n or "").strip())
    return n[:24]

def remember_name(s, mac, ip, hostname=""):
    mac=(mac or "").lower(); ip=ip or ""
    if mac and ip: s.setdefault("ipmac",{})[ip]=mac
    hn=clean_name(hostname) if hostname and hostname not in ("*","+") else ""
    if hn and mac:
        s.setdefault("names",{})[mac]=hn
        if ip: s.setdefault("ipnames",{})[ip]=hn
    elif hn and ip:
        s.setdefault("ipnames",{})[ip]=hn

def dev_name(s, mac=None, ip=None):
    mac=(mac or s.get("ipmac",{}).get(ip or "") or "").lower()
    if mac and s.get("names",{}).get(mac):
        return s["names"][mac]
    if ip and s.get("ipnames",{}).get(ip):
        return s["ipnames"][ip]
    if mac:
        return short_mac(mac)+("※" if random_mac(mac) else "")
    if ip and ip.startswith("10.42."):
        return "."+".".join(ip.split(".")[2:])
    return "不明"

def read_leases(s):
    try: lines=open(LEASES,errors="replace")
    except Exception: return
    for line in lines:
        p=line.split()
        if len(p)<4: continue
        remember_name(s, p[1], p[2], p[3])

def parse_dhcpack(s, line):
    m=DHCPACK.search(line)
    if m: remember_name(s, m.group(2), m.group(1), m.group(3) or "")

def backfill_names(s):
    if s.get("names_v")!=2:
        s["names_filled"]=False
    if not s.get("names_filled"):
        for path in (DNSLOG+".2", DNSLOG+".1", DNSLOG):
            try:
                for line in open(path, errors="replace"):
                    parse_dhcpack(s, line)
            except Exception:
                pass
        s["names_filled"]=True
        s["names_v"]=2
    read_leases(s)

def station_details():
    out=subprocess.run(["/usr/sbin/iw","dev","freeap0","station","dump"],capture_output=True,text=True).stdout
    stas=[]; cur=None
    for line in out.splitlines():
        if line.startswith("Station "):
            if cur: stas.append(cur)
            cur={"mac":line.split()[1].lower(),"signal":None,"connected":0}
        elif cur:
            ls=line.strip()
            if ls.startswith("signal:") and "avg" not in ls.split(":")[0]:
                try: cur["signal"]=int(ls.split()[1])
                except Exception: pass
            elif ls.startswith("connected time:"):
                try: cur["connected"]=int(ls.split()[2])
                except Exception: pass
    if cur: stas.append(cur)
    return stas

def stations():
    return sorted(x["mac"] for x in station_details())

def flowparse(line):
    m=FL.search(line)
    if not m: return None
    src,d,port,b1,b2,i=m.groups()
    if not src.startswith("10.42.") or src=="10.42.0.1" or d.startswith("10.42."): return None
    return i, src, f"{d}:{port}", int(b1)+int(b2)

def readnew(path,key,s):
    try: size=os.path.getsize(path)
    except Exception: return []
    off=s.get(key,0)
    if off>size: off=0
    with open(path,errors="replace") as f:
        f.seek(off); data=f.read(); s[key]=f.tell()
    return data.splitlines()

def prev_bytes(ent):
    if not ent or not isinstance(ent,(list,tuple)): return 0
    for i in (2,1):
        if len(ent)>i and isinstance(ent[i],(int,float)): return int(ent[i])
    return 0

def add_flow(s, bucket, src, dst, b):
    if b<=0: return
    bucket[f"{src}|{dst}"]=bucket.get(f"{src}|{dst}",0)+b
    mac=s.get("ipmac",{}).get(src)
    owner=mac or src
    s.setdefault("day_dest",{})[f"{owner}|{dst}"]=s["day_dest"].get(f"{owner}|{dst}",0)+b
    s.setdefault("day_dev",{})[owner]=s["day_dev"].get(owner,0)+b

def backfill_day(s):
    if s.get("dest_v")==2 and "day_dest" in s: return
    s["day_dest"]={}; s["day_dev"]={}
    try:
        for line in open(DESTROY, errors="replace"):
            r=flowparse(line)
            if r:
                _,src,dst,b=r
                add_flow(s, {}, src, dst, b)
    except Exception:
        pass
    s["dest_v"]=2

def flows(s,minute):
    prev=s.get("fl_prev",{}); bucket={}
    for l in readnew(DNSLOG,"dns_off",s):
        parse_dhcpack(s,l)
        m=DNSREPLY.search(l)
        if m: s.setdefault("dns",{})[m.group(2)]=m.group(1)
    if len(s.get("dns",{}))>5000: s["dns"]=dict(list(s["dns"].items())[-3000:])
    for l in readnew(DESTROY,"fl_off",s):
        r=flowparse(l)
        if r:
            i,src,dst,b=r
            old=prev.pop(i, None)
            add_flow(s,bucket,src,dst, b-prev_bytes(old) if old is not None else b)
    out=subprocess.run(["/usr/sbin/conntrack","-L","-s","10.42.0.0/24","-o","id,extended"],capture_output=True,text=True).stdout
    cur={}
    for l in out.splitlines():
        r=flowparse(l)
        if r:
            i,src,dst,b=r; cur[i]=[src,dst,b]
            old=prev.get(i)
            add_flow(s,bucket,src,dst, b-prev_bytes(old) if old is not None else b)
    s["fl_prev"]=cur
    b=s.setdefault("buckets",{}); mk=str(minute)
    acc=b.get(mk,{})
    for k,v in bucket.items(): acc[k]=acc.get(k,0)+v
    b[mk]=acc
    for k in [k for k in b if int(k)<minute-60]: del b[k]

def svc(name):
    n=(name or "").lower()
    for k,v in SVC:
        if k in n: return v
    return ""

def split_key(k):
    if "|" in k:
        src,dest=k.split("|",1)
        return src,dest
    return "",k

def owner_name(s, owner):
    if not owner:
        return "不明"
    if re.match(r"(?i)^[0-9a-f]{2}(:[0-9a-f]{2}){5}$", owner):
        return dev_name(s, mac=owner)
    return dev_name(s, ip=owner)

def dest_rows(s, data, limit=15, minb=100*1024):
    grp={}
    for k,v in data.items():
        src,dest=split_key(k)
        ip,port=dest.rsplit(":",1) if ":" in dest else (dest,"")
        name=s.get("dns",{}).get(ip)
        key=name or (f"{ip}:{port}" if port else ip)
        g=grp.setdefault(key,[0,set(),{}]); g[0]+=v; g[1].add(ip)
        dn=owner_name(s, src) if src else "不明"
        g[2][dn]=g[2].get(dn,0)+v
    allbig=sorted(((g[0],k,len(g[1]),g[2]) for k,g in grp.items() if g[0]>=minb),reverse=True)
    big=allbig[:limit]
    if not big: return ["（なし）"], False
    rows=[]; used_rand=False
    for v,k,nip,devs in big:
        items=sorted(devs.items(), key=lambda x:-x[1])
        names=[n for n,_ in items if n!="不明"] or [n for n,_ in items]
        if any(n.endswith("※") for n in names): used_rand=True
        if not names or names==["不明"]:
            dstr=""
        elif len(names)==1:
            dstr="  "+names[0]
        else:
            extra=len(names)-2
            dstr="  "+names[0]+", "+names[1]+(f" +{extra}" if extra>0 else "")
        host=k if len(k)<=28 else "…"+k[-27:]
        rows.append(f"{fmt(v):>8}  {(svc(k) or '-'):<11} {host}"+(f" ×{nip}IP" if nip>1 else "")+dstr)
    if len(allbig)>limit: rows.append(f"{'':>8}  ほか{len(allbig)-limit}件（{fmt(sum(x[0] for x in allbig[limit:]))}）")
    return ["```"]+rows+["```"], used_rand

def topdest(s, daily=False, limit=15):
    if daily:
        data=s.get("day_dest") or {}
        if not data:
            data={}
            for bk in s.get("buckets",{}).values():
                for d,v in bk.items(): data[d]=data.get(d,0)+v
    else:
        data={}
        for bk in s.get("buckets",{}).values():
            for d,v in bk.items(): data[d]=data.get(d,0)+v
    return dest_rows(s, data, limit=limit)

def online_rows(s):
    rows=[]; used_rand=False
    for d in s.get("online") or []:
        name=d.get("name") or dev_name(s, mac=d.get("mac"), ip=d.get("ip"))
        if name.endswith("※"): used_rand=True
        ip=d.get("ip") or "-"
        short="."+".".join(ip.split(".")[2:]) if ip.startswith("10.42.") else ip
        sig=f"{d['signal']}dBm" if d.get("signal") is not None else "-dBm"
        traf=fmt(d.get("traffic") or 0)
        rows.append(f"{name:<16} {short:<7} {fmt_dur(d.get('connected',0)):>5} {sig:>7} {traf:>7}")
    return rows, used_rand

def device_rank(s):
    traffic=s.get("day_dev") or {}
    devs=s.get("devs") or {}
    claimed=set()
    rows=[]
    def take(owner, mins, name, *extra_keys):
        by=traffic.get(owner,0)
        for k in extra_keys:
            if k and k not in claimed and k in traffic:
                by+=traffic[k]; claimed.add(k)
        claimed.add(owner)
        rows.append((by, mins or 0, name, owner))
    for mac,info in devs.items():
        name=info.get("name") or dev_name(s, mac=mac, ip=info.get("ip"))
        take(mac, info.get("minutes") or 0, name, info.get("ip"))
    for mac in s.get("macs") or []:
        if mac in claimed: continue
        take(mac, 0, dev_name(s, mac=mac), (s.get("macip") or {}).get(mac))
    for k,by in traffic.items():
        if k in claimed: continue
        if k=="10.42.0.1":
            continue
        if re.match(r"^\d+\.\d+\.\d+\.\d+$", k):
            mac=s.get("ipmac",{}).get(k)
            if mac and mac in claimed: continue
            take(k, 0, dev_name(s, mac=mac, ip=k))
        else:
            take(k, 0, owner_name(s, k))
    rows.sort(key=lambda x:(-x[0],-x[1],x[2]))
    out=[]; used=set(); used_rand=False
    for by,mins,name,key in rows:
        if key in used: continue
        used.add(key)
        if name.endswith("※"): used_rand=True
        out.append((by,mins,name))
    return out, used_rand

def _render(s, final, ndest, nrank):
    avg=s["sum"]/s["samples"] if s["samples"] else 0
    hrs=s["devmin"]/60
    dest, dest_rand=topdest(s, daily=final, limit=ndest)
    title=f"📶 **フリーWiFi 接続台数 {s['date']}**" + ("（確定）" if final else "")
    lines=[title,
      f"終了時: {s['cur']}台" if final else f"現在: **{s['cur']}台**",
      f"最大: {s['max']}台（{s['max_at']} JST）",
      f"延べ端末数: {len(s['macs'])}台",
      f"平均: {avg:.2f}台",
      f"合計接続時間: {hrs:.1f}台時間",
      f"接続あり時間帯: {', '.join(f'{h}時' for h in sorted(set(s['hours']),key=int)) or 'なし'}",
      ""]
    used_rand=dest_rand
    if not final:
        lines.append("📱 **接続中の端末**")
        on, on_rand=online_rows(s)
        used_rand=used_rand or on_rand
        if not on:
            lines.append("（なし）")
        else:
            lines.append("```")
            lines.extend(on)
            lines.append("```")
        lines.append("")
    else:
        rank, rank_rand=device_rank(s)
        used_rand=used_rand or rank_rand
        lines.append("📊 **端末別（通信量 / 接続時間）**")
        if not rank:
            lines.append("（なし）")
        else:
            show=rank[:nrank]
            rows=[f"{name:<16} {fmt(by):>8}  {fmt_min(mins):>6}" for by,mins,name in show]
            if len(rank)>nrank:
                rows.append(f"{'ほか'+str(len(rank)-nrank)+'台':<16} {fmt(sum(x[0] for x in rank[nrank:])):>8}")
            lines += ["```"]+rows+["```"]
        lines.append("")
    lines += [
      "🌐 **通信状況**",
      f"今日の通信量: 下り {fmt(s['down'])} / 上り {fmt(s['up'])}",
      (f"現在の速度: 下り {fmt(s['rate_down'])}/s / 上り {fmt(s['rate_up'])}/s" if not final else "現在の速度: -（締め済み）"),
      f"最大速度（1分平均）: 下り {fmt(s['peak_down'])}/s（{s['peak_at']} JST）",
      f"usque: {s['tun_active']} / warp={s['tun_warp']} / {s['tun_colo']}（{s['tun_at']} 確認）",
      f"トンネル再接続: 今日 {s['reconn']}回",
      "",
      "📡 **今日の通信先（100KB以上）**" if final else "📡 **直近1時間の通信先（100KB以上）**",
      *dest,
    ]
    if used_rand:
        lines.append("※はランダムMAC")
    lines += ["", f"{'確定' if final else '更新'}: {s['updated']} JST"]
    return "\n".join(lines)

def render(s, final=False):
    last="…"
    for ndest in [15,12,10,8,6,5,4,3,2,1,0]:
        for nrank in [16,12,8,6,4,3,2,1,0]:
            if not final and nrank!=16: continue
            text=_render(s, final, ndest, nrank)
            last=text
            if len(text)<=DISCORD_LIMIT:
                return text
    note="\n…（省略）"
    return last[:DISCORD_LIMIT-len(note)]+note

def save_state(s):
    os.makedirs(os.path.dirname(STATE),exist_ok=True)
    tmp=STATE+".tmp"; json.dump(s,open(tmp,"w")); os.replace(tmp,STATE)

def flush_pending(s, wh):
    p=s.get("pending_final")
    if not p or not p.get("msg") or not wh: return
    try:
        req("PATCH", f"{wh}/messages/{p['msg']}", {"content":p["content"]})
        s["pending_final"]=None
    except urllib.error.HTTPError as e:
        print("final patch HTTP", e.code, file=sys.stderr)
        if e.code==404:
            s["pending_final"]=None
    except Exception as e:
        print("final patch error", type(e).__name__, file=sys.stderr)

def update_online(s, sta):
    online=[]
    macip={}
    for ip,mac in s.get("ipmac",{}).items():
        macip[mac]=ip
    s["macip"]=macip
    day=s.get("day_dev") or {}
    for st in sta:
        mac=st["mac"]; ip=macip.get(mac,"")
        traf=day.get(mac,0)+ (day.get(ip,0) if ip else 0)
        name=dev_name(s, mac=mac, ip=ip or None)
        remember_name(s, mac, ip)
        info=s.setdefault("devs",{}).setdefault(mac,{"name":name,"ip":ip,"minutes":0,"first":s.get("updated") or "","last":s.get("updated") or ""})
        info["name"]=name; info["ip"]=ip or info.get("ip",""); info["last"]=s.get("updated") or info.get("last","")
        if not info.get("first"): info["first"]=s.get("updated") or ""
        online.append({"mac":mac,"ip":ip,"name":name,"signal":st.get("signal"),"connected":st.get("connected") or 0,"traffic":traf})
    s["online"]=online
    return online

def bump_devs(s, sta, hm):
    for st in sta:
        mac=st["mac"]
        ip=(s.get("macip") or {}).get(mac,"")
        name=dev_name(s, mac=mac, ip=ip or None)
        info=s.setdefault("devs",{}).setdefault(mac,{"name":name,"ip":ip,"minutes":0,"first":hm,"last":hm})
        info["name"]=name
        if ip: info["ip"]=ip
        info["minutes"]=info.get("minutes",0)+1
        info["last"]=hm
        if not info.get("first"): info["first"]=hm

def new_day(today, hm, n, keep):
    s={"date":today,"msg":None,"cur":n,"max":n,"max_at":hm,"macs":[],"sum":0,"samples":0,"devmin":0,"hours":[],"updated":hm,"last_content":"","down":0,"up":0,"rate_down":0,"rate_up":0,"peak_down":0,"peak_at":"-","tun_active":"-","tun_warp":"-","tun_colo":"-","tun_at":"-","reconn":0,"ctr":keep.get("ctr") or [None,None,None],
       "buckets":{},"day_dest":{},"day_dev":{},"devs":{},"online":[]}
    for k in ("fl_prev","fl_off","dns_off","dns","names","ipmac","ipnames","names_filled","pending_final"):
        if k in keep: s[k]=keep[k]
    return s

def main():
    dry="--dry-run" in sys.argv
    force="--force" in sys.argv
    os.makedirs(os.path.dirname(STATE),exist_ok=True)
    now=datetime.datetime.now(JST); today=now.strftime("%Y-%m-%d"); hm=now.strftime("%H:%M")
    try: s=json.load(open(STATE))
    except Exception: s=None
    sta=station_details(); macs=[x["mac"] for x in sta]; n=len(sta)
    if s:
        backfill_names(s)
        if not dry: backfill_day(s)
        else:
            # in-memory backfill for realistic final preview
            if "day_dest" not in s:
                tmp=json.loads(json.dumps(s))
                backfill_day(tmp)
                s["day_dest"]=tmp.get("day_dest",{})
                s["day_dev"]=tmp.get("day_dev",{})
    keep={}
    if dry:
        if not s:
            s=new_day(today,hm,n,{})
            backfill_names(s)
        s["cur"]=n; s["updated"]=hm
        update_online(s, sta)
        live=render(s, False)
        final=render(s, True)
        print("===== LIVE =====")
        print(live)
        print("===== LIVE LEN %d ====="%len(live))
        print("===== FINAL =====")
        print(final)
        print("===== FINAL LEN %d ====="%len(final))
        return
    wh=webhook()
    if s:
        flush_pending(s, wh)
        if s.get("date")!=today:
            content=render(s, True)
            if s.get("msg"):
                s["pending_final"]={"msg":s["msg"],"content":content,"date":s["date"]}
                save_state(s)
                flush_pending(s, wh)
                save_state(s)
            keep={k:s[k] for k in ["ctr","fl_prev","fl_off","dns_off","dns","names","ipmac","ipnames","names_filled","pending_final"] if k in s}
            s=None
    if not s:
        s=new_day(today,hm,n,keep)
        backfill_names(s)
    s["cur"]=n; s["sum"]+=n; s["samples"]+=1; s["devmin"]+=n
    if n>s["max"]: s["max"]=n; s["max_at"]=hm
    s["macs"]=sorted(set(s.get("macs") or [])|set(macs))
    if n: s["hours"]=sorted(set(s["hours"])|{str(now.hour)},key=int)
    s["updated"]=hm
    for k,v in {"down":0,"up":0,"rate_down":0,"rate_up":0,"peak_down":0,"peak_at":"-","tun_active":"-","tun_warp":"-","tun_colo":"-","tun_at":"-","reconn":0,"devs":{},"day_dest":{},"day_dev":{},"names":{},"ipmac":{},"ipnames":{},"online":[]}.items():
        s.setdefault(k,v)
    read_leases(s)
    tx=rd("/sys/class/net/freeap0/statistics/tx_bytes"); rx=rd("/sys/class/net/freeap0/statistics/rx_bytes"); t=time.time()
    lt,lr,lts=s.get("ctr",[None,None,None])
    if lt is not None and tx>=lt and rx>=lr and t>lts:
        dd,du=tx-lt,rx-lr; s["down"]+=dd; s["up"]+=du
        s["rate_down"]=dd/(t-lts); s["rate_up"]=du/(t-lts)
        if s["rate_down"]>s["peak_down"]: s["peak_down"]=s["rate_down"]; s["peak_at"]=hm
    s["ctr"]=[tx,rx,t]
    try: flows(s,int(t//60))
    except Exception as e: print("flows error",e)
    s["tun_active"],s["tun_warp"],s["tun_colo"]=tunnel(); s["tun_at"]=hm; s["reconn"]=reconnects()
    update_online(s, sta)
    bump_devs(s, sta, hm)
    flush_pending(s, wh)
    changed = force or n!=s.get("last_n") or now.minute%5==0 or not s["msg"] or s["tun_warp"]!=s.get("last_warp")
    if changed:
        c=render(s)
        if s["msg"]:
            try: req("PATCH",f"{wh}/messages/{s['msg']}",{"content":c})
            except urllib.error.HTTPError as e:
                if e.code==404: s["msg"]=None
                else: raise
        if not s["msg"]:
            s["msg"]=req("POST",wh+"?wait=true",{"content":c})["id"]
        s["last_n"]=n; s["last_warp"]=s["tun_warp"]
    save_state(s)

if __name__=="__main__":
    main()
