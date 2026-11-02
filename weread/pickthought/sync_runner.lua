-- PickThought 同步执行器：网络、章节映射和 EPUB 注入统一复用 WeRead Client。
-- 由 BackgroundWorker 子进程调用；本模块不直接操作 KOReader UI。
local Adapter = require("weread.pickthought.weread_adapter")
local EpubReader = require("weread.pickthought.epub_reader")
local EpubInject = require("weread.pickthought.epub_inject")
local Json = require("weread.pickthought.json")
local Sync = require("weread.pickthought.sync")
local SyncBudget = require("weread.pickthought.sync_budget")
local Thoughts = require("weread.pickthought.thoughts")
local U = require("weread.pickthought.util")

local Runner = {}

local function memory_available_kb()
    local file = io.open("/proc/meminfo", "r")
    if not file then return nil end
    local raw = file:read("*a") or ""
    file:close()
    local available = tonumber(raw:match("MemAvailable:%s*(%d+)%s*kB"))
    if available then return available end
    local free = tonumber(raw:match("MemFree:%s*(%d+)%s*kB"))
    local buffers = tonumber(raw:match("Buffers:%s*(%d+)%s*kB")) or 0
    local cached = tonumber(raw:match("Cached:%s*(%d+)%s*kB")) or 0
    return free and (free + buffers + cached) or nil
end

local function decode_file(path)
    local raw = U.read_file(path, true)
    if not raw then return nil end
    local ok, value = pcall(Json.decode, raw)
    if ok and type(value) == "table" then return value end
end

local function write_json(path, value)
    local ok, encoded = pcall(Json.encode, value)
    if not ok then return nil, encoded end
    return U.atomic_write(path, encoded, true)
end

local function chapter_cache_valid(data)
    return type(data) == "table"
        and type(data.underlines) == "table"
        and type(data.review_map) == "table"
        and tonumber(data.underline_count) ~= nil
end

local function cache_key(uid)
    return U.id_name(uid) .. ".json"
end

local function normalize_chapter_ids(chapters)
    if type(chapters) ~= "table" then return nil end
    local normalized = {}
    for _, chapter in ipairs(chapters) do
        if type(chapter) == "table" then
            local uid = chapter.uid or chapter.chapterUid or chapter.chapter_uid
            if uid ~= nil and tostring(uid) ~= "" then
                local item = {}
                for key, value in pairs(chapter) do item[key] = value end
                item.uid = tostring(uid)
                normalized[#normalized + 1] = item
            end
        end
    end
    return #normalized > 0 and normalized or nil
end

function Runner.run(plugin, doc_path, book_id, worker_context, options)
    options = options or {}
    local adapter = Adapter:new(plugin)
    local book_dir = adapter:book_dir(book_id)
    U.mkdir(book_dir)
    local cache_dir = book_dir .. "/pickthought-sync-cache"
    U.mkdir(cache_dir)

    local chapter_list_path = cache_dir .. "/chapters.json"
    local api = adapter.api
    local online_chapters = api.chapters
    api.chapters = function(api_self, bid)
        if options.offline then
            local cached = normalize_chapter_ids(decode_file(chapter_list_path))
            if not cached then
                error("离线同步没有可用的章节列表缓存")
            end
            return cached
        end
        local ok, chapters = pcall(online_chapters, api_self, bid)
        local normalized = ok and normalize_chapter_ids(chapters) or nil
        if normalized then
            local saved, save_err = write_json(chapter_list_path, normalized)
            if not saved then
                error("章节列表缓存保存失败: " .. tostring(save_err))
            end
            return normalized
        end
        local cached = normalize_chapter_ids(decode_file(chapter_list_path))
        if cached then return cached end
        error(ok and "微信读书章节列表为空" or tostring(chapters))
    end

    local pending_full_cache = {}
    local annotations = {}
    function annotations:fetch_chapter(bid, uid, progress)
        local path = cache_dir .. "/" .. U.id_name(bid) .. "-" .. cache_key(uid)
        local cached = decode_file(path)
        if chapter_cache_valid(cached) then
            cached.resumed = true
            if type(progress) == "function" then
                progress("cached", 1, 1, "", {
                    current_underlines = tonumber(cached.underline_count) or 0,
                    current_thoughts = tonumber(cached.thought_entry_count) or 0,
                })
            end
            return cached
        end
        if options.offline then
            error("离线模式缺少章节缓存: " .. tostring(uid))
        end
        local data = adapter:fetch_chapter(bid, uid, progress)
        if type(data) ~= "table" or data.underline_request_ok == false
            or #(data.errors or {}) > 0 then
            return data
        end
        if #(data.review_groups or {}) > 0 then
            -- 先暂存完整结果；只有想法成功写入 SQLite 后才压缩成续传缓存。
            pending_full_cache[tostring(bid) .. "/" .. tostring(uid)] = {
                path = path, data = data,
            }
        else
            local saved, save_err = write_json(path, SyncBudget.compact(data))
            if not saved then error("章节缓存保存失败: " .. tostring(save_err)) end
        end
        return data
    end

    local function save_thoughts(bid, uid, groups)
        local count, save_err = Thoughts.save(adapter, bid, uid, groups)
        if not count then return nil, save_err end
        local key = tostring(bid) .. "/" .. tostring(uid)
        local pending = pending_full_cache[key]
        if pending then
            local saved, cache_err = write_json(pending.path, SyncBudget.compact(pending.data))
            pending_full_cache[key] = nil
            if not saved then
                return nil, "想法已保存，但章节续传缓存写入失败: " .. tostring(cache_err)
            end
        end
        return count
    end

    local report, sync_err = Sync.run{
        doc_path = doc_path,
        book_id = tostring(book_id),
        api = api,
        annotations = annotations,
        load_meta = function(path) return EpubReader.load(path) end,
        read_text = function(meta, href) return EpubReader.read(meta, href) end,
        read_spine = function(meta, callback) return EpubReader.each_spine(meta, callback) end,
        save_thoughts = save_thoughts,
        merge_thoughts = function(bid, uid, from_range, into_range)
            return Thoughts.merge(adapter, bid, uid, from_range, into_range)
        end,
        inject = function(src, bid, mapped, dest, inject_opts)
            return EpubInject.inject_copy(src, bid, mapped, {
                dest = dest,
                append = inject_opts and inject_opts.append == true,
                meta = inject_opts and inject_opts.meta,
                book_ids = inject_opts and inject_opts.book_ids,
                progress = function(path, done, total, detail)
                    if worker_context and worker_context.cancelled
                        and worker_context.cancelled() then return false end
                    if inject_opts and type(inject_opts.progress) == "function" then
                        return inject_opts.progress(path, done, total, detail) ~= false
                    end
                    return true
                end,
            })
        end,
        append = true,
        map_cache_path = function(bid)
            U.mkdir(cache_dir)
            return cache_dir .. "/map-" .. U.id_name(bid) .. ".json"
        end,
        spine_cache = true,
        max_batch_cache_bytes = SyncBudget.DEFAULTS.max_cache_bytes,
        max_batch_underlines = SyncBudget.DEFAULTS.max_underlines,
        max_batch_thought_entries = SyncBudget.DEFAULTS.max_thought_entries,
        min_available_kb = SyncBudget.DEFAULTS.min_available_kb,
        read_memory_available_kb = memory_available_kb,
        map_checkpoint = function()
            return not (worker_context and worker_context.cancelled
                and worker_context.cancelled())
        end,
        progress = function(phase, current, total, title, progress_book_id, metrics)
            if worker_context and worker_context.cancelled
                and worker_context.cancelled() then return false end
            if worker_context and worker_context.emit then
                worker_context.emit({
                    stage = phase,
                    current = tonumber(current) or 0,
                    count = tonumber(total) or 0,
                    title = tostring(title or ""),
                    book_id = tostring(progress_book_id or book_id),
                    metrics = metrics or {},
                })
            end
            return true
        end,
    }
    if not report then
        return {ok = false, error = tostring(sync_err or "PickThought 同步失败")}
    end
    return {ok = true, report = report}
end

return Runner
