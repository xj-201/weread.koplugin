-- WeRead Client 适配层：PickThought 不创建第二套 HTTP、Cookie 或登录会话。
-- 所有请求都通过主插件 self.client，确保沿用 WeRead 已保存的登录态。
local Content = require("weread.lib.content")
local WebFetch = require("weread.lib.pickthought.web_fetch")

local Adapter = {}
Adapter.__index = Adapter

local Api = {}
Api.__index = Api

function Api:new(plugin)
    return setmetatable({ plugin = plugin }, self)
end

local function book_for(plugin, book_id)
    local books = plugin.settings:get("books", {})
    local original = books[tostring(book_id)] or books[book_id]
    if type(original) ~= "table" then
        local path = plugin.ui and plugin.ui.document and plugin.ui.document.file
        local entry = path and plugin.external_annotations_db
            and plugin.external_annotations_db:getDocument(path)
        local binding = entry and entry.binding
        if type(binding) == "table"
            and tostring(binding.book_id or "") == tostring(book_id) then
            original = binding
        end
    end
    if type(original) ~= "table" then
        error("WeRead 书籍不存在或尚未绑定: " .. tostring(book_id))
    end
    -- ReaderState 会写入 psvts/pclts/token 等单次请求状态；使用浅拷贝，
    -- 避免把临时 reader token 写回插件持久化的书籍条目。
    local book = {}
    for key, value in pairs(original) do book[key] = value end
    book.book_id = tostring(book_id)
    book.bookId = tostring(book_id)
    return book
end

function Api:chapters(book_id)
    local plugin = self.plugin
    local book = book_for(plugin, book_id)
    Content.ensure_reader_state(plugin.client, book)
    local chapters = Content.fetch_catalog(plugin.client, book)
    if type(chapters) ~= "table" or #chapters == 0 then
        error("微信读书没有返回可用章节列表")
    end
    -- WeRead Content.fetch_catalog 返回官方字段 chapterUid；
    -- PickThought Sync.run 的章节契约使用 uid。这里做显式适配，
    -- 不修改 WeRead 原始目录对象，也不让同步层拿到 nil 章节 ID。
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
    if #normalized == 0 then
        error("微信读书章节目录缺少 chapterUid")
    end
    return normalized
end

function Api:underlines(book_id, chapter_uid)
    local ok, result, err = self.plugin.client:get_chapter_underlines(book_id, chapter_uid)
    if not ok then error(err or "获取章节划线失败") end
    if type(result) ~= "table" then error("章节划线响应格式无效") end
    return result
end

function Api:review_batches(ranges, count)
    -- Client 的批次构造器与 PickThought WebFetch 的批次协议一致：
    -- 每批最多 30 个 range，每个 range 请求 count=30。
    local client = self.plugin.client
    local batches = client:build_chapter_review_batches(ranges or {})
    local requested = tonumber(count) or 30
    if requested ~= 30 then
        for _, batch in ipairs(batches) do
            for _, item in ipairs(batch) do item.count = requested end
        end
    end
    return batches
end

function Api:readreviews(book_id, chapter_uid, batch)
    local ok, result, err = self.plugin.client:get_chapter_reviews_batch(
        book_id, chapter_uid, batch)
    if not ok then error(err or "获取章节想法失败") end
    if type(result) ~= "table" or type(result.reviews) ~= "table" then
        error("章节想法响应格式无效")
    end
    return result
end

function Adapter:new(plugin)
    assert(plugin and plugin.client and plugin.settings, "WeRead plugin client/settings required")
    local api = Api:new(plugin)
    return setmetatable({
        plugin = plugin,
        api = api,
        fetcher = WebFetch:new(api),
    }, self)
end

function Adapter:book_dir(book_id)
    local book = book_for(self.plugin, book_id)
    return Content.book_resolved_dir(self.plugin.settings, book_id, book)
end

function Adapter:fetch_chapter(book_id, chapter_uid, progress)
    return self.fetcher:fetch_chapter(book_id, chapter_uid, progress)
end

return Adapter
