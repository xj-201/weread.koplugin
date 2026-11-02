-- Fault-injection tests for the isolated EPUB backup transaction layer.
package.path = "./?.lua;" .. package.path

local Transaction = require("weread.pickthought.backup_transaction")
local function clone(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = clone(v) end
    return out
end

local function new_fs()
    local fs = { files = {}, dirs = { ["/"] = true }, fail_rename = nil }
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
    function fs.read(path) return fs.files[path] end
    function fs.write(path, data)
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

local function harness(fs, id)
    local registry, sequence = {}, 0
    local tx = Transaction.new{
        id = function() return id end,
        fs = {
            exists = fs.exists, mkdir = fs.mkdir, rename = fs.rename,
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
        validate = function(path, role)
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
    fs.write("/books/a.epub.orig", "CLEAN-v1")
    local tx = harness(fs, "success-1")
    local result, err = tx:commit{
        root = "/books/a.epub.pickthought", doc_path = "/books/a.epub",
        candidate_path = "/books/candidate.epub", operation = "append",
    }
    expect(result and result.state == "committed", "incremental commit should succeed: " .. tostring(err))
    expect(fs.read("/books/a.epub") == "INJECTED-v2", "candidate installed")
    expect(fs.read("/books/a.epub.orig") == "CLEAN-v1", "baseline untouched")
    expect(fs.read(result.previous_current) == "INJECTED-v1", "previous current retained")
end

-- A rename that reports failure after moving the candidate must still restore
-- the exact old current EPUB and keep the failed candidate as a transaction artifact.
do
    local fs = new_fs()
    fs.write("/books/b.epub", "INJECTED-old")
    fs.write("/books/b.epub.orig", "CLEAN-old")
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
    expect(fs.read("/books/b.epub.orig") == "CLEAN-old", "baseline remains untouched")
end

-- Replacing an external clean source is one transaction: both the active book
-- and baseline change together, while both previous versions are retained.
do
    local fs = new_fs()
    fs.write("/books/c.epub", "INJECTED-v1")
    fs.write("/books/c.epub.orig", "CLEAN-v1")
    fs.write("/books/candidate.epub", "INJECTED-v2")
    fs.write("/books/new-clean.epub", "CLEAN-v2")
    local tx = harness(fs, "rebuild-success")
    local result, err = tx:commit{
        root = "/books/c.epub.pickthought", doc_path = "/books/c.epub",
        candidate_path = "/books/candidate.epub", original_path = "/books/c.epub.orig",
        new_original_path = "/books/new-clean.epub", operation = "rebuild",
    }
    expect(result and result.state == "committed", "rebuild should commit: " .. tostring(err))
    expect(fs.read("/books/c.epub") == "INJECTED-v2", "new injected EPUB installed")
    expect(fs.read("/books/c.epub.orig") == "CLEAN-v2", "new clean baseline installed")
    expect(fs.read(result.previous_current) == "INJECTED-v1", "previous current retained")
    expect(fs.read(result.previous_original) == "CLEAN-v1", "previous baseline retained")
end

-- If the new baseline rename moves and then reports failure, rollback restores
-- both prior files without confusing a clean current EPUB with the baseline.
do
    local fs = new_fs()
    fs.write("/books/d.epub", "INJECTED-v1")
    fs.write("/books/d.epub.orig", "CLEAN-v1")
    fs.write("/books/candidate.epub", "INJECTED-v2")
    fs.write("/books/new-clean.epub", "CLEAN-v2")
    fs.fail_rename = function(from, to)
        return from:match("/new%-original%.epub$") and to == "/books/d.epub.orig"
    end
    local tx = harness(fs, "rebuild-rollback")
    local result, err = tx:commit{
        root = "/books/d.epub.pickthought", doc_path = "/books/d.epub",
        candidate_path = "/books/candidate.epub", original_path = "/books/d.epub.orig",
        new_original_path = "/books/new-clean.epub", operation = "rebuild",
    }
    expect(not result and tostring(err):match("previous files restored"),
        "baseline install error should roll back: " .. tostring(err))
    expect(fs.read("/books/d.epub") == "INJECTED-v1", "old injected EPUB restored")
    expect(fs.read("/books/d.epub.orig") == "CLEAN-v1", "old baseline restored")
end

-- Unknown data at doc_path must never be overwritten during recovery.
do
    local fs = new_fs()
    fs.write("/books/e.epub", "USER-CHANGED")
    fs.write("/books/candidate.epub", "INJECTED-new")
    local tx = harness(fs, "conflict")
    local result = tx:commit{
        root = "/books/e.epub.pickthought", doc_path = "/books/e.epub",
        candidate_path = "/books/candidate.epub",
    }
    expect(not result, "invalid candidate should not commit")
    expect(fs.read("/books/e.epub") == "USER-CHANGED", "unknown current data preserved")
end

print("backup_transaction_spec: " .. checks .. " checks passed")
