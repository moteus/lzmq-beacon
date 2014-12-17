local function zbeacon_thread(pipe, host_or_port, port)
local host, interface

local ID = string.format("%.8X", pipe:fd())

local verbose  = false

local function log(...)
  if verbose then
    print("[" .. ID .. "] " .. string.format(...))
  end
end

if port then host = host_or_port else host, port = "*", host_or_port end

local function prequire(mod)
  local ok, m = pcall(require, mod)
  if not ok then return nil, m end
  return m, mod
end

local zlp    = require "lzmq.loop"
local socket = require "socket"

local get_address do
  local uv  = prequire "lluv"
  local bit = prequire "bit32" or prequire "bit"

  local MASKS = {[ 0 ] = 0;[128] = 1;[192] = 2;[224] = 3;
    [240] = 4;[248] = 5;[252] = 6;[254] = 7;[255] = 8}
  local bcast if bit then
    bcast = function(net, mask)
      if net == "*" or net == "0.0.0.0" then
        return "255.255.255.255"
      end

      local n = tonumber(mask:match("^%d+%.%d+%.%d+%.(%d+)$"))
      local a = tonumber(net:match("^%d+%.%d+%.%d+%.(%d+)$"))
      n = assert(MASKS[n], "Invalid subnet mask:" .. mask)
      local m = 8 - n
      local d = 2^m

      local bcast = bit.bor(a, d-1)
      local gate  = bit.band(a, bit.bnot(d-1))

      return
      (net:gsub("^(%d+%.%d+%.%d+%.)(%d+)$", "%1" .. bcast)),
      (net:gsub("^(%d+%.%d+%.%d+%.)(%d+)$", "%1" .. gate))
    end
  else
    bcast = function() return "255.255.255.255" end
  end

  local get_address_
  if uv then
    get_address_ = function (name)
      local function check_int(int)
        if name                 then return int.name == name end
        if int.internal         then return false end
        if int.family ~= "inet" then return false end
        return true
      end

      if verbose then
        log("I: enum interface:")
        for _, int in ipairs(uv.interface_addresses())do
          log("-- interface %s %s/%s (%s) %s - %s",
            int.name, int.address, int.netmask, int.family,
            int.internal and "internal" or "external",
            check_int(int) and "match" or "not match"
          )
        end
      end

      if name == "*" then return "*", bcast("*") end

      for _, int in ipairs(uv.interface_addresses())do
        if check_int(int) then
          return int.address, bcast(int.address, int.netmask)
        end
      end
    end
  elseif socket.dns.local_addresses then
    get_address_ = function()
      local a = socket.dns.local_addresses()[1] or "*"
      return a, "255.255.255.255"
    end
  else
    get_address_ = function()
      return "*", "255.255.255.255"
    end
  end

  get_address = function() return get_address_(interface) end
end

local Udp = {} do
Udp.__index = Udp

function Udp:new(host, port, broadcast)
  assert(type(host) == 'string')
  assert(type(port) == 'number')
  broadcast = broadcast or "255.255.255.255"

  local cnn, err = socket.udp()
  if not cnn then return nil, err end

  assert(1 == cnn:setoption('broadcast', true))
  assert(1 == cnn:setoption('reuseaddr', true))
  assert(1 == cnn:setoption('reuseport', true))

  local ok, err = cnn:setsockname(host, port)
  if not ok then
    cnn:close()
    return nil, err
  end

  local o = setmetatable({}, self)
  o._private = {
    broadcast = broadcast;
    host      = host;
    port      = port;
    cnn       = cnn;
  }

  return o
end

function Udp:destroy()
  if self._private.cnn then
    self._private.cnn:close()
    self._private.cnn = nil
  end
end

Udp.__gc = Udp.destroy

function Udp:host()
   return self._private.cnn:getsockname() or self._private.host
end

function Udp:port()
   return self._private.port
end

function Udp:bcast()
   return self._private.broadcast
end

function Udp:send(buffer)
  return self._private.cnn:sendto(buffer, self._private.broadcast, self._private.port)
end

function Udp:recv()
  local buffer, host, port = self._private.cnn:receivefrom()
  if not buffer then return nil, host, port end
  
  self._private.from = host
  return buffer, host, port
end

function Udp:fd()
  return self._private.cnn:getfd()
end

end

local loop     = zlp.new()
local socks    = {}
local noecho   = false
local interval
local transmit
local refresh

pipe:set_linger(100)

local api = {} do

local OK = "OK"

function api.interval(skt, val)
  val = tonumber(val)
  if val then
    interval:set_interval(val)
  end
  return OK
end

function api.refresh(skt, val)
  if val then
    host, interface = val
  end
  refresh(skt)
  return OK
end

function api.noecho(skt)
  noecho = true
  return OK
end

function api.publish(skt, val)
  assert(val)
  log("I: publish %s", val)
  transmit = val
  return OK
end

function api.silence(skt)
  transmit = nil
  -- todo remove time event
  return OK
end

function api.subscribe(skt, val)
  log("I: subscribe %s", val)
  filter = val
  return OK
end

function api.unsubscribe(skt)
  log("I: unsubscribe")
  filter = nil
  return OK
end

function api.terminate(skt)
  loop:interrupt()
  return OK
end

function api.verbose(skt, val)
  verbose = val ~= "0"
  return OK
end

function api._dispatch(skt, cmd, ...)
  if not cmd then return nil, ... end
  local handler = api[cmd:lower()]
  if handler then return handler(skt, ...) end
  log("E: unexpected API command '%s'", cmd)
  return OK
end

end

local function on_beacon(msg, host, port)
  if not filter then
    log("I: filterout `%s` by any filter", msg)
    return true
  end

  if filter ~= msg:sub(1, #filter) then
    log("I: filterout `%s` by `%s`", msg, filter)
    return true
  end

  if noecho and (transmit == msg) then
    return true
  end

  return pipe:sendx(host, msg)
end

refresh = function()

  if host then
    if not host:find("^%d+%.%d+%.%d+%.%d+$") then
      interface, host = host
    end
  end

  for _, sock in ipairs(socks) do
    loop:remove_socket(sock:fd())
    sock:destroy()
  end
  socks = {}

  local host, bcast = assert(get_address())

  local addresses = {{ip=host, bcast=bcast}}

  local sock_address = {}

  for _, host in ipairs(addresses) do
    local sock, err = Udp:new(host.ip, port, host.bcast)
    if not sock then
      log("E: can not bind on %s. Error: %s", host, tostring(err))
    else
      local ok, err = loop:add_socket(sock:fd(), function()
        local msg, host, port = sock:recv()
        if not msg then
          log("E: recv error %s from %s:%s", tostring(host))
        else
          log("I: recv %s from %s:%s", msg, tostring(host), tostring(port))
          local ok, err = on_beacon(msg, tostring(host), tostring(port))
          if not ok then
            loop:interrup()
          end
        end
      end)
      if ok then
        log("I: bind on %s:%s (%s)", tostring(sock:host()), tostring(sock:port()), tostring(sock:bcast()))
        socks[#socks + 1] = sock
        sock_address[#sock_address + 1] = sock:host()
      else
        log("E: bind on %s:%s fail!", tostring(sock:host()), tostring(sock:port()))
        sock:destroy()
      end
    end
  end

  if #sock_address == 0 then
    sock_address[1] = '@'
  end

  local unpack = unpack or table.unpack
  pipe:sendx(unpack(sock_address))
end

loop:add_socket(pipe, function(skt)
  local ok, err = api._dispatch(skt, skt:recvx())
  if not ok then
    log("E: pipe poll error: %s", tostring(err))
    return loop:interrupt()
  end
end)

interval = loop:add_interval(5000, function()
  if transmit then
    for _, sock in ipairs(socks) do
      local ok, err = sock:send(transmit)
    end
  end
end)

log("I: Started")

loop:start()

for _, sock in ipairs(socks) do
  loop:remove_socket(sock:fd())
  sock:destroy()
end

loop:destroy()

end

local zth = require "lzmq.threads"

local zbeacon = {} do
zbeacon.__index = zbeacon

function zbeacon:new(...)
  local ct = type((...))
  local has_ctx = not ((ct == "string") or (ct == "number"))
  local actor
  if has_ctx then
    actor = zth.actor((...), zbeacon_thread, select(2, ...))
  else
    actor = zth.xactor(zbeacon_thread, ...)
  end

  local ok, err = actor:start()
  if not ok then return nil, err end

  local o = setmetatable({}, self)
  o._private = {
    actor     = actor;
  }

  local ok, err = o:refresh()
  if not ok then
    o:destroy()
    return nil, err
  end

  return o
end

function zbeacon:verbose(val)
  local actor = self._private.actor
  actor:sendx("VERBOSE", val and "1" or "0")
  return self
end

function zbeacon:refresh(val)
  local actor = self._private.actor
  if val then actor:sendx("REFRESH", val)
  else actor:sendx("REFRESH") end

  local addresses = {actor:recvx()}
  if not addresses[1] then
   return nil, addresses[2]
  end

  if addresses[1] == '@' then
    assert(addresses[2] == nil)
    addresses[1] = nil;
  end

  self._private.addresses = addresses
  return self
end

function zbeacon:noecho()
  local actor = self._private.actor
  actor:sendx("NOECHO")
  return self
end

function zbeacon:silence()
  local actor = self._private.actor
  actor:sendx("SILENCE")
  return self
end

function zbeacon:interval(val)
  local actor = self._private.actor
  assert(type(val) == "number")
  actor:sendx("INTERVAL", tostring(val))
  return self
end

function zbeacon:publish(val)
  local actor = self._private.actor
  assert(type(val) == "string")
  actor:sendx("PUBLISH", val)
  return self
end

function zbeacon:subscribe(val)
  local actor = self._private.actor
  val = val or ""
  assert(type(val) == "string")
  actor:sendx("SUBSCRIBE", val)
  return self
end

function zbeacon:unsubscribe()
  local actor = self._private.actor
  actor:sendx("UNSUBSCRIBE")
  return self
end

function zbeacon:destroy()
  local actor = self._private.actor
  if actor then
    actor:sendx("TERMINATE")
    actor:join()
    self._private.actor = nil
  end
end

function zbeacon:socket()
  return self._private.actor:socket()
end

function zbeacon:handle()
  return self._private.actor:socket():handle()
end

function zbeacon:recv()
  return self._private.actor:recvx()
end

function zbeacon:host()
  local addresses = self._private.addresses
  return addresses[1], not not addresses[2]
end

end

local function zbeacon_test(verbose)
  local zmq = require "lzmq"
  local zpl = require "lzmq.poller"
  local ztm = require "lzmq.timer"

  local printf = function(...) return io.write(string.format(...)) end

  printf (" * zbeacon: ");

  --  @selftest
  --  Basic test: create a service and announce it
  local ctx = zth.context()

  --  Create a service socket and bind to an ephemeral port
  local service  = ctx:socket(zmq.PUB)
  local port_nbr = assert(service:bind_to_random_port("tcp://127.0.0.1"))

  -- Create beacon to broadcast our service
  local announcement = string.format("%.4X", port_nbr)
  local service_beacon = assert(zbeacon:new(9999))

  service_beacon:interval(100)
  service_beacon:publish(announcement)

  -- Create beacon to lookup service
  local client_beacon = assert(zbeacon:new(9999))
  client_beacon:subscribe()

  -- Wait for at most 1/2 second if there's no broadcast networking
  client_beacon:socket():set_rcvtimeo(500)

  local ipaddress, content = assert(client_beacon:recv())
  assert(announcement == content)

  client_beacon:destroy()
  service_beacon:destroy()

  local node1 = zbeacon:new(5670)
  local node2 = zbeacon:new(5670)
  local node3 = zbeacon:new(5670)

  assert (node1:host())
  assert (node2:host())
  assert (node3:host())

  node1:interval(250)
  node2:interval(250)
  node3:interval(250)

  node1:noecho()

  node1:publish( "NODE/1"  )
  node2:publish( "NODE/2"  )
  node3:publish( "GARBAGE" )

  node1:subscribe("NODE")

  local poller = zpl.new(3)

  poller:add(node1, zmq.POLLIN, function(s)
    assert(node1 == s)
    local ipaddress, beacon = assert(node1:recv())
    assert(beacon == "NODE/2")
  end)

  poller:add(node2, zmq.POLLIN, function(s)
    assert(false)
  end)

  poller:add(node3, zmq.POLLIN, function(s)
    assert(false)
  end)

  local timer = ztm.monotonic(1000):start()
  while timer:rest() > 0 do
    assert(poller:poll(100))
  end

  node1:destroy()
  node2:destroy()
  node3:destroy()

  printf("OK\n")
  return true
end

return {
  new        = function(...) return zbeacon:new(...) end;
  self_check = zbeacon_test;
}
