local H = require("helpers")
local BS = require("booksync")

local function R(id, kind, start, fin, text) return { annotation_id = id, kind = kind, start = start, ["end"] = fin, text = text } end
local function L(key, kind, start, fin, text, note) return { key = key, kind = kind, start = start, ["end"] = fin, text = text, note = note } end

-- 1. Fresh book: everything remote imports, everything local pushes; a
--    remote note on a remote highlight folds into one import.
local remote = { R("bm1", "bookmark", 5000), R("hl1", "highlight", 6000, 6100), R("n1", "note", 6000, 6100, "a note"), R("n2", "note", 9000, 9000, "lonely") }
local locals = { L("k1", "bookmark", 20000), L("k2", "highlight", 30000, 30050, "words", "my note") }
local plan = BS.plan(remote, locals, {})
H.eq(#plan.imports, 3, "three imports (note folded into highlight)")
H.eq(plan.imports[2].remote.annotation_id, "hl1", "highlight import")
H.eq(plan.imports[2].note and plan.imports[2].note.annotation_id, "n1", "note attached to highlight")
H.eq(plan.imports[3].remote.annotation_id, "n2", "standalone note imported")
H.eq(#plan.pushes, 2, "two pushes")
H.eq(#plan.pair, 0, "nothing to pair")

-- 2. Same place both sides: pair without a request (bookmark 1 byte off).
plan = BS.plan({ R("bm1", "bookmark", 5000) }, { L("k1", "bookmark", 5001) }, {})
H.eq(#plan.pair, 1, "paired by position within slop")
H.eq(#plan.imports, 0, "no import when paired")
H.eq(#plan.pushes, 0, "no push when paired")

-- 3. Linked both sides: nothing happens.
local links = { k1 = { id = "bm1", kind = "bookmark", start = 5000, ["end"] = 5000 } }
plan = BS.plan({ R("bm1", "bookmark", 5000) }, { L("k1", "bookmark", 5000) }, links)
H.eq(#plan.imports + #plan.pushes + #plan.pair + #plan.delete_remote + #plan.remote_gone, 0, "steady state is quiet")

-- 4. Local deleted -> delete upstream; remote deleted -> remote_gone.
plan = BS.plan({ R("bm1", "bookmark", 5000) }, {}, links)
H.eq(#plan.delete_remote, 1, "local deletion propagates")
H.eq(plan.delete_remote[1].key, "k1", "right key")
plan = BS.plan({}, { L("k1", "bookmark", 5000) }, links)
H.eq(#plan.remote_gone, 1, "remote deletion noticed")
H.eq(#plan.pushes, 0, "remote-deleted item is not re-pushed")
plan = BS.plan({}, {}, links)
H.eq(#plan.remote_gone, 1, "both gone: forget the link")
H.eq(#plan.delete_remote, 0, "nothing to delete when remote already gone")

-- 5. Wire items: highlight with note becomes two records; note delete carries text.
local items = BS.create_items({ L("k2", "highlight", 30000, 30050, "words", "my note") })
H.eq(#items, 2, "highlight+note = two records")
H.eq(items[2].kind, "note", "second is the note"); H.eq(items[2].text, "my note", "note text")
local del = BS.delete_items({ id = "hl", note_id = "n", kind = "highlight", start = 1, ["end"] = 2, note = "my note" })
H.eq(#del, 2, "delete highlight and its note")
H.eq(del[2].text, "my note", "note delete carries its text")

-- 6. Pairing after a push: Amazon assigned ids; bookmarks come back with no end.
local after = { R("newbm", "bookmark", 20001), R("newhl", "highlight", 30000, 30050), R("newn", "note", 30000, 30050, "my note"), R("old", "bookmark", 5000) }
local newlinks, orphans = BS.pair_after_push(locals, after, links)
H.eq(newlinks.k1.id, "newbm", "bookmark paired within slop")
H.eq(newlinks.k1["end"], 20001, "missing end defaults to start")
H.eq(newlinks.k2.id, "newhl", "highlight paired")
H.eq(newlinks.k2.note_id, "newn", "note paired to highlight")
H.eq(#orphans, 0, "no orphans")
local _, orphans2 = BS.pair_after_push({ L("k9", "bookmark", 99999) }, after, {})
H.eq(#orphans2, 1, "unmatched push reported as orphan")

-- 7. Position decisions.
local D = BS.decide_position
H.eq(D({ local_pos = 100 }, nil), "push", "no remote yet: push")
H.eq(D({}, nil), "none", "nothing anywhere")
H.eq(D({ local_pos = 5000, last_pushed_pos = 5000 }, { position = 5000 }), "none", "in sync")
H.eq(D({ local_pos = 9000, last_pushed_pos = 5000 }, { position = 5000 }), "push", "we moved, remote is ours")
H.eq(D({ local_pos = 5050, last_pushed_pos = 5000 }, { position = 5000 }), "none", "tiny local move ignored")
H.eq(D({ local_pos = 5000, last_pushed_pos = 5000 }, { position = 40000 }), "pull", "remote moved, we didn't")
H.eq(D({ local_pos = 5000 }, { position = 5100 }), "none", "never synced but already at the same place")
H.eq(D({ local_pos = 5000 }, { position = 40000, last_read_epoch = 1000 }), "pull", "never synced, remote elsewhere, no local history")
H.eq(D({ local_pos = 9000, last_pushed_pos = 5000, last_local_change = 2000 }, { position = 40000, last_read_epoch = 1000 }), "conflict_local_newer", "both moved, local newer")
H.eq(D({ local_pos = 9000, last_pushed_pos = 5000, last_local_change = 1000 }, { position = 40000, last_read_epoch = 2000 }), "conflict_remote_newer", "both moved, remote newer")

H.done("test_booksync")
