import 'dart:async';
import 'dart:convert';
import 'dart:core';

import 'package:inobus_chatwoot_sdk/chatwoot_callbacks.dart';
import 'package:inobus_chatwoot_sdk/chatwoot_client.dart';
import 'package:inobus_chatwoot_sdk/data/local/entity/chatwoot_user.dart';
import 'package:inobus_chatwoot_sdk/data/local/local_storage.dart';
import 'package:inobus_chatwoot_sdk/data/remote/chatwoot_client_exception.dart';
import 'package:inobus_chatwoot_sdk/data/remote/requests/chatwoot_action_data.dart';
import 'package:inobus_chatwoot_sdk/data/remote/requests/chatwoot_new_message_request.dart';
import 'package:inobus_chatwoot_sdk/data/remote/responses/chatwoot_event.dart';
import 'package:inobus_chatwoot_sdk/data/remote/service/chatwoot_client_service.dart';
import 'package:flutter/material.dart';

/// Handles interactions between chatwoot client api service[clientService] and
/// [localStorage] if persistence is enabled.
///
/// Results from repository operations are passed through [callbacks] to be handled
/// appropriately
abstract class ChatwootRepository {
  @protected
  final ChatwootClientService clientService;
  @protected
  final LocalStorage localStorage;
  @protected
  ChatwootCallbacks callbacks;
  List<StreamSubscription> _subscriptions = [];

  ChatwootRepository(this.clientService, this.localStorage, this.callbacks);

  Future<void> initialize(ChatwootUser? user);

  void getPersistedMessages();

  Future<void> getMessages();

  void listenForEvents();

  Future<void> sendMessage(ChatwootNewMessageRequest request);

  void sendAction(ChatwootActionType action);

  Future<void> clear();

  void dispose();
}

class ChatwootRepositoryImpl extends ChatwootRepository {
  bool _isListeningForEvents = false;
  Timer? _publishPresenceTimer;
  Timer? _presenceResetTimer;

  ///The pubsub token the live websocket is currently subscribed with. Used to
  ///detect when the contact has been re-registered (new token) so we can
  ///re-subscribe the socket to the new contact's channel.
  String? _subscribedPubsubToken;

  ///Websocket auto-reconnect state.
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _isDisposed = false;
  static const _maxReconnectDelay = Duration(seconds: 30);

  ChatwootRepositoryImpl(
      {required ChatwootClientService clientService,
      required LocalStorage localStorage,
      required ChatwootCallbacks streamCallbacks})
      : super(clientService, localStorage, streamCallbacks);

  /// Fetches persisted messages.
  ///
  /// Calls [ChatwootCallbacks.onMessagesRetrieved] when [ChatwootClientService.getAllMessages] is successful
  /// Calls [ChatwootCallbacks.onError] when [ChatwootClientService.getAllMessages] fails
  @override
  Future<void> getMessages() async {
    try {
      final messages = await clientService.getAllMessages();
      await localStorage.messagesDao.saveAllMessages(messages);
      callbacks.onMessagesRetrieved?.call(messages);
      // A 404 recovery may have re-registered the contact with a new pubsub
      // token while this request was in flight; make sure the socket follows it.
      _resubscribeIfContactChanged();
    } on ChatwootClientException catch (e) {
      callbacks.onError?.call(e);
    }
  }

  ///Re-subscribes the websocket when the persisted contact's pubsub token no
  ///longer matches the one the live socket is using (e.g. after the contact was
  ///re-registered following a 401/403/404 reset).
  void _resubscribeIfContactChanged() {
    final token = localStorage.contactDao.getContact()?.pubsubToken;
    if (token == null || token == _subscribedPubsubToken) {
      return;
    }
    listenForEvents();
  }

  /// Fetches persisted messages.
  ///
  /// Calls [ChatwootCallbacks.onPersistedMessagesRetrieved] if persisted messages are found
  @override
  void getPersistedMessages() {
    final persistedMessages = localStorage.messagesDao.getMessages();
    if (persistedMessages.isNotEmpty) {
      callbacks.onPersistedMessagesRetrieved?.call(persistedMessages);
    }
  }

  /// Initializes chatwoot client repository
  Future<void> initialize(ChatwootUser? user) async {
    try {
      if (user != null) {
        await localStorage.userDao.saveUser(user);
      }

      //refresh contact
      final contact = await clientService.getContact();
      localStorage.contactDao.saveContact(contact);

      //refresh conversation
      final conversations = await clientService.getConversations();
      final persistedConversation =
          localStorage.conversationDao.getConversation()!;
      final refreshedConversation = conversations.firstWhere(
          (element) => element.id == persistedConversation.id,
          orElse: () =>
              persistedConversation //highly unlikely orElse will be called but still added it just in case
          );
      localStorage.conversationDao.saveConversation(refreshedConversation);
    } on ChatwootClientException catch (e) {
      callbacks.onError?.call(e);
    }

    listenForEvents();
  }

  ///Sends message to chatwoot inbox
  Future<void> sendMessage(ChatwootNewMessageRequest request) async {
    try {
      final createdMessage = await clientService.createMessage(request);
      await localStorage.messagesDao.saveMessage(createdMessage);
      callbacks.onMessageSent?.call(createdMessage, request.echoId);
      if (clientService.connection != null && !_isListeningForEvents) {
        listenForEvents();
      } else {
        // Sending may have triggered a 404 contact reset; follow the new token.
        _resubscribeIfContactChanged();
      }
    } on ChatwootClientException catch (e) {
      callbacks.onError?.call(
          ChatwootClientException(e.cause, e.type, data: request.echoId));
    }
  }

  /// Connects to chatwoot websocket and starts listening for updates
  ///
  /// Received events/messages are pushed through [ChatwootClient.callbacks]
  @override
  void listenForEvents() {
    final token = localStorage.contactDao.getContact()?.pubsubToken;
    if (token == null) {
      return;
    }

    //Tear down any previous connection before opening a new one. Without this
    //every call leaves an orphaned socket behind that keeps delivering events,
    //so callbacks fire once per stale connection.
    _reconnectTimer?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
    _publishPresenceTimer?.cancel();
    _presenceResetTimer?.cancel();
    _isListeningForEvents = false;

    _subscribedPubsubToken = token;
    clientService.startWebSocketConnection(token);

    final newSubscription = clientService.connection!.stream.listen((event) {
      ChatwootEvent chatwootEvent = ChatwootEvent.fromJson(jsonDecode(event));
      if (chatwootEvent.type == ChatwootEventType.welcome) {
        callbacks.onWelcome?.call();
      } else if (chatwootEvent.type == ChatwootEventType.ping) {
        callbacks.onPing?.call();
      } else if (chatwootEvent.type == ChatwootEventType.confirm_subscription) {
        // A confirmed subscription means the socket is healthy: reset backoff.
        _reconnectAttempts = 0;
        if (!_isListeningForEvents) {
          _isListeningForEvents = true;
        }
        _publishPresenceUpdates();
        callbacks.onConfirmedSubscription?.call();
      } else if (chatwootEvent.message?.event ==
          ChatwootEventMessageType.message_created) {
        print("here comes message: $event");
        final message = chatwootEvent.message!.data!.getMessage();
        localStorage.messagesDao.saveMessage(message);
        if (message.isMine) {
          callbacks.onMessageDelivered
              ?.call(message, chatwootEvent.message!.data!.echoId!);
        } else {
          callbacks.onMessageReceived?.call(message);
        }
      } else if (chatwootEvent.message?.event ==
          ChatwootEventMessageType.message_updated) {
        print("here comes the updated message: $event");

        final message = chatwootEvent.message!.data!.getMessage();
        localStorage.messagesDao.saveMessage(message);

        callbacks.onMessageUpdated?.call(message);
      } else if (chatwootEvent.message?.event ==
          ChatwootEventMessageType.conversation_typing_off) {
        callbacks.onConversationStoppedTyping?.call();
      } else if (chatwootEvent.message?.event ==
          ChatwootEventMessageType.conversation_typing_on) {
        callbacks.onConversationStartedTyping?.call();
      } else if (chatwootEvent.message?.event ==
              ChatwootEventMessageType.conversation_status_changed &&
          chatwootEvent.message?.data?.status == "resolved" &&
          chatwootEvent.message?.data?.id ==
              (localStorage.conversationDao.getConversation()?.id ?? 0)) {
        //delete conversation result
        localStorage.conversationDao.deleteConversation();
        localStorage.messagesDao.clear();
        callbacks.onConversationResolved?.call();
      } else if (chatwootEvent.message?.event ==
          ChatwootEventMessageType.presence_update) {
        final presenceStatuses =
            (chatwootEvent.message!.data!.users as Map<dynamic, dynamic>)
                .values;
        final isOnline = presenceStatuses.contains("online");
        if (isOnline) {
          callbacks.onConversationIsOnline?.call();
          _presenceResetTimer?.cancel();
          _startPresenceResetTimer();
        } else {
          callbacks.onConversationIsOffline?.call();
        }
      } else {
        print("chatwoot unknown event: $event");
      }
    },
        // The socket dropped (network change, server close, idle timeout, …).
        // dart's WebSocketChannel surfaces this as an error and/or done; either
        // way schedule a reconnect with backoff.
        onError: (_) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
        cancelOnError: true);
    _subscriptions.add(newSubscription);
  }

  ///Schedules a websocket reconnect using exponential backoff (capped at
  ///[_maxReconnectDelay]). Backoff is reset once a subscription is confirmed.
  void _scheduleReconnect() {
    if (_isDisposed) return;

    _isListeningForEvents = false;
    _publishPresenceTimer?.cancel();
    _reconnectTimer?.cancel();

    final seconds = 1 << (_reconnectAttempts.clamp(0, 5)); // 1,2,4,8,16,32→cap
    final delay = seconds > _maxReconnectDelay.inSeconds
        ? _maxReconnectDelay
        : Duration(seconds: seconds);
    _reconnectAttempts++;

    _reconnectTimer = Timer(delay, () {
      if (_isDisposed) return;
      listenForEvents();
    });
  }

  /// Clears all data related to current chatwoot client instance
  @override
  Future<void> clear() async {
    await localStorage.clear();
  }

  /// Cancels websocket stream subscriptions and disposes [localStorage]
  @override
  void dispose() {
    _isDisposed = true;
    _reconnectTimer?.cancel();
    localStorage.dispose();
    callbacks = ChatwootCallbacks();
    _presenceResetTimer?.cancel();
    _publishPresenceTimer?.cancel();
    _subscriptions.forEach((subs) {
      subs.cancel();
    });
  }

  ///Send actions like user started typing
  @override
  void sendAction(ChatwootActionType action) {
    clientService.sendAction(
        localStorage.contactDao.getContact()!.pubsubToken ?? "", action);
  }

  ///Publishes presence update to websocket channel at a 30 second interval
  void _publishPresenceUpdates() {
    sendAction(ChatwootActionType.update_presence);
    _publishPresenceTimer?.cancel();
    _publishPresenceTimer = Timer.periodic(Duration(seconds: 30), (timer) {
      sendAction(ChatwootActionType.update_presence);
    });
  }

  ///Triggers an offline presence event after 40 seconds without receiving a presence update event
  void _startPresenceResetTimer() {
    _presenceResetTimer = Timer.periodic(Duration(seconds: 40), (timer) {
      callbacks.onConversationIsOffline?.call();
      _presenceResetTimer?.cancel();
    });
  }
}
