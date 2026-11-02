-- Fault-injection tests for the isolated EPUB backup transaction layer.
package.path = "./?.lua;" .. package.path
-- Keep this spec runnable outside KOReader: production injects its filesystem
-- and JSON implementation, while the module only needs these imports loaded.
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function() return nil end, mkdir = function() return true end }
end
package.preload["json"] = function()
    return { encode = function() return "{}" end, decode = function() return {} end }
end

local Transaction = require("weread.pickthought.backup_transaction")
local function clone(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = clone(v) end
    return out
end

local function new_fs()
    local fs = { files = {}, dirs = { ["/"] = true }, fail_rename = nil, fail_write = nil, write_count = 0 }
    local function parent(path) return path:match("^(.*)/[^/]+$") or "/" end
    local function ensure_dir(path)
        if fs.dirs[path] then return true end
        local p = parent(path)
        if p ~= path then ensure_dir(p) end
        fs.dirs[path] = true
        return true
    end
    function fs.exists(path) return fs.files[path] ~= nil or fs.dirs[path] == true end
    function fs.mkdir(path) ensure_dir(path); return true end
    function fs.dir_exists(path) return fs.dirs[path] == true end
    function fs.read(path) return fs.files[path] end
    function fs.write(path, data)
        fs.write_count = fs.write_count + 1
        if fs.fail_write and fs.fail_write(path, data, fs.write_count) then
            return nil, "injected manifest write failure"
        end
        ensure_dir(parent(path))
        fs.files[path] = data
        return true
    end
    function fs.rename(from, to)
        if fs.files[from] == nil then return nil, "source missing" end
        if fs.exists(to) then return nil, "destination exists" end
        local data = fs.files[from]
        fs.files[from] = nil
        fs.files[to] = data
        if fs.fail_rename and fs.fail_rename(from, to) then
            return nil, "injected failure after rename"
        end
        return true
    end
    function fs.fingerprint(path)
        local data = fs.files[path]
        if data == nil then return nil end
        return tostring(#data) .. ":" .. data
    end
    return fs
end

local function harness(fs, id, validate_fn)
    local registry, sequence = {}, 0
    local tx = Transaction.new{
        id = function() return id end,
        fs = {
            exists = fs.exists, dir_exists = fs.dir_exists, mkdir = fs.mkdir, rename = fs.rename,
            fingerprint = fs.fingerprint, read_file = fs.read, write_atomic = fs.write,
        },
        encode = function(value)
            sequence = sequence + 1
            local key = "manifest-" .. sequence
            registry[key] = clone(value)
            return key
        end,
        decode = function(raw)
            assert(registry[raw], "unknown manifest token")
            return clone(registry[raw])
        end,
        validate = validate_fn or function(path, role)
            local data = fs.read(path)
            if not data then return false, "missing " .. role end
            if role == "candidate" or role == "installed_current" then
                return data:match("^INJECTED") ~= nil, "not injected"
            end
            if role == "clean_original" or role == "installed_original" then
                return data:match("^CLEAN") ~= nil, "not clean"
            end
            return true
        end,
    }
    return tx, registry
end

local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end

-- Successful incremental replacement preserves the prior current file and
-- does not touch the clean baseline.
do
    local fs = new_fs()
    fs.write("/books/a.epub", "INJECTED-v1")
    fs.write("/books/a.epub.pickthought/unused", "keep")
    fs.write("/books/candidate.epub", "INJECTED-v2")
    fs.write("/books/a.epub.pickthought/original.epub", "CLEAN-v1")
    local tx = harness(fs, "success-1")
    local result, err = tx:commit{
        root = "/books/a.epub.pickthought", doc_path = "/books/a.epub",
        candidate_path = "/books/candidate.epub", operation = "append",
    }
    expect(result and result.state == "committed", "incremental commit should succeed: " .. tostring(err))
    expect(fs.read("/books/a.epub") == "INJECTED-v2", "candidate installed")
    expect(fs.read("/books/a.epub.pickthought/original.epub") == "CLEAN-v1", "baseline untouched")
    expect(fs.read(result.previous_current) == "INJECTED-v1", "previous current retained")
end

-- A rename that reports failure after moving the candidate must still restore
-- the exact old current EPUB and keep the failed candidate as a transaction artifact.
do
    local fs = new_fs()
    fs.write("/books/b.epub", "INJECTED-old")
    fs.write("/books/b.epub.pickthought/original.epub", "CLEAN-old")
    fs.write("/books/candidate.epub", "INJECTED-new")
    fs.fail_rename = function(from, to)
        return from:match("/candidate%.epub$") and to == "/books/b.epub"
    end
    local tx = harness(fs, "rename-after-move")
    local result, err = tx:commit{
        root = "/books/b.epub.pickthought", doc_path = "/books/b.epub",
        candidate_path = "/books/candidate.epub",
    }
    expect(not result and tostring(err):match("previous files restored"),
        "post-rename error should trigger rollback: " .. tostring(err))
    expect(fs.read("/books/b.epub") == "INJECTED-old", "old current restored")
    expect(fs.read("/books/b.epub.pickthought/original.epub") == "CLEAN-old", "baseline remains untouched")
end

-- Replacing an external clean source is one transaction: both the active book
-- and baseline change together, while both previous versions are retained.
do
    local fs = new_fs()
    fs.write("/books/c.epub", "INJECTED-v1")
    fs.write("/books/c.epub.pickthought/original.epub", "CLEAN-v1")
    fs.write("/books/candidate.epub", "INJECTED-v2")
    fs.write("/books/new-clean.epub", "CLEAN-v2")
    local tx = harness(fs, "rebuild-success")
    local result, err = tx:commit{
        root = "/books/c.epub.pickthought", doc_path = "/books/c.epub",
        candidate_path = "/books/candidate.epub", original_path = "/books/c.epub.pickthought/original.epub",
        new_original_path = "/books/new-clean.epub", operation = "rebuild",
    }
    expect(result and result.state == "committed", "rebuild should commit: " .. tostring(err))
    expect(fs.read("/books/c.epub") == "INJECTED-v2", "new injected EPUB installed")
    expect(fs.read("/books/c.epub.pickthought/original.epub") == "CLEAN-v2", "new clean baseline installed")
    expect(fs.read(result.previous_current) == "INJECTED-v1", "previous current retained")
    expect(fs.read(result.previous_original) == "CLEAN-v1", "previous baseline retained")
end

-- If the new baseline rename moves and then reports failure, rollback restores
-- both prior files without confusing a clean current EPUB with the baseline.
do
    local fs = new_fs()
    fs.write("/books/d.epub", "INJECTED-v1")
    fs.write("/books/d.epub.pickthought/original.epub", "CLEAN-v1")
    fs.write("/books/candidate.epub", "INJECTED-v2")
    fs.write("/books/new-clean.epub", "CLEAN-v2")
    fs.fail_rename = function(from, to)
        return from:match("/new%-original%.epub$") and to == "/books/d.epub.pickthought/original.epub"
    end
    local tx = harness(fs, "rebuild-rollback")
    local result, err = tx:commit{
        root = "/books/d.epub.pickthought", doc_path = "/books/d.epub",
        candidate_path = "/books/candidate.epub", original_path = "/books/d.epub.pickthought/original.epub",
        new_original_path = "/books/new-clean.epub", operation = "rebuild",
    }
    expect(not result and tostring(err):match("previous files restored"),
        "baseline install error should roll back: " .. tostring(err))
    expect(fs.read("/books/d.epub") == "INJECTED-v1", "old injected EPUB restored")
    expect(fs.read("/books/d.epub.pickthought/original.epub") == "CLEAN-v1", "old baseline restored")
end

-- Unknown data at doc_path must never be overwritten during recovery.
do
    local fs = new_fs()
    fs.write("/books/e.epub", "USER-CHANGED")
    fs.write("/books/candidate.epub", "BROKEN-candidate")
    local tx = harness(fs, "conflict")
    local result = tx:commit{
        root = "/books/e.epub.pickthought", doc_path = "/books/e.epub",
        candidate_path = "/books/candidate.epub",
    }
    expect(not result, "invalid candidate should not commit")
    expect(fs.read("/books/e.epub") == "USER-CHANGED", "unknown current data preserved")
end


-- Recovery after a simulated process stop at current_staged restores the
-- previous current file, persists rolled_back, and is idempotent.
do
    local fs = new_fs()
    fs.write("/books/f.epub.pickthought/transactions/recover-1/previous-current.epub", "INJECTED-before")
    fs.write("/books/f.epub.pickthought/transactions/recover-1/candidate.epub", "INJECTED-after")
    local tx = harness(fs, "unused-id")
    local paths = {
        manifest = "/books/f.epub.pickthought/transactions/recover-1/transaction.json",
    }
    local root = "/books/f.epub.pickthought"
    fs.write(root .. "/transactions/recover-1/transaction.json", "placeholder")
    fs.write(root .. "/manifest.json", "placeholder")
    local tx_manifest = {
        schema_version = 1, transaction_id = "recover-1", state = "current_staged",
        doc_path = "/books/f.epub", original_changed = false, original_existed_before = false,
        candidate_fingerprint = fs.fingerprint(root .. "/transactions/recover-1/candidate.epub"),
        previous_current_fingerprint = fs.fingerprint(root .. "/transactions/recover-1/previous-current.epub"),
    }
    local root_manifest = {
        schema_version = 1, state = "active", active_transaction_id = "recover-1",
        last_committed_transaction_id = nil,
    }
    assert(tx:_write(paths.manifest, tx_manifest))
    assert(tx:_write(root .. "/manifest.json", root_manifest))
    local ok, message = tx:recover(root)
    expect(ok == true, "recovery should restore staged current: " .. tostring(message))
    expect(fs.read("/books/f.epub") == "INJECTED-before", "recovery restores previous current")
    local second, second_message = tx:recover(root)
    expect(second == true, "second recovery should be harmless: " .. tostring(second_message))
    expect(fs.read("/books/f.epub") == "INJECTED-before", "repeated recovery leaves current unchanged")
end


-- If validation of the staged new clean baseline fails before the old baseline
-- is moved, the preexisting baseline must remain untouched and must not be
-- mistaken for the failed new baseline.
do
    local fs = new_fs()
    fs.write("/books/g.epub", "INJECTED-v1")
    fs.write("/books/g.epub.pickthought/original.epub", "CLEAN-v1")
    fs.write("/books/candidate.epub", "INJECTED-v2")
    fs.write("/books/new-clean.epub", "BROKEN-clean")
    local tx = harness(fs, "bad-clean-stage", function(path, role)
        if role == "clean_original" then return false, "deliberate validation failure" end
        return fs.read(path) ~= nil
    end)
    local result, err = tx:commit{
        root = "/books/g.epub.pickthought", doc_path = "/books/g.epub",
        candidate_path = "/books/candidate.epub", original_path = "/books/g.epub.pickthought/original.epub",
        new_original_path = "/books/new-clean.epub", operation = "rebuild",
    }
    expect(not result and tostring(err):match("previous files restored"),
        "bad staged baseline should abort cleanly: " .. tostring(err))
    expect(fs.read("/books/g.epub") == "INJECTED-v1", "current EPUB unchanged on staged baseline validation failure")
    expect(fs.read("/books/g.epub.pickthought/original.epub") == "CLEAN-v1", "preexisting baseline remains untouched")
end


-- First injection creates the clean baseline and installs the injected book
-- as one transaction. The original clean EPUB remains available in the txn.
do
    local fs = new_fs()
    fs.write("/books/h.epub", "CLEAN-first")
    fs.write("/books/candidate.epub", "INJECTED-first")
    fs.write("/books/new-clean.epub", "CLEAN-first")
    local tx = harness(fs, "initial-import")
    local result, err = tx:commit{
        root = "/books/h.epub.pickthought", doc_path = "/books/h.epub",
        candidate_path = "/books/candidate.epub",
        original_path = "/books/h.epub.pickthought/original.epub",
        new_original_path = "/books/new-clean.epub", operation = "initial",
    }
    expect(result and result.state == "committed", "initial injection should commit: " .. tostring(err))
    expect(fs.read("/books/h.epub") == "INJECTED-first", "initial injected book installed")
    expect(fs.read("/books/h.epub.pickthought/original.epub") == "CLEAN-first",
        "initial clean baseline created")
    expect(fs.read(result.previous_current) == "CLEAN-first", "initial source EPUB retained")
end

-- Recovery refuses a conflicting doc_path instead of overwriting user data.
do
    local fs = new_fs()
    local root = "/books/i.epub.pickthought"
    fs.write("/books/i.epub", "USER-EDITED")
    fs.write(root .. "/transactions/recover-conflict/previous-current.epub", "INJECTED-before")
    local tx = harness(fs, "unused-conflict")
    assert(tx:_write(root .. "/transactions/recover-conflict/transaction.json", {
        schema_version = 1, transaction_id = "recover-conflict", state = "current_staged",
        doc_path = "/books/i.epub", original_changed = false, original_existed_before = false,
        candidate_fingerprint = "missing-candidate-fingerprint",
        previous_current_fingerprint = fs.fingerprint(root .. "/transactions/recover-conflict/previous-current.epub"),
    }))
    assert(tx:_write(root .. "/manifest.json", {
        schema_version = 1, state = "active", active_transaction_id = "recover-conflict",
    }))
    local ok, err = tx:recover(root)
    expect(not ok and tostring(err):match("unknown file"), "recovery should report doc_path conflict")
    expect(fs.read("/books/i.epub") == "USER-EDITED", "conflicting current file preserved")
    expect(fs.read(root .. "/transactions/recover-conflict/previous-current.epub") == "INJECTED-before",
        "previous current preserved when destination conflicts")
end


-- If the post-install checkpoint cannot be written, the already persisted
-- installing_candidate state and fingerprints are sufficient to roll back.
do
    local fs = new_fs()
    fs.write("/books/j.epub", "INJECTED-v1")
    fs.write("/books/candidate.epub", "INJECTED-v2")
    local tx_manifest_writes = 0
    fs.fail_write = function(path)
        if path:match("/transaction%.json$") then
            tx_manifest_writes = tx_manifest_writes + 1
            return tx_manifest_writes == 6
        end
        return false
    end
    local tx = harness(fs, "manifest-failure")
    local result, err = tx:commit{
        root = "/books/j.epub.pickthought", doc_path = "/books/j.epub",
        candidate_path = "/books/candidate.epub",
    }
    expect(not result and tostring(err):match("previous files restored"),
        "checkpoint write failure should roll back: " .. tostring(err))
    expect(fs.read("/books/j.epub") == "INJECTED-v1", "old current restored after checkpoint failure")
    local recovered, recovery_message = tx:recover("/books/j.epub.pickthought")
    expect(recovered == true, "recovery after rollback should be idempotent: " .. tostring(recovery_message))
end

-- Recovery must fingerprint doc_path when the current file was checkpointed
-- for staging but the rename had not happened before the process stopped.
do
    local fs = new_fs()
    local root = "/books/k.epub.pickthought"
    fs.write("/books/k.epub", "USER-REPLACED")
    fs.write(root .. "/transactions/current-identity/transaction.json", "placeholder")
    fs.write(root .. "/manifest.json", "placeholder")
    local tx = harness(fs, "unused-current-identity")
    assert(tx:_write(root .. "/transactions/current-identity/transaction.json", {
        schema_version = 1, transaction_id = "current-identity", state = "staging_current",
        doc_path = "/books/k.epub", original_changed = false, original_existed_before = false,
        candidate_fingerprint = "INJECTED-candidate",
        previous_current_fingerprint = "INJECTED-before",
    }))
    assert(tx:_write(root .. "/manifest.json", {
        schema_version = 1, state = "active", active_transaction_id = "current-identity",
    }))
    local ok, err = tx:recover(root .. "/")
    expect(not ok and tostring(err):match("current EPUB identity mismatch"),
        "recovery must reject a changed current EPUB before staging: " .. tostring(err))
    expect(fs.read("/books/k.epub") == "USER-REPLACED", "changed current EPUB must remain untouched")
end

-- Likewise, a preexisting clean baseline must be fingerprinted if its staging
-- rename had not happened yet; an unknown replacement must not be accepted.
do
    local fs = new_fs()
    local root = "/books/l.epub.pickthought"
    fs.write("/books/l.epub", "INJECTED-current")
    fs.write(root .. "/original.epub", "USER-REPLACED-BASELINE")
    fs.write(root .. "/transactions/original-identity/transaction.json", "placeholder")
    fs.write(root .. "/manifest.json", "placeholder")
    local tx = harness(fs, "unused-original-identity")
    assert(tx:_write(root .. "/transactions/original-identity/transaction.json", {
        schema_version = 1, transaction_id = "original-identity", state = "staging_original",
        doc_path = "/books/l.epub", original_path = root .. "/original.epub",
        original_changed = true, original_existed_before = true,
        candidate_fingerprint = "INJECTED-candidate",
        previous_current_fingerprint = fs.fingerprint("/books/l.epub"),
        previous_original_fingerprint = "CLEAN-before",
        new_original_fingerprint = "CLEAN-after",
    }))
    assert(tx:_write(root .. "/manifest.json", {
        schema_version = 1, state = "active", active_transaction_id = "original-identity",
    }))
    local ok, err = tx:recover(root)
    expect(not ok and tostring(err):match("previous original identity mismatch"),
        "recovery must reject a changed baseline before staging: " .. tostring(err))
    expect(fs.read(root .. "/original.epub") == "USER-REPLACED-BASELINE",
        "changed baseline must remain untouched")
end

-- A root manifest without an active transaction is only valid in the idle
-- state; malformed state must not be silently overwritten by a new commit.
do
    local fs = new_fs()
    local root = "/books/m.epub.pickthought"
    fs.write("/books/m.epub", "INJECTED-v1")
    fs.write("/books/candidate.epub", "INJECTED-v2")
    local tx = harness(fs, "bad-root-state")
    assert(tx:_write(root .. "/manifest.json", {
        schema_version = 1, state = "active", active_transaction_id = nil,
    }))
    local result, err = tx:commit{
        root = root, doc_path = "/books/m.epub", candidate_path = "/books/candidate.epub",
    }
    expect(not result and tostring(err):match("not idle"),
        "commit must reject root manifest with active state but no transaction: " .. tostring(err))
    expect(fs.read("/books/m.epub") == "INJECTED-v1", "invalid root manifest must not change current EPUB")
end

-- Operation labels must agree with baseline semantics: initial always
-- creates a baseline, append never changes it, and rebuild always supplies one.
do
    local fs = new_fs()
    fs.write("/books/n.epub", "CLEAN-n")
    fs.write("/books/candidate.epub", "INJECTED-n")
    local tx = harness(fs, "invalid-operation")
    local initial, initial_err = tx:commit{
        root = "/books/n.epub.pickthought", doc_path = "/books/n.epub",
        candidate_path = "/books/candidate.epub", operation = "initial",
    }
    expect(not initial and tostring(initial_err):match("must install a clean baseline"),
        "initial without a baseline must be rejected")
    expect(fs.read("/books/n.epub") == "CLEAN-n", "invalid initial operation leaves current unchanged")

    fs.write("/books/n.epub.pickthought/original.epub", "CLEAN-old")
    fs.write("/books/new-clean.epub", "CLEAN-new")
    local append, append_err = tx:commit{
        root = "/books/n.epub.pickthought", doc_path = "/books/n.epub",
        candidate_path = "/books/candidate.epub",
        original_path = "/books/n.epub.pickthought/original.epub",
        new_original_path = "/books/new-clean.epub", operation = "append",
    }
    expect(not append and tostring(append_err):match("must not replace the clean baseline"),
        "append must not change the clean baseline")
    local rebuild, rebuild_err = tx:commit{
        root = "/books/n.epub.pickthought", doc_path = "/books/n.epub",
        candidate_path = "/books/candidate.epub", operation = "rebuild",
    }
    expect(not rebuild and tostring(rebuild_err):match("must provide a new clean baseline"),
        "rebuild without a new baseline must be rejected")
    expect(fs.read("/books/n.epub") == "CLEAN-n", "invalid operation labels leave current unchanged")
end

print("backup_transaction_spec: " .. checks .. " checks passed")
