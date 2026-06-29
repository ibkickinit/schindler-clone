import json, asyncio, websockets
PINS=[0,100,200,-100,-200]
CORNERS={
 "none":     {"tl":{"x":0,"y":0},"tr":{"x":0,"y":0},"br":{"x":0,"y":0},"bl":{"x":0,"y":0}},
 "keystone": {"tl":{"x":-100,"y":0},"tr":{"x":-100,"y":0},"br":{"x":0,"y":0},"bl":{"x":0,"y":0}},
 "twist":    {"tl":{"x":-100,"y":100},"tr":{"x":-100,"y":-100},"br":{"x":100,"y":-100},"bl":{"x":-100,"y":-100}},
}
async def rpc(ws,m,p):
    rpc.id=getattr(rpc,'id',0)+1; rid=rpc.id
    await ws.send(json.dumps({"jsonrpc":"2.0","id":rid,"method":m,"params":p}))
    while True:
        r=json.loads(await asyncio.wait_for(ws.recv(),timeout=30))
        if r.get("id")==rid: return r
async def main():
    async with websockets.connect("ws://127.0.0.1:8081",open_timeout=5) as ws:
        await rpc(ws,"scale.set",{"pct":100}); await rpc(ws,"warp.set",{"deg":0,"panx":0,"pany":0}); await asyncio.sleep(1)
        for cname,cfg in CORNERS.items():
            for pin in PINS:
                await rpc(ws,"corner.set",dict(cfg,override=True)); await asyncio.sleep(0.8)
                await rpc(ws,"pincushion.set",{"x":pin,"y":pin,"override":True}); await asyncio.sleep(1.0)
                await rpc(ws,"lead.autotune",{"scan":True}); await asyncio.sleep(12)
                print(f"{cname:9} pin={pin}",flush=True)
asyncio.run(main())
