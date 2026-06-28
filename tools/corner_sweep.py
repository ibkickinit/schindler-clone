import sys, json, asyncio, websockets
START=int(sys.argv[1]); END=int(sys.argv[2]); ZOOM=int(sys.argv[3]) if len(sys.argv)>3 else 100
CORNERS=["tl","tr","br","bl"]; AXES=["x","y"]
async def rpc(ws, method, params):
    rpc.id=getattr(rpc,'id',0)+1; rid=rpc.id
    await ws.send(json.dumps({"jsonrpc":"2.0","id":rid,"method":method,"params":params}))
    while True:
        r=json.loads(await asyncio.wait_for(ws.recv(), timeout=30))
        if r.get("id")==rid: return r
async def main():
    async with websockets.connect("ws://127.0.0.1:8081", open_timeout=5) as ws:
        await rpc(ws,"scale.set",{"pct":ZOOM}); await asyncio.sleep(1.5)
        for combo in range(START, END):
            cfg={}; bit=0
            for c in CORNERS:
                cfg[c]={}
                for a in AXES:
                    cfg[c][a] = 200 if (combo>>bit)&1 else -200; bit+=1
            await rpc(ws,"corner.set",dict(cfg, override=True)); await asyncio.sleep(1.2)
            await rpc(ws,"lead.autotune",{"scan":True}); await asyncio.sleep(13)
            print(f"combo {combo:3d} done", flush=True)
asyncio.run(main())
