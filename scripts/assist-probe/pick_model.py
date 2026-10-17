"""Prototype of the AI Assist model picker. No model names are hard-coded:
1. discover models live from each CLI (Codex `model/list`, Claude `initialize`),
2. drop ones that can't be used (hidden, specialty, extra paid credits),
3. pre-rank by the CLI's own hints (descriptions, usage multipliers) to choose what to test,
4. measure the top few on golden cases with a warm process, pick the fastest that passes.
"""
import json, re, statistics, subprocess, sys, threading, queue, time

SCHEMA = json.load(open("schema.json")); SYS = open("sys.txt").read()
CASES = [  # (edit, expected terms); a reworded edit expects nothing
    ({"pasted": "Ask hey vedu team to sync with Shree ya about the cube control rollout",
      "edited": "Ask HeyVedu team to sync with Shreya about the kubectl rollout today"}, {"HeyVedu", "Shreya", "kubectl"}),
    ({"pasted": "Push the fix to get hub and ping Ravi", "edited": "Push the fix to GitHub and ping Ravi"}, {"GitHub"}),
    ({"pasted": "I think we should go there tomorrow", "edited": "Let's go there tomorrow morning"}, set()),
    ({"pasted": "Deploy it on cuber netties tonight", "edited": "Deploy it on Kubernetes tonight"}, {"Kubernetes"}),
]
TOP_K = int(sys.argv[1]) if len(sys.argv) > 1 else 3

class Lines:
    def __init__(self, args):
        self.p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.q = queue.Queue(); threading.Thread(target=lambda: [self.q.put(json.loads(l)) for l in self.p.stdout], daemon=True).start()
    def send(self, o): self.p.stdin.write(json.dumps(o) + "\n"); self.p.stdin.flush()
    def get(self, t=90): return self.q.get(timeout=t)
    def close(self): self.p.terminate()

# ---------- discovery ----------
def codex_server():
    s = Lines(["codex", "app-server", "--listen", "stdio://"]); s.n = 0
    def req(method, params):
        s.n += 1; i = s.n; s.send({"id": i, "method": method, "params": params})
        while True:
            m = s.get()
            if m.get("id") == i and "method" not in m:
                if "error" in m: raise RuntimeError(m["error"].get("message"))
                return m["result"]
            if "method" in m and "id" in m: s.send({"id": m["id"], "result": {"decision": "decline"}})
    s.req = req
    req("initialize", {"clientInfo": {"name": "heyvedu_probe", "title": "probe", "version": "0"}, "capabilities": {"experimentalApi": True}})
    s.send({"method": "initialized"})
    return s

def discover_codex(srv):
    out = []
    for m in srv.req("model/list", {"includeHidden": False})["data"]:
        efforts = [e["reasoningEffort"] for e in m.get("supportedReasoningEfforts", [])]
        out.append({"provider": "codex", "id": m["id"], "name": m["displayName"], "desc": m["description"],
                    "hidden": m["hidden"], "specialty": m.get("modelSpecialty"), "effort": efforts[0] if efforts else None})
    return out

def discover_claude():
    s = Lines(["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
               "--tools", "", "--no-session-persistence", "--strict-mcp-config", "--setting-sources", ""])
    s.send({"type": "control_request", "request_id": "init", "request": {"subtype": "initialize"}})
    while True:
        m = s.get()
        if m.get("type") == "control_response": break
    s.close()
    resp = m["response"].get("response", m["response"]); out = {}
    for x in resp["models"]:
        rid = x.get("resolvedModel") or x["value"]
        if rid in out: continue  # "default" and "opus" can name the same model
        out[rid] = {"provider": "claude", "id": x["value"], "resolved": rid, "name": x["displayName"], "desc": x["description"],
                    "hidden": False, "specialty": None, "effort": (x.get("supportedEffortLevels") or [None])[0]}
    return list(out.values())

# ---------- filtering and pre-ranking from the CLI's own hints ----------
FAST = re.compile(r"\b(fast(est)?|quick|affordable|efficient|cheap|lightweight|routine|easier)\b", re.I)
SLOW = re.compile(r"\b(frontier|most capable|hardest|demanding|complex|longest)\b", re.I)
PAID = re.compile(r"requires (usage )?credits|extra usage|pay", re.I)
OLD = re.compile(r"\b(older|previous)\b", re.I)
def usable(m): return not m["hidden"] and not m["specialty"] and not PAID.search(m["desc"])
def hint_score(m):
    d = m["desc"]; s = 2 * len(FAST.findall(d)) - 2 * len(SLOW.findall(d)) - (0.5 if OLD.search(d) else 0)
    mult = re.search(r"~?(\d+(?:\.\d+)?)\s*[×x]\s*usage", d)
    if mult: s -= float(mult.group(1))
    return s


# ---------- pre-ranking by asking the CLI's default model ----------
RANK_SYS = ("You rank AI models for a background task in a dictation app: short JSON classification of one "
            "edited sentence, under 2k tokens in and 200 out, where speed and low cost matter most and only basic "
            "accuracy is needed. Use what you know about these model families plus the names and descriptions given. "
            "Return every id exactly once, fastest and cheapest first. Reply only with JSON matching the schema.")
RANK_SCHEMA = {"type": "object", "additionalProperties": False, "required": ["ranked"],
               "properties": {"ranked": {"type": "array", "items": {"type": "object", "additionalProperties": False,
                   "required": ["id", "reason"], "properties": {"id": {"type": "string"}, "reason": {"type": "string"}}}}}}

def rank_with_cli(ranker, models, srv=None):
    """Ask the ranker CLI, on its default model and effort, to sort the candidates. Returns ids, or None."""
    listing = json.dumps([{"id": f"{m['provider']}:{m['id']}", "name": m["name"], "description": m["desc"],
                           "efforts": m.get("effort")} for m in models])
    t = time.time()
    if ranker == "claude":
        r = subprocess.run(["claude", "-p", "--output-format", "json", "--tools", "", "--no-session-persistence",
                            "--strict-mcp-config", "--setting-sources", "", "--system-prompt", RANK_SYS,
                            "--json-schema", json.dumps(RANK_SCHEMA)], input=listing, capture_output=True, text=True, timeout=120)
        out = json.loads(r.stdout); data = out.get("structured_output")
        meta = f"model={list(out.get('modelUsage', {}).keys())} cost=${out.get('total_cost_usd')}"
    else:
        th = srv.req("thread/start", {"ephemeral": True, "sandbox": "read-only", "approvalPolicy": "never", "baseInstructions": RANK_SYS, "cwd": "."})
        srv.req("turn/start", {"threadId": th["thread"]["id"], "input": [{"type": "text", "text": listing}], "outputSchema": RANK_SCHEMA})
        text = None
        while True:
            e = srv.get(); meth = e.get("method", "")
            if meth == "item/completed" and e["params"]["item"].get("type") == "agentMessage": text = e["params"]["item"].get("text")
            if meth == "turn/completed": break
        data = json.loads(text) if text else None; meta = f"model={th.get('model')} effort={th.get('reasoningEffort')}"
    known = {f"{m['provider']}:{m['id']}" for m in models}
    ids = [x["id"] for x in (data or {}).get("ranked", []) if x["id"] in known]
    ids = list(dict.fromkeys(ids)) + [i for i in known if i not in ids]  # drop unknown/duplicate ids, append missing
    print(f"ranked by {ranker} in {time.time()-t:.1f}s ({meta})")
    for x in (data or {}).get("ranked", [])[:8]: print(f"   {x['id']}: {x['reason'][:110]}")
    return ids

# ---------- measuring ----------
def score(out, expected):
    got = {s["term"] for s in (out or {}).get("suggestions", [])}
    return got == expected

def bench_codex(srv, m):
    lat, ok, toks = [], 0, []
    for edit, exp in CASES:
        t = time.time()
        th = srv.req("thread/start", {"model": m["id"], "ephemeral": True, "sandbox": "read-only", "approvalPolicy": "never", "baseInstructions": SYS, "cwd": "."})["thread"]["id"]
        srv.req("turn/start", {"threadId": th, "input": [{"type": "text", "text": json.dumps(edit)}], "outputSchema": SCHEMA, "effort": m["effort"]})
        text, usage = None, None
        while True:
            e = srv.get(); meth = e.get("method", "")
            if meth == "item/completed" and e["params"]["item"].get("type") == "agentMessage": text = e["params"]["item"].get("text")
            if meth == "thread/tokenUsage/updated": usage = e["params"]["tokenUsage"]["last"]
            if meth == "turn/completed":
                if e["params"]["turn"].get("status") == "failed": raise RuntimeError(json.dumps(e["params"]["turn"].get("error"))[:200])
                break
        lat.append(time.time() - t); toks.append((usage or {}).get("inputTokens", 0))
        try: ok += score(json.loads(text), exp)
        except Exception: pass
    return lat, ok, statistics.median(toks), None

def bench_claude(m):
    s = Lines(["claude", "-p", "--model", m["id"], "--effort", m["effort"] or "low", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
               "--tools", "", "--no-session-persistence", "--strict-mcp-config", "--setting-sources", "",
               "--system-prompt", SYS, "--json-schema", json.dumps(SCHEMA)])
    time.sleep(3)  # a warm process, as in the app
    lat, ok, toks, cost = [], 0, [], 0.0
    for edit, exp in CASES:
        t = time.time(); s.send({"type": "user", "message": {"role": "user", "content": json.dumps(edit)}})
        while True:
            e = s.get()
            if e.get("type") == "result": break
        if e.get("is_error"): s.close(); raise RuntimeError(str(e.get("result"))[:200])
        lat.append(time.time() - t); u = e.get("usage", {})
        toks.append(u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0) + u.get("cache_creation_input_tokens", 0))
        cost = e.get("total_cost_usd", cost)  # cumulative for the session
        ok += score(e.get("structured_output"), exp)
    s.close()
    return lat, ok, statistics.median(toks), cost / len(CASES)

def main():
    srv = codex_server()
    found = discover_codex(srv) + discover_claude()
    print(f"discovered {len(found)} models")
    for m in found: m["hint"] = hint_score(m)
    pool = [m for m in found if usable(m)]
    ranker = sys.argv[2] if len(sys.argv) > 2 else "claude"
    try:
        order = rank_with_cli(ranker, pool, srv)
    except Exception as e:  # the ranking call failed: fall back to the description keywords
        print("ranking failed, using keywords:", e); order = [f"{m['provider']}:{m['id']}" for m in sorted(pool, key=lambda m: -m["hint"])]
    pos = {k: i for i, k in enumerate(order)}
    cands = []
    for prov in ("claude", "codex"):
        mine = sorted([m for m in pool if m["provider"] == prov], key=lambda m: pos[f"{m['provider']}:{m['id']}"])
        print(f"{prov}: " + ", ".join(m["name"] for m in mine))
        cands += mine[:TOP_K]
    if len(sys.argv) > 3 and sys.argv[3] == "rank-only": srv.close(); return
    results = []
    for m in cands:
        try:
            lat, ok, toks, cost = bench_codex(srv, m) if m["provider"] == "codex" else bench_claude(m)
            r = {"model": f"{m['provider']}:{m['id']}", "effort": m["effort"], "passed": f"{ok}/{len(CASES)}",
                 "p50_s": round(statistics.median(lat[1:] or lat), 2), "max_s": round(max(lat), 2), "input_tokens": int(toks),
                 "usd_per_call": round(cost, 5) if cost is not None else None, "ok": ok}
        except Exception as e:
            r = {"model": f"{m['provider']}:{m['id']}", "error": str(e), "ok": -1}
        print(json.dumps(r)); results.append(r)
    srv.close()
    need = len(CASES) - 1  # quality bar: at most one miss
    passing = sorted([r for r in results if r["ok"] >= need], key=lambda r: (r["p50_s"], r["input_tokens"]))
    print("\nchosen order:", [r["model"] for r in passing] or "none passed")

main()
