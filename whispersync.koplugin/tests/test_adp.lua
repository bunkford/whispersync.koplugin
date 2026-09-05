local H = require("helpers")
local adp = require("adp")

-- Key + expected signature produced by Python `cryptography` (fixture/gen_adp.py).
local key_pem = H.read(H.here .. "fixture/adp_key.pem")
local key_b64der = H.read(H.here .. "fixture/adp_key.b64der")
local expected = H.read(H.here .. "fixture/adp_expected.txt"):match("^(.-)%s*$")

local DATE = "2026-07-29T23:14:42Z"
local TOKEN = "{enc:ABCDEF...fake...}{key:XYZ}"
local BODY = '<annotations version="1.0" timestamp="2026-07-29T23:14:42-0400"><book key="K" type="PDOC" guid="CR!X:CAFEF00D"><last_read begin="744912" pos="744912" timestamp="2026-07-29T23:14:42-0400"/></book></annotations>'
local PATH = "/FionaCDEServiceEngine/sidecar?type=PDOC"

H.eq(adp.b64_encode("hello"), "aGVsbG8=", "b64 encode")
H.eq(adp.b64_decode("aGVsbG8="), "hello", "b64 decode")
H.eq(adp.b64url("\255\254\253"), "__79", "b64url")
H.eq(adp.hex(adp.sha256("abc")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256")
H.eq(#adp.random_bytes(32), 32, "random bytes")
H.eq(adp.adp_date(0), "1970-01-01T00:00:00Z", "adp date format")

-- PEM key, FFI backend
local h = assert(adp.headers("POST", PATH, BODY, TOKEN, key_pem, DATE))
H.eq(h["x-adp-token"], TOKEN, "token header")
H.eq(h["x-adp-alg"], "SHA256withRSA:1.0", "alg header")
H.eq(h["x-adp-signature"], expected .. ":" .. DATE, "signature matches Python cryptography (PEM, " .. tostring(adp.backend) .. ")")

-- base64 DER key gives the same signature
local h2 = assert(adp.headers("POST", PATH, BODY, TOKEN, key_b64der, DATE))
H.eq(h2["x-adp-signature"], expected .. ":" .. DATE, "signature matches (base64 DER)")

-- Force the CLI fallback and compare again.
adp.backend = "cli"
local h3 = assert(adp.headers("POST", PATH, BODY, TOKEN, key_pem, DATE))
H.eq(h3["x-adp-signature"], expected .. ":" .. DATE, "signature matches (openssl CLI)")
H.eq(adp.backend, "cli", "cli backend recorded")

-- GET with empty body: the empty line is still part of the string to sign.
adp.backend = nil
local expected_get = H.read(H.here .. "fixture/adp_expected_get.txt"):match("^(.-)%s*$")
local hg = assert(adp.headers("GET", "/FionaTodoListProxy/syncMetaData?type=EBOK", "", TOKEN, key_pem, DATE))
H.eq(hg["x-adp-signature"], expected_get .. ":" .. DATE, "GET signature matches")

H.done("test_adp")
