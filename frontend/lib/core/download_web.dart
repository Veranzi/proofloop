import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Triggers a browser download of [text] as [fileName].
Future<void> saveTextFile(String fileName, String text, String mimeType) async {
  final blob = web.Blob([text.toJS].toJS, web.BlobPropertyBag(type: mimeType));
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = fileName;
  web.document.body!.append(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}

/// Opens a signed download or view link in a new tab.
Future<void> openUrl(String url) async {
  web.window.open(url, '_blank', 'noopener');
}
