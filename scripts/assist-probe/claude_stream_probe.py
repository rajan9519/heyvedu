import json, subprocess, time, threading, queue
schema = open("schema.json").read(); sysmsg = open("sys.txt").read()
t0 = time.time()
p = subprocess.Popen(["claude", "-p", "--model", "haiku", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
    "--tools", "", "--no-session-persistence", "--strict-mcp-config", "--setting-sources", "",
    "--system-prompt", sysmsg, "--json-schema", schema], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
q = queue.Queue(); threading.Thread(target=lambda: [q.put(json.loads(l)) for l in p.stdout], daemon=True).start()
inputs = [open("in.json").read(),
  '{"pasted":"Push the fix to get hub and ping Ravi","edited":"Push the fix to GitHub and ping Ravi"}',
  '{"pasted":"I think we should go there tomorrow","edited":"Let\'s go there tomorrow morning"}',
  '{"pasted":"Deploy it on cuber netties tonight","edited":"Deploy it on Kubernetes tonight"}']
time.sleep(3)  # let the process start, as a warm app process would be
for n, text in enumerate(inputs):
    t = time.time()
    p.stdin.write(json.dumps({"type": "user", "message": {"role": "user", "content": text}}) + "\n"); p.stdin.flush()
    while True:
        m = q.get(timeout=60)
        if m.get("type") == "result":
            u = m.get("usage", {})
            print(f"call{n} {time.time()-t:.2f}s api={m.get('duration_api_ms')}ms in={u.get('input_tokens')}+cache_read={u.get('cache_read_input_tokens')}+cache_new={u.get('cache_creation_input_tokens')} out={u.get('output_tokens')}\n  {json.dumps(m.get('structured_output'))}")
            break
p.stdin.close(); p.terminate()
