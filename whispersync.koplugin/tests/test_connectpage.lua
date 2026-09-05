local H = require("helpers")
package.path = H.here .. "vendor/?.lua;" .. package.path
require("kostubs")
local Whispersync = require("main")
local amazon = require("amazon")

local ws = Whispersync:new{ ui = { menu = { registerToMainMenu = function() end } } }

ws.pending_login = amazon.build_login("ca")
local sent
ws.connect_server = { send = function(_, data) sent = data end }

-- GET / renders the page with the sign-in link and the paste form.
ws:onConnectRequest("GET / HTTP/1.1\r\nHost: x\r\n\r\n", {})
H.ok(sent:find("^HTTP/1.1 200 OK\r\n"), "200 for /")
H.ok(sent:find("Content%-Length: %d+"), "content length present")
H.ok(sent:find('href="https://www.amazon.ca/ap/signin?', 1, true), "sign-in link on the .ca domain")
H.ok(sent:find("&amp;openid", 1, true), "link is HTML-escaped")
H.ok(sent:find("<form method=get action=/finish>", 1, true), "GET form (the server never delivers a body)")

-- Bad paste comes back as an error on the same page.
ws:onConnectRequest("GET /finish?code=https%3A%2F%2Fwww.amazon.ca%2F HTTP/1.1\r\n\r\n", {})
H.ok(sent:find("class=bad", 1, true), "bad paste explained")
H.ok(sent:find("has no authorization code", 1, true), "specific message")

-- Good paste: registration is attempted through the transport; a failure is shown.
amazon.transport = function(req)
    H.ok(req.url == "https://api.amazon.ca/auth/register", "registers on the marketplace domain")
    H.ok(req.body:find('"authorization_code":"ANabc123XYZ"', 1, true), "code forwarded")
    H.ok(req.body:find('"website_cookies":[]', 1, true), "website_cookies is an empty array")
    return 400, '{"response":{"error":{"code":"InvalidValue","message":"nope"}}}', {}
end
local url = "https://www.amazon.ca/ap/maplanding?openid.oa2.authorization_code=ANabc123XYZ&openid.mode=id_res"
ws:onConnectRequest("GET /finish?code=" .. amazon.url_encode(url) .. " HTTP/1.1\r\n\r\n", {})
H.ok(sent:find("Amazon rejected the registration: InvalidValue", 1, true), "rejection surfaced")
H.ok(ws.pending_login ~= nil, "still pending after failure")

-- Success path stores the device and stops the page.
amazon.transport = function(req)
    return 200, '{"response":{"success":{"tokens":{"mac_dms":{"adp_token":"{enc:x}","device_private_key":"-----BEGIN RSA PRIVATE KEY-----\\nAAA\\n-----END RSA PRIVATE KEY-----"},"bearer":{"refresh_token":"r"}},"extensions":{"customer_info":{"name":"Test User"}}}}}', {}
end
local stopped = false
ws.stopConnectServer = function() stopped = true end
ws:onConnectRequest("GET /finish?code=" .. amazon.url_encode(url) .. " HTTP/1.1\r\n\r\n", {})
H.ok(sent:find("<h1 class=ok>Connected</h1>", 1, true), "success page")
H.eq(ws.device.adp_token, "{enc:x}", "device stored")
H.eq(ws.device.marketplace, "ca", "marketplace stored")
H.eq(ws.pending_login, nil, "no longer pending")
H.ok(stopped, "listener stopped after success")

-- Afterwards the page is gone.
ws.pending_login = nil
ws:onConnectRequest("GET / HTTP/1.1\r\n\r\n", {})
H.ok(sent:find("^HTTP/1.1 410 Gone"), "410 once finished")
ws:onConnectRequest("POST / HTTP/1.1\r\n\r\n", {})

H.done("test_connectpage")
