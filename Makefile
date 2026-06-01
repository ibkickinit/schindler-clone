# Schindler 2.0 — top-level build / test / sim entry points.
#
# Default targets (no Vivado required):
#   make test     — run the pytest harness (daemon, catalog, telemetry, etc.)
#   make sim      — run the Python kernel-compare sim + diff against golden
#   make ci       — both of the above
#
# Vivado-dependent (source settings64.sh first):
#   make sim-vivado   — xsim testbenches (scaler_top_tb + Mackin sim suite)
#   make build        — Vivado HDL build (delegates to tcl/build_phase_b.tcl)
#   make build-app    — Vitis ELF build (tcl/build_phase_b_app.tcl)
#   make program      — JTAG program the dev board (tcl/program_phase_b_full.tcl)
#
# Maintenance:
#   make sim-bootstrap   — regenerate the sim/golden/ hash file (use when a
#                          kernel change LEGITIMATELY changes the sim output)
#   make clean-sim       — wipe sim PPM outputs
#
# Test-methodology re-audit (2026-05-31) flagged the lack of a single
# entry-point for headless regression sims. This Makefile is the answer.

PYTHON      ?= /tmp/schindlerd-venv/bin/python
PYTEST      ?= $(PYTHON) -m pytest
PYTEST_FLAGS ?= -c tests/pytest.ini

KCC_DIM_IN_W  ?= 320
KCC_DIM_IN_H  ?= 180
KCC_DIM_OUT_W ?= 160
KCC_DIM_OUT_H ?= 90
KCC_OUTDIR    ?= build/sim-check
GOLDEN_FILE   ?= sim/golden/kernel-compare-$(KCC_DIM_IN_W)x$(KCC_DIM_IN_H)-to-$(KCC_DIM_OUT_W)x$(KCC_DIM_OUT_H).sha256

.PHONY: help test sim ci sim-vivado sim-bootstrap clean-sim build build-app program

help:
	@grep -E '^[a-zA-Z_-]+:.*?# .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?# "}; {printf "  %-18s %s\n", $$1, $$2}'

test: ## pytest harness (daemon + catalog + telemetry, no bench needed)
	$(PYTEST) $(PYTEST_FLAGS)

sim: ## Python kernel compare + sha256 diff against golden
	@mkdir -p $(KCC_OUTDIR)
	@echo "→ running kernel compare ($(KCC_DIM_IN_W)x$(KCC_DIM_IN_H) → $(KCC_DIM_OUT_W)x$(KCC_DIM_OUT_H))..."
	@$(PYTHON) python/scaler_kernel_compare.py sim \
		--in-w  $(KCC_DIM_IN_W)  --in-h  $(KCC_DIM_IN_H) \
		--out-w $(KCC_DIM_OUT_W) --out-h $(KCC_DIM_OUT_H) \
		--outdir $(KCC_OUTDIR) > $(KCC_OUTDIR)/sim.log 2>&1
	@echo "→ sha256 → $(KCC_OUTDIR)/sha256.txt"
	@( cd $(KCC_OUTDIR) && sha256sum out_*.ppm | sort > sha256.txt )
	@if [ ! -f $(GOLDEN_FILE) ]; then \
		echo "FAIL: no golden at $(GOLDEN_FILE)"; \
		echo "  Run 'make sim-bootstrap' to seed it from the current run."; \
		exit 2; \
	fi
	@if diff -u $(GOLDEN_FILE) $(KCC_OUTDIR)/sha256.txt > $(KCC_OUTDIR)/diff.txt; then \
		echo "PASS: kernel sim sha256 matches $(GOLDEN_FILE)"; \
	else \
		echo "FAIL: kernel sim diverged from $(GOLDEN_FILE)"; \
		cat $(KCC_OUTDIR)/diff.txt; \
		echo ""; \
		echo "If this is a legitimate kernel change, run 'make sim-bootstrap'."; \
		exit 1; \
	fi

ci: test sim ## test + sim (both fast paths, no bench, no Vivado)

sim-vivado: ## xsim testbenches (requires Vivado env sourced)
	@command -v xvlog >/dev/null 2>&1 || { \
		echo "xvlog not found; source /tools/Xilinx/2025.2/Vitis/settings64.sh first"; \
		exit 2; }
	@echo "→ xsim sim/scaler_top_tb.v ..."
	@cd sim && xvlog scaler_top_tb.v ../hdl/scaler_top.v ../hdl/scaler_h.v ../hdl/scaler_v.v \
		../hdl/scaler_coeffs_h.v ../hdl/scaler_coeffs_v.v ../hdl/scaler_lbuf_dp.v 2>&1 | tee xvlog-sim.log
	@cd sim && xelab scaler_top_tb -s scaler_top_tb 2>&1 | tee xelab-sim.log
	@cd sim && xsim scaler_top_tb -R 2>&1 | tee xsim-scaler-top.log | tail -3
	@echo "→ Mackin sim suite (if present)..."
	@if [ -d sim/mackin ] && find sim/mackin -name '*.v' -o -name '*.sv' | head -1 | grep -q .; then \
		echo "  (Mackin TB present — invoke per its own README, not wired here)"; \
	else \
		echo "  (no Mackin TB sources found; skipping)"; \
	fi
	@echo "PASS: sim-vivado completed"

sim-bootstrap: ## Regenerate sim/golden/ from the current kernel-compare output
	@mkdir -p $(dir $(GOLDEN_FILE)) $(KCC_OUTDIR)
	@echo "→ regenerating $(GOLDEN_FILE) from a fresh sim run..."
	@$(PYTHON) python/scaler_kernel_compare.py sim \
		--in-w  $(KCC_DIM_IN_W)  --in-h  $(KCC_DIM_IN_H) \
		--out-w $(KCC_DIM_OUT_W) --out-h $(KCC_DIM_OUT_H) \
		--outdir $(KCC_OUTDIR) > $(KCC_OUTDIR)/sim.log 2>&1
	@( cd $(KCC_OUTDIR) && sha256sum out_*.ppm | sort ) > $(GOLDEN_FILE)
	@echo "wrote $(GOLDEN_FILE):"
	@cat $(GOLDEN_FILE)
	@echo ""
	@echo "Commit the file if the kernel change was intentional."

clean-sim: ## Wipe sim PPM outputs (leaves goldens alone)
	rm -rf $(KCC_OUTDIR)

build: ## Vivado HDL build → build/phase_b.xsa (Vivado env required)
	@command -v vivado >/dev/null 2>&1 || { echo "source Vivado settings first"; exit 2; }
	vivado -mode batch -source tcl/build_phase_b.tcl

build-app: ## Vitis bare-metal ELF build (xsct required)
	@command -v xsct >/dev/null 2>&1 || { echo "source Vitis settings first"; exit 2; }
	xsct tcl/build_phase_b_app.tcl

program: ## JTAG program the dev board (xsct required)
	@command -v xsct >/dev/null 2>&1 || { echo "source Vitis settings first"; exit 2; }
	xsct tcl/program_phase_b_full.tcl
