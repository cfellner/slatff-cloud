"""Test helper: DPoP keys and proofs (RFC 9449).
  python3 dpop.py keygen FILE            new RSA key
  python3 dpop.py jkt FILE               key thumbprint (RFC 7638)
  python3 dpop.py proof FILE METHOD URL TOKEN [IAT_OFFSET]"""
import base64, hashlib, json, sys, time, uuid
import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from jwt.algorithms import RSAAlgorithm

def b64u(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
def load(f): return serialization.load_pem_private_key(open(f, "rb").read(), None)
def pub_jwk(k):
    j = json.loads(RSAAlgorithm.to_jwk(k.public_key())); return {"kty": "RSA", "e": j["e"], "n": j["n"]}

cmd, f = sys.argv[1], sys.argv[2]
if cmd == "keygen":
    k = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    open(f, "wb").write(k.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
elif cmd == "jkt":
    j = pub_jwk(load(f)); print(b64u(hashlib.sha256(json.dumps(j, separators=(",", ":"), sort_keys=True).encode()).digest()))
elif cmd == "proof":
    method, url, token = sys.argv[3], sys.argv[4], sys.argv[5]
    off = int(sys.argv[6]) if len(sys.argv) > 6 else 0
    k = load(f)
    print(jwt.encode({"jti": str(uuid.uuid4()), "htm": method, "htu": url, "iat": int(time.time()) + off,
                      "ath": b64u(hashlib.sha256(token.encode()).digest())},
                     k, algorithm="RS256", headers={"typ": "dpop+jwt", "jwk": pub_jwk(k)}))
