connect
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch { stop }
mrd -force 0x00000000 12
exit
