import json, subprocess, sys
p = subprocess.Popen(["codex", "app-server", "--listen", "stdio://"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
def send(o): p.stdin.write(json.dumps(o) + "\n"); p.stdin.flush()
def wait(i):
    for line in p.stdout:
        m = json.loads(line)
        if m.get("id") == i and "method" not in m: return m
send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "heyvedu_probe", "title": "probe", "version": "0"}, "capabilities": {"experimentalApi": True}}}); wait(1)
send({"method": "initialized"})
send({"id": 2, "method": "model/list", "params": {"includeHidden": True}}); r = wait(2)
json.dump(r, open("codex_model_list.json", "w"), indent=1)
for m in r["result"]["data"]:
    print(json.dumps({k: m.get(k) for k in ["id", "displayName", "hidden", "isDefault", "description", "defaultReasoningEffort", "modelSpecialty", "upgrade"]}))
    print("   efforts:", [e.get("reasoningEffort") for e in m.get("supportedReasoningEfforts", [])], "tiers:", m.get("serviceTiers"), "speed:", m.get("additionalSpeedTiers"))
print("nextCursor:", r["result"].get("nextCursor"))
p.terminate()
