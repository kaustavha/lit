exports.name = "creationix/coro-channel"
exports.version = "1.0.0"

local uv = require('uv')

-- Given a raw uv_stream_t userdara, return coro-friendly read/write functions.
-- Given a raw uv_stream_t userdara, return coro-friendly read/write functions.
function exports.wrapStream(socket)
  local paused = true
  local queue = {}
  local waiting
  local reading = true
  local writing = true

  local onRead

  local function read()
    if #queue > 0 then
      return unpack(table.remove(queue, 1))
    end
    if paused then
      paused = false
      uv.read_start(socket, onRead)
    end
    waiting = coroutine.running()
    return coroutine.yield()
  end

  function onRead(err, chunk)
    p("IN", {err=err,chunk=chunk})
    local data = err and {nil, err} or {chunk}
    if waiting then
      local thread = waiting
      waiting = nil
      assert(coroutine.resume(thread, unpack(data)))
    else
      queue[#queue + 1] = data
      if not paused then
        paused = true
        uv.read_stop(socket)
      end
    end
    if not chunk then
      reading = false
      -- Close the whole socket if the writing side is also closed already.
      if not writing and not uv.is_closing(socket) then
        uv.close(socket)
      end
    end
  end

  local function write(chunk)
    p("OUT", {chunk=chunk})
    if chunk == nil then
      -- Shutdown our side of the socket
      writing = false
      if not uv.is_closing(socket) then
        uv.shutdown(socket)
        -- Close if we're done reading too
        if not reading and not uv.is_closing(socket) then
          uv.close(socket)
        end
      end
    else
      -- TODO: add backpressure by pausing and resuming coroutine
      -- when write buffer is full.
      uv.write(socket, chunk)
    end
  end

  return read, write
end


function exports.chain(...)
  local args = {...}
  local nargs = select("#", ...)
  return function (read, write)
    local threads = {} -- coroutine thread for each item
    local waiting = {} -- flag when waiting to pull from upstream
    local boxes = {}   -- storage when waiting to write to downstream
    for i = 1, nargs do
      threads[i] = coroutine.create(args[i])
      waiting[i] = false
      local r, w
      if i == 1 then
        r = read
      else
        function r()
          local j = i - 1
          if boxes[j] then
            local data = boxes[j]
            boxes[j] = nil
            assert(coroutine.resume(threads[j]))
            return unpack(data)
          else
            waiting[i] = true
            return coroutine.yield()
          end
        end
      end
      if i == nargs then
        w = write
      else
        function w(...)
          local j = i + 1
          if waiting[j] then
            waiting[j] = false
            assert(coroutine.resume(threads[j], ...))
          else
            boxes[i] = {...}
            coroutine.yield()
          end
        end
      end
      assert(coroutine.resume(threads[i], r, w))
    end
  end
end
