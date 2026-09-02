import hashlib
import json
import time
import urllib.request

AUTH = "/state/auth.json"
TOKEN = "/var/run/secrets/kubernetes.io/serviceaccount/token"
ROLE = "codex-checkpoint"
VAULT = "https://vault.monosense.io:8200"
PATH = "platform/data/kubernetes/ai/codex-adapter"
last = ""

def request(path, data, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["X-Vault-Token"] = token
    req = urllib.request.Request(f"{VAULT}/v1/{path}", json.dumps(data).encode(), headers)
    return json.load(urllib.request.urlopen(req, timeout=10))

while True:
    try:
        raw = open(AUTH, "rb").read()
        json.loads(raw)
        digest = hashlib.sha256(raw).hexdigest()
        if digest != last:
            jwt = open(TOKEN).read()
            client = request("auth/kubernetes/login", {"role": ROLE, "jwt": jwt})["auth"]["client_token"]
            request(PATH, {"data": {"auth_json": raw.decode()}}, client)
            last = digest
    except Exception as error:
        print(f"checkpoint failed: {type(error).__name__}", flush=True)
    time.sleep(30)
