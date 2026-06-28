import json, asyncio, websockets
# Anchor one diagonal (=0,0), sweep the other diagonal's x/y at ±200. Both pairings.
PAIRS=[("TLBR_anchor", ["tr","bl"]), ("TRBL_anchor", ["tl","br"])]  # name, the corners we SWEEP
async def rpc(ws,m,p):
    rpc.id=getattr(rpc,'id',0)+1; rid=rpc.id
    await ws.send(json.dumps({"jsonrpc":"2.0","id":rid,"method":m,"params":p}))
    while True:
        r=json.loads(await asyncio.wait_for(ws.recv(),timeout=30))
        if r.get("id")==rid: return r
async def main():
    async with websockets.connect("ws://127.0.0.1:8081",open_timeout=5) as ws:
        await rpc(ws,"scale.set",{"pct":100}); await asyncio.sleep(1)
        for name,sweepc in PAIRS:
            for combo in range(16):  # 2^4: 2 corners x 2 axes
                cfg={c:{"x":0,"y":0} for c in ["tl","tr","br","bl"]}
                bit=0
                for c in sweepc:
                    for a in ["x","y"]:
                        cfg[c][a]=200 if (combo>>bit)&1 else -200; bit+=1
                await rpc(ws,"corner.set",dict(cfg,override=True)); await asyncio.sleep(1.2)
                await rpc(ws,"lead.autotune",{"scan":True}); await asyncio.sleep(12)
                print(f"{name} {combo:2d}",flush=True)
asyncio.run(main())
