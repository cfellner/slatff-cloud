import sys, time, uuid, jwt
key=open("key.pem").read()
user, roles = sys.argv[1], sys.argv[2].split(",") if sys.argv[2] else []
aud = sys.argv[3] if len(sys.argv)>3 else "model-gateway"
iss = sys.argv[4] if len(sys.argv)>4 else "http://127.0.0.1:9001/realms/slatff"
exp = int(time.time()) + (300 if len(sys.argv)<6 else int(sys.argv[5]))
import os, json
c = {"iss":iss,"sub":"id-"+user,"aud":aud,"azp":os.environ.get("AZP","open-webui"),"exp":exp,"iat":int(time.time()),
  "jti":str(uuid.uuid4()),"preferred_username":user,"roles":roles,"groups":[r+"s" for r in roles]}
for claim in ("act", "may_act"):              # JSON, e.g. ACT='{"sub":"sa-1","client_id":"research-agent"}'
    if os.environ.get(claim.upper()):
        c[claim] = json.loads(os.environ[claim.upper()])
if os.environ.get("CNF_JKT"):
    c["cnf"] = {"jkt": os.environ["CNF_JKT"]}
print(jwt.encode(c,
  key, algorithm="RS256", headers={"kid":"k1"}))
