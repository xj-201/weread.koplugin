-- PickThought EPUB file transaction layer.
-- Not wired into sync.lua until fault-injection specs cover recovery behavior.
local U = require("weread.pickthought.util")
local Json = require("weread.pickthought.json")
local lfs = require("libs/libkoreader-lfs")
local Transaction = {}
Transaction.__index = Transaction

local function default_id()
    local value = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
        .. "-" .. tostring({})
    return (value:gsub("[^%w%-]", ""))
end
local function join(a, b)
    return tostring(a):gsub("/+$", "") .. "/" .. tostring(b):gsub("^/+", "")
end
local function valid_id(value)
    return type(value) == "string" and value ~= "" and not value:find("[^%w%-_]")
end
local function call_ok(fn, ...)
    local ok, a, b = pcall(fn, ...)
    if not ok then return nil, tostring(a) end
    if not a then return nil, tostring(b or "operation failed") end
    return true
end

function Transaction.new(deps)
    deps = deps or {}
    local fs = deps.fs or {}
    return setmetatable({
        exists = fs.exists or U.file_exists,
        dir_exists = fs.dir_exists or function(path) return lfs.attributes(path, "mode") == "directory" end,
        mkdir = fs.mkdir or U.mkdir,
        rename = fs.rename or os.rename,
        fingerprint = fs.fingerprint or U.content_fingerprint,
        validate = deps.validate,
        encode = deps.encode or Json.encode,
        decode = deps.decode or Json.decode,
        write = fs.write_atomic or U.atomic_write,
        read = fs.read_file or U.read_file,
        id = deps.id or default_id,
    }, Transaction)
end

function Transaction:_write(path, value)
    local serializable = value
    if type(value) == "table" and value.manifest_path then
        serializable = {}
        for key, item in pairs(value) do
            if key ~= "manifest_path" then serializable[key] = item end
        end
    end
    local ok, encoded = pcall(self.encode, serializable)
    if not ok or type(encoded) ~= "string" then
        return nil, "encode manifest failed: " .. tostring(encoded)
    end
    return call_ok(self.write, path, encoded, true)
end
function Transaction:_read(path)
    local read_ok, raw, read_err = pcall(self.read, path, true)
    if not read_ok then return nil, "manifest read failed: " .. tostring(raw) end
    if not raw then return nil, read_err or "manifest missing" end
    local decode_ok, value = pcall(self.decode, raw)
    if not decode_ok or type(value) ~= "table" then
        return nil, "manifest invalid: " .. tostring(value)
    end
    return value
end
function Transaction:_fingerprint(path)
    local ok, value = pcall(self.fingerprint, path)
    if not ok then return nil, tostring(value) end
    if type(value) ~= "string" or value == "" then return nil, "cannot fingerprint " .. tostring(path) end
    return value
end
function Transaction:_valid(path, role, opts)
    if type(self.validate) ~= "function" then return nil, "EPUB validator is required" end
    local ok, valid, err = pcall(self.validate, path, role, opts)
    if not ok then return nil, tostring(valid) end
    if not valid then return nil, tostring(err or ("validation failed: " .. role)) end
    return true
end
function Transaction:_paths(root, id)
    local dir = join(join(root, "transactions"), id)
    return {
        dir = dir, manifest = join(dir, "transaction.json"),
        candidate = join(dir, "candidate.epub"),
        failed_candidate = join(dir, "failed-candidate.epub"),
        previous_current = join(dir, "previous-current.epub"),
        new_original = join(dir, "new-original.epub"),
        failed_original = join(dir, "failed-original.epub"),
        previous_original = join(dir, "previous-original.epub"),
    }
end

-- Roll back only files whose complete-content fingerprints match this txn.
-- Never overwrite a destination and never infer file identity from its name.
function Transaction:_rollback(root_manifest_path, root_manifest, tx, paths)
    local errors = {}
    local function move_owned(source, destination, expected, label)
        if not self.exists(source) then return true end
        local actual, fp_err = self:_fingerprint(source)
        if not actual or actual ~= expected then
            errors[#errors + 1] = label .. " identity mismatch at " .. source
                .. ": " .. tostring(fp_err or actual)
            return nil
        end
        if self.exists(destination) then
            errors[#errors + 1] = label .. " restore target already exists: " .. destination
            return nil
        end
        local moved, move_err = call_ok(self.rename, source, destination)
        if not moved then errors[#errors + 1] = label .. " restore failed: " .. tostring(move_err); return nil end
        return true
    end

    if self.exists(paths.previous_current) then
        if self.exists(tx.doc_path) then
            local current_fp = self:_fingerprint(tx.doc_path)
            if current_fp == tx.candidate_fingerprint then
                if self.exists(paths.failed_candidate) then
                    errors[#errors + 1] = "failed-candidate path already exists: " .. paths.failed_candidate
                else
                    local moved, move_err = call_ok(self.rename, tx.doc_path, paths.failed_candidate)
                    if not moved then errors[#errors + 1] = "cannot stage installed candidate: " .. tostring(move_err) end
                end
            else
                errors[#errors + 1] = "doc_path contains an unknown file; refusing to overwrite: " .. tx.doc_path
            end
        end
        if not self.exists(tx.doc_path) then
            move_owned(paths.previous_current, tx.doc_path, tx.previous_current_fingerprint, "previous current")
        end
    elseif not self.exists(tx.doc_path) then
        errors[#errors + 1] = "both current EPUB and previous-current are missing"
    end

    if tx.original_changed then
        if self.exists(paths.previous_original) then
            if self.exists(tx.original_path) then
                local original_fp = self:_fingerprint(tx.original_path)
                if original_fp == tx.new_original_fingerprint then
                    if self.exists(paths.failed_original) then
                        errors[#errors + 1] = "failed-original path already exists: " .. paths.failed_original
                    else
                        local moved, move_err = call_ok(self.rename, tx.original_path, paths.failed_original)
                        if not moved then errors[#errors + 1] = "cannot stage new original: " .. tostring(move_err) end
                    end
                else
                    errors[#errors + 1] = "original path contains an unknown file; refusing to overwrite: " .. tx.original_path
                end
            end
            if not self.exists(tx.original_path) then
                move_owned(paths.previous_original, tx.original_path,
                    tx.previous_original_fingerprint, "previous original")
            end
        elseif not tx.original_existed_before and self.exists(tx.original_path) then
            local original_fp = self:_fingerprint(tx.original_path)
            if original_fp == tx.new_original_fingerprint and not self.exists(paths.failed_original) then
                local moved, move_err = call_ok(self.rename, tx.original_path, paths.failed_original)
                if not moved then errors[#errors + 1] = "cannot retain new original: " .. tostring(move_err) end
            elseif original_fp ~= tx.new_original_fingerprint then
                errors[#errors + 1] = "unexpected original file; refusing to move: " .. tx.original_path
            end
        end
    end

    tx.state = #errors == 0 and "rolled_back" or "rollback_conflict"
    tx.recovery_errors = errors
    local tx_ok, tx_err = self:_write(tx.manifest_path, tx)
    if not tx_ok then
        errors[#errors + 1] = "cannot persist rollback result: " .. tostring(tx_err)
    end
    if root_manifest and tx_ok then
        if #errors == 0 then
            root_manifest.active_transaction_id = nil
            root_manifest.state = "idle"
        else
            -- Keep the active pointer so a later recovery attempt can retry
            -- unresolved moves instead of silently orphaning the transaction.
            root_manifest.state = "recovery_required"
        end
        root_manifest.last_recovery_transaction_id = tx.transaction_id
        local root_ok, root_err = self:_write(root_manifest_path, root_manifest)
        if not root_ok then errors[#errors + 1] = "cannot persist root recovery state: " .. tostring(root_err) end
    end
    if #errors > 0 then return nil, table.concat(errors, "; ") end
    return true
end

-- opts: root, doc_path, candidate_path, original_path (optional),
-- new_original_path (optional), operation.
-- validate(path, role, opts) must parse the EPUB and verify its marker/role.
function Transaction:commit(opts)
    opts = opts or {}
    local root, doc_path, candidate_path = opts.root, opts.doc_path, opts.candidate_path
    if type(root) ~= "string" or root == "" or type(doc_path) ~= "string" or doc_path == ""
        or type(candidate_path) ~= "string" or candidate_path == "" then
        return nil, "root, doc_path and candidate_path are required"
    end
    if root ~= doc_path .. ".pickthought" then
        return nil, "transaction root must be doc_path .. '.pickthought'"
    end
    if doc_path == candidate_path then return nil, "candidate_path must differ from doc_path" end
    if not self.exists(doc_path) then return nil, "current EPUB does not exist: " .. doc_path end
    if not self.exists(candidate_path) then return nil, "candidate EPUB does not exist: " .. candidate_path end
    if type(self.validate) ~= "function" then return nil, "EPUB validator is required" end

    local original_path, new_original_path = opts.original_path, opts.new_original_path
    local original_changed = new_original_path ~= nil
    if original_changed and (original_path ~= join(root, "original.epub")
        or original_path == doc_path or original_path == candidate_path
        or new_original_path == doc_path or new_original_path == candidate_path
        or new_original_path == original_path or not self.exists(new_original_path)) then
        return nil, "original_path must be the transaction root original.epub and new_original_path must exist"
    end

    local operation = opts.operation or (original_changed and "rebuild" or "append")
    if operation ~= "initial" and operation ~= "append" and operation ~= "rebuild" then
        return nil, "unsupported transaction operation"
    end
    local id = tostring(self.id())
    if not valid_id(id) then return nil, "invalid transaction id" end
    local paths = self:_paths(root, id)
    if self.dir_exists(paths.dir) then return nil, "transaction directory already exists: " .. paths.dir end
    local made, mkdir_err = call_ok(self.mkdir, paths.dir)
    if not made then return nil, "cannot create transaction directory: " .. tostring(mkdir_err) end

    local tx = {
        schema_version = 1, transaction_id = id,
        operation = operation,
        state = "preparing", doc_path = doc_path, original_path = original_path,
        original_changed = original_changed,
        original_existed_before = original_changed and self.exists(original_path) or false,
        files = {
            candidate = "candidate.epub", previous_current = "previous-current.epub",
            new_original = original_changed and "new-original.epub" or nil,
            previous_original = original_changed and "previous-original.epub" or nil,
        },
    }
    tx.manifest_path = paths.manifest
    local root_manifest_path = join(root, "manifest.json")
    local root_manifest = {
        schema_version = 1, state = "active", active_transaction_id = id,
        last_committed_transaction_id = nil,
    }
    if self.exists(root_manifest_path) then
        local existing, read_err = self:_read(root_manifest_path)
        if not existing then return nil, "existing root manifest is unreadable: " .. tostring(read_err) end
        if existing.active_transaction_id then
            return nil, "another transaction is active: " .. tostring(existing.active_transaction_id)
        end
        if existing.state == "recovery_required" then
            return nil, "previous transaction requires manual recovery; refusing a new transaction"
        end
        root_manifest.last_committed_transaction_id = existing.last_committed_transaction_id
    end
    local persisted, persist_err = self:_write(paths.manifest, tx)
    if not persisted then return nil, "cannot initialize transaction manifest: " .. tostring(persist_err) end
    persisted, persist_err = self:_write(root_manifest_path, root_manifest)
    if not persisted then return nil, "cannot activate transaction manifest: " .. tostring(persist_err) end

    local function fail(message)
        local recovered, recovery_err = self:_rollback(root_manifest_path, root_manifest, tx, paths)
        if not recovered then return nil, tostring(message) .. "; recovery required: " .. tostring(recovery_err) end
        return nil, tostring(message) .. "; previous files restored; transaction artifacts retained at " .. paths.dir
    end
    local function checkpoint(state)
        tx.state = state
        local ok, err = self:_write(paths.manifest, tx)
        if not ok then return nil, "manifest checkpoint failed (" .. state .. "): " .. tostring(err) end
        return true
    end
    local function move(source, destination, label)
        if self.exists(destination) then return nil, label .. " destination already exists: " .. destination end
        local ok, err = call_ok(self.rename, source, destination)
        if not ok then return nil, label .. " rename failed: " .. tostring(err) end
        return true
    end

    local ok, err = move(candidate_path, paths.candidate, "candidate staging")
    if not ok then return fail(err) end
    tx.candidate_fingerprint, err = self:_fingerprint(paths.candidate)
    if not tx.candidate_fingerprint then return fail(err) end
    ok, err = self:_valid(paths.candidate, "candidate", opts)
    if not ok then return fail(err) end

    if original_changed then
        ok, err = move(new_original_path, paths.new_original, "new original staging")
        if not ok then return fail(err) end
        tx.new_original_fingerprint, err = self:_fingerprint(paths.new_original)
        if not tx.new_original_fingerprint then return fail(err) end
        ok, err = self:_valid(paths.new_original, "clean_original", opts)
        if not ok then return fail(err) end
        if self.exists(original_path) then
            tx.previous_original_fingerprint, err = self:_fingerprint(original_path)
            if not tx.previous_original_fingerprint then return fail(err) end
            ok, err = self:_valid(original_path, "previous_original", opts)
            if not ok then return fail(err) end
        end
    end
    tx.previous_current_fingerprint, err = self:_fingerprint(doc_path)
    if not tx.previous_current_fingerprint then return fail(err) end
    ok, err = self:_valid(doc_path, "previous_current", opts)
    if not ok then return fail(err) end
    ok, err = checkpoint("prepared")
    if not ok then return fail(err) end

    ok, err = checkpoint("staging_current")
    if not ok then return fail(err) end
    ok, err = move(doc_path, paths.previous_current, "current staging")
    if not ok then return fail(err) end
    ok, err = checkpoint("current_staged")
    if not ok then return fail(err) end

    if original_changed and tx.previous_original_fingerprint then
        ok, err = checkpoint("staging_original")
        if not ok then return fail(err) end
        ok, err = move(original_path, paths.previous_original, "original staging")
        if not ok then return fail(err) end
        ok, err = checkpoint("original_staged")
        if not ok then return fail(err) end
    end

    ok, err = checkpoint("installing_candidate")
    if not ok then return fail(err) end
    ok, err = move(paths.candidate, doc_path, "candidate install")
    if not ok then return fail(err) end
    ok, err = checkpoint("candidate_installed")
    if not ok then return fail(err) end

    if original_changed then
        ok, err = checkpoint("installing_original")
        if not ok then return fail(err) end
        ok, err = move(paths.new_original, original_path, "new original install")
        if not ok then return fail(err) end
        ok, err = checkpoint("original_installed")
        if not ok then return fail(err) end
    end

    ok, err = self:_valid(doc_path, "installed_current", opts)
    if not ok then return fail(err) end
    if original_changed then
        ok, err = self:_valid(original_path, "installed_original", opts)
        if not ok then return fail(err) end
    end
    ok, err = checkpoint("committed")
    if not ok then return fail(err) end

    root_manifest.state = "idle"
    root_manifest.active_transaction_id = nil
    root_manifest.last_committed_transaction_id = id
    ok, err = self:_write(root_manifest_path, root_manifest)
    if not ok then
        return nil, "transaction committed but root manifest update failed: " .. tostring(err)
            .. "; recovery record: " .. paths.manifest
    end
    return {
        transaction_id = id, transaction_dir = paths.dir, state = "committed",
        previous_current = paths.previous_current,
        previous_original = tx.previous_original_fingerprint and paths.previous_original or nil,
    }
end

function Transaction:recover(root)
    if type(root) ~= "string" or root == "" then return nil, "root is required" end
    local root_manifest_path = join(root, "manifest.json")
    if not self.exists(root_manifest_path) then return true, "no transaction manifest" end
    local root_manifest, err = self:_read(root_manifest_path)
    if not root_manifest then return nil, err end
    if root_manifest.schema_version ~= 1 then return nil, "unsupported root manifest schema" end
    local id = root_manifest.active_transaction_id
    if not id then return true, "no active transaction" end
    if not valid_id(id) then return nil, "invalid active transaction id; refusing recovery" end
    local paths = self:_paths(root, id)
    local tx, tx_err = self:_read(paths.manifest)
    if not tx then return nil, "active transaction manifest unreadable: " .. tostring(tx_err) end
    local expected_doc_path = root:sub(1, -#".pickthought" - 1)
    if expected_doc_path == "" or tx.doc_path ~= expected_doc_path
        or (tx.original_changed and tx.original_path ~= join(root, "original.epub")) then
        return nil, "transaction manifest paths do not match the requested book root"
    end
    tx.manifest_path = paths.manifest
    if tx.transaction_id ~= id or tx.schema_version ~= 1
        or type(tx.doc_path) ~= "string" or type(tx.original_changed) ~= "boolean"
        or type(tx.original_existed_before) ~= "boolean" then
        return nil, "active transaction manifest identity/version/fields mismatch"
    end
    local valid_states = {
        preparing = true, prepared = true, staging_current = true, current_staged = true,
        staging_original = true, original_staged = true, installing_candidate = true,
        candidate_installed = true, installing_original = true, original_installed = true,
        committed = true, rolled_back = true, rollback_conflict = true,
    }
    if not valid_states[tx.state] then return nil, "unknown transaction state; refusing recovery" end
    if tx.state == "committed" or tx.state == "rolled_back" then
        root_manifest.active_transaction_id = nil
        if tx.state == "committed" then root_manifest.last_committed_transaction_id = id end
        root_manifest.state = "idle"
        local ok, write_err = self:_write(root_manifest_path, root_manifest)
        if not ok then return nil, "cannot finalize completed root manifest: " .. tostring(write_err) end
        return true, tx.state .. " transaction finalized"
    end
    return self:_rollback(root_manifest_path, root_manifest, tx, paths)
end

return Transaction
