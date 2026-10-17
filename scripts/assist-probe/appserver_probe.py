import json, subprocess, sys, time, threading, queue
model = sys.argv[1]; base = sys.argv[2] if len(sys.argv) > 2 else None
schema = json.load(open("schema.json")); sysmsg = open("sys.txt").read()
p = subprocess.Popen(["codex", "--config", 'model_reasoning_effort="low"', "app-server", "--listen", "stdio://"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
q = queue.Queue(); threading.Thread(target=lambda: [q.put(json.loads(l)) for l in p.stdout], daemon=True).start()
nid = [0]
def req(method, params):
    nid[0] += 1; i = nid[0]; p.stdin.write(json.dumps({"id": i, "method": method, "params": params}) + "\n"); p.stdin.flush()
    while True:
        m = q.get(timeout=60)
        if m.get("id") == i and "method" not in m:
            if "error" in m: raise SystemExit(f"{method}: {m['error']}")
            return m["result"]
        if "method" in m and "id" in m:  # server request (approval) -> decline
            p.stdin.write(json.dumps({"id": m["id"], "result": {"decision": "decline"}}) + "\n"); p.stdin.flush()
t0 = time.time()
req("initialize", {"clientInfo": {"name": "heyvedu_probe", "title": "probe", "version": "0"}, "capabilities": {"experimentalApi": True}})
p.stdin.write(json.dumps({"method": "initialized"}) + "\n"); p.stdin.flush()
print(f"init {time.time()-t0:.2f}s")
inputs = [open("in.json").read(),
  '{"pasted":"Push the fix to get hub and ping Ravi","edited":"Push the fix to GitHub and ping Ravi"}',
  '{"pasted":"I think we should go there tomorrow","edited":"Let\'s go there tomorrow morning"}']
for n, text in enumerate(inputs):
    t = time.time()
    params = {"model": model, "ephemeral": True, "sandbox": "read-only", "approvalPolicy": "never", "cwd": "."}
    if base == "min": params["baseInstructions"] = sysmsg
    th = req("thread/start", params)["thread"]["id"]
    turn = {"threadId": th, "input": [{"type": "text", "text": text if base == "min" else sysmsg + "\n\n" + text}], "outputSchema": schema}
    req("turn/start", turn)
    out, usage = None, None
    while True:
        m = q.get(timeout=60); meth = m.get("method", "")
        if meth == "item/completed" and m["params"]["item"].get("type") == "agentMessage": out = m["params"]["item"].get("text")
        if meth == "thread/tokenUsage/updated": usage = m["params"].get("tokenUsage", {}).get("last")
        if meth == "error": print("ERR", json.dumps(m)[:300])
        if meth == "turn/completed": break
    print(f"call{n} {time.time()-t:.2f}s usage={usage}\n  {out}")
p.terminate()
