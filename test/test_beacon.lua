local HAS_RUNNER = not not lunit
local lunit      = require "lunit"
local TEST_CASE  = assert(lunit.TEST_CASE)
local skip       = lunit.skip or function() end

local zmq = require "lzmq"
local zpl = require "lzmq.poller"
local ztm = require "lzmq.timer"
local zbn = require "lzmq.beacon"

local BEACON_PORT = 9999

local _ENV = TEST_CASE "lzmq.beacon" do

local ctx, node1, node2, node3

function setup()
  ctx  = assert(zmq.context())
end

function teardown()
  if node1 then node1:destroy() end
  if node2 then node2:destroy() end
  if node3 then node3:destroy() end
  if ctx   then ctx:destroy()   end

  ctx, node1, node2, node3 = nil
end

function test_basic()
  local port_nbr     = 0x1234
  local announcement = string.format("%.4X", port_nbr)

  -- Create beacon to broadcast our service
  node1 = assert(zbn.new(ctx, BEACON_PORT))
  assert_equal(node1, node1:interval(100))
  assert_equal(node1, node1:publish(announcement))

  -- Create beacon to lookup service
  node2 = assert(zbn.new(ctx, BEACON_PORT))
  assert_equal(node2, node2:subscribe())

  -- Wait for at most 1/2 second if there's no broadcast networking
  node2:socket():set_rcvtimeo(500)

  local ipaddress, content = assert_string(node2:recv())
  assert_equal(announcement, content)
end

function test_filter()
  node1 = assert(zbn.new(ctx, BEACON_PORT))
  node2 = assert(zbn.new(ctx, BEACON_PORT))
  node3 = assert(zbn.new(ctx, BEACON_PORT))

  assert_string(node1:host())
  assert_string(node2:host())
  assert_string(node3:host())

  assert_equal(node1, node1:interval(250))
  assert_equal(node2, node2:interval(250))
  assert_equal(node3, node3:interval(250))

  assert_equal(node1, node1:noecho())

  assert_equal(node1, node1:publish( "NODE/1"  ))
  assert_equal(node2, node2:publish( "NODE/2"  ))
  assert_equal(node3, node3:publish( "GARBAGE" ))

  assert_equal(node1, node1:subscribe("NODE"))

  local poller = assert(zpl.new(3))
  local flag

  poller:add(node1, zmq.POLLIN, function(s)
    assert_equal(node1, s)
    local ipaddress, beacon = assert(node1:recv())
    assert_equal("NODE/2", beacon)
    flag = true
  end)

  poller:add(node2, zmq.POLLIN, function(s)
    assert(false)
  end)

  poller:add(node3, zmq.POLLIN, function(s)
    assert(false)
  end)

  local timer = ztm.monotonic(1000):start()
  while timer:rest() > 0 do
    assert_number(poller:poll(100))
  end
  assert_true(flag)
end

end

local _ENV = TEST_CASE "lzmq.beacon.global_context" do
-- We use global zmq context

local node1, node2

function setup()
end

function teardown()
  if node1 then node1:destroy() end
  if node2 then node2:destroy() end

  node1, node2, node3 = nil
end

function test_basic()
  local port_nbr     = 0x1234
  local announcement = string.format("%.4X", port_nbr)

  -- Create beacon to broadcast our service
  node1 = assert(zbn.new(BEACON_PORT))
  assert_equal(node1, node1:interval(100))
  assert_equal(node1, node1:publish(announcement))

  -- Create beacon to lookup service
  node2 = assert(zbn.new(BEACON_PORT))
  assert_equal(node2, node2:subscribe())

  -- Wait for at most 1/2 second if there's no broadcast networking
  node2:socket():set_rcvtimeo(500)

  local ipaddress, content = assert_string(node2:recv())
  assert_equal(announcement, content)
end

end

if not HAS_RUNNER then lunit.run() end
