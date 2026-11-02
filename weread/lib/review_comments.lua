-- Read-only review comments for a WeRead thought.
-- Uses the existing WeRead web session and a small per-book SQLite cache.
local logger = require("weread.lib.logger")

local M = {}
local TTL_SECONDS = 15 * 60
local MAX_COMMENTS = 50

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function safe_meta(value)
    local text = trim(value)
    text = text:gsub("[%c]", " ")
    if #text > 256 then text = text:sub(1, 256) end
    return trim(text)
end

local function safe_content(value)
    local text = tostring(value or "")
    text = text:gsub("[%c]", function(char)
        if char == "\n" or char == "\r" or char == "\t" then return char end
        return " "
    end)
    if #text > 8000 then
        text = text:sub(1, 8000)
        while #text > 0 do
            local byte = text:byte(#text)
            if byte >= 128 then
                text = text:sub(1, -2)
            else
                break
            end
        end
    end
    return trim(text)
end

local function comment_from(entry)
    if type(entry) ~= "table" then return nil end
    local user = type(entry.user) == "table" and entry.user or {}
    local author_obj = type(entry.author) == "table" and entry.author or {}
    local author = safe_meta(user.name or user.nick or user.nickname
        or author_obj.name or author_obj.nick
        or (type(entry.author) == "string" and entry.author)
        or entry.name or entry.nickName)
    local content = safe_content(entry.content or entry.text or entry.htmlContent)
    if content == "" then return nil end
    return {
        author = author ~= "" and author or "微信读书用户",
        content = content,
        likes_count = math.max(0, tonumber(entry.likes or entry.likeCount
            or entry.likesCount) or 0),
    }
end

local function comments_array(data)
    if type(data.comments) == "table" then return data.comments end
    if type(data.review) == "table" and type(data.review.comments) == "table" then
        return data.review.comments
    end
    if type(data.data) == "table" then
        if type(data.data.comments) == "table" then return data.data.comments end
        if type(data.data.review) == "table"
            and type(data.data.review.comments) == "table" then
            return data.data.review.comments
        end
    end
    return nil
end

function M.normalize_response(data)
    if type(data) ~= "table" then
        return { ok = false, message = "微信读书返回了无效的评论数据。" }
    end
    local code = tonumber(data.errCode)
    if code and code ~= 0 then
        return {
            ok = false,
            message = tostring(data.errMsg or "获取评论失败。"),
        }
    end

    local raw = comments_array(data)
    if not raw then
        local nested_review = type(data.data) == "table" and data.data.review or nil
        if type(data.review) == "table" or type(nested_review) == "table" then
            raw = {}
        else
            return { ok = false, message = "无法识别微信读书的评论响应。" }
        end
    end

    local items = {}
    for _, entry in ipairs(raw) do
        local item = comment_from(entry)
        if item then items[#items + 1] = item end
        if #items >= MAX_COMMENTS then break end
    end
    local total = tonumber(data.commentsCount or data.total or data.totalCount)
    if not total and type(data.review) == "table" then
        total = tonumber(data.review.commentsCount)
    end
    if not total and type(data.data) == "table" then
        total = tonumber(data.data.commentsCount)
            or (type(data.data.review) == "table"
                and tonumber(data.data.review.commentsCount))
    end
    return {
        ok = true,
        items = items,
        total_count = math.max(#items, total or #items),
    }
end

local Cache = {}
Cache.__index = Cache

local function open_db(path)
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok or not SQ3 then return nil end
    local opened, db = pcall(SQ3.open, path)
    if not opened or not db then return nil end
    pcall(function() db:exec("PRAGMA journal_mode=WAL") end)
    pcall(function() db:exec("PRAGMA synchronous=NORMAL") end)
    local schema_ok = pcall(function()
        db:exec([[CREATE TABLE IF NOT EXISTS review_comment_cache (
            review_id TEXT PRIMARY KEY,
            total_count INTEGER NOT NULL,
            payload_json TEXT NOT NULL,
            fetched_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL
        )]])
    end)
    if not schema_ok then
        pcall(function() db:close() end)
        return nil
    end
    return db
end

function Cache.new(path, client)
    return setmetatable({ path = tostring(path or ""), client = client }, Cache)
end

function Cache:get(review_id, now)
    if self.path == "" or trim(review_id) == "" then return nil end
    now = tonumber(now) or os.time()
    local db = open_db(self.path)
    if not db then return nil end
    local record
    local ok, err = pcall(function()
        local stmt = db:prepare([[SELECT total_count, payload_json, fetched_at
            FROM review_comment_cache WHERE review_id=? AND expires_at>?]])
        stmt:reset():bind(tostring(review_id), now)
        local row = stmt:step()
        if type(row) == "table" then
            local decoded = self.client:json_decode(tostring(row[2] or ""))
            if type(decoded) == "table" then
                record = {
                    ok = true,
                    items = decoded,
                    total_count = tonumber(row[1]) or #decoded,
                    fetched_at = tonumber(row[3]) or now,
                    from_cache = true,
                }
            end
        end
        stmt:close()
        local purge = db:prepare("DELETE FROM review_comment_cache WHERE expires_at<=?")
        purge:reset():bind(now):step()
        purge:close()
    end)
    pcall(function() db:close() end)
    if not ok then logger.warn("review comment cache read failed:", tostring(err)) end
    return record
end

function Cache:put(review_id, result, now)
    if self.path == "" or trim(review_id) == "" or type(result) ~= "table"
        or result.ok ~= true or type(result.items) ~= "table" then
        return false
    end
    now = tonumber(now) or os.time()
    local db = open_db(self.path)
    if not db then return false end
    local ok, err = pcall(function()
        local payload = self.client:json_encode(result.items)
        local stmt = db:prepare([[INSERT INTO review_comment_cache
            (review_id, total_count, payload_json, fetched_at, expires_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(review_id) DO UPDATE SET
                total_count=excluded.total_count,
                payload_json=excluded.payload_json,
                fetched_at=excluded.fetched_at,
                expires_at=excluded.expires_at]])
        stmt:reset():bind(tostring(review_id),
            tonumber(result.total_count) or #result.items, payload, now, now + TTL_SECONDS):step()
        stmt:close()
        db:exec([[DELETE FROM review_comment_cache WHERE review_id IN (
            SELECT review_id FROM review_comment_cache
            ORDER BY fetched_at DESC LIMIT -1 OFFSET 128)]])
    end)
    pcall(function() db:close() end)
    if not ok then logger.warn("review comment cache write failed:", tostring(err)) end
    return ok == true
end

M.Cache = Cache
M.TTL_SECONDS = TTL_SECONDS
M.MAX_COMMENTS = MAX_COMMENTS
return M
