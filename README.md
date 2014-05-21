mqtt-exec
=========

A simple mqtt subscriber that executes a command on mqtt messages

Build requriements
------------------
- C compiler + make
- libmosquitto


Example usage
-------------
This example shows how to get messages as desktop notifications:

`mqtt-exec -h $mqtt_host -t $topic -v -- /usr/bin/notify-send -t 3000  -i network-server`
