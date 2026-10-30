# 第三方组件

Kitty Clear 自己的代码以 MIT 许可证发布（见 [LICENSE](LICENSE)）。App 里随包分发的第三方东西如下，各按各的许可证：

| 组件 | 用途 | 许可证 | 来源 |
|---|---|---|---|
| Mole（版本见 `build-app.sh` 里的 `MOLE_VERSION`） | 清理、卸载、磁盘分析、优化、状态数据 | GNU GPL-3.0 | https://github.com/tw93/mole ，作为单独的程序放在 `Contents/Resources/mole`，许可证全文在 `Contents/Resources/mole/LICENSE`；对应源码就是该版本的 tag（如 `V1.65.0`） |

Mole 不在仓库里：`build-app.sh` 从上面的地址按版本下载，两个 Go 小工具按发布页的 SHA256SUMS 校验。Kitty Clear 只通过命令行调用 Mole，不包含它的代码。按 Mole 的 `TRADEMARK.md`，本项目不使用「Mole」的名字和图标。
