import 'package:chatwoot_sdk/chatwoot_sdk.dart';
import 'package:chatwoot_sdk/data/chatwoot_repository.dart';
import 'package:chatwoot_sdk/data/local/entity/chatwoot_contact.dart';
import 'package:chatwoot_sdk/data/local/entity/chatwoot_conversation.dart';
import 'package:chatwoot_sdk/data/remote/requests/chatwoot_action_data.dart';
import 'package:chatwoot_sdk/data/remote/requests/chatwoot_new_message_request.dart';
import 'package:chatwoot_sdk/di/modules.dart';
import 'package:chatwoot_sdk/chatwoot_parameters.dart';
import 'package:dio/dio.dart';
import 'package:chatwoot_sdk/repository_parameters.dart';
import 'package:riverpod/riverpod.dart';
import 'package:uuid/uuid.dart';

import 'data/local/local_storage.dart';

/// Represents a chatwoot client instance. All chatwoot operations (Example: sendMessages) are
/// passed through chatwoot client. For more info visit
/// https://www.chatwoot.com/docs/product/channels/api/client-apis
///
/// {@category FlutterClientSdk}
class ChatwootClient {
  late final ChatwootRepository _repository;
  final ChatwootParameters _parameters;
  final ChatwootCallbacks? callbacks;
  final ChatwootUser? user;

  String get baseUrl => _parameters.baseUrl;

  String get inboxIdentifier => _parameters.inboxIdentifier;

  ChatwootClient._(this._parameters, {this.user, this.callbacks}) {
    providerContainerMap.putIfAbsent(
      _parameters.clientInstanceKey,
      () => ProviderContainer(),
    );
    final container = providerContainerMap[_parameters.clientInstanceKey]!;
    _repository = container.read(
      chatwootRepositoryProvider(
        RepositoryParameters(
          params: _parameters,
          callbacks: callbacks ?? ChatwootCallbacks(),
        ),
      ),
    );
  }

  void _init() {
    try {
      _repository.initialize(user);
    } on ChatwootClientException catch (e) {
      callbacks?.onError?.call(e);
    }
  }

  ///Retrieves chatwoot client's messages. If persistence is enabled [ChatwootCallbacks.onPersistedMessagesRetrieved]
  ///will be triggered with persisted messages. On successfully fetch from remote server
  ///[ChatwootCallbacks.onMessagesRetrieved] will be triggered
  Future<void> loadMessages() async {
    _repository.getPersistedMessages();
    await _repository.getMessages();
  }

  /// Sends chatwoot message. The [echoId] is your temporary message id used to
  /// correlate this message with the [ChatwootCallbacks] it triggers. When
  /// omitted, a unique id is generated automatically. When message sends
  /// successfully [ChatwootMessage] will be returned with the echoId on
  /// [ChatwootCallbacks.onMessageSent]. If message fails to send
  /// [ChatwootCallbacks.onError] will be triggered with the echoId as data.
  ///
  /// Provide [attachmentPaths] with local file paths (images/docs) to upload them
  /// alongside the message. When attachments are present the message is sent as
  /// multipart/form-data. [content] may be left empty to send attachments only.
  ///
  /// Returns the echoId used for the message so it can be matched against the
  /// callbacks (e.g. for optimistic UI updates).
  Future<String> sendMessage({
    String content = "",
    String? echoId,
    List<String> attachmentPaths = const [],
  }) async {
    assert(content.isNotEmpty || attachmentPaths.isNotEmpty,
        "A message must have content or at least one attachment");
    final resolvedEchoId = echoId ?? const Uuid().v4();
    final request = ChatwootNewMessageRequest(
      content: content,
      echoId: resolvedEchoId,
      attachmentPaths: attachmentPaths,
    );
    await _repository.sendMessage(request);
    return resolvedEchoId;
  }

  ///Send chatwoot action performed by user.
  ///
  /// Example: User started typing
  Future<void> sendAction(ChatwootActionType action) async {
    _repository.sendAction(action);
  }

  ///Disposes chatwoot client and cancels all stream subscriptions
  dispose() {
    final container = providerContainerMap[_parameters.clientInstanceKey]!;
    _repository.dispose();
    container.dispose();
    providerContainerMap.remove(_parameters.clientInstanceKey);
  }

  /// Clears all chatwoot client data
  clearClientData() {
    final container = providerContainerMap[_parameters.clientInstanceKey]!;
    final localStorage = container.read(localStorageProvider(_parameters));
    localStorage.clear(clearChatwootUserStorage: false);
  }

  /// Creates an instance of [ChatwootClient] with the [baseUrl] of your chatwoot installation,
  /// [inboxIdentifier] for the targeted inbox. Specify custom user details using [user] and [callbacks] for
  /// handling chatwoot events. By default persistence is enabled, to disable persistence set [enablePersistence] as false
  ///Registers chatwoot's hive adapters using a typeId range starting from [typeIdBase].
  ///Call this from the host app (e.g. `main()`) when the app also uses hive, so the
  ///chatwoot adapters don't clash with the app's own typeIds. Safe to call multiple times.
  static void registerHiveAdapters({
    int typeIdBase = kDefaultChatwootHiveTypeIdBase,
  }) {
    LocalStorage.registerHiveAdapters(typeIdBase: typeIdBase);
  }

  static Future<ChatwootClient> create({
    required String baseUrl,
    required String inboxIdentifier,
    ChatwootUser? user,
    bool enablePersistence = true,
    ChatwootCallbacks? callbacks,
    List<Interceptor> dioInterceptors = const [],
    int hiveTypeIdBase = kDefaultChatwootHiveTypeIdBase,
  }) async {
    if (enablePersistence) {
      await LocalStorage.openDB(typeIdBase: hiveTypeIdBase);
    }

    final chatwootParams = ChatwootParameters(
      clientInstanceKey: getClientInstanceKey(
        baseUrl: baseUrl,
        inboxIdentifier: inboxIdentifier,
        userIdentifier: user?.identifier,
      ),
      isPersistenceEnabled: enablePersistence,
      baseUrl: baseUrl,
      inboxIdentifier: inboxIdentifier,
      userIdentifier: user?.identifier,
      dioInterceptors: dioInterceptors,
    );

    final client = ChatwootClient._(
      chatwootParams,
      callbacks: callbacks,
      user: user,
    );

    client._init();

    return client;
  }

  static final _keySeparator = "|||";

  ///Create a chatwoot client instance key using the chatwoot client instance baseurl, inboxIdentifier
  ///and userIdentifier. Client instance keys are used to differentiate between client instances and their data
  ///(contact ([ChatwootContact]),conversation ([ChatwootConversation]) and messages ([ChatwootMessage]))
  ///
  /// Create separate [ChatwootClient] instances with same baseUrl, inboxIdentifier, userIdentifier and persistence
  /// enabled will be regarded as same therefore use same contact and conversation.
  static String getClientInstanceKey({
    required String baseUrl,
    required String inboxIdentifier,
    String? userIdentifier,
  }) {
    return "$baseUrl$_keySeparator$userIdentifier$_keySeparator$inboxIdentifier";
  }

  static Map<String, ProviderContainer> providerContainerMap = Map();

  ///Clears all persisted chatwoot data on device for a particular chatwoot client instance.
  ///See [getClientInstanceKey] on how chatwoot client instance are differentiated
  static Future<void> clearData({
    required String baseUrl,
    required String inboxIdentifier,
    String? userIdentifier,
  }) async {
    final clientInstanceKey = getClientInstanceKey(
      baseUrl: baseUrl,
      inboxIdentifier: inboxIdentifier,
      userIdentifier: userIdentifier,
    );
    providerContainerMap.putIfAbsent(
      clientInstanceKey,
      () => ProviderContainer(),
    );
    final container = providerContainerMap[clientInstanceKey]!;
    final params = ChatwootParameters(
      isPersistenceEnabled: true,
      baseUrl: "",
      inboxIdentifier: "",
      clientInstanceKey: "",
    );

    final localStorage = container.read(localStorageProvider(params));
    await localStorage.clear();

    localStorage.dispose();
    container.dispose();
    providerContainerMap.remove(clientInstanceKey);
  }

  /// Clears all persisted chatwoot data on device.
  static Future<void> clearAllData() async {
    providerContainerMap.putIfAbsent("all", () => ProviderContainer());
    final container = providerContainerMap["all"]!;
    final params = ChatwootParameters(
      isPersistenceEnabled: true,
      baseUrl: "",
      inboxIdentifier: "",
      clientInstanceKey: "",
    );

    final localStorage = container.read(localStorageProvider(params));
    await localStorage.clearAll();

    localStorage.dispose();
    container.dispose();
  }
}
