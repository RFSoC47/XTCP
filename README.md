# XTCP

XTCP (eXtreme TCP) is a synthesizable, single-connection FPGA TCP/IPv4 endpoint for detector readout over 10 and 25 Gigabit Ethernet. It connects application logic to a standard host TCP socket. The Vivado IP supports three configurations: XTCP-10G, XTCP-25G and XTCP-25G-Jumbo. Each instance has configurable MAC and IPv4 addresses and TCP and UDP ports.

## Use the IP

1. Download the source package or clone this repository. In Vivado 2025.2, add `sdk/ip_repo` to the project's IP repository paths. Search for **XTCP** in the IP Catalog and choose the configuration and addresses for your instance. [Vivado IP descriptor](sdk/ip_repo/xtcp/component.xml) · [Synthesizable HDL](sdk/ip_repo/xtcp/hdl)
2. For a working Block Design, source `sdk/tools/new_bd.tcl` in Vivado. The integration manual describes the Tcl arguments, clocks, resets, application streams, byte ordering, and direct RTL integration. [Integration manual, in Chinese](sdk/docs/用户集成与接口手册.md) · [Block Design example](sdk/tools/new_bd.tcl) · [Application example](sdk/examples/xtcp_example_app.sv)
3. To rebuild the RDX051 design, use the board build script and select the matching part, clock and optical lane. The board scripts instantiate the required physical interface IP from the user's installation of Vivado. [RDX051 reference design](sdk/boards/rdx051) · [Board build script](sdk/boards/rdx051/build.tcl)
4. The host tools include a Python client and a Linux throughput measurement utility. To check the delivered SDK files and their hashes, run `python sdk/tools/verify_release.py sdk` from the repository root or the unpacked source package. [Python client](sdk/tools/xtcp_client.py) · [Measurement tool](sdk/tools/xtcp_measure.py) · [Linux measurement source](sdk/tools/linux/xtcp_perf.c)

## Release files

The v1.0.0 source package contains the reviewed SDK, its file manifest, documentation and licence notices. The optional board package contains three matched bitstream and debug-probe pairs, one per configuration, for the RDX051 Kintex UltraScale+ KU5P reference hardware with a 156.25 MHz transceiver reference clock. Use these images only to program the corresponding AMD/Xilinx device on that board. The matching LTX files describe the debug probes in those designs. [Source package](https://github.com/RFSoC47/XTCP/releases/download/v1.0.0/XTCP-1.0.0-source.zip) · [RDX051 BIT/LTX package](https://github.com/RFSoC47/XTCP/releases/download/v1.0.0/XTCP-1.0.0-RDX051.zip) · [Release checksums](https://github.com/RFSoC47/XTCP/releases/download/v1.0.0/SHA256SUMS.txt)

## Measurements

On the released jumbo-frame image at MTU 9000 B, median single-connection application throughput was 24.70 Gbit/s from FPGA to host and 24.08 Gbit/s from host to FPGA, measured in separate transfers. The paper supplement for *XTCP: an open-source FPGA TCP endpoint for readout over 10 and 25 Gigabit Ethernet* includes transfer measurements, resource counts, the sustained echo measurements on the engineering prototypes, and editable figures. [Release validation](sdk/docs/验证记录.md) · [Paper supplement](https://github.com/RFSoC47/XTCP/releases/download/v1.0.0/XTCP-paper-supplement.zip)

## Licensing

Copyright 2026 Tao Xue. The original XTCP software and RTL in this SDK are licensed under the Apache License, Version 2.0. Alex Forencich's Ethernet MAC, AXI Stream components and FIFO constraint script retain their MIT notices. AMD Vivado and vendor IP are supplied by AMD under their own terms. These terms also apply to the included AMD components in the board-specific bitstreams. [Apache-2.0](LICENSE) · [Notices](NOTICE) · [Third-party inventory](sdk/THIRD_PARTY.md) · [AMD Vivado 2025.2 EULA](https://download.amd.com/docnav/documents/eula/end-user-license-agreement_2025.2.pdf)
