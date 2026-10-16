import 'package:url_launcher/url_launcher.dart';

/// Not on the web: there's no browser download, so say so.
Future<void> saveTextFile(String fileName, String text, String mimeType) async {
  throw UnsupportedError('Saving files is only available in the web app.');
}

Future<void> openUrl(String url) async {
  if (!await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)) {
    throw StateError("Couldn't open the link.");
  }
}
