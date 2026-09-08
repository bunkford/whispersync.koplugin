-- A fake crengine document for tests: words w1..wN with xpointers "<i>s"/"<i>e",
-- sentences as word index ranges, and a "current page" of word indexes.
return function(words, sentences, page)
    local d = { words = words, sentences = sentences, page = page or { 1, #words }, file = "/fake/book.epub", info = {} }
    local function idx(xp) return tonumber(xp:match("^(%d+)")) end
    function d:compareXPointers(a, b)
        local va = idx(a) * 2 + (a:sub(-1) == "e" and 1 or 0)
        local vb = idx(b) * 2 + (b:sub(-1) == "e" and 1 or 0)
        if va == vb then return 0 end
        return vb > va and 1 or -1
    end
    function d:getNextVisibleWordStart(xp) local n = idx(xp) + 1; if n > #words then return nil end; return n .. "s" end
    function d:getNextVisibleWordEnd(xp) local i = idx(xp); local n = xp:sub(-1) == "s" and i or i + 1; if n > #words then return nil end; return n .. "e" end
    function d:getPrevVisibleWordStart(xp) local i = idx(xp); local n = xp:sub(-1) == "e" and i or i - 1; if n < 1 then return nil end; return n .. "s" end
    -- Text of a range. Words carry their own punctuation; the text between
    -- word i's end and word i+1's start is a space, or a newline at a
    -- paragraph boundary (d.paragraph_after[i] = true).
    d.paragraph_after = d.paragraph_after or {}
    function d:getTextFromXPointers(a, b)
        local ia, ib = idx(a), idx(b)
        if a:sub(-1) == "e" and b:sub(-1) == "s" and ib == ia + 1 then return self.paragraph_after[ia] and "\n" or " " end
        local t = {}
        for i = ia, ib do t[#t + 1] = words[i] end
        return table.concat(t, " ")
    end
    function d:extendXPointersToSentenceSegment(a)
        local i = idx(a)
        for _, s in ipairs(sentences) do
            if i >= s[1] and i <= s[2] then return { pos0 = s[1] .. "s", pos1 = s[2] .. "e", text = self:getTextFromXPointers(s[1] .. "s", s[2] .. "e") } end
        end
    end
    function d:getXPointer() return self.page[1] .. "s" end
    function d:isXPointerInCurrentPage(xp) local i = idx(xp); return i >= self.page[1] and i <= self.page[2] end
    function d:getScreenBoxesFromPositions(a, b)
        local out = {}
        for i = idx(a), idx(b) do
            if i >= self.page[1] and i <= self.page[2] then out[#out + 1] = { x = 10, y = (i - self.page[1]) * 20, w = 50, h = 18 } end
        end
        return out
    end
    return d
end
