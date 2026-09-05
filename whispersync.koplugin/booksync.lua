--[[--
Per-book synchronisation logic: what to pull, what to push, and how to pair
records once Amazon has assigned its own ids.

Kept free of KOReader dependencies so it can be tested on a desktop. The
plugin (main.lua) supplies converted local items and applies the plan.

Vocabulary:
  remote  -- annotation records from the sidecar: {annotation_id, kind,
             start, end, text, colour}
  local   -- KOReader annotations already converted to Kindle offsets:
             {key, kind ("bookmark"|"highlight"), start, end, text, note}
  links   -- persisted pairing table, local key -> {id, note_id, kind,
             start, end, text, note, remote_gone}

Amazon never returns the id at write time, so a pushed record is paired by
(kind, position) on the following read-back. Amazon returns bookmarks with
no `end` and stores positions in markup bytes, so equality is too strict:
MATCH_SLOP bytes of tolerance are allowed, as in this repo's kindle_push.py.
]]

local M = {}

M.MATCH_SLOP = 2
-- Don't re-push a position for a handful of bytes; a page is ~1-2 KB.
M.MIN_DELTA = 200
-- Local page-turn time vs Amazon's creationTime: allow for clock skew.
M.TIME_SLACK = 5

local function near(a, b, slop)
    if a == nil or b == nil then return false end
    return math.abs(a - b) <= (slop or M.MATCH_SLOP)
end

--- Find Amazon's copy of a record we know the position of.
-- `used` is a set of ids already paired in this pass.
function M.match_remote(remote, kind, start, used, text)
    local best, best_gap
    for _, r in ipairs(remote) do
        if r.kind == kind and r.start and not (used and used[r.annotation_id]) then
            local gap = math.abs(r.start - start)
            if gap <= M.MATCH_SLOP and (kind ~= "note" or text == nil or r.text == text) then
                if not best or gap < best_gap then best, best_gap = r, gap end
            end
        end
    end
    return best
end

--- Decide what to do about annotations.
-- Returns {
--   imports      = { remote records with no local counterpart },
--   pushes       = { local items never sent },
--   pair         = { {local=item, remote=record} to link without any request },
--   delete_remote= { links whose local item is gone },
--   remote_gone  = { keys whose remote record vanished },
-- }
function M.plan(remote, locals, links)
    links = links or {}
    local plan = { imports = {}, pushes = {}, pair = {}, delete_remote = {}, remote_gone = {} }
    local remote_by_id = {}
    for _, r in ipairs(remote) do
        if r.annotation_id and r.annotation_id ~= "" then remote_by_id[r.annotation_id] = r end
    end
    local local_by_key = {}
    for _, l in ipairs(locals) do local_by_key[l.key] = l end

    local linked_remote = {}
    for key, link in pairs(links) do
        if link.id then linked_remote[link.id] = key end
        if link.note_id then linked_remote[link.note_id] = key end
    end

    -- Links whose local side vanished: the user deleted it in KOReader.
    for key, link in pairs(links) do
        if not local_by_key[key] and not link.remote_gone then
            if remote_by_id[link.id] or (link.note_id and remote_by_id[link.note_id]) then
                plan.delete_remote[#plan.delete_remote + 1] = { key = key, link = link }
            else
                plan.remote_gone[#plan.remote_gone + 1] = key -- both sides gone; forget it
            end
        end
    end

    -- Links whose remote side vanished: deleted on a Kindle.
    for key, link in pairs(links) do
        if local_by_key[key] and not link.remote_gone and link.id and not remote_by_id[link.id] then
            plan.remote_gone[#plan.remote_gone + 1] = key
        end
    end

    -- Unlinked local items: pair with an unlinked remote at the same place,
    -- else push.
    local used = {}
    for _, l in ipairs(locals) do
        local link = links[l.key]
        if not link then
            local r = M.match_remote(remote, l.kind, l.start, used)
            if r and not linked_remote[r.annotation_id] then
                used[r.annotation_id] = true
                local pairing = { ["local"] = l, remote = r }
                if l.kind == "highlight" and l.note and l.note ~= "" then
                    local n = M.match_remote(remote, "note", l.start, used, l.note)
                    if n and not linked_remote[n.annotation_id] then
                        used[n.annotation_id] = true
                        pairing.note = n
                    end
                end
                plan.pair[#plan.pair + 1] = pairing
            else
                plan.pushes[#plan.pushes + 1] = l
            end
        end
    end

    -- Unlinked remote records: import. A Kindle note sitting on a Kindle
    -- highlight becomes one KOReader highlight with a note.
    local notes_by_pos = {}
    for _, r in ipairs(remote) do
        if r.kind == "note" and not linked_remote[r.annotation_id] and not used[r.annotation_id] then
            notes_by_pos[#notes_by_pos + 1] = r
        end
    end
    local consumed_notes = {}
    for _, r in ipairs(remote) do
        if not linked_remote[r.annotation_id] and not used[r.annotation_id] and r.kind ~= "note" then
            local imp = { remote = r }
            if r.kind == "highlight" then
                for _, n in ipairs(notes_by_pos) do
                    if not consumed_notes[n.annotation_id] and near(n.start, r.start, M.MATCH_SLOP) then
                        imp.note = n
                        consumed_notes[n.annotation_id] = true
                        break
                    end
                end
            end
            plan.imports[#plan.imports + 1] = imp
        end
    end
    for _, n in ipairs(notes_by_pos) do
        if not consumed_notes[n.annotation_id] then
            plan.imports[#plan.imports + 1] = { remote = n }
        end
    end
    return plan
end

--- Records to send for a batch of local items (creates).
function M.create_items(locals)
    local items = {}
    for _, l in ipairs(locals) do
        items[#items + 1] = { kind = l.kind, action = "create", begin = l.start, ["end"] = l["end"] }
        if l.kind == "highlight" and l.note and l.note ~= "" then
            items[#items + 1] = { kind = "note", action = "create", begin = l.start, ["end"] = l["end"], text = l.note }
        end
    end
    return items
end

--- Records to send to delete what a link points at. A note delete must carry
-- the note's text or Amazon keeps the note.
function M.delete_items(link)
    local items = {}
    if link.kind then
        items[#items + 1] = { kind = link.kind, action = "delete", begin = link.start, ["end"] = link["end"],
                              text = link.kind == "note" and link.text or nil }
    end
    if link.note_id and link.note then
        items[#items + 1] = { kind = "note", action = "delete", begin = link.start, ["end"] = link["end"], text = link.note }
    end
    return items
end

--- After a create batch: pair each pushed local item with Amazon's record.
-- Returns new links (key -> link) and the list of items that did not come back.
function M.pair_after_push(pushed, remote_after, existing_links)
    local used = {}
    for _, link in pairs(existing_links or {}) do
        if link.id then used[link.id] = true end
        if link.note_id then used[link.note_id] = true end
    end
    local links, orphans = {}, {}
    for _, l in ipairs(pushed) do
        local r = M.match_remote(remote_after, l.kind, l.start, used)
        if r then
            used[r.annotation_id] = true
            local link = { id = r.annotation_id, kind = l.kind, start = r.start, ["end"] = r["end"] or r.start,
                           text = l.text }
            if l.kind == "highlight" and l.note and l.note ~= "" then
                local n = M.match_remote(remote_after, "note", l.start, used, l.note)
                if n then used[n.annotation_id] = true; link.note_id = n.annotation_id; link.note = l.note end
            end
            links[l.key] = link
        else
            orphans[#orphans + 1] = l
        end
    end
    return links, orphans
end

--- Decide what to do about the reading position.
-- state: {last_pushed_pos, last_local_change (epoch), local_pos (offset)}
-- remote: sidecar {position, last_read_epoch} or nil
-- Returns one of:
--   "none"     nothing to do
--   "pull"     Amazon is newer: move the reader to remote.position
--   "push"     local is newer: write state.local_pos
--   "conflict" both moved since we last synced; caller asks the user
function M.decide_position(state, remote, opts)
    opts = opts or {}
    local now = opts.now or os.time()
    local have_local = state.local_pos ~= nil
    local remote_pos = remote and remote.position or nil
    if remote_pos == nil then
        return have_local and "push" or "none"
    end
    local remote_is_ours = state.last_pushed_pos ~= nil and near(remote_pos, state.last_pushed_pos, M.MATCH_SLOP)
    if have_local and near(remote_pos, state.local_pos, M.MIN_DELTA) then
        return "none" -- same place, whoever got there first
    end
    if state.last_pushed_pos == nil then
        -- First contact for this book. Without a record of local reading,
        -- Amazon's position is the one worth having (a freshly downloaded
        -- book sits at the start). With one, compare times like a conflict.
        if not have_local or not state.last_local_change then return "pull" end
        local remote_t = remote.last_read_epoch
        if remote_t and state.last_local_change > remote_t + M.TIME_SLACK then return "conflict_local_newer" end
        return "conflict_remote_newer"
    end
    local local_moved = have_local and math.abs(state.local_pos - state.last_pushed_pos) >= M.MIN_DELTA
    if remote_is_ours then
        return local_moved and "push" or "none"
    end
    -- Remote moved since we last wrote. Did we move too?
    if not local_moved then return "pull" end
    local remote_t = remote.last_read_epoch
    local local_t = state.last_local_change
    if remote_t and local_t then
        if remote_t > local_t + M.TIME_SLACK then return "conflict_remote_newer" end
        if local_t > remote_t + M.TIME_SLACK then return "conflict_local_newer" end
    end
    local _ = now
    return "conflict_remote_newer"
end

return M
