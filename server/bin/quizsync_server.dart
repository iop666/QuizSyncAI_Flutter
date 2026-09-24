import 'dart:io';

import 'package:quizsync_server/src/cli.dart';
import 'package:quizsync_server/src/config.dart';
import 'package:quizsync_server/src/constants.dart';
import 'package:quizsync_server/src/hotkey_service.dart';
import 'package:quizsync_server/src/terminal.dart';

/// QuizSyncAI Server：`QuizSyncAI_Server.exe`
///
/// 只做一件事 —— Windows 截图 → AI 识别 → 通过既有协议把结果推给 Android。
/// 没有 GUI、没有托盘、没有悬浮窗，也没有第二个 Flutter 引擎。
void main(List<String> argv) async {
  // 中文与二维码半块字符要按 UTF-8 写，二维码要 ANSI 配色。
  Terminal.enableAnsiConsole();

  final CliArgs args;
  try {
    args = parseCliArgs(argv);
  } on FormatException catch (e) {
    final terminal = Terminal.console();
    terminal.error(e.message);
    terminal.line(kUsage);
    exit(2);
  }

  // `--stop`：只发一个停机请求就退出，不启动服务、不注册热键。
  if (args.stop) {
    exit(await stopRunningServer(Terminal.console(),
        configPath: args.configPath));
  }

  // `--status`：只报告「在不在跑 / 第几次启动」，不启动服务。
  if (args.status) {
    exit(await printServerStatus(Terminal.console(),
        configPath: args.configPath));
  }

  // `--background`：另起一个完全没有控制台的自己，本次启动立刻返回。
  if (args.background) {
    exit(await launchBackgroundServer(Terminal.console(),
        configPath: args.configPath));
  }

  // `--help` / `--version`：只打印，不建数据目录、不写日志。
  if (args.help) {
    Terminal.console().line(kUsage);
    exit(0);
  }
  if (args.version) {
    Terminal.console().line('$kServerProductName v$kServerVersion');
    exit(0);
  }

  // 已经有实例在跑 → 本次启动**不起第二个服务**，直接当它的命令行窗口。
  //
  // 这正是用户要的「重新呼出命令行界面」：后台跑着的时候再双击一次 exe，得到的就是
  // 一个能敲 status / qr / hotkey / stop 的窗口，命令都送到那个进程上执行。
  // `--hidden` 例外：那是「我也要后台运行」，不该弹窗口。
  if (!args.hidden) {
    final attached = await attachToRunningServer(
      Terminal.console(),
      configPath: args.configPath,
      force: args.console,
    );
    if (attached != null) exit(attached);
  }

  // 日志**始终**同时写 `<数据目录>\server.log`。
  //
  // 不只是 `--hidden` 才要文件：用户在普通窗口里输入 `hidden` 转后台之后，那个控制台
  // 马上就要被抛弃，后面所有日志只能落在文件里（`consoleWithFile` 会自动在脱离控制台
  // 之后停掉控制台那一路，也不会在没有控制台时往死句柄里写）。
  final paths = ConfigPaths.resolve(override: args.configPath);
  await paths.ensure();
  final terminal = Terminal.consoleWithFile(paths.logFile);

  final app = ServerApp(
    terminal: terminal,
    args: args,
    hotkeys: args.registerHotkeys
        ? HotkeyService(trace: (message) => terminal.log('Hotkey', message))
        : null,
  );
  exit(await app.run());
}
