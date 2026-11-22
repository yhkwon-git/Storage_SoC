# Implementation flow for soc_top (docs/09_timing.md). Needs sv2v, Yosys and
# OpenSTA (not in the CI image, so this runs locally).
#   make -C flow pdk    Sky130 HD liberty files into build/pdk (SHA-256 checked)
#   make -C flow syn    sv2v, Yosys, fanout buffers: build/syn/soc_top.nl.v
#   make -C flow cdc    structural clock-domain-crossing check of the netlist
#   make -C flow sta    OpenSTA at ss, tt and ff: build/sta/
#   make -C flow area   standard-cell area by block
#   make -C flow        all of the above

.PHONY: all pdk syn cdc sta area

all: pdk syn cdc sta area

pdk:
	bash syn/fetch_sky130.sh

syn: pdk
	bash syn/run_syn.sh

cdc:
	python3 cdc/check_cdc.py

sta:
	bash sta/run_sta.sh

area:
	python3 syn/area_by_block.py
