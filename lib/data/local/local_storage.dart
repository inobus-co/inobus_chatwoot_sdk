import 'package:chatwoot_sdk/data/local/dao/chatwoot_contact_dao.dart';
import 'package:chatwoot_sdk/data/local/dao/chatwoot_conversation_dao.dart';
import 'package:chatwoot_sdk/data/local/dao/chatwoot_messages_dao.dart';
import 'package:chatwoot_sdk/data/local/dao/chatwoot_user_dao.dart';
import 'package:chatwoot_sdk/data/local/entity/chatwoot_conversation.dart';
import 'package:chatwoot_sdk/data/remote/responses/chatwoot_event.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'entity/chatwoot_contact.dart';
import 'entity/chatwoot_message.dart';
import 'entity/chatwoot_user.dart';

const CHATWOOT_CONTACT_HIVE_TYPE_ID = 100;
const CHATWOOT_CONVERSATION_HIVE_TYPE_ID = 101;
const CHATWOOT_MESSAGE_HIVE_TYPE_ID = 102;
const CHATWOOT_USER_HIVE_TYPE_ID = 103;
const CHATWOOT_EVENT_USER_HIVE_TYPE_ID = 104;

const kDefaultChatwootHiveTypeIdBase = 100;

///Wraps a generated [TypeAdapter] so its [typeId] can be assigned at runtime,
///allowing the host app to choose a typeId range that doesn't clash with its own.
class _BasedTypeAdapter<T> extends TypeAdapter<T> {
  _BasedTypeAdapter(this.typeId, this._delegate);

  @override
  final int typeId;
  final TypeAdapter<T> _delegate;

  @override
  T read(BinaryReader reader) => _delegate.read(reader);

  @override
  void write(BinaryWriter writer, T obj) => _delegate.write(writer, obj);
}

class LocalStorage {
  ChatwootUserDao userDao;
  ChatwootConversationDao conversationDao;
  ChatwootContactDao contactDao;
  ChatwootMessagesDao messagesDao;

  LocalStorage({
    required this.userDao,
    required this.conversationDao,
    required this.contactDao,
    required this.messagesDao,
  });

  static int? _registeredTypeIdBase;

  ///Registers all chatwoot hive adapters starting from [typeIdBase]
  ///(contact, conversation, message, user and event user take [typeIdBase]..[typeIdBase] + 4).
  ///
  ///Can be called from the host app (e.g. in `main()`) before [ChatwootClient.create]
  ///to pick a typeId range that doesn't clash with the app's own adapters.
  ///Safe to call multiple times; only the first call registers.
  static void registerHiveAdapters({
    int typeIdBase = kDefaultChatwootHiveTypeIdBase,
  }) {
    if (_registeredTypeIdBase != null) return;

    void register<T>(int typeId, TypeAdapter<T> delegate) {
      if (!Hive.isAdapterRegistered(typeId)) {
        Hive.registerAdapter(_BasedTypeAdapter<T>(typeId, delegate));
      }
    }

    register<ChatwootContact>(typeIdBase + 0, ChatwootContactAdapter());
    register<ChatwootConversation>(
        typeIdBase + 1, ChatwootConversationAdapter());
    register<ChatwootMessage>(typeIdBase + 2, ChatwootMessageAdapter());
    register<ChatwootUser>(typeIdBase + 3, ChatwootUserAdapter());
    register<ChatwootEventMessageUser>(
        typeIdBase + 4, ChatwootEventMessageUserAdapter());

    _registeredTypeIdBase = typeIdBase;
  }

  static Future<void> openDB({
    int typeIdBase = kDefaultChatwootHiveTypeIdBase,
    void Function()? onInitializeHive,
  }) async {
    if (onInitializeHive == null) {
      await Hive.initFlutter();
      registerHiveAdapters(typeIdBase: typeIdBase);
    } else {
      onInitializeHive();
    }

    await PersistedChatwootContactDao.openDB();
    await PersistedChatwootConversationDao.openDB();
    await PersistedChatwootMessagesDao.openDB();
    await PersistedChatwootUserDao.openDB();
  }

  Future<void> clear({bool clearChatwootUserStorage = true}) async {
    await conversationDao.deleteConversation();
    await messagesDao.clear();
    if (clearChatwootUserStorage) {
      await userDao.deleteUser();
      await contactDao.deleteContact();
    }
  }

  Future<void> clearAll() async {
    await conversationDao.clearAll();
    await contactDao.clearAll();
    await messagesDao.clearAll();
    await userDao.clearAll();
  }

  dispose() {
    userDao.onDispose();
    conversationDao.onDispose();
    contactDao.onDispose();
    messagesDao.onDispose();
  }
}
