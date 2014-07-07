lzmq-beacon
===========
[![Build Status](https://travis-ci.org/moteus/lzmq-beacon.svg?branch=master)](https://travis-ci.org/moteus/lzmq-beacon)
[![Licence](http://img.shields.io/badge/Licence-MIT-brightgreen.svg)](LICENSE)

## Usage
```Lua
--
-- service node
local service_beacon = zbeacon.new(9999)
  :interval(100)
  :publish(announcement)
```
```Lua
--
-- client node
local client_beacon = zbeacon.new(9999):subscribe()

-- poll `client_beacon` to receave IP and announcement
local ipaddress, announcement = client_beacon:recv()
```

##Limitation

 * LuaSocket do not provide way to get its own IP or enumerate interfaces.
   So you can provide IP address as first argument in zbeacon constructor.
   e.g. `beacon = zbeacon.new('192.168.1.10', 9999)`
 * zbeacon always use broadcast address `255.255.255.255`
