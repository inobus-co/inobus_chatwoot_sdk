import 'package:inobus_chatwoot_sdk/data/local/entity/chatwoot_contact.dart';
import 'package:inobus_chatwoot_sdk/data/local/entity/chatwoot_conversation.dart';
import 'package:inobus_chatwoot_sdk/data/local/entity/chatwoot_user.dart';
import 'package:inobus_chatwoot_sdk/data/remote/service/chatwoot_client_api_interceptor.dart';
import 'package:inobus_chatwoot_sdk/data/remote/service/chatwoot_client_auth_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import '../../utils/test_resources_util.dart';
import '../chatwoot_repository_test.mocks.dart';
import '../local/local_storage_test.mocks.dart';
import 'chatwoot_client_api_interceptor_test.mocks.dart';
import 'chatwoot_client_service_test.mocks.dart';

class _HasPath extends Matcher {
  final String _pathValue;
  const _HasPath(this._pathValue);

  @override
  bool matches(item, Map matchState) =>
      (item as RequestOptions).path == _pathValue;

  @override
  Description describe(Description description) =>
      description.addDescriptionOf(_pathValue);
}

@GenerateMocks([
  ResponseInterceptorHandler,
  RequestInterceptorHandler,
  ErrorInterceptorHandler,
  ChatwootClientAuthService
])
void main() {
  group("Client Api Interceptor Test", () {
    late final ChatwootClientApiInterceptor interceptor;
    final testInboxIdentifier = "testIdentifier";
    final mockAuthService = MockChatwootClientAuthService();
    final mockLocalStorage = MockLocalStorage();
    final mockContactDao = MockChatwootContactDao();
    final mockUserDao = MockChatwootUserDao();
    final mockDio = MockDio();
    final mockConversationDao = MockChatwootConversationDao();
    final mockMessagesDao = MockChatwootMessagesDao();
    final mockRequestHandler = MockRequestInterceptorHandler();
    final mockErrorHandler = MockErrorInterceptorHandler();

    late final testContact;

    late final testConversation;

    final testUser = ChatwootUser(
        identifier: "identifier",
        identifierHash: "identifierHash",
        name: "name",
        email: "email",
        avatarUrl: "avatarUrl",
        customAttributes: {});

    setUpAll(() async {
      when(mockLocalStorage.contactDao).thenReturn(mockContactDao);
      when(mockLocalStorage.userDao).thenReturn(mockUserDao);
      when(mockAuthService.dio).thenReturn(mockDio);
      when(mockLocalStorage.conversationDao).thenReturn(mockConversationDao);
      when(mockLocalStorage.messagesDao).thenReturn(mockMessagesDao);
      testContact = ChatwootContact.fromJson(
          await TestResourceUtil.readJsonResource(fileName: "contact"));
      testConversation = ChatwootConversation.fromJson(
          await TestResourceUtil.readJsonResource(fileName: "conversation"));
      interceptor = ChatwootClientApiInterceptor(
          testInboxIdentifier, mockLocalStorage, mockAuthService);
    });

    tearDown(() {
      reset(mockAuthService);
      reset(mockContactDao);
      reset(mockConversationDao);
      when(mockAuthService.dio).thenReturn(mockDio);
    });

    _createSuccessResponse(body) {
      return Response(
          data: body,
          statusCode: 200,
          requestOptions: RequestOptions(path: "", headers: new Map()));
    }

    test(
        'Given persisted contact is null when a request is made, then recreate contact and submit request',
        () async {
      //GIVEN
      final testRequest = RequestOptions(path: "/");

      when(mockContactDao.getContact()).thenReturn(null);
      when(mockConversationDao.getConversation()).thenReturn(null);
      when(mockUserDao.getUser()).thenReturn(testUser);
      when(mockAuthService.createNewContact(any, any))
          .thenAnswer((_) => Future.value(testContact));
      when(mockAuthService.createNewConversation(any, any))
          .thenAnswer((_) => Future.value(testConversation));

      //WHEN
      await interceptor.onRequest(testRequest, mockRequestHandler);

      //THEN
      verify(mockAuthService.createNewContact(testInboxIdentifier, testUser));
      verify(mockAuthService.createNewConversation(
          testInboxIdentifier, testContact.contactIdentifier));
      verify(mockContactDao.saveContact(testContact));
      verify(mockConversationDao.saveConversation(testConversation));
      verify(mockRequestHandler.next(any));
    });

    test(
        'Given persisted conversation is null when a request is made, then create a conversation and submit request',
        () async {
      //GIVEN
      final testRequest = RequestOptions(path: "/");

      when(mockContactDao.getContact()).thenReturn(testContact);
      when(mockConversationDao.getConversation()).thenReturn(null);
      when(mockAuthService.createNewConversation(any, any))
          .thenAnswer((_) => Future.value(testConversation));

      //WHEN
      await interceptor.onRequest(testRequest, mockRequestHandler);

      //THEN
      verify(mockAuthService.createNewConversation(
          testInboxIdentifier, testContact.contactIdentifier));
      verify(mockConversationDao.saveConversation(testConversation));
      verify(mockRequestHandler.next(any));
    });

    test(
        'Given contact identifier is needed when a request is made, then attach contact identifier and submit request',
        () async {
      //GIVEN
      final testRequest = RequestOptions(
          path:
              "/${ChatwootClientApiInterceptor.INTERCEPTOR_CONTACT_IDENTIFIER_PLACEHOLDER}");

      when(mockContactDao.getContact()).thenReturn(testContact);
      when(mockConversationDao.getConversation()).thenReturn(testConversation);

      //WHEN
      await interceptor.onRequest(testRequest, mockRequestHandler);

      //THEN
      verify(mockRequestHandler
          .next(argThat(_HasPath("/${testContact.contactIdentifier}"))));
    });

    test(
        'Given inbox identifier is needed when a request is made, then attach inbox identifier and submit request',
        () async {
      //GIVEN
      final testRequest = RequestOptions(
          path:
              "/${ChatwootClientApiInterceptor.INTERCEPTOR_INBOX_IDENTIFIER_PLACEHOLDER}");

      when(mockContactDao.getContact()).thenReturn(testContact);
      when(mockConversationDao.getConversation()).thenReturn(testConversation);

      //WHEN
      await interceptor.onRequest(testRequest, mockRequestHandler);

      //THEN
      verify(
          mockRequestHandler.next(argThat(_HasPath("/$testInboxIdentifier"))));
    });

    test(
        'Given conversation identifier is needed when a request is made, then attach conversation identifier and submit request',
        () async {
      //GIVEN
      final testRequest = RequestOptions(
          path:
              "/${ChatwootClientApiInterceptor.INTERCEPTOR_CONVERSATION_IDENTIFIER_PLACEHOLDER}");

      when(mockContactDao.getContact()).thenReturn(testContact);
      when(mockConversationDao.getConversation()).thenReturn(testConversation);

      //WHEN
      await interceptor.onRequest(testRequest, mockRequestHandler);

      //THEN
      verify(mockRequestHandler
          .next(argThat(_HasPath("/${testConversation.id}"))));
    });

    _createPublicApiError(int statusCode) {
      final requestOptions = RequestOptions(
          path:
              "/public/api/v1/inboxes/$testInboxIdentifier/contacts/oldContact/conversations/1/messages");
      return DioException(
          requestOptions: requestOptions,
          response: Response(
              statusCode: statusCode, requestOptions: requestOptions));
    }

    test(
        'Given a 401 unauthorized error on the public api, then re-register contact and resubmit the failed request',
        () async {
      //GIVEN
      final testError = _createPublicApiError(401);

      when(mockContactDao.getContact()).thenReturn(testContact);
      when(mockConversationDao.getConversation()).thenReturn(null);
      when(mockContactDao.deleteContact()).thenAnswer((_) async {});
      when(mockConversationDao.deleteConversation()).thenAnswer((_) async {});
      when(mockMessagesDao.clear()).thenAnswer((_) async {});
      when(mockContactDao.saveContact(any)).thenAnswer((_) async {});
      when(mockConversationDao.saveConversation(any)).thenAnswer((_) async {});
      when(mockUserDao.getUser()).thenReturn(testUser);
      when(mockAuthService.createNewContact(any, any))
          .thenAnswer((_) => Future.value(testContact));
      when(mockAuthService.createNewConversation(any, any))
          .thenAnswer((_) => Future.value(testConversation));
      when(mockDio.fetch(any))
          .thenAnswer((_) => Future.value(_createSuccessResponse({})));

      //WHEN
      await interceptor.onError(testError, mockErrorHandler);

      //THEN
      verify(mockContactDao.saveContact(testContact));
      verify(mockConversationDao.saveConversation(testConversation));
      verify(mockDio.fetch(any));
      verify(mockErrorHandler.resolve(any));
    });

    test(
        'Given a non-recoverable error, then forward the error without re-registering a contact',
        () async {
      //GIVEN
      final testError = _createPublicApiError(500);

      //WHEN
      await interceptor.onError(testError, mockErrorHandler);

      //THEN
      verify(mockErrorHandler.next(any));
      verifyNever(mockAuthService.createNewContact(any, any));
      verifyNever(mockContactDao.saveContact(any));
      verifyNever(mockConversationDao.saveConversation(any));
    });

    test(
        'Given a recoverable error on a non-public-api path, then forward the error without re-registering a contact',
        () async {
      //GIVEN
      final requestOptions = RequestOptions(path: "/some/other/path");
      final testError = DioException(
          requestOptions: requestOptions,
          response:
              Response(statusCode: 404, requestOptions: requestOptions));

      //WHEN
      await interceptor.onError(testError, mockErrorHandler);

      //THEN
      verify(mockErrorHandler.next(any));
      verifyNever(mockAuthService.createNewContact(any, any));
      verifyNever(mockContactDao.saveContact(any));
      verifyNever(mockConversationDao.saveConversation(any));
    });
  });
}
