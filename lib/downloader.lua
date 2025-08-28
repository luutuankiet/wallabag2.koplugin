--[[--
@module koplugin.wallabag2.downloader
A simple, safe, serial asynchronous downloader.
--]]

local logger = require("logger")
local co = coroutine
local UIManager = require("ui/uimanager")
local socket = require("socket")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")

local Downloader = {
    download_queue = {},
    wallabag_instance = nil,
    on_progress = nil,
    on_complete = nil,
    is_running = false,
}

function Downloader:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function Downloader:add_to_queue(url, destination)
    table.insert(self.download_queue, { url = url, destination = destination })
end

function Downloader:start()
    if self.is_running then return end
    self.is_running = true
    co.wrap(function()
        self:_download_coroutine()
    end)()
end

function Downloader:_download_coroutine()
    while #self.download_queue > 0 do
        local item = table.remove(self.download_queue, 1)
        local success = self:_download_single(item.url, item.destination)
        if self.on_progress then
            self.on_progress(success)
        end
        -- Yield to the event loop to keep the UI responsive between downloads
        UIManager.ioloop:sleep(0)
    end

    if self.on_complete then
        self.on_complete()
    end
    self.is_running = false
end

function Downloader:_download_single(url, destination)
    local request = {
        url = url,
        sink = ltn12.sink.file(io.open(destination, "w")),
        headers = {
            ["Authorization"] = "Bearer " .. self.wallabag_instance.access_token,
        }
    }
    socketutil:set_timeout(500, 1000)
    local code = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    if code == 200 then
        logger.dbg("Downloader: successfully downloaded ", url)
        return true
    else
        logger.err("Downloader: failed to download ", url, " with code ", code)
        os.remove(destination)
        return false
    end
end

return Downloader