local H = require("helpers")
local stubs = require("kostubs")
local fakedoc = require("fakedoc")
local Main = require("main")

-- Loads and registers its menu without a document
local menu_items = {}
local ui = { menu = { registerToMainMenu = function(_, plugin) plugin:addToMainMenu(menu_items) end } }
local plugin = Main:new{ ui = ui }
H.ok(menu_items.readaloud, "menu registered"); H.eq(menu_items.readaloud.text, "Read aloud", "menu title")
H.eq(plugin.settings.voice, "en-US-AndrewNeural", "default voice"); H.eq(plugin.settings.highlight, "word", "default marker mode")
H.eq(plugin:supported(), false, "no document: not supported")
local sub = menu_items.readaloud.sub_item_table
H.eq(sub[1].enabled_func(), false, "start disabled without a document")
H.ok(#sub[3].sub_item_table > 20, "voice list present")

-- With a crengine document the plugin is supported; a PDF is not
local doc = fakedoc({ "a", "b." }, { { 1, 2 } })
plugin.ui = { document = doc, rolling = {}, menu = ui.menu }
H.eq(plugin:supported(), true, "reflowable document supported")
plugin.ui.document.info.has_pages = true
H.eq(plugin:supported(), false, "paged document (PDF) not supported")
plugin.ui.document.info.has_pages = false

-- Settings round-trip through the menu callbacks
sub[4].sub_item_table[5].callback()
H.eq(plugin.settings.speed, 1.25, "speed set from the menu")
sub[5].sub_item_table[2].callback()
H.eq(plugin.settings.highlight, "sentence", "sentence mode from the menu")
sub[5].sub_item_table[4].sub_item_table[2].callback()
H.eq(plugin.settings.style, "underline", "style from the menu")
H.eq(plugin:plan().backend ~= nil, true, "plan detected on the desktop: " .. tostring(plugin:plan().backend))
plugin:log("hello")
H.ok(plugin.synclog[#plugin.synclog]:find("hello"), "log line kept")
-- Stop without ever starting is harmless
plugin:stop(); plugin:onCloseDocument()
H.done("test_main")
