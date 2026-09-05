#!/usr/bin/env python3
"""Generate an RSA key and reference ADP signatures with the same code path as kindle_auth.py."""
import base64, pathlib
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

here = pathlib.Path(__file__).parent
key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption())
der = key.private_bytes(serialization.Encoding.DER, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
(here / "adp_key.pem").write_bytes(pem)
(here / "adp_key.b64der").write_text(base64.b64encode(der).decode())

DATE = "2026-07-29T23:14:42Z"
TOKEN = "{enc:ABCDEF...fake...}{key:XYZ}"
BODY = '<annotations version="1.0" timestamp="2026-07-29T23:14:42-0400"><book key="K" type="PDOC" guid="CR!X:CAFEF00D"><last_read begin="744912" pos="744912" timestamp="2026-07-29T23:14:42-0400"/></book></annotations>'

def sign(method, path, body):
    data = f"{method}\n{path}\n{DATE}\n{body}\n{TOKEN}"
    return base64.b64encode(key.sign(data.encode(), padding.PKCS1v15(), hashes.SHA256())).decode()

(here / "adp_expected.txt").write_text(sign("POST", "/FionaCDEServiceEngine/sidecar?type=PDOC", BODY))
(here / "adp_expected_get.txt").write_text(sign("GET", "/FionaTodoListProxy/syncMetaData?type=EBOK", ""))
print("adp fixtures written")
