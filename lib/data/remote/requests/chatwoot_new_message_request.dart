import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

part 'chatwoot_new_message_request.g.dart';

@JsonSerializable(explicitToJson: true)
class ChatwootNewMessageRequest extends Equatable {
  @JsonKey()
  final String content;
  @JsonKey(name: "echo_id")
  final String echoId;

  ///Local file paths of attachments (images/docs) to upload with the message.
  ///Sent as multipart `attachments[]`. Not part of the JSON body.
  @JsonKey(includeFromJson: false, includeToJson: false)
  final List<String> attachmentPaths;

  ChatwootNewMessageRequest({
    required this.content,
    required this.echoId,
    this.attachmentPaths = const [],
  });

  ///Whether this request carries file attachments and must be sent as multipart.
  bool get hasAttachments => attachmentPaths.isNotEmpty;

  @override
  List<Object> get props => [content, echoId, attachmentPaths];

  factory ChatwootNewMessageRequest.fromJson(Map<String, dynamic> json) =>
      _$ChatwootNewMessageRequestFromJson(json);

  Map<String, dynamic> toJson() => _$ChatwootNewMessageRequestToJson(this);
}
