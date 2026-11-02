-- PickThought 与 WeRead 的生命周期/网络会话适配。
-- 不创建独立登录、Cookie、书籍库或设置存储。
local UIManager = require("ui/uimanager")
local PluginUtil = require("weread.lib.plugin_util")
local _ = PluginUtil.tr
local M = {}

local function current_file(plugin)
    return plugin.ui and plugin.ui.document and plugin.ui.document.file
end

local function current_book_id(plugin)
    local binding = plugin._annotationBinding and plugin:_annotationBinding()
    if binding and binding.book_id then return tostring(binding.book_id) end
    return plugin:detectWeReadBook()
end

function M:getPickThoughtMenuItems()
    local path = current_file(self)
    local book_id = current_book_id(self)
    if not path or not book_id or not path:lower():match("%.epub$") then
        return {}
    end
    return {
        {
            text = _("Inject PickThought into this EPUB"),
            callback = function()
                self:startPickThoughtInjection()
            end,
        },
    }
end

function M:_pickThoughtWorker()
    if self._pickthought_worker then return self._pickthought_worker end
    local BackgroundWorker = require("weread.lib.background_worker")
    local temp_dir = self.settings.data_dir .. "/pickthought-workers"
    self._pickthought_worker = BackgroundWorker:new{
        temp_dir = temp_dir,
        min_available_kb = 96 * 1024,
        timeout = 1800,
        cancel_grace = 8,
    }
    return self._pickthought_worker
end

local function progress_title(state)
    local stage = tostring(state.stage or "")
    local title = tostring(state.title or "")
    local current, count = tonumber(state.current) or 0, tonumber(state.count) or 0
    local label = ({
        chapters = "获取微信读书章节",
        fetch = "下载划线与想法",
        map = "匹配本地 EPUB 章节",
        inject = "生成 PickThought EPUB 副本",
        copy = "准备原书副本",
    })[stage] or "PickThought 同步"
    if title ~= "" then label = label .. " · " .. title end
    if count > 0 then label = label .. string.format(" (%d/%d)", current, count) end
    return label
end

function M:startPickThoughtInjection(options)
    options = options or {}
    local path = current_file(self)
    local book_id = current_book_id(self)
    if not path or not book_id or not path:lower():match("%.epub$") then
        self:showInfo(_("PickThought injection requires an open WeRead EPUB."))
        return false
    end
    if options.offline == nil then
        options.offline = not self:isNetworkConnected()
    end
    -- 离线续传只读取本地章节/想法缓存，不需要在线登录检查；
    -- 在线拉取时才验证 WeRead 会话，避免断网时缓存也无法重注。
    if not options.offline and not self:requireLogin(true, true) then return false end

    local worker = self:_pickThoughtWorker()
    if worker:busy() then
        self:showTransientInfo(_("A PickThought task is already running."), 2)
        return false
    end

    -- BackgroundWorker uses fork on Linux. SQLite connections opened by the
    -- reader process must not be inherited and then reused across the fork: close
    -- PickThought per-book handles first; the child will open its own connections.
    require("weread.pickthought.thoughts").clear_memory_cache()

    local Dialog = require("weread.ui.download_dialog")
    local dialog = Dialog:new{
        title = _("Preparing PickThought injection"),
        description = _("The current EPUB will be replaced by the injected version. The clean original is retained as a .orig backup. You can pause the task."),
        progress_max = 100,
        buttons = { { {
            text = _("Pause"),
            callback = function()
                if self._pickthought_request then
                    worker:cancel(self._pickthought_request, "user_cancelled")
                end
            end,
        } } },
    }
    dialog:show()
    self._pickthought_dialog = dialog

    local Runner = require("weread.pickthought.sync_runner")
    local request
    local start_returned = false
    local ok, result = worker:start{
        kind = "pickthought_sync",
        task = function(context)
            return Runner.run(self, path, tostring(book_id), context, options)
        end,
        on_progress = function(state)
            if self._pickthought_dialog ~= dialog then return end
            local title = progress_title(state)
            local current, count = tonumber(state.current) or 0, tonumber(state.count) or 0
            if count > 0 then
                dialog:reportProgress(math.max(0, math.min(100, current / count * 100)))
            end
            dialog:setTitle(title)
        end,
        on_done = function(outcome)
            -- BackgroundWorker may report worker_unavailable/low_memory
            -- synchronously from start(); let the caller show that failure once.
            if not start_returned then return end
            if self._pickthought_request == request then self._pickthought_request = nil end
            if self._pickthought_dialog == dialog then
                self._pickthought_dialog = nil
                pcall(function() dialog:close() end)
            end
            if outcome and outcome.ok and type(outcome.value) == "table"
                and outcome.value.ok then
                local report = outcome.value.report or {}
                if report.deferred then
                    self:showTransientInfo(_("PickThought task deferred; cached data was retained."), 4)
                    return
                end
                if report.no_changes then
                    self:showInfo(_("PickThought found no new data to inject."))
                    return
                end
                if report.book_failed or (type(report.failed_books) == "table"
                    and #report.failed_books > 0) then
                    self:showInfo(_("PickThought finished with incomplete books; check the task log before using the EPUB copy."))
                    return
                end
                local message = string.format(
                    "PickThought 注入完成。\n拉取划线：%s 条\n成功注入划线：%s 条\n成功注入想法：%s 条\n匹配章节：%s 章\n原书备份：%s\n\n请关闭并重新打开本书以加载新副本。",
                    tostring(report.total_underlines or "—"),
                    tostring(report.underlines_injected or "—"),
                    tostring(report.thoughts_injected or "—"),
                    tostring(report.chapters_matched or "—"),
                    tostring(report.backup or "—"))
                self:showInfo(message)
            elseif outcome and outcome.cancelled then
                self:showTransientInfo(_("PickThought injection paused. Saved chapter data can be reused."), 3)
            else
                local reason = outcome and outcome.value and outcome.value.error
                    or outcome and outcome.error or "unknown error"
                self:showInfo(_("PickThought injection failed: ") .. tostring(reason))
            end
        end,
    }
    start_returned = true
    if not ok then
        self._pickthought_dialog = nil
        pcall(function() dialog:close() end)
        self:showInfo(_("Unable to start PickThought worker: ") .. tostring(result))
        return false
    end
    request = result
    self._pickthought_request = request
    return true
end

function M:cancelPickThoughtInjection()
    if not self._pickthought_worker or not self._pickthought_request then return false end
    return self._pickthought_worker:cancel(self._pickthought_request, "user_cancelled")
end

function M:_pickThoughtStore()
    if not self._pickthought_store then
        local Adapter = require("weread.pickthought.weread_adapter")
        self._pickthought_store = Adapter:new(self)
    end
    return self._pickthought_store
end

local function comment_error_kind(err)
    local value = tostring(err or ""):lower()
    if value:find("http 401", 1, true) or value:find("http 403", 1, true)
        or value:find("not logged", 1, true) then return "not_logged_in" end
    if value:find("429", 1, true) or value:find("rate limit", 1, true)
        or value:find("频率", 1, true) then return "rate_limited" end
    if value:find("timeout", 1, true) or value:find("network", 1, true)
        or value:find("连接", 1, true) then return "network" end
    return "invalid_response"
end

function M:_viewPickThoughtComments(book_id, item, popup, request_token)
    -- Invalidate any older count-prefetch result for this thought. The full
    -- comment request is now the newest source of truth for its count.
    if type(item) == "table" then
        item._comment_count_request_generation =
            (tonumber(item._comment_count_request_generation) or 0) + 1
    end
    local popup_generation = popup and popup._popup_generation
    local function request_is_current()
        if not popup then return false end
        return popup._popup_generation == popup_generation
            and popup._comment_request_token == request_token
    end
    local review_id = tostring(item and item.review_id or "")
    local ReviewComments = require("weread.pickthought.review_comments")
    local Json = require("weread.pickthought.json")
    local U = require("weread.pickthought.util")
    if review_id == "" then
        return {ok = false, error = "invalid_review_id",
            message = ReviewComments.message_for("invalid_review_id")}
    end

    local store = self:_pickThoughtStore()
    local cache = ReviewComments.Cache.new{
        path = store:book_dir(book_id) .. "/review_comments.db",
    }
    local ttl = ReviewComments.DEFAULT_TTL_SECONDS
    local now = os.time()
    local cached = cache:get(review_id, now)
    if cached then
        cached.ok, cached.review_id, cached.from_cache = true, review_id, true
        return cached
    end

    local function load_comments()
        local page_size = 30
        local max_pages = 20
        local offset = 0
        local synckey = 0
        local all_items, seen = {}, {}
        local total_count = 0
        local stopped_before_page_limit = false

        for page_index = 1, max_pages do
            local ok, data, err = self.client:get_review_comments(review_id, page_size, {
                comments_max_idx = offset,
                synckey = synckey,
            })
            if not ok then
                local kind = comment_error_kind(err)
                return {ok = false, error = kind,
                    message = ReviewComments.message_for(kind)}
            end

            local page = ReviewComments.normalize_response(data, review_id)
            if not page.ok then return page end
            if page_index == 1 then
                total_count = tonumber(page.total_count) or 0
                synckey = tonumber(data.synckey) or synckey
            else
                total_count = math.max(total_count, tonumber(page.total_count) or 0)
                synckey = tonumber(data.synckey) or synckey
            end

            for _, comment in ipairs(page.items or {}) do
                local id = tostring(comment.review_id or "")
                if id ~= "" then
                    -- Only a stable server comment ID is safe for cross-page
                    -- deduplication. Author + content can legitimately repeat.
                    local key = "id:" .. id
                    if not seen[key] then
                        seen[key] = true
                        all_items[#all_items + 1] = comment
                    end
                else
                    -- Without an ID, preserve the server row rather than
                    -- merging distinct comments that happen to share text.
                    all_items[#all_items + 1] = comment
                end
            end

            local raw_count = tonumber(page.raw_count) or #(page.items or {})
            if raw_count <= 0 then
                stopped_before_page_limit = true
                break
            end
            offset = offset + raw_count
            if raw_count < page_size then
                stopped_before_page_limit = true
                break
            end
            if offset >= total_count and total_count > 0 then
                stopped_before_page_limit = true
                break
            end
        end

        local final_total = math.max(total_count, #all_items)
        return {
            ok = true,
            items = all_items,
            total_count = final_total,
            truncated = not stopped_before_page_limit or final_total > #all_items,
            review_id = review_id,
        }
    end

    local connected = false
    pcall(function()
        connected = require("ui/network/manager"):isConnected() == true
    end)
    if not connected then
        return {ok = false, error = "network",
            message = ReviewComments.message_for("network")}
    end

    -- 评论请求放到子进程，避免同步 HTTP 占住 Kindle 阅读器 UI 循环。
    local FFIUtil = require("ffi/util")
    local result_dir = self.settings.data_dir .. "/pickthought-workers"
    U.mkdir(result_dir)
    local result_path = result_dir .. "/comments-" .. tostring(os.time())
        .. "-" .. tostring(math.random(100000, 999999)) .. ".json"
    local child = function()
        local child_ok, value = pcall(function()
            return ReviewComments.cache_get(cache, review_id, load_comments,
                book_id, os.time(), ttl)
        end)
        local encoded_ok, encoded = pcall(Json.encode,
            child_ok and (value or {ok = false}) or {
                ok = false, error = "network",
                message = ReviewComments.message_for("network"),
            })
        if encoded_ok then U.atomic_write(result_path, encoded, true) end
        require("ffi").C._exit(0)
    end
    local fork_ok, pid = pcall(FFIUtil.runInSubProcess, child, false, false)
    if not fork_ok or not pid then
        return load_comments()
    end

    if popup and popup._showCommentNotice then
        popup:_showCommentNotice("正在加载评论…")
    end
    local deadline = os.time() + 180
    local function poll()
        pcall(function() FFIUtil.isSubProcessDone(pid) end)
        if U.file_exists(result_path) then
            local raw = U.read_file(result_path, true)
            os.remove(result_path)
            local ok_decode, result = pcall(Json.decode, raw or "")
            local shown = false
            pcall(function() shown = UIManager:isWidgetShown(popup) == true end)
            if shown and request_is_current() and ok_decode and type(result) == "table" then
                if result.ok then popup:_enterComments(item, result)
                else popup:_showCommentNotice(result.message or ReviewComments.message_for("network")) end
            end
            return
        end
        if not U.file_exists("/proc/" .. tostring(pid)) then
            if request_is_current() and popup._showCommentNotice then
                popup:_showCommentNotice(ReviewComments.message_for("network"))
            end
            return
        end
        if os.time() >= deadline then
            -- 超时后必须终止子进程并结束轮询；原逻辑会每 5 秒永久轮询，
            -- 让弹窗一直停留在"正在加载评论…"。
            if type(FFIUtil.terminateSubProcess) == "function" then
                pcall(FFIUtil.terminateSubProcess, pid)
            end
            os.remove(result_path)
            if request_is_current() and popup._showCommentNotice then
                popup:_showCommentNotice(ReviewComments.message_for("network"))
            end
            return
        end
        UIManager:scheduleIn(0.5, poll)
    end
    UIManager:scheduleIn(0.5, poll)
    return nil
end

function M:_prefetchPickThoughtCommentCounts(popup, book_id)
    if not popup or type(popup.visible_thought_items) ~= "function"
        or type(popup.refresh_comment_counts) ~= "function" then return end
    local shown = false
    pcall(function() shown = UIManager:isWidgetShown(popup) == true end)
    if not shown then return end
    -- This invocation represents the latest settled viewport. Replace any
    -- older queued viewport; if nothing needs fetching below, the old queue
    -- must not run after the active worker finishes.
    self._pickthought_comment_prefetch_queued = nil
    local connected = false
    pcall(function()
        connected = require("ui/network/manager"):isConnected() == true
    end)
    local store = self:_pickThoughtStore()
    local ReviewComments = require("weread.pickthought.review_comments")
    local Json = require("weread.pickthought.json")
    local U = require("weread.pickthought.util")
    local cache = ReviewComments.Cache.new{
        path = store:book_dir(book_id) .. "/review_comments.db",
    }
    local popup_generation = popup._popup_generation
    local function popup_is_current()
        return popup._popup_generation == popup_generation
    end
    local visible = popup:visible_thought_items()
    local pending, pending_generations, changed = {}, {}, false
    for _, item in ipairs(visible) do
        local review_id = tostring(item and item.review_id or "")
        if review_id ~= "" and (tonumber(item.comment_count) or 0) <= 0 then
            local record = cache:get(review_id, os.time())
            if record then
                local count = tonumber(record.total_count) or 0
                if (tonumber(item.comment_count) or 0) ~= count then
                    item.comment_count = count
                    changed = true
                end
            elseif connected then
                pending[#pending + 1] = item
                pending_generations[item] =
                    tonumber(item._comment_count_request_generation) or 0
            end
        end
    end
    if changed then popup:refresh_comment_counts() end
    if #pending == 0 then return end

    -- 每条想法在当前对象生命周期内最多自动重试一次；只对网络类
    -- 临时故障重试，登录失效、限流和无效响应不自动重复请求。
    local function schedule_retry(items, retry_ids)
        local has_retry = false
        for _, item in ipairs(items) do
            local id = tostring(item.review_id or "")
            local generation = pending_generations[item]
            local current_generation =
                tonumber(item._comment_count_request_generation) or 0
            if (not retry_ids or retry_ids[id])
                and current_generation == generation
                and (tonumber(item._comment_count_prefetch_retries) or 0) < 1 then
                item._comment_count_prefetch_retries =
                    (tonumber(item._comment_count_prefetch_retries) or 0) + 1
                has_retry = true
            end
        end
        if not has_retry then return end
        UIManager:scheduleIn(2, function()
            if popup._popup_generation ~= popup_generation then return end
            local still_shown = false
            pcall(function() still_shown = UIManager:isWidgetShown(popup) == true end)
            if still_shown then
                self:_prefetchPickThoughtCommentCounts(popup, book_id)
            end
        end)
    end

    -- 只运行一个预取子进程。若旧任务尚未完成，保存最新视口；
    -- 旧任务结束后会重新扫描该视口，而不是沿用过期的 pending 列表。
    if self._pickthought_comment_prefetch_pid then
        self._pickthought_comment_prefetch_queued = {
            popup = popup,
            book_id = book_id,
            popup_generation = popup_generation,
        }
        return
    end
    local FFIUtil = require("ffi/util")
    local result_dir = self.settings.data_dir .. "/pickthought-workers"
    U.mkdir(result_dir)
    local result_path = result_dir .. "/comment-counts-" .. tostring(os.time())
        .. "-" .. tostring(math.random(100000, 999999)) .. ".json"
    local ids = {}
    for _, item in ipairs(pending) do ids[#ids + 1] = tostring(item.review_id) end
    local child = function()
        local child_ok, results = pcall(function()
            local out = {}
            for index, review_id in ipairs(ids) do
                -- Count prefetch only needs commentsCount. Do not put this
                -- single-page response into the full comment-list cache.
                local ok, data, err = self.client:get_review_comments(review_id, 30)
                local result
                if not ok then
                    local kind = comment_error_kind(err)
                    result = {ok = false, error = kind,
                        message = ReviewComments.message_for(kind)}
                else
                    result = ReviewComments.normalize_response(data, review_id)
                end
                if type(result) == "table" and result.ok then
                    out[#out + 1] = {
                        review_id = review_id,
                        ok = true,
                        total_count = tonumber(result.total_count) or 0,
                    }
                else
                    out[#out + 1] = {
                        review_id = review_id,
                        ok = false,
                        error = type(result) == "table" and result.error or "invalid_response",
                    }
                end
                if index < #ids then
                    local ok_socket, socket = pcall(require, "socket")
                    if ok_socket and socket.sleep then socket.sleep(0.2) end
                end
            end
            return out
        end)
        local encoded_ok, encoded = pcall(Json.encode,
            child_ok and (results or {}) or {})
        if encoded_ok then U.atomic_write(result_path, encoded, true) end
        require("ffi").C._exit(0)
    end
    local fork_ok, pid = pcall(FFIUtil.runInSubProcess, child, false, false)
    if not fork_ok or not pid then
        schedule_retry(pending)
        return
    end
    self._pickthought_comment_prefetch_pid = pid
    local deadline = os.time() + 180

    -- Release this worker exactly once and replay only the newest queued
    -- viewport. Re-scan live popup items so closed/reopened or scrolled views
    -- cannot reuse an obsolete pending list.
    local function finish_prefetch()
        if self._pickthought_comment_prefetch_pid == pid then
            self._pickthought_comment_prefetch_pid = nil
        end
        local queued = self._pickthought_comment_prefetch_queued
        self._pickthought_comment_prefetch_queued = nil
        if queued then
            UIManager:scheduleIn(0.1, function()
                local queued_popup = queued.popup
                if queued_popup
                    and queued_popup._popup_generation == queued.popup_generation then
                    self:_prefetchPickThoughtCommentCounts(
                        queued_popup, queued.book_id)
                end
            end)
        end
    end

    local function poll()
        pcall(function() FFIUtil.isSubProcessDone(pid) end)
        if U.file_exists(result_path) then
            local raw = U.read_file(result_path, true)
            os.remove(result_path)
            local decoded_ok, results = pcall(Json.decode, raw or "")
            local still_shown = false
            pcall(function() still_shown = UIManager:isWidgetShown(popup) == true end)
            if still_shown and popup_is_current()
                and (not decoded_ok or type(results) ~= "table") then
                -- A corrupt/partial worker result is not a successful empty
                -- count response. Allow the same single bounded retry.
                schedule_retry(pending)
            elseif still_shown and popup_is_current()
                and decoded_ok and type(results) == "table" then
                local counts, retry_ids = {}, {}
                for _, row in ipairs(results) do
                    local id = tostring(row.review_id or "")
                    if row.ok == true then
                        counts[id] = tonumber(row.total_count) or 0
                    elseif row.error == "network" then
                        retry_ids[id] = true
                    end
                end
                local updated = false
                for _, item in ipairs(pending) do
                    local count = counts[tostring(item.review_id)]
                    local generation = tonumber(item._comment_count_request_generation) or 0
                    -- A user may have opened this thought while prefetch was
                    -- running. Never let that older count overwrite the
                    -- result of the newer full-comment request.
                    if generation == pending_generations[item]
                        and count ~= nil
                        and (tonumber(item.comment_count) or 0) ~= count then
                        item.comment_count = count
                        updated = true
                    end
                end
                if updated then
                    pcall(function() popup:refresh_comment_counts() end)
                end
                schedule_retry(pending, retry_ids)
            end
            -- The child writes its result immediately before _exit(). Keep the
            -- worker slot occupied until the process is actually gone.
            if U.file_exists("/proc/" .. tostring(pid)) then
                UIManager:scheduleIn(0.1, poll)
                return
            end
            finish_prefetch()
            return
        end
        if not U.file_exists("/proc/" .. tostring(pid)) then
            os.remove(result_path)
            local still_shown = false
            pcall(function() still_shown = UIManager:isWidgetShown(popup) == true end)
            if still_shown and popup_is_current() then
                -- The child exited without producing a result file. Treat
                -- this as one transient worker failure, not as a successful
                -- empty response.
                schedule_retry(pending)
            end
            finish_prefetch()
            return
        end
        if os.time() >= deadline then
            if type(FFIUtil.terminateSubProcess) == "function" then
                pcall(FFIUtil.terminateSubProcess, pid)
            end
            -- Do not start the queued worker while the timed-out child is
            -- still present; terminateSubProcess may need a poll to reap it.
            if U.file_exists("/proc/" .. tostring(pid)) then
                UIManager:scheduleIn(0.5, poll)
                return
            end
            os.remove(result_path)
            finish_prefetch()
            return
        end
        UIManager:scheduleIn(0.5, poll)
    end
    UIManager:scheduleIn(0.5, poll)
end

function M:cleanupPickThought()
    self._pickthought_comment_prefetch_queued = nil
    if self._pickthought_request and self._pickthought_worker then
        self._pickthought_worker:cancel(self._pickthought_request, "document_closed")
    end
    self._pickthought_request = nil
    if self._pickthought_dialog then
        pcall(function() self._pickthought_dialog:close() end)
        self._pickthought_dialog = nil
    end
    local popup = package.loaded["weread.pickthought.thought_popup"]
    if popup then pcall(popup.cleanup) end
    local thoughts = package.loaded["weread.pickthought.thoughts"]
    if thoughts then pcall(thoughts.clear_memory_cache) end
end

return M
