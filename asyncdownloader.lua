--[[--
@module koplugin.wallabag2.asyncdownloader
--]]

local logger = require("logger")

local ioloop = require("common.turbo.ioloop")
local socket = require("common.turbo.socket_ffi")
local coctx = require("common.turbo.coctx")
local co = coroutine

local AsyncDownloader = {
    max_concurrent_downloads = 5, -- Adjust as needed
    download_queue = {},
    active_downloads = 0,
    on_complete = nil,
}

function AsyncDownloader:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    self.ioloop = ioloop.instance()
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

    local url_parts = self:_parse_url(url)
    if not url_parts then
        logger.err("AsyncDownloader: invalid url: ", url)
        self:_download_finished()
        return
    end

    local ip = self:_resolve_host(url_parts.host)
    if not ip then
        logger.err("AsyncDownloader: could not resolve host: ", url_parts.host)
        self:_download_finished()
        return
    end

    local fd, err = socket.new_nonblock_socket()
    if fd == -1 then
        logger.err("AsyncDownloader: could not create socket: ", err)
        self:_download_finished()
        return
    end

    local ok, err = self:_connect(fd, ip, url_parts.port)
    if not ok then
        logger.err("AsyncDownloader: could not connect: ", err)
        ffi.C.close(fd)
        self:_download_finished()
        return
    end

    local request = self:_build_request(url_parts)
    ok, err = self:_send(fd, request)
    if not ok then
        logger.err("AsyncDownloader: could not send request: ", err)
        ffi.C.close(fd)
        self:_download_finished()
        return
    end

    local file, err = io.open(destination, "w")
    if not file then
        logger.err("AsyncDownloader: could not open destination file: ", err)
        ffi.C.close(fd)
        self:_download_finished()
        return
    end

    ok, err = self:_receive(fd, file)
    if not ok then
        logger.err("AsyncDownloader: could not receive response: ", err)
    end

    file:close()
    ffi.C.close(fd)
    self:_download_finished()
end

function AsyncDownloader:_download_finished()
    self.active_downloads = self.active_downloads - 1
    if self.on_complete then
        self.on_complete()
    end
    self:start()
end

function AsyncDownloader:_parse_url(url)
    local _, _, protocol, host, port, path = string.find(url, "^(https?)://([^:/]+):?([0-9]*)(/.*)$")
    if not protocol then
        return nil
    end
    port = port == "" and (protocol == "https" and 443 or 80) or tonumber(port)
    path = path or "/"
    return {
        protocol = protocol,
        host = host,
        port = port,
        path = path,
    }
end

function AsyncDownloader:_resolve_host(host)
    local res = socket.resolv_hostname(host)
    if res == -1 or #res.in_addr == 0 then
        return nil
    end
    return ffi.string(ffi.C.inet_ntoa(res.in_addr))
end

function AsyncDownloader:_connect(fd, ip, port)
    local sockaddr = ffi.new("struct sockaddr_in")
    sockaddr.sin_family = socket.AF_INET
    sockaddr.sin_port = ffi.C.htons(port)
    sockaddr.sin_addr.s_addr = ffi.C.inet_addr(ip)

    local rc = ffi.C.connect(fd, ffi.cast("struct sockaddr *", sockaddr), ffi.sizeof(sockaddr))
    if rc == 0 then
        return true
    end

    local errno = ffi.errno()
    if errno ~= socket.EINPROGRESS then
        return false, socket.strerror(errno)
    end

    local ctx = coctx.CoroutineContext()
    self.ioloop:add_handler(fd, ioloop.WRITE, function()
        self.ioloop:remove_handler(fd)
        ctx:set_coroutine_arguments(true)
        self.ioloop:finalize_coroutine_context(ctx)
    end)
    return co.yield(ctx)
end

function AsyncDownloader:_send(fd, data)
    local total_sent = 0
    while total_sent < #data do
        local sent = ffi.C.send(fd, data:sub(total_sent + 1), #data - total_sent, 0)
        if sent == -1 then
            local errno = ffi.errno()
            if errno ~= socket.EAGAIN and errno ~= socket.EWOULDBLOCK then
                return false, socket.strerror(errno)
            end
            local ctx = coctx.CoroutineContext()
            self.ioloop:add_handler(fd, ioloop.WRITE, function()
                self.ioloop:remove_handler(fd)
                ctx:set_coroutine_arguments(true)
                self.ioloop:finalize_coroutine_context(ctx)
            end)
            co.yield(ctx)
        else
            total_sent = total_sent + sent
        end
    end
    return true
end

function AsyncDownloader:_receive(fd, file)
    local buffer = ffi.new("char")
    while true do
        local bytes_received = ffi.C.recv(fd, buffer, 4096, 0)
        if bytes_received == 0 then
            -- Connection closed
            return true
        elseif bytes_received == -1 then
            local errno = ffi.errno()
            if errno ~= socket.EAGAIN and errno ~= socket.EWOULDBLOCK then
                return false, socket.strerror(errno)
            end
            local ctx = coctx.CoroutineContext()
            self.ioloop:add_handler(fd, ioloop.READ, function()
                self.ioloop:remove_handler(fd)
                ctx:set_coroutine_arguments(true)
                self.ioloop:finalize_coroutine_context(ctx)
            end)
            co.yield(ctx)
        else
            file:write(ffi.string(buffer, bytes_received))
        end
    end
end

function AsyncDownloader:_build_request(url_parts)
    local request = "GET " .. url_parts.path .. " HTTP/1.1\r\n"
    request = request .. "Host: " .. url_parts.host .. "\r\n"
    request = request .. "Connection: close\r\n"
    request = request .. "\r\n"
    return request
end

return AsyncDownloader