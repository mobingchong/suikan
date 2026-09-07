import 'package:simple_live_app/models/sync_client_info_model.dart';
import 'package:simple_live_app/requests/http_client.dart';
import 'package:simple_live_app/services/sync_service.dart';

class SyncClientRequest {
  Future<SyncClientInfoModel> getClientInfo(SyncClinet client) async {
    var url = "http://${client.address}:${client.port}/info";
    var data = await HttpClient.instance.getJson(url);

    return SyncClientInfoModel.fromJson(data);
  }

  Future<bool> syncFollow(
    SyncClinet client,
    dynamic body, {
    bool overlay = false,
    Map<String, String> extraQueryParameters = const {},
  }) async {
    var url = "http://${client.address}:${client.port}/sync/follow";
    var data = await HttpClient.instance.postJson(
      url,
      data: body,
      queryParameters: {
        'overlay': overlay ? '1' : '0',
        ...extraQueryParameters,
      },
    );

    if (data["status"]) {
      return true;
    } else {
      throw data["message"];
    }
  }

  Future<bool> syncTag(
    SyncClinet client,
    dynamic body, {
    bool overlay = false,
    Map<String, String> extraQueryParameters = const {},
  }) async {
    var data = await postTag(client, body, overlay, extraQueryParameters);
    if (data["status"]) {
      return true;
    } else {
      throw data["message"];
    }
  }

  /// 推送关注标签并返回服务端反馈 message(用于诚实提示目标端是否支持,
  /// 如 TV 端暂不支持标签会如实返回"已跳过"而非假装成功)。
  Future<String?> syncTagForMessage(
    SyncClinet client,
    dynamic body, {
    bool overlay = false,
  }) async {
    final data = await postTag(client, body, overlay, const {});
    if (data["status"]) {
      return data["message"]?.toString();
    }
    throw data["message"];
  }

  Future<dynamic> postTag(
    SyncClinet client,
    dynamic body,
    bool overlay,
    Map<String, String> extraQueryParameters,
  ) async {
    var url = "http://${client.address}:${client.port}/sync/tag";
    return HttpClient.instance.postJson(
      url,
      data: body,
      queryParameters: {
        'overlay': overlay ? '1' : '0',
        ...extraQueryParameters,
      },
    );
  }

  Future<bool> syncHistory(
    SyncClinet client,
    dynamic body, {
    bool overlay = false,
    Map<String, String> extraQueryParameters = const {},
  }) async {
    var url = "http://${client.address}:${client.port}/sync/history";
    var data = await HttpClient.instance.postJson(
      url,
      data: body,
      queryParameters: {
        'overlay': overlay ? '1' : '0',
        ...extraQueryParameters,
      },
    );

    if (data["status"]) {
      return true;
    } else {
      throw data["message"];
    }
  }

  Future<bool> syncBlockedWord(
    SyncClinet client,
    dynamic body, {
    bool overlay = false,
    Map<String, String> extraQueryParameters = const {},
  }) async {
    var url = "http://${client.address}:${client.port}/sync/blocked_word";
    var data = await HttpClient.instance.postJson(
      url,
      data: body,
      queryParameters: {
        'overlay': overlay ? '1' : '0',
        ...extraQueryParameters,
      },
    );

    if (data["status"]) {
      return true;
    } else {
      throw data["message"];
    }
  }

  Future<bool> syncProfile(
    SyncClinet client,
    dynamic body, {
    bool overlay = false,
  }) async {
    var url = "http://${client.address}:${client.port}/sync/profile";
    var data = await HttpClient.instance.postJson(
      url,
      data: body,
      queryParameters: {
        'overlay': overlay ? '1' : '0',
      },
    );

    if (data["status"]) {
      return true;
    } else {
      throw data["message"];
    }
  }

  Future<bool> syncBiliAccount(SyncClinet client, String cookie) async {
    var url = "http://${client.address}:${client.port}/sync/account/bilibili";
    var data = await HttpClient.instance.postJson(
      url,
      data: {
        "cookie": cookie,
      },
    );

    if (data["status"]) {
      return true;
    } else {
      throw data["message"];
    }
  }

  Future<bool> syncDouyinAccount(SyncClinet client, String cookie) async {
    var url = "http://${client.address}:${client.port}/sync/account/douyin";
    var data = await HttpClient.instance.postJson(
      url,
      data: {
        "cookie": cookie,
      },
    );

    if (data["status"]) {
      return true;
    } else {
      throw data["message"];
    }
  }

  Future<bool> syncKuaishouAccount(
    SyncClinet client,
    String cookie,
    String kww,
    int cookieExpiresAt,
  ) async {
    var url = "http://${client.address}:${client.port}/sync/account/kuaishou";
    var data = await HttpClient.instance.postJson(
      url,
      data: {
        "cookie": cookie,
        "kww": kww,
        "cookieExpiresAt": cookieExpiresAt,
      },
    );

    if (data["status"]) {
      return true;
    } else {
      throw data["message"];
    }
  }
}
