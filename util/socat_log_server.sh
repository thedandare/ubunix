#!/bin/sh
# stdout: Tells socat to pass all incoming data directly to the standard output of your terminal instead of sending it back to the client.
#   | tee -a traffic.log: Pipes that terminal output into the tee utility. This utility prints the data to your screen and appends (-a) it to a file named traffic.log at the same time.
# socat TCP4-LISTEN:1234,bind=100.100.1.2,fork stdout | tee -a traffic.log

# Alternative: Pure Socat Logging (No Pipe)
# socat TCP4-LISTEN:1234,bind=100.100.1.2,fork SYSTEM:'tee -a traffic.log'


# To make your logs more useful by adding connection details and timestamps directly into the terminal output, add the -v (verbose) flag and the -d -d (debug) flags:
tmux new -d -s socat100  "socat -d -d -v TCP4-LISTEN:100,bind=100.100.1.2,fork stdout | tee -a /var/log/socat100.log"

