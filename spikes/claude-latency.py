import subprocess, json, time, sys
cmd = ["claude","-p","--model","haiku","--input-format","stream-json","--output-format","stream-json",
       "--verbose","--include-partial-messages","--tools","","--strict-mcp-config","--setting-sources","",
       "--system-prompt","You are a grammar corrector. Reply only with the corrected sentence."]
t0=time.time()
p=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,bufsize=1)
sents=["i has went to the meeting yesterday and we discuss about the budget.",
       "Can you sent me the file when you will have time?",
       "We was thinking to make a decision tomorow."]
for i,s in enumerate(sents):
    ts=time.time()
    p.stdin.write(json.dumps({"type":"user","message":{"role":"user","content":s}})+"\n"); p.stdin.flush()
    first=None
    for line in p.stdout:
        ev=json.loads(line)
        if first is None and ev.get("type")=="stream_event" and ev.get("event",{}).get("type")=="content_block_delta":
            first=time.time()-ts
        if ev.get("type")=="result":
            print(f"msg{i+1}: first_token={first and round(first,2)}s total={round(time.time()-ts,2)}s -> {ev.get('result','')[:80]!r}")
            break
print("since spawn:",round(time.time()-t0,2),"s")
p.stdin.close(); p.wait(timeout=10)
