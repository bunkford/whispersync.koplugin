local H = require("helpers")
local Shelf = require("shelf")

-- Paperwhite 6 portrait: 1272x1696 at 300 dpi (scale ~1.875).
local L = Shelf.layout(1272, 1696, 1.875, 120, 90)
H.eq(L.cols, 4, "four columns on a 1272 px wide 300 dpi screen")
H.ok(L.rows >= 2, "at least two rows (" .. L.rows .. ")")
H.ok(L.cols * (L.cell_w + L.padding) + L.padding <= 1272, "grid fits the width")
H.ok(L.rows * (L.cell_h + L.padding) <= L.body_h, "grid fits the body height")
H.eq(L.cover_h, math.floor(L.cover_w * 1.5), "cover ratio 2:3")

-- A 6-inch 600x800 device at 167 dpi.
local L2 = Shelf.layout(600, 800, 1.04, 80, 60)
H.eq(L2.cols, 3, "three columns on 600 px")
H.ok(L2.rows >= 1, "at least one row on a small screen")

-- Landscape uses more columns.
local L3 = Shelf.layout(1696, 1272, 1.875, 120, 90)
H.eq(L3.cols, 6, "six columns landscape, capped")

-- Paging.
H.eq(Shelf.page_count(0, 8), 1, "empty shelf has one page")
H.eq(Shelf.page_count(8, 8), 1, "exact fit")
H.eq(Shelf.page_count(9, 8), 2, "one over")
local items = {}
for i = 1, 19 do items[i] = i end
H.eq(#Shelf.page_slice(items, 3, 8), 3, "last page has the remainder")
H.eq(Shelf.page_slice(items, 2, 8)[1], 9, "second page starts at 9")

H.done("test_shelf")
