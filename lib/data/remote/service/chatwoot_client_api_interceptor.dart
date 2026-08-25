import 'package:inobus_chatwoot_sdk/data/local/entity/chatwoot_contact.dart';
import 'package:inobus_chatwoot_sdk/data/local/entity/chatwoot_conversation.dart';
import 'package:inobus_chatwoot_sdk/data/local/local_storage.dart';
import 'package:inobus_chatwoot_sdk/data/remote/service/chatwoot_client_auth_service.dart';
import 'package:dio/dio.dart';
import 'package:synchronized/synchronized.dart' as synchronized;

///Intercepts network requests and attaches inbox identifier, contact identifiers, conversation identifiers
class ChatwootClientApiInterceptor extends Interceptor {
  static const INTERCEPTOR_INBOX_IDENTIFIER_PLACEHOLDER = "{INBOX_IDENTIFIER}";
  static const INTERCEPTOR_CONTACT_IDENTIFIER_PLACEHOLDER =
      "{CONTACT_IDENTIFIER}";
  static const INTERCEPTOR_CONVERSATION_IDENTIFIER_PLACEHOLDER =
      "{CONVERSATION_IDENTIFIER}";

  ///Marks a request that has already been retried after a contact reset, so a
  ///persistent failure doesn't cause an infinite retry loop.
  static const _retriedAfterResetKey = "chatwoot_retried_after_reset";

  ///Key under which the service stashes attachment file paths on a request's
  ///`extra`, so a consumed multipart body can be rebuilt and resent after a
  ///contact reset.
  static const attachmentPathsKey = "chatwoot_attachment_paths";

  final String _inboxIdentifier;
  final LocalStorage _localStorage;
  final ChatwootClientAuthService _authService;
  final requestLock = synchronized.Lock();
  final responseLock = synchronized.Lock();

  ChatwootClientApiInterceptor(
    this._inboxIdentifier,
    this._localStorage,
    this._authService,
  );

  /// Creates a new contact and conversation when no persisted contact is found when an api call is made
  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    await requestLock.synchronized(() async {
      RequestOptions newOptions = options;
      ChatwootContact? contact = _localStorage.contactDao.getContact();
      ChatwootConversation? conversation = _localStorage.conversationDao
          .getConversation();

      if (contact == null) {
        // create new contact from user if no token found
        contact = await _authService.createNewContact(
          _inboxIdentifier,
          _localStorage.userDao.getUser(),
        );
        conversation = await _authService.createNewConversation(
          _inboxIdentifier,
          contact.contactIdentifier!,
        );
        await _localStorage.conversationDao.saveConversation(conversation);
        await _localStorage.contactDao.saveContact(contact);
      }

      if (conversation == null) {
        conversation = await _authService.createNewConversation(
          _inboxIdentifier,
          contact.contactIdentifier!,
        );
        await _localStorage.conversationDao.saveConversation(conversation);
      }

      newOptions.path = _resolvePath(newOptions.path, contact, conversation);

      handler.next(newOptions);
    });
  }

  /// Re-registers a stale contact and retries the failed request.
  ///
  /// When the persisted contact or conversation has been deleted on the chatwoot
  /// server, requests fail with 401 (Unauthorized), 403 (Forbidden) or 404 (Not
  /// Found). Because dio's default `validateStatus` throws on these codes, they
  /// surface here in [onError] (not [onResponse]). We wipe the stale
  /// contact/conversation/messages, register a fresh contact + conversation and
  /// resend the original request with the new identifiers so the caller succeeds
  /// transparently. The user is kept, since its identifier + identifier_hash are
  /// needed to recreate the contact.
  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final statusCode = err.response?.statusCode;
    final isRecoverable =
        statusCode == 401 || statusCode == 403 || statusCode == 404;
    final isPublicApiCall = err.requestOptions.path.contains(
      "/public/api/v1/inboxes/",
    );
    final alreadyRetried =
        err.requestOptions.extra[_retriedAfterResetKey] == true;

    if (!isRecoverable || !isPublicApiCall || alreadyRetried) {
      handler.next(err);
      return;
    }

    try {
      final response = await responseLock.synchronized(() async {
        var contact = _localStorage.contactDao.getContact();
        var conversation = _localStorage.conversationDao.getConversation();

        // Recreate only when the cached contact is the one that just failed. If a
        // concurrent recovery already refreshed it, reuse the new one instead.
        final needsRecreation =
            contact == null ||
            conversation == null ||
            err.requestOptions.path.contains(contact.contactIdentifier ?? "");

        if (needsRecreation) {
          await _localStorage.contactDao.deleteContact();
          await _localStorage.conversationDao.deleteConversation();
          await _localStorage.messagesDao.clear();

          contact = await _authService.createNewContact(
            _inboxIdentifier,
            _localStorage.userDao.getUser(),
          );
          conversation = await _authService.createNewConversation(
            _inboxIdentifier,
            contact.contactIdentifier!,
          );
          await _localStorage.contactDao.saveContact(contact);
          await _localStorage.conversationDao.saveConversation(conversation);
        }

        // A multipart body is consumed once sent, so rebuild it from the original
        // attachment paths (stashed in extra by the service). Without those paths
        // it can't be resent — the cache is already refreshed, so let the caller
        // retry the send itself.
        var retryData = err.requestOptions.data;
        if (retryData is FormData) {
          final rebuilt =
              await _rebuildMultipartBody(retryData, err.requestOptions.extra);
          if (rebuilt == null) return null;
          retryData = rebuilt;
        }

        final retryOptions = err.requestOptions
          ..path = _resolvePath(err.requestOptions.path, contact, conversation)
          ..data = retryData
          ..extra = {...err.requestOptions.extra, _retriedAfterResetKey: true};

        // authService's dio has no ChatwootClientApiInterceptor, so this retry
        // won't recurse back into onRequest/onError.
        return _authService.dio.fetch(retryOptions);
      });

      if (response == null) {
        handler.next(err);
      } else {
        handler.resolve(response);
      }
    } on DioException catch (e) {
      handler.next(e);
    } catch (_) {
      handler.next(err);
    }
  }

  ///Rebuilds a fresh multipart body for a retry, reusing the original text fields
  ///(content, echo_id) and re-reading each attachment from its file path (stashed
  ///in [extra] under [attachmentPathsKey]). Returns null when the paths are
  ///missing, in which case the body can't be resent.
  Future<FormData?> _rebuildMultipartBody(
      FormData original, Map<String, dynamic> extra) async {
    final paths = (extra[attachmentPathsKey] as List?)?.cast<String>();
    if (paths == null || paths.isEmpty) return null;

    final rebuilt = FormData();
    rebuilt.fields.addAll(original.fields);
    for (final path in paths) {
      rebuilt.files.add(MapEntry(
        "attachments[]",
        await MultipartFile.fromFile(path, filename: path.split("/").last),
      ));
    }
    return rebuilt;
  }

  ///Resolves the inbox/contact/conversation segments in [path].
  ///
  ///First the `{…}` placeholders are substituted (fresh request from the
  ///service). Then, for an already-resolved path being retried after a contact
  ///reset, the `/contacts/…` and `/conversations/…` segments are rewritten by
  ///shape so a stale identifier is swapped for the freshly created one.
  String _resolvePath(
    String path,
    ChatwootContact contact,
    ChatwootConversation conversation,
  ) {
    return path
        .replaceAll(INTERCEPTOR_INBOX_IDENTIFIER_PLACEHOLDER, _inboxIdentifier)
        .replaceAll(
          INTERCEPTOR_CONTACT_IDENTIFIER_PLACEHOLDER,
          contact.contactIdentifier!,
        )
        .replaceAll(
          INTERCEPTOR_CONVERSATION_IDENTIFIER_PLACEHOLDER,
          "${conversation.id}",
        )
        .replaceAll(
          RegExp(r'/contacts/[^/]+'),
          "/contacts/${contact.contactIdentifier}",
        )
        .replaceAll(
          RegExp(r'/conversations/[^/]+'),
          "/conversations/${conversation.id}",
        );
  }
}

extension Range on num {
  bool isBetween(num from, num to) {
    return from < this && this < to;
  }
}
