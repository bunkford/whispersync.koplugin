--[[--
ADP request signing — how Kindle hardware authenticates to the *-ta-g7g hosts.

String to sign, joined with "\n":

    {METHOD}\n{path+query}\n{ISO8601 Z date}\n{body}\n{adp_token}

then RSA-PKCS#1 v1.5 over SHA-256 with the device private key, base64'd, sent
as "x-adp-signature: <sig>:<date>" alongside "x-adp-token" and
"x-adp-alg: SHA256withRSA:1.0".

Verified live in this repo's Python (kindle_auth.adp_headers). Two traps, both
of which show up as an opaque HTTP 500 rather than a 401: the signed path must
include the query string, and the signed body must be the exact bytes sent.

The private key arrives from Amazon as a PEM block (PKCS#1, "BEGIN RSA PRIVATE
KEY") on current accounts, but older write-ups say base64 PKCS#8 DER. Both are
accepted.

Crypto comes from libcrypto through LuaJIT's FFI — KOReader already ships it
for TLS. If the library cannot be loaded we fall back to the `openssl` command
line tool, which stock Kindle firmware carries.
]]

local M = {}

local ffi_ok, ffi = pcall(require, "ffi")

-------------------------------------------------------------------------------
-- base64
-------------------------------------------------------------------------------

local mime_ok, mime = pcall(require, "mime")

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function b64_encode_pure(data)
    return ((data:gsub(".", function(x)
        local r, b = "", x:byte()
        for i = 8, 1, -1 do r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and "1" or "0") end
        return r
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
        if #x < 6 then return "" end
        local c = 0
        for i = 1, 6 do c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0) end
        return B64:sub(c + 1, c + 1)
    end) .. ({ "", "==", "=" })[#data % 3 + 1])
end

local function b64_decode_pure(data)
    data = data:gsub("[^%w%+%/%=]", "")
    return (data:gsub(".", function(x)
        if x == "=" then return "" end
        local r, f = "", (B64:find(x, 1, true) - 1)
        for i = 6, 1, -1 do r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and "1" or "0") end
        return r
    end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
        if #x ~= 8 then return "" end
        local c = 0
        for i = 1, 8 do c = c + (x:sub(i, i) == "1" and 2 ^ (8 - i) or 0) end
        return string.char(c)
    end))
end

function M.b64_encode(data)
    if mime_ok and mime.b64 then return (mime.b64(data)) end
    return b64_encode_pure(data)
end

function M.b64_decode(data)
    if mime_ok and mime.unb64 then return (mime.unb64(data)) end
    return b64_decode_pure(data)
end

--- URL-safe base64 without padding (PKCE).
function M.b64url(data)
    return (M.b64_encode(data):gsub("+", "-"):gsub("/", "_"):gsub("=", ""))
end

-------------------------------------------------------------------------------
-- libcrypto via FFI
-------------------------------------------------------------------------------

local libcrypto
local cdef_done = false

local function cdefs()
    if cdef_done then return end
    cdef_done = true
    ffi.cdef[[
typedef struct bio_st BIO;
typedef struct evp_pkey_st EVP_PKEY;
typedef struct evp_pkey_ctx_st EVP_PKEY_CTX;
typedef struct evp_md_ctx_st EVP_MD_CTX;
typedef struct evp_md_st EVP_MD;
typedef struct engine_st ENGINE;
BIO *BIO_new_mem_buf(const void *buf, int len);
int BIO_free(BIO *a);
EVP_PKEY *PEM_read_bio_PrivateKey(BIO *bp, EVP_PKEY **x, void *cb, void *u);
EVP_PKEY *d2i_AutoPrivateKey(EVP_PKEY **a, const unsigned char **pp, long length);
void EVP_PKEY_free(EVP_PKEY *pkey);
int EVP_PKEY_size(const EVP_PKEY *pkey);
EVP_MD_CTX *EVP_MD_CTX_new(void);
void EVP_MD_CTX_free(EVP_MD_CTX *ctx);
const EVP_MD *EVP_sha256(void);
int EVP_DigestSignInit(EVP_MD_CTX *ctx, EVP_PKEY_CTX **pctx, const EVP_MD *type, ENGINE *e, EVP_PKEY *pkey);
int EVP_DigestUpdate(EVP_MD_CTX *ctx, const void *d, size_t cnt);
int EVP_DigestSignFinal(EVP_MD_CTX *ctx, unsigned char *sigret, size_t *siglen);
unsigned char *SHA256(const unsigned char *d, size_t n, unsigned char *md);
int RAND_bytes(unsigned char *buf, int num);
]]
end

local function load_libcrypto()
    if libcrypto ~= nil then return libcrypto or nil end
    if not ffi_ok then libcrypto = false; return nil end
    cdefs()
    local candidates = {}
    -- KOReader's own loader knows where its bundled libcrypto lives.
    if ffi.loadlib then
        candidates[#candidates + 1] = function() return ffi.loadlib("crypto", "57") end
        candidates[#candidates + 1] = function() return ffi.loadlib("crypto", "3") end
        candidates[#candidates + 1] = function() return ffi.loadlib("crypto", "1.1") end
    end
    for _, name in ipairs({ "crypto", "libcrypto.so.3", "libcrypto.so.1.1", "libcrypto.so" }) do
        candidates[#candidates + 1] = function() return ffi.load(name) end
    end
    for _, try in ipairs(candidates) do
        local ok, lib = pcall(try)
        if ok and lib then
            -- Make sure the symbols we need actually resolve.
            local ok2 = pcall(function() return lib.EVP_sha256 end)
            if ok2 then libcrypto = lib; return lib end
        end
    end
    libcrypto = false
    return nil
end

--- Load a private key from whatever form Amazon handed back.
local function load_key(lib, raw)
    raw = raw:match("^%s*(.-)%s*$")
    local pkey
    if raw:find("-----BEGIN", 1, true) then
        local bio = lib.BIO_new_mem_buf(raw, #raw)
        if bio == nil then return nil, "BIO_new_mem_buf failed" end
        pkey = lib.PEM_read_bio_PrivateKey(bio, nil, nil, nil)
        lib.BIO_free(bio)
    else
        local der = M.b64_decode(raw)
        local buf = ffi.new("const unsigned char[?]", #der, der)
        local pp = ffi.new("const unsigned char*[1]", buf)
        pkey = lib.d2i_AutoPrivateKey(nil, pp, #der)
        if pkey == nil then
            -- Some responses base64 a PEM block rather than DER.
            local bio = lib.BIO_new_mem_buf(der, #der)
            if bio ~= nil then
                pkey = lib.PEM_read_bio_PrivateKey(bio, nil, nil, nil)
                lib.BIO_free(bio)
            end
        end
    end
    if pkey == nil then return nil, "could not parse the device private key" end
    return pkey
end

local function ffi_sign(data, key_raw)
    local lib = load_libcrypto()
    if not lib then return nil, "libcrypto not available" end
    local pkey, err = load_key(lib, key_raw)
    if not pkey then return nil, err end
    local ctx = lib.EVP_MD_CTX_new()
    if ctx == nil then lib.EVP_PKEY_free(pkey); return nil, "EVP_MD_CTX_new failed" end
    local sig, result
    if lib.EVP_DigestSignInit(ctx, nil, lib.EVP_sha256(), nil, pkey) == 1
        and lib.EVP_DigestUpdate(ctx, data, #data) == 1 then
        local siglen = ffi.new("size_t[1]")
        if lib.EVP_DigestSignFinal(ctx, nil, siglen) == 1 then
            sig = ffi.new("unsigned char[?]", tonumber(siglen[0]))
            if lib.EVP_DigestSignFinal(ctx, sig, siglen) == 1 then
                result = ffi.string(sig, tonumber(siglen[0]))
            end
        end
    end
    lib.EVP_MD_CTX_free(ctx)
    lib.EVP_PKEY_free(pkey)
    if not result then return nil, "RSA signing failed" end
    return result
end

-------------------------------------------------------------------------------
-- openssl CLI fallback
-------------------------------------------------------------------------------

local function shell_quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function write_tmp(data, mode)
    local path = os.tmpname()
    local f = io.open(path, "wb")
    if not f then return nil end
    f:write(data)
    f:close()
    if mode then os.execute("chmod " .. mode .. " " .. shell_quote(path)) end
    return path
end

local function cli_sign(data, key_raw)
    key_raw = key_raw:match("^%s*(.-)%s*$")
    local key_pem = key_raw
    if not key_raw:find("-----BEGIN", 1, true) then
        -- Wrap base64 DER as PKCS#8 PEM; openssl accepts either PKCS#1 or #8.
        local lines = {}
        for i = 1, #key_raw, 64 do lines[#lines + 1] = key_raw:sub(i, i + 63) end
        key_pem = "-----BEGIN PRIVATE KEY-----\n" .. table.concat(lines, "\n") .. "\n-----END PRIVATE KEY-----\n"
    end
    local key_path = write_tmp(key_pem, "600")
    local data_path = write_tmp(data)
    if not key_path or not data_path then return nil, "cannot write temp files" end
    local cmd = ("openssl dgst -sha256 -sign %s -binary %s"):format(shell_quote(key_path), shell_quote(data_path))
    local p = io.popen(cmd, "r")
    local sig = p and p:read("*a")
    if p then p:close() end
    os.remove(key_path)
    os.remove(data_path)
    if not sig or #sig < 64 then return nil, "openssl CLI signing failed" end
    return sig
end

-------------------------------------------------------------------------------
-- public API
-------------------------------------------------------------------------------

M.backend = nil -- "ffi" | "cli" once known

--- RSA-SHA256 PKCS#1 v1.5 signature over `data`, raw bytes.
function M.rsa_sha256(data, key_raw)
    if M.backend ~= "cli" then
        local sig, err = ffi_sign(data, key_raw)
        if sig then M.backend = "ffi"; return sig end
        if M.backend == "ffi" then return nil, err end
    end
    local sig, err = cli_sign(data, key_raw)
    if sig then M.backend = "cli"; return sig end
    return nil, err
end

--- The date string ADP wants: UTC, second precision, trailing Z.
function M.adp_date(t)
    return os.date("!%Y-%m-%dT%H:%M:%S", t) .. "Z"
end

--- Signed headers for a request. `date` is only overridable for tests.
function M.headers(method, path_with_query, body, adp_token, key_raw, date)
    date = date or M.adp_date()
    local data = table.concat({ method, path_with_query, date, body or "", adp_token }, "\n")
    local sig, err = M.rsa_sha256(data, key_raw)
    if not sig then return nil, err end
    return {
        ["x-adp-token"] = adp_token,
        ["x-adp-alg"] = "SHA256withRSA:1.0",
        ["x-adp-signature"] = M.b64_encode(sig) .. ":" .. date,
    }
end

--- SHA-256 digest (raw bytes). Used for the PKCE challenge at registration.
function M.sha256(data)
    local lib = load_libcrypto()
    if lib then
        local md = ffi.new("unsigned char[32]")
        lib.SHA256(data, #data, md)
        return ffi.string(md, 32)
    end
    local ok, sha2 = pcall(require, "ffi/sha2")
    if ok and sha2 and sha2.sha256 then
        -- KOReader's pure-Lua sha2 returns hex.
        local hex = sha2.sha256(data)
        return (hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
    end
    local p = io.popen("printf '%s' " .. shell_quote(data) .. " | openssl dgst -sha256 -binary", "r")
    local d = p and p:read("*a")
    if p then p:close() end
    return d
end

--- `n` random bytes, from libcrypto or /dev/urandom.
function M.random_bytes(n)
    local lib = load_libcrypto()
    if lib then
        local buf = ffi.new("unsigned char[?]", n)
        if lib.RAND_bytes(buf, n) == 1 then return ffi.string(buf, n) end
    end
    local f = io.open("/dev/urandom", "rb")
    if f then
        local d = f:read(n); f:close()
        if d and #d == n then return d end
    end
    local t = {}
    for i = 1, n do t[i] = string.char(math.random(0, 255)) end
    return table.concat(t)
end

function M.hex(data)
    return (data:gsub(".", function(c) return ("%02x"):format(c:byte()) end))
end

return M
