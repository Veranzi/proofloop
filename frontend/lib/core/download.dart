/// Save text as a file in the browser, or open a URL in a new tab.
library;

export 'download_stub.dart' if (dart.library.js_interop) 'download_web.dart';
