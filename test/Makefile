# Makefile
# See https://docs.cocotb.org/en/stable/quickstart.html for more info

# defaults
SIM ?= icarus
FST ?= -fst # Use more efficient FST format
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(PWD)/../src
# every .sv in info.yaml's source_files; the .svh headers are found through -I$(SRC_DIR)
PROJECT_SOURCES = aquafuse_icg.sv aquafuse_lat.sv aquafuse_wgate.sv aquafuse_sel.sv aquafuse_sensor_if.sv aquafuse_stem_accum.sv \
	aquafuse_conv_stage.sv aquafuse_rom_stem.sv aquafuse_rom_b1.sv aquafuse_rom_b2.sv \
	aquafuse_rom_obj.sv aquafuse_bg_fifo.sv aquafuse_bg_store.sv aquafuse_bg_block.sv \
	aquafuse_temporal_head.sv tt_um_aquafuse_stream12c.sv

ifneq ($(GATES),yes)

# RTL simulation. Icarus 12 rejects one expression in aquafuse_temporal_head.sv (an unsized divisor
# inside a concatenation), so the RTL run uses compat/aquafuse_temporal_head.sv, the same arithmetic
# with a sized divisor. The file that is HARDENED is ../src/aquafuse_temporal_head.sv, untouched.
SIM_BUILD				= sim_build/rtl
# Icarus simulates this RTL at about 260 s per frame (VPS, 19 Oct 2026), so the 32-frame clip plus the config test
# would run for 3-5 hours against GitHub's 6-hour job limit. 12 frames reach the first alarm (frame 5) and the
# wake bit's rising edge (frame 7). All 32 frames in RTL are covered by the project's Verilator equivalence run, and
# the gate-level job below keeps all 32. Set AQUAFUSE_FRAMES=32 for the full RTL clip.
export AQUAFUSE_FRAMES ?= 12
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(filter-out aquafuse_temporal_head.sv,$(PROJECT_SOURCES)))
VERILOG_SOURCES += $(PWD)/compat/aquafuse_temporal_head.sv

else

# Gate level simulation:
SIM_BUILD				= sim_build/gl
COMPILE_ARGS    += -DGL_TEST
COMPILE_ARGS    += -DFUNCTIONAL
COMPILE_ARGS    += -DUSE_POWER_PINS
COMPILE_ARGS    += -DSIM
COMPILE_ARGS    += -DUNIT_DELAY=\#1
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/primitives.v
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v

# this gets copied in by the GDS action workflow
VERILOG_SOURCES += $(PWD)/gate_level_netlist.v

endif

# Allow sharing configuration between design and testbench via `include`:
COMPILE_ARGS 		+= -I$(SRC_DIR)

# Include the testbench sources:
VERILOG_SOURCES += $(PWD)/tb.v
TOPLEVEL = tb

# List test modules to run, separated by commas and without the .py suffix:
COCOTB_TEST_MODULES = test

# include cocotb's make rules to take care of the simulator setup
include $(shell cocotb-config --makefiles)/Makefile.sim
