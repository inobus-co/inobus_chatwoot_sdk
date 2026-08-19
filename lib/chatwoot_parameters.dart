import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';

class ChatwootParameters extends Equatable {
  final bool isPersistenceEnabled;
  final String baseUrl;
  final String clientInstanceKey;
  final String inboxIdentifier;
  final String? userIdentifier;
  final List<Interceptor> dioInterceptors;

  ChatwootParameters(
      {required this.isPersistenceEnabled,
      required this.baseUrl,
      required this.inboxIdentifier,
      required this.clientInstanceKey,
      this.userIdentifier,
      this.dioInterceptors = const []});

  @override
  List<Object?> get props => [
        isPersistenceEnabled,
        baseUrl,
        clientInstanceKey,
        inboxIdentifier,
        userIdentifier
      ];
}
