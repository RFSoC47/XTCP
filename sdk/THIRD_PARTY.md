# 第三方组件与工具

| 内容 | 用途 | 随包材料 |
|---|---|---|
| Alex Forencich，verilog-ethernet | XGMII 收发与以太网 CRC 计算 | [源文件和版权声明](ip_repo/xtcp/hdl/third_party/mac/COPYING) |
| Alex Forencich，verilog-axis | AXI Stream 宽度转换与异步 FIFO | [源文件版权声明](ip_repo/xtcp/hdl/third_party/axis/COPYING) · [FIFO 约束脚本](tools/axis_async_fifo.tcl) |
| AMD Vivado 2025.2、XPM、10G/25G High Speed Ethernet Subsystem、VIO | 综合实现、存储原语、RDX051 的 PCS/PMA 与板上状态读回 | 由使用方的 Vivado 安装提供，板级示例在新工程中创建所用的 AMD IP |

两个第三方 HDL 目录和约束脚本保留了上游版权与许可文字。其中的 MIT 许可适用于相应第三方文件。[verilog-ethernet 上游许可](https://github.com/alexforencich/verilog-ethernet/blob/master/COPYING) · [verilog-axis 上游许可](https://github.com/alexforencich/verilog-axis/blob/master/COPYING)

XTCP 协议实现、公共顶层、板级集成和用户文档随本包交付，供接收方在自己的工程中集成、综合和验证。
