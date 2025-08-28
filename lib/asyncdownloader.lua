--[[--
@module koplugin.wallabag2.asyncdownloader
--]]

local logger = require("logger")
local co = coroutine

local AsyncDownloader = {
    max_concurrent_downloads = 10, -- Adjust as needed
    download_queue = {},
    active_downloads = 0,
    on_complete = nil,
    wallabag_instance = nil,
}

function AsyncDownloader:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function AsyncDownloader:add_to_queue(url, destination)
    logger.dbg("AsyncDownloader: adding to queue: ", url)
    table.insert(self.download_queue, { url = url, destination = destination })
end

function AsyncDownloader:start()
    logger.dbg("AsyncDownloader: starting downloads")
    while self.active_downloads < self.max_concurrent_downloads and #self.download_queue > 0 do
        local item = table.remove(self.download_queue, 1)
        self:download(item.url, item.destination)
    end
end

function AsyncDownloader:download(url, destination)
    self.active_downloads = self.active_downloads + 1
    co.wrap(function()
        self:_download_coroutine(url, destination)
    end)()
end

function AsyncDownloader:_download_coroutine(url, destination)
    logger.dbg("AsyncDownloader: downloading ", url)

    local success = self.wallabag_instance:callAPI("GET", url, nil, "", destination, true, true)

    if not success then
        logger.err("AsyncDownloader: download failed for", url)
    end

    self:_download_finished()
end

function AsyncDownloader:_download_finished()
    self.active_downloads = self.active_downloads - 1
    if self.on_complete then
        self.on_complete()
    end
    self:start()
end

return AsyncDownloader