-- Minimal test helpers: no framework needed, runs under plain luajit.
local H = {}
local passed, failed = 0, 0
local here = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
H.here = here
package.path = here .. "../?.lua;" .. here .. "?.lua;" .. here .. "vendor/?.lua;" .. package.path

function H.eq(a, b, msg)
    if a == b then passed = passed + 1
    else
        failed = failed + 1
        io.stderr:write(("FAIL %s\n  expected: %s\n  actual:   %s\n"):format(msg or "", tostring(b), tostring(a)))
    end
end
function H.ok(v, msg)
    if v then passed = passed + 1 else failed = failed + 1; io.stderr:write("FAIL " .. (msg or "") .. "\n") end
end
function H.near(a, b, tol, msg)
    H.ok(math.abs(a - b) <= tol, (msg or "") .. (" (%s vs %s, tol %s)"):format(a, b, tol))
end
function H.read(path)
    local f = assert(io.open(path, "rb")); local d = f:read("*a"); f:close(); return d
end
function H.done(name)
    print(("%s: %d passed, %d failed"):format(name, passed, failed))
    if failed > 0 then os.exit(1) end
end
return H
