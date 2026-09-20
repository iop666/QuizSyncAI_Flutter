import 'dart:io';
import 'dart:typed_data';

import 'package:quizsync_core/quizsync_core.dart';

import '../state/app_state.dart';

/// 安卓端本地原图的固定保留张数（用户反馈 M14 第 7 条）。
///
/// 用户明确要求「安卓端本地默认只保存最近 20 张，不再提供图片缓存选项」，
/// 所以这里写死常量：不再读 `app.settings.app.imageCacheLimit`
/// （那个设置项留给 Windows 端继续用，字段本身保留不删）。
const int kAndroidLocalImageLimit = 20;

/// Android 端同步编排（M6 任务 1、4、5）：
/// 1. 离线队列按序补跑（Windows 上线后）；
/// 2. 图片后台补传（最近 200 张、一次 5 张）；
/// 3. reconcile：先拉后推。
class AndroidSync {
  final AndroidAppState app;
  final String imageDir;

  AndroidSync({required this.app, required this.imageDir});

  /// 队列补跑 + 补传 + 同步。任何一步失败静默返回（下次再试）。
  Future<({int drained, int backfilled, int pulled, int pushed})> runFull(
      PairingInfo info) async {
    var drained = 0;
    var backfilled = 0;
    var pulled = 0;
    var pushed = 0;
    try {
      final api = ApiClient(baseUrl: info.httpBase, token: info.token);

      // 1. 离线队列按序补跑（data-model 2.8）。
      //    多页 / 合集归属必须在补跑时原样复原（用户需求 4/8），
      //    否则主机收到的是一个「只有第一页、没归类」的任务。
      //    每一页都要重新上传：离线期间主机那边这些图也不存在。
      drained = await app.queue.drain((task) async {
        final payload = OfflineQueue.parsePayload(task);
        try {
          final uploaded = <String>[];
          for (final hash in payload.imageHashes) {
            final meta = await app.repo.getImage(hash);
            final path = meta?.localPath;
            if (path == null) return false; // 原图不在磁盘上，补跑没意义
            final bytes = await File(path).readAsBytes();
            final up = await api.uploadImage(bytes);
            uploaded.add(up.imageHash);
          }
          if (uploaded.isEmpty) return false;
          await api.createTask(
            taskId: task.taskId,
            imageHash: uploaded.first,
            sourceDevice: app.repo.deviceId,
            imageHashes: uploaded,
            collectionId: payload.collectionId,
          );
          return true;
        } on ApiClientException catch (e) {
          // 主机还没选任务合集：这是**整体性**阻塞，不是这条任务坏了。
          // 直接 return false 会让 attempts+1，5 次之后整条队列变成
          // queue_give_up 死信——等用户终于选好合集时反而再也补跑不了。
          if (e.code == 'no_active_collection') {
            throw QueueRetryLater(e.message);
          }
          return false;
        }
      });

      // 2. 图片后台补传（一次最多 5 张，data-model 2.4）。
      final missing = await imagesMissingFile(app.repo, recentLimit: 200);
      for (final meta in missing.take(5)) {
        try {
          final bytes = await api.downloadImage(meta.hash);
          if (bytes == null) continue;
          final file = File('$imageDir/${meta.hash}.jpg');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes);
          await app.repo.setImageLocalPath(meta.hash, file.path);
          backfilled++;
        } on ApiClientException {
          break;
        }
      }

      // 3. 先拉后推（断线重连规则）。
      final engine =
          SyncEngine(repo: app.repo, localDeviceId: app.repo.deviceId);
      final r = await engine.reconcile(
        info.serverDeviceId,
        fetcher: (since) => api.pullAllOps(
            sinceLamport: since, fromDevice: info.serverDeviceId),
        sender: api.pushOps,
      );
      pulled = r.pulled;
      pushed = r.pushed;

      // 4. 本地图片缓存清理（用户反馈 M14 第 7 条）：固定只留最近 20 张。
      await pruneImages();
    } catch (_) {
      // 主机不在线等情况：下次再试。
    }
    return (
      drained: drained,
      backfilled: backfilled,
      pulled: pulled,
      pushed: pushed
    );
  }

  /// 把主机上报的**当前活跃合集列表**打进本地库（M18 第 4 条）。
  ///
  /// 用户原话：「安卓端现在识别不到无法同步 windows 端的分类，想办法完成同步」。
  /// 落地动作在 `CoreRepository.mirrorCollections`（**只增改、不删**，本机已删的
  /// 合集绝不复活）。这里只是把「要不要动界面」的判断做完：一行都没写就不用
  /// invalidate，免得每秒重建历史列表。
  ///
  /// **异常往外抛**（与 `AndroidSync` 其余方法的「静默返回」相反）：调用方是
  /// `HostStatusPoller`，它靠异常把「已镜像」的指纹撤回去、下一轮探测重试；
  /// 这里吞掉的话轮询器会以为成功，这个合集就再也补不进来了。
  ///
  /// 返回真正写进去的行数。
  Future<int> mirrorHostCollections(Iterable<Collection> host) =>
      app.repo.mirrorCollections(host);

  /// **只拉不推**的轻量同步（M17 第 5 条）：「Windows 有什么安卓就要有什么」。
  ///
  /// 主机的本地 ops 水位涨了（改题目、改设置里的识别记录…）就会被叫一次。刻意不
  /// 复用 [runFull]：那条会 drain 离线队列并 push ops，一秒一次的频率下既重又可能
  /// 重复上传。这里只做 `pullFromPeer`（拉回来 LWW 落地），随后由宿主失效本地数据。
  /// 失败静默返回 0（下次水位再涨或重连时还会拉）。
  ///
  /// 注意：合集**不靠这条通道**（M18 第 4 条）—— 主机删除合集的 op 在
  /// `CoreRepository.applyRemoteCollectionDeletes = false` 下不会落地，
  /// 手机本地的分组因此不会被删掉。
  Future<int> pullOpsOnly(PairingInfo info) async {
    try {
      final api = ApiClient(baseUrl: info.httpBase, token: info.token);
      final engine =
          SyncEngine(repo: app.repo, localDeviceId: app.repo.deviceId);
      return await engine.pullFromPeer(
        info.serverDeviceId,
        (since) => api.pullAllOps(
            sinceLamport: since, fromDevice: info.serverDeviceId),
      );
    } catch (_) {
      return 0;
    }
  }

  /// 固定只保留最近的 [kAndroidLocalImageLimit] 张本地原图，多出来的删最旧的
  /// （文本结果与元数据永久保留）。返回删除张数。
  Future<int> pruneImages() async {
    try {
      return await pruneImageFiles(
        app.repo,
        (hash) => '$imageDir/$hash.jpg',
        maxFiles: kAndroidLocalImageLimit,
        onDelete: (path) async {
          final f = File(path);
          if (await f.exists()) await f.delete();
        },
      );
    } catch (_) {
      return 0; // 清理失败不能影响同步
    }
  }

  /// 截屏/相册字节持久化（离线队列能补跑的前提）。
  Future<void> saveImageFile(String hash, Uint8List bytes) async {
    final file = File('$imageDir/$hash.jpg');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    await app.repo.setImageLocalPath(hash, file.path);
  }
}
