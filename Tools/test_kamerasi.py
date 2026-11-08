#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""TEST KAMERASI - gercek kameranin yerine gecer; yalnizca uygulamayi (ekran goruntuleri / otomatik test) denemek icin.
Protokolu taklit eder: el sikisma, LoginDev/GetDevInfo/GetDevVideoInfo cevaplari ve OpenVideo ile 01AFAFAF cerceveli
H.264 akisi. Akis, Tools/test_sahne.h264 dosyasindaki TEST SAHNESIDIR (gercek bir belge/kamera goruntusu degildir).
Sahte UID: GHBB-000001-TESTX   Kullanim: python3 Tools/test_kamerasi.py   (127.0.0.1:32100 dinler)"""
import json, socket, struct, threading, time

F1=0xF1; T_PUNCH=0x41; T_P2P_RDY=0x42; T_P2P_RDY_ACK=0x43
T_DRW=0xD0; T_DRW_ACK=0xD1; T_ALIVE=0xE0; T_ALIVE_ACK=0xE1; T_CLOSE=0xF0
T_LAN=0x30; T_REQ=0x20
MYKJ=b"\xa0\xaf\xaf\xaf"; TR=b"\xf4\xf3\xf2\xf1"; VID=b"\x01\xaf\xaf\xaf"

def f1(t,p=b""): return bytes([F1,t,(len(p)>>8)&0xFF,len(p)&0xFF])+p
def mykj(js):
    b=js.encode(); buf=bytearray(26+len(b)+4); buf[0:4]=MYKJ; buf[5]=8
    struct.pack_into("<Q",buf,6,int(time.time())+8*3600)
    struct.pack_into("<I",buf,22,len(b)); buf[26:26+len(b)]=b; buf[26+len(b):]=TR
    return bytes(buf)
def drw(ch,idx,body): return f1(T_DRW,bytes([0xD1,ch,(idx>>8)&0xFF,idx&0xFF])+body)
def mykj_dec(d):
    i=d.find(MYKJ)
    if i<0: return None
    n=struct.unpack_from("<I",d,i+22)[0]
    return d[i+26:i+26+n].decode("utf-8","replace")

def nal(t,size=40):  # basit H.264 NAL: 00 00 00 01 <tip baytı> + dolgu
    return b"\x00\x00\x00\x01"+bytes([t])+b"\x11"*size
def vframe(payload):
    hdr=bytearray(83); hdr[0:4]=VID
    struct.pack_into("<I",hdr,79,len(payload))
    return bytes(hdr)+payload

class Cam:
    def __init__(self):
        self.s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
        self.s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
        import os; self.s.bind((os.environ.get("SAHTE_BIND","127.0.0.1"),32100)); self.s.settimeout(0.3)
        self.cli=None; self.run=True; self.streaming=False; self.vidx=0
        self.load_video()
        self.did=b"GHBB"+struct.pack(">Q",1)+b"TESTX\0\0\0"
    def reply(self,cmd):
        m={"LoginDev":{"cmd":"LoginDev","result":0,"connectNum":1,"devtype":"ipc","audioType":2,"SampleRate":8000,"csType":1,"time":0},
           "AppointDev":{"cmd":"AppointDev","state":0},
           "GetDevInfo":{"cmd":"GetDevInfo","id":"GHBB-000001-TESTX","ver":"Mar 16 2026 14:28:19","ip":"192.168.100.1"},
           "GetDevVideoInfo":{"cmd":"GetDevVideoInfo","brightness":30,"saturation":30},
           "GetDevStream":{"cmd":"GetDevStream","mainstream":"4K","substream":"2K","threestream":"1080P"}}
        return m.get(cmd)
    def load_video(self):
        """Test sahnesi akisindan erisim birimleri uretir (3 ve 4 baytlik baslangic kodlarini ayirir)."""
        import os, re
        path=os.environ.get("TEST_VIDEO",os.path.join(os.path.dirname(os.path.abspath(__file__)),"test_sahne.h264"))
        data=open(path,"rb").read()
        idx=[m.start() for m in re.finditer(b"\x00\x00\x01",data)]
        nals=[b"\x00\x00\x00\x01"+data[a+3:b].rstrip(b"\x00") for a,b in zip(idx,idx[1:]+[len(data)])]
        aus=[];cur=b""
        for n in nals:
            t=n[4]&0x1F
            if t in (1,5):
                aus.append(cur+n); cur=b""
            else:
                cur+=n
        self.aus=aus
        self.hdr=bytes.fromhex("01 af af af 7b f4 0a 0b b7 0d 40 68 c9 6f 25 e8 17 6a 9d 49 b3 00 00 00 00 00 00 40 40 88 5d 5a 0e 03 45 75 f8 0c f9 01 bf ce 1c 00 00 00 ab 6f 03 00 00 00 00 00 77 51 6a 2f 00 00 00 00 00 00 78 00 0a b4 00 00 00 32 c4 18 f8 ac 5c 58 79 a8 1c 00 00")
    def send_pkt(self,idx,body):
        import random, os
        r=random.random()
        if r<float(os.environ.get("TEST_KAYIP","0")): return   # paket kaybi (varsayilan yok)
        pk=drw(0,idx,body)
        try:
            self.s.sendto(pk,self.cli)
            if r>0.95: self.s.sendto(pk,self.cli)  # %5 tekrar
            time.sleep(0.0002)
        except OSError: pass
    def stream_loop(self):
        n=0
        while self.run:
            if self.streaming and self.cli:
                au=self.aus[n%len(self.aus)]; n+=1
                h=bytearray(self.hdr); struct.pack_into("<I",h,79,len(au))
                data=bytes(h)+au+TR
                for k in range(0,len(data),1024):
                    self.send_pkt(self.vidx&0xFFFF,data[k:k+1024]); self.vidx+=1
                time.sleep(0.1)    # ~10 kare/sn
            else:
                time.sleep(0.05)
    def go(self):
        threading.Thread(target=self.stream_loop,daemon=True).start()
        print("[test kamerasi] 127.0.0.1:32100 dinleniyor", flush=True)
        while self.run:
            try: d,a=self.s.recvfrom(65535)
            except socket.timeout: continue
            if len(d)<2 or d[0]!=F1: continue
            t=d[1]; self.cli=a
            if t==T_PUNCH:
                self.s.sendto(f1(T_P2P_RDY,self.did),a)
            elif t==T_P2P_RDY:
                self.s.sendto(f1(T_P2P_RDY_ACK,self.did),a)
            elif t==T_ALIVE:
                self.s.sendto(f1(T_ALIVE_ACK),a)
            elif t==T_CLOSE:
                self.streaming=False
            elif t==T_DRW:
                pl=d[4:]; ch=pl[1]; idx=(pl[2]<<8)|pl[3]; body=pl[4:]
                js=mykj_dec(body)
                if not js: continue
                try: obj=json.loads(js)
                except Exception: continue
                cmd=obj.get("cmd")
                if cmd=="OpenVideo":
                    self.streaming = obj.get("state",0)!=0
                    continue
                r=self.reply(cmd)
                if r:
                    self.s.sendto(drw(1,idx,mykj(json.dumps(r,separators=(",",":")))),a)

if __name__=="__main__":
    try: Cam().go()
    except KeyboardInterrupt: pass
