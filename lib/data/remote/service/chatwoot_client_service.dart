import 'dart:async';
import 'dart:convert';

import 'package:inobus_chatwoot_sdk/data/local/entity/chatwoot_contact.dart';
import 'package:inobus_chatwoot_sdk/data/local/entity/chatwoot_conversation.dart';
import 'package:inobus_chatwoot_sdk/data/local/entity/chatwoot_message.dart';
import 'package:inobus_chatwoot_sdk/data/remote/chatwoot_client_exception.dart';
import 'package:inobus_chatwoot_sdk/data/remote/requests/chatwoot_action.dart';
import 'package:inobus_chatwoot_sdk/data/remote/requests/chatwoot_action_data.dart';
import 'package:inobus_chatwoot_sdk/data/remote/requests/chatwoot_new_message_request.dart';
import 'package:inobus_chatwoot_sdk/data/remote/service/chatwoot_client_api_interceptor.dart';
import 'package:dio/dio.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Service for handling chatwoot api calls
/// See [ChatwootClientServiceImpl]
abstract class ChatwootClientService {
  final String _baseUrl;
  WebSocketChannel? connection;
  final Dio _dio;

  ChatwootClientService(this._baseUrl, this._dio);

  Future<ChatwootContact> updateContact(update);

  Future<ChatwootContact> getContact();

  Future<List<ChatwootConversation>> getConversations();

  Future<ChatwootMessage> createMessage(ChatwootNewMessageRequest request);

  Future<ChatwootMessage> updateMessage(String messageIdentifier, update);

  Future<List<ChatwootMessage>> getAllMessages();

  void startWebSocketConnection(String contactPubsubToken,
      {WebSocketChannel Function(Uri)? onStartConnection});

  void sendAction(String contactPubsubToken, ChatwootActionType action);
}

class ChatwootClientServiceImpl extends ChatwootClientService {
  ChatwootClientServiceImpl(String baseUrl, {required Dio dio})
      : super(baseUrl, dio);

  ///Sends message to chatwoot inbox
  @override
  Future<ChatwootMessage> createMessage(
      ChatwootNewMessageRequest request) async {
    try {
      final path =
          "/public/api/v1/inboxes/${ChatwootClientApiInterceptor.INTERCEPTOR_INBOX_IDENTIFIER_PLACEHOLDER}/contacts/${ChatwootClientApiInterceptor.INTERCEPTOR_CONTACT_IDENTIFIER_PLACEHOLDER}/conversations/${ChatwootClientApiInterceptor.INTERCEPTOR_CONVERSATION_IDENTIFIER_PLACEHOLDER}/messages";

      // When the message carries attachments it must be sent as
      // multipart/form-data with each file under the `attachments[]` field.
      // Plain text messages keep using a JSON body.
      final data = request.hasAttachments
          ? FormData.fromMap({
              "content": request.content,
              "echo_id": request.echoId,
              "attachments[]": [
                for (final filePath in request.attachmentPaths)
                  await MultipartFile.fromFile(filePath,
                      filename: filePath.split("/").last)
              ],
            })
          : request.toJson();

      // Stash the attachment paths so the interceptor can rebuild the (consumed)
      // multipart body and resend it if the request needs a contact reset retry.
      final options = request.hasAttachments
          ? Options(extra: {
              ChatwootClientApiInterceptor.attachmentPathsKey:
                  request.attachmentPaths,
            })
          : null;

      final createResponse = await _dio.post(path, data: data, options: options);
      if ((createResponse.statusCode ?? 0).isBetween(199, 300)) {
        return ChatwootMessage.fromJson(createResponse.data);
      } else {
        throw ChatwootClientException(
            createResponse.statusMessage ?? "unknown error",
            ChatwootClientExceptionType.SEND_MESSAGE_FAILED);
      }
    } on DioException catch (e) {
      throw ChatwootClientException(
          e.message ?? '', ChatwootClientExceptionType.SEND_MESSAGE_FAILED);
    }
  }

  ///Gets all messages of current chatwoot client instance's conversation
  @override
  Future<List<ChatwootMessage>> getAllMessages() async {
    try {
      final createResponse = await _dio.get(
          "/public/api/v1/inboxes/${ChatwootClientApiInterceptor.INTERCEPTOR_INBOX_IDENTIFIER_PLACEHOLDER}/contacts/${ChatwootClientApiInterceptor.INTERCEPTOR_CONTACT_IDENTIFIER_PLACEHOLDER}/conversations/${ChatwootClientApiInterceptor.INTERCEPTOR_CONVERSATION_IDENTIFIER_PLACEHOLDER}/messages");
      if ((createResponse.statusCode ?? 0).isBetween(199, 300)) {
        return (createResponse.data as List<dynamic>)
            .map(((json) => ChatwootMessage.fromJson(json)))
            .toList();
      } else {
        throw ChatwootClientException(
            createResponse.statusMessage ?? "unknown error",
            ChatwootClientExceptionType.GET_MESSAGES_FAILED);
      }
    } on DioException catch (e) {
      throw ChatwootClientException(
          e.message ?? '', ChatwootClientExceptionType.GET_MESSAGES_FAILED);
    }
  }

  ///Gets contact of current chatwoot client instance
  @override
  Future<ChatwootContact> getContact() async {
    try {
      final createResponse = await _dio.get(
          "/public/api/v1/inboxes/${ChatwootClientApiInterceptor.INTERCEPTOR_INBOX_IDENTIFIER_PLACEHOLDER}/contacts/${ChatwootClientApiInterceptor.INTERCEPTOR_CONTACT_IDENTIFIER_PLACEHOLDER}");
      if ((createResponse.statusCode ?? 0).isBetween(199, 300)) {
        return ChatwootContact.fromJson(createResponse.data);
      } else {
        throw ChatwootClientException(
            createResponse.statusMessage ?? "unknown error",
            ChatwootClientExceptionType.GET_CONTACT_FAILED);
      }
    } on DioException catch (e) {
      throw ChatwootClientException(
          e.message ?? '', ChatwootClientExceptionType.GET_CONTACT_FAILED);
    }
  }

  ///Gets all conversation of current chatwoot client instance
  @override
  Future<List<ChatwootConversation>> getConversations() async {
    try {
      final createResponse = await _dio.get(
          "/public/api/v1/inboxes/${ChatwootClientApiInterceptor.INTERCEPTOR_INBOX_IDENTIFIER_PLACEHOLDER}/contacts/${ChatwootClientApiInterceptor.INTERCEPTOR_CONTACT_IDENTIFIER_PLACEHOLDER}/conversations");
      if ((createResponse.statusCode ?? 0).isBetween(199, 300)) {
        return (createResponse.data as List<dynamic>)
            .map(((json) => ChatwootConversation.fromJson(json)))
            .toList();
      } else {
        throw ChatwootClientException(
            createResponse.statusMessage ?? "unknown error",
            ChatwootClientExceptionType.GET_CONVERSATION_FAILED);
      }
    } on DioException catch (e) {
      throw ChatwootClientException(
          e.message ?? '', ChatwootClientExceptionType.GET_CONVERSATION_FAILED);
    }
  }

  ///Update current client instance's contact
  @override
  Future<ChatwootContact> updateContact(update) async {
    try {
      final updateResponse = await _dio.patch(
          "/public/api/v1/inboxes/${ChatwootClientApiInterceptor.INTERCEPTOR_INBOX_IDENTIFIER_PLACEHOLDER}/contacts/${ChatwootClientApiInterceptor.INTERCEPTOR_CONTACT_IDENTIFIER_PLACEHOLDER}",
          data: update);
      if ((updateResponse.statusCode ?? 0).isBetween(199, 300)) {
        return ChatwootContact.fromJson(updateResponse.data);
      } else {
        throw ChatwootClientException(
            updateResponse.statusMessage ?? "unknown error",
            ChatwootClientExceptionType.UPDATE_CONTACT_FAILED);
      }
    } on DioException catch (e) {
      throw ChatwootClientException(
          e.message ?? '', ChatwootClientExceptionType.UPDATE_CONTACT_FAILED);
    }
  }

  ///Update message with id [messageIdentifier] with contents of [update]
  @override
  Future<ChatwootMessage> updateMessage(
      String messageIdentifier, update) async {
    try {
      final updateResponse = await _dio.patch(
          "/public/api/v1/inboxes/${ChatwootClientApiInterceptor.INTERCEPTOR_INBOX_IDENTIFIER_PLACEHOLDER}/contacts/${ChatwootClientApiInterceptor.INTERCEPTOR_CONTACT_IDENTIFIER_PLACEHOLDER}/conversations/${ChatwootClientApiInterceptor.INTERCEPTOR_CONVERSATION_IDENTIFIER_PLACEHOLDER}/messages/$messageIdentifier",
          data: update);
      if ((updateResponse.statusCode ?? 0).isBetween(199, 300)) {
        return ChatwootMessage.fromJson(updateResponse.data);
      } else {
        throw ChatwootClientException(
            updateResponse.statusMessage ?? "unknown error",
            ChatwootClientExceptionType.UPDATE_MESSAGE_FAILED);
      }
    } on DioException catch (e) {
      throw ChatwootClientException(
          e.message ?? '', ChatwootClientExceptionType.UPDATE_MESSAGE_FAILED);
    }
  }

  @override
  void startWebSocketConnection(String contactPubsubToken,
      {WebSocketChannel Function(Uri)? onStartConnection}) {
    final socketUrl = Uri.parse(_baseUrl.replaceFirst("http", "ws") + "/cable");
    //Close the previous channel, otherwise it stays open and keeps streaming
    //events even though nothing references it anymore.
    connection?.sink.close();
    this.connection = onStartConnection == null
        ? WebSocketChannel.connect(socketUrl)
        : onStartConnection(socketUrl);
    connection!.sink.add(jsonEncode({
      "command": "subscribe",
      "identifier": jsonEncode(
          {"channel": "RoomChannel", "pubsub_token": contactPubsubToken})
    }));
  }

  @override
  void sendAction(String contactPubsubToken, ChatwootActionType actionType) {
    final ChatwootAction action;
    final identifier = jsonEncode(
        {"channel": "RoomChannel", "pubsub_token": contactPubsubToken});
    switch (actionType) {
      case ChatwootActionType.subscribe:
        action = ChatwootAction(identifier: identifier, command: "subscribe");
        break;
      default:
        action = ChatwootAction(
            identifier: identifier,
            data: ChatwootActionData(action: actionType),
            command: "message");
        break;
    }
    connection?.sink.add(jsonEncode(action.toJson()));
  }
}
