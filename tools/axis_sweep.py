import sys, json, asyncio, websockets
TEST = len(sys.argv)>1 and sys.argv[1]=="test"
OFFENDERS = {
 "A": (-100,100,-100,-100,100,-100,-100,-100),
 "B": (100,100,-100,-100,100,-100,100,-100),
 "C": (-100,100,100,-100,-100,-100,-100,100),
 "D": (100,100,100,-100,-100,-100,-100,100),
 "E": (100,100,-100,-100,-100,-100,-100,100),
}
ZOOMS=[90,95,100,105,110,120]; ROTS=[0,10,20,30,45]; PINS=[-20,-10,0,10,20]
if TEST:
    OFFENDERS={"A":OFFENDERS["A"]}; ZOOMS=[100,90]; ROTS=[10]; PINS=[-10]
def cornercfg(t):
    return {"tl":{"x":t[0],"y":t[1]},"tr":{"x":t[2],"y":t[3]},"br":{"x":t[4],"y":t[5]},"bl":{"x":t[6],"y":t[7]}}
async def rpc(ws,m,p):
    rpc.id=getattr(rpc,'id',0)+1; rid=rpc.id
    await ws.send(json.dumps({"jsonrpc":"2.0","id":rid,"method":m,"params":p}))
    while True:
        r=json.loads(await asyncio.wait_for(ws.recv(),timeout=35))
        if r.get("id")==rid: return r
async def sweep(ws,label):
    await rpc(ws,"lead.autotune",{"scan":True}); await asyncio.sleep(13); print(label,flush=True)
async def main():
    async with websockets.connect("ws://127.0.0.1:8081",open_timeout=5) as ws:
        for name,t in OFFENDERS.items():
            await rpc(ws,"corner.set",cornercfg(t)); await asyncio.sleep(1.2)
            await rpc(ws,"warp.set",{"deg":0,"panx":0,"pany":0}); await rpc(ws,"pincushion.set",{"x":0,"y":0})
            for z in ZOOMS:
                await rpc(ws,"scale.set",{"pct":z}); await asyncio.sleep(1.0); await sweep(ws,f"{name} zoom {z}")
            await rpc(ws,"scale.set",{"pct":100})
            for d in ROTS:
                await rpc(ws,"warp.set",{"deg":d,"panx":0,"pany":0}); await asyncio.sleep(1.0); await sweep(ws,f"{name} rot {d}")
            await rpc(ws,"warp.set",{"deg":0,"panx":0,"pany":0})
            for pn in PINS:
                await rpc(ws,"pincushion.set",{"x":pn,"y":pn}); await asyncio.sleep(1.0); await sweep(ws,f"{name} pin {pn}")
            await rpc(ws,"pincushion.set",{"x":0,"y":0})
asyncio.run(main())
