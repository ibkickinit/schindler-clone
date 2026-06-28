import json, asyncio, websockets
# cardinal +/-15 deg, with no corner-pin vs a coherent keystone (top edge narrowed by 100px)
CORNERS={
 "none":     {"tl":{"x":0,"y":0},"tr":{"x":0,"y":0},"br":{"x":0,"y":0},"bl":{"x":0,"y":0}},
 "keystone": {"tl":{"x":-100,"y":0},"tr":{"x":-100,"y":0},"br":{"x":0,"y":0},"bl":{"x":0,"y":0}},
}
ANGLES=[0,15,345, 75,90,105, 165,180,195, 255,270,285]
async def rpc(ws,m,p):
    rpc.id=getattr(rpc,'id',0)+1; rid=rpc.id
    await ws.send(json.dumps({"jsonrpc":"2.0","id":rid,"method":m,"params":p}))
    while True:
        r=json.loads(await asyncio.wait_for(ws.recv(),timeout=30))
        if r.get("id")==rid: return r
async def main():
    async with websockets.connect("ws://127.0.0.1:8081",open_timeout=5) as ws:
        await rpc(ws,"scale.set",{"pct":100}); await asyncio.sleep(1)
        for cname,cfg in CORNERS.items():
            for deg in ANGLES:
                await rpc(ws,"corner.set",dict(cfg,override=True)); await asyncio.sleep(0.8)
                await rpc(ws,"warp.set",{"deg":deg,"panx":0,"pany":0}); await asyncio.sleep(1.0)
                await rpc(ws,"lead.autotune",{"scan":True}); await asyncio.sleep(12)
                print(f"{cname:9} deg={deg}",flush=True)
asyncio.run(main())
