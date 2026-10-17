import json, subprocess, threading, queue, time
p = subprocess.Popen(["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--tools", "", "--no-session-persistence", "--strict-mcp-config", "--setting-sources", ""],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
q = queue.Queue(); threading.Thread(target=lambda: [q.put(l) for l in p.stdout], daemon=True).start()
p.stdin.write(json.dumps({"type": "control_request", "request_id": "r1", "request": {"subtype": "initialize"}}) + "\n"); p.stdin.flush()
end = time.time() + 20
while time.time() < end:
    try: line = q.get(timeout=1)
    except queue.Empty: continue
    m = json.loads(line)
    if m.get("type") == "control_response":
        resp = m["response"].get("response", m["response"])
        json.dump(resp, open("claude_init.json", "w"), indent=1)
        print("keys:", list(resp.keys()))
        for x in resp.get("models", []): print(json.dumps(x))
        break
    else: print("other:", line[:200])
p.stdin.close(); p.terminate()
