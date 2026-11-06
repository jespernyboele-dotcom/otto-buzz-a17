#!/usr/bin/env python3
"""OTTO EDL read-only discovery: Sahara -> Firehose -> GPT -> misc BCB backup.
Transport extracted from proven R29E worker; NO Firehose program/reset/erase.
"""
import ctypes as C, errno, hashlib, json, os, shlex, struct, sys, time, traceback
from pathlib import Path
fd=int(sys.argv[1]); usb_path=sys.argv[2]; programmer_path=Path(sys.argv[3]); edir=Path(sys.argv[4]); edir.mkdir(parents=True,exist_ok=True)
rawlog=edir/'usb_raw.hexlog'; SECTOR=512
GPT_SHA='712ca75b50cb24cec9e9a7beaf3a2bdeb1871d3a0a7276fad5243456edf1d181'
EXPECTED_GOCO='f7799eb9e38177ff7c7776e472b11c0e54c46e0a984232e3705000719cf30bba'
if hashlib.sha256(programmer_path.read_bytes()).hexdigest()!=EXPECTED_GOCO: raise SystemExit('goco7.bin SHA256 mismatch')
libc=C.CDLL(None,use_errno=True)
_IOC_NRSHIFT=0; _IOC_TYPESHIFT=8; _IOC_SIZESHIFT=16; _IOC_DIRSHIFT=30
_IOC_WRITE=1; _IOC_READ=2
def _IOC(d,t,n,s): return (d<<_IOC_DIRSHIFT)|(ord(t)<<_IOC_TYPESHIFT)|(n<<_IOC_NRSHIFT)|(s<<_IOC_SIZESHIFT)
def _IOR(t,n,c): return _IOC(_IOC_READ,t,n,C.sizeof(c))
def _IOWR(t,n,c): return _IOC(_IOC_READ|_IOC_WRITE,t,n,C.sizeof(c))
class Ctrl(C.Structure):
    _fields_=[("bRequestType",C.c_ubyte),("bRequest",C.c_ubyte),("wValue",C.c_ushort),("wIndex",C.c_ushort),("wLength",C.c_ushort),("timeout",C.c_uint),("data",C.c_void_p)]
class Bulk(C.Structure):
    _fields_=[("ep",C.c_uint),("len",C.c_uint),("timeout",C.c_uint),("data",C.c_void_p)]
USBDEVFS_CONTROL=_IOWR('U',0,Ctrl); USBDEVFS_BULK=_IOWR('U',2,Bulk)
USBDEVFS_CLAIMINTERFACE=_IOR('U',15,C.c_uint); USBDEVFS_RELEASEINTERFACE=_IOR('U',16,C.c_uint)

records=[]; stash=b""; ep_in=None; ep_out=None; iface=None
def H(b): return hashlib.sha256(b).hexdigest()
def q(v): return shlex.quote(str(v))
def log(direction,data): records.append((time.time(),direction,bytes(data)))
def flush():
    with rawlog.open("w") as f:
        for ts,d,b in records: f.write(f"{ts:.6f} {d} {len(b)} {b.hex()}\n")
def ioctl(req,obj,what):
    rc=libc.ioctl(fd,req,C.byref(obj))
    if rc<0:
        e=C.get_errno(); raise OSError(e,f"{what}: {os.strerror(e)}")
    return rc
def ctrl(dtype,index,length,timeout=3000):
    b=C.create_string_buffer(length)
    x=Ctrl(0x80,0x06,(dtype<<8)|index,0,length,timeout,C.cast(b,C.c_void_p))
    rc=ioctl(USBDEVFS_CONTROL,x,f"GET_DESCRIPTOR {dtype}/{index}")
    return bytes(b.raw[:rc])
def discover():
    dev=ctrl(1,0,18); vid=struct.unpack_from("<H",dev,8)[0]; pid=struct.unpack_from("<H",dev,10)[0]
    hdr=ctrl(2,0,9); total=struct.unpack_from("<H",hdr,2)[0]; blob=ctrl(2,0,total)
    candidates=[]; off=0; cur=None; alt=0; eps=[]
    def close():
        nonlocal cur,alt,eps
        if cur is None:return
        ins=[a for a,t in eps if a&0x80 and t==2]; outs=[a for a,t in eps if not(a&0x80) and t==2]
        if ins and outs:candidates.append((cur,alt,ins[0],outs[0]))
    while off+2<=len(blob):
        ln=blob[off]; typ=blob[off+1]
        if ln<2 or off+ln>len(blob): break
        d=blob[off:off+ln]
        if typ==4 and ln>=9: close(); cur=d[2]; alt=d[3]; eps=[]
        elif typ==5 and ln>=7 and cur is not None: eps.append((d[2],d[3]&3))
        off+=ln
    close(); candidates.sort(key=lambda x:(x[1]!=0,x[0],x[1]))
    if (vid,pid)!=(0x05c6,0x9008): raise RuntimeError(f"descriptor gate failed {vid:04x}:{pid:04x}")
    if not candidates: raise RuntimeError("no bulk endpoints")
    return vid,pid,*candidates[0]

vid,pid,iface,alt,ep_in,ep_out=discover()
ioctl(USBDEVFS_CLAIMINTERFACE,C.c_uint(iface),f"CLAIM {iface}")

def bw(data,timeout=30000):
    if not data:return 0
    total=0; mv=memoryview(data)
    while total<len(data):
        piece=bytes(mv[total:total+65536])
        b=C.create_string_buffer(piece,len(piece))
        x=Bulk(ep_out,len(piece),timeout,C.cast(b,C.c_void_p))
        rc=libc.ioctl(fd,USBDEVFS_BULK,C.byref(x))
        if rc<0:
            e=C.get_errno(); raise OSError(e,f"bulk_write: {os.strerror(e)}")
        if rc<=0: raise RuntimeError("zero bulk write")
        log("TX",piece[:rc]); total+=rc
    return total
def send_zlp(timeout=5000):
    x=Bulk(ep_out,0,timeout,C.c_void_p(0))
    rc=libc.ioctl(fd,USBDEVFS_BULK,C.byref(x))
    if rc<0:
        e=C.get_errno(); raise OSError(e,f"bulk_write_zlp: {os.strerror(e)}")
    log("TX_ZLP",b"")
    return rc
def br(maxlen=65536,timeout=1500,allow_timeout=False):
    req=max(4096,int(maxlen))
    while True:
        b=C.create_string_buffer(req)
        x=Bulk(ep_in,req,timeout,C.cast(b,C.c_void_p))
        rc=libc.ioctl(fd,USBDEVFS_BULK,C.byref(x))
        if rc<0:
            e=C.get_errno()
            if allow_timeout and e in (errno.ETIMEDOUT,110): return b""
            if e==errno.ENOMEM and req>4096: req=max(4096,req//2); continue
            raise OSError(e,f"bulk_read: {os.strerror(e)}")
        d=b.raw[:rc]; log("RX",d); return d

def response_doc(timeout_s=30, accept_stale=False):
    global stash
    pending=stash; stash=b""; seen=[]; start=time.time()
    while time.time()-start<timeout_s:
        progressed=True
        while progressed:
            progressed=False
            lo=pending.lower(); end=lo.find(b"</data>")
            if end>=0:
                end+=7; doc=pending[:end]; pending=pending[end:]; seen.append(doc); progressed=True
                dlo=doc.lower()
                if b"<response" in dlo and (b'value="ack"' in dlo or b"value='ack'" in dlo or b'value="nak"' in dlo or b"value='nak'" in dlo):
                    ack=b'value="ack"' in dlo or b"value='ack'" in dlo
                    nak=b'value="nak"' in dlo or b"value='nak'" in dlo
                    raw=b'rawmode="true"' in dlo or b"rawmode='true'" in dlo
                    if accept_stale or raw or nak:
                        stash=pending+stash
                        return b"".join(seen),ack,nak,raw
                    continue
        d=br(65536,1000,True)
        if d: pending+=d
    stash=pending+stash
    return b"".join(seen)+pending,False,False,False

def terminal_ack(timeout_s=6):
    global stash
    pending=stash; stash=b""; seen=[]; start=time.time()
    while time.time()-start<timeout_s:
        progressed=True
        while progressed:
            progressed=False
            lo=pending.lower(); end=lo.find(b"</data>")
            if end>=0:
                end+=7; doc=pending[:end]; pending=pending[end:]; seen.append(doc); progressed=True
                dlo=doc.lower()
                if b"<response" in dlo and (b'value="ack"' in dlo or b"value='ack'" in dlo or b'value="nak"' in dlo or b"value='nak'" in dlo):
                    stash=pending+stash
                    return b"".join(seen), (b'value="ack"' in dlo or b"value='ack'" in dlo), (b'value="nak"' in dlo or b"value='nak'" in dlo)
        d=br(65536,750,True)
        if d: pending+=d
    stash=pending+stash
    return b"".join(seen)+pending,False,False

def drain_startup():
    global stash
    stash=b""; quiet=0; start=time.time()
    while time.time()-start<12 and quiet<4:
        d=br(65536,750,True); quiet=0 if d else quiet+1

def fh_simple(xml):
    bw(xml); r,a,n,_=response_doc(20,True); return r,a,n

def fh_read(lba,nbytes,label):
    global stash
    if nbytes%SECTOR: raise RuntimeError("unaligned read")
    nsect=nbytes//SECTOR; stash=b""
    xml=(f'<?xml version="1.0" ?><data><read SECTOR_SIZE_IN_BYTES="512" num_partition_sectors="{nsect}" physical_partition_number="0" start_sector="{lba}" /></data>').encode()
    t0=time.monotonic(); bw(xml)
    pre,a,n,raw=response_doc(20,False)
    (edir/f"{label}.READ_PRE_XML.bin").write_bytes(pre)
    if n or not a or not raw: return b"",False,False,time.monotonic()-t0
    data=bytearray()
    while len(data)<nbytes:
        if stash:
            need=nbytes-len(data); data+=stash[:need]; stash=stash[need:]; continue
        d=br(min(65536,nbytes-len(data)),5000,True)
        if not d: return bytes(data),False,False,time.monotonic()-t0
        need=nbytes-len(data); data+=d[:need]
        if len(d)>need: stash=d[need:]+stash
    term,a2,n2=terminal_ack(8)
    (edir/f"{label}.READ_POST_XML.bin").write_bytes(term)
    return bytes(data),True,bool(a2 and not n2),time.monotonic()-t0

def fh_read_span(lba,nbytes,label,max_chunk=1048576):
    # Firehose is proven for <=1 MiB raw read payloads. Never request the
    # whole 8 MiB init_boot_b in one read command: R1 showed the target
    # returned exactly 1 MiB and then terminated rawmode.
    if nbytes%SECTOR: raise RuntimeError("unaligned span read")
    out=bytearray(); total_dt=0.0
    off=0; idx=0
    while off<nbytes:
        take=min(max_chunk,nbytes-off)
        d,ok,ack,dt=fh_read(lba+(off//SECTOR),take,f"{label}_C{idx}")
        total_dt+=dt
        if not ok or len(d)!=take:
            return bytes(out)+bytes(d),False,False,total_dt
        out+=d
        off+=take; idx+=1
    return bytes(out),True,True,total_dt



def run():
    hello=br(4096,10000)
    if len(hello)<24 or struct.unpack_from("<I",hello,0)[0]!=1: raise RuntimeError("Sahara HELLO missing")
    _,_,ver,minver=struct.unpack_from("<IIII",hello,0)
    bw(struct.pack("<12I",2,0x30,ver,max(1,min(minver,ver)),0,0,0,0,0,0,0,0))
    while True:
        pkt=br(4096,10000)
        if len(pkt)<8: raise RuntimeError("short Sahara packet")
        cmd=struct.unpack_from("<I",pkt,0)[0]
        if cmd==3: _,_,img,off,n=struct.unpack_from("<IIIII",pkt,0)
        elif cmd==0x12: _,_,img,off,n=struct.unpack_from("<IIQQQ",pkt,0)
        elif cmd==4: _,_,img,end_status=struct.unpack_from("<IIII",pkt,0); break
        else: raise RuntimeError(f"unexpected Sahara cmd {cmd:#x}")
        if off+n>programmer_path.stat().st_size: raise RuntimeError("Sahara range outside programmer")
        pdata=programmer_path.read_bytes()[off:off+n]
        bw(pdata,15000)
    if end_status!=0: raise RuntimeError(f"programmer rejected {end_status}")
    bw(struct.pack("<II",5,8)); done=br(4096,10000)
    if len(done)<8 or struct.unpack_from("<I",done,0)[0]!=6: raise RuntimeError("Sahara DONE missing")
    drain_startup()

    nr,na,nn=fh_simple(b'<?xml version="1.0" ?><data><nop /></data>')
    if not na or nn: raise RuntimeError("NOP ACK not proven")
    cfg=b'<?xml version="1.0" ?><data><configure MemoryName="eMMC" Verbose="0" AlwaysValidate="0" MaxDigestTableSizeInBytes="2048" MaxPayloadSizeToTargetInBytes="1048576" ZlpAwareHost="1" SkipStorageInit="0" /></data>'
    cr,ca,cn=fh_simple(cfg)
    if not ca or cn: raise RuntimeError("configure ACK not proven")


    hdr,ok,ack,_=fh_read(1,512,'GPT_HEADER')
    if not ok or not ack or H(hdr)!=GPT_SHA or hdr[:8]!=b'EFI PART': raise RuntimeError('GPT identity failed')
    entry_lba=struct.unpack_from('<Q',hdr,72)[0]
    nent=struct.unpack_from('<I',hdr,80)[0]
    entsz=struct.unpack_from('<I',hdr,84)[0]
    if not 1<=nent<=4096 or not 128<=entsz<=1024: raise RuntimeError('Invalid GPT geometry')
    padded=((nent*entsz+511)//512)*512
    tab,ok,ack,_=fh_read(entry_lba,padded,'GPT_ENTRIES')
    if not ok or not ack or len(tab)!=padded: raise RuntimeError('GPT entry read failed')
    matches=[]
    for i in range(nent):
        e=tab[i*entsz:(i+1)*entsz]
        if len(e)<128 or e[:16]==b'\0'*16: continue
        first,last=struct.unpack_from('<QQ',e,32)
        name=e[56:128].decode('utf-16le','ignore').split('\0',1)[0]
        if name=='misc': matches.append((first,last))
    if len(matches)!=1: raise RuntimeError(f'Expected one misc partition, found {len(matches)}')
    first,last=matches[0]
    if last-first+1<4: raise RuntimeError('misc smaller than 2048 bytes')
    # Read 2048 bytes: full BCB, preserving all bytes, with zero device writes.
    bcb,ok,ack,_=fh_read(first,2048,'MISC_BCB')
    if not ok or not ack or len(bcb)!=2048: raise RuntimeError('BCB read incomplete')
    (edir/'misc_bcb_2048.bin').write_bytes(bcb)
    (edir/'misc_first_2048.sha256').write_text(H(bcb)+'  misc_bcb_2048.bin\n')
    # Report command without leaking other BCB contents into plain text.
    cmd=bcb[:32].split(b'\0',1)[0]
    result={'status':'READ_ONLY_PASS','usb_path':usb_path,'gpt_header_sha256':H(hdr),
      'misc_first_lba':first,'misc_last_lba':last,'bcb_sha256':H(bcb),
      'bcb_command_hex':cmd.hex(),'bcb_command_ascii':cmd.decode('ascii','backslashreplace'),
      'device_writes':0,'power_reset_sent':False}
    (edir/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2),flush=True)

try:
    run()
except Exception as exc:
    (edir/'result.json').write_text(json.dumps({'status':'FAIL','error':str(exc),'device_writes':0},indent=2)+'\n')
    (edir/'error.txt').write_text(traceback.format_exc())
    print('READ_ONLY_FAIL:',str(exc),flush=True)
    sys.exit(1)
finally:
    flush()
