import 'dart:convert';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:webviewx/src/utils/constants.dart';

import 'embedded_js_content.dart';

/// Specifies where to embed ("burn") the javascript inside the HTML source
enum EmbedPosition {
  BELOW_BODY_OPEN_TAG,
  ABOVE_BODY_CLOSE_TAG,
  BELOW_HEAD_OPEN_TAG,
  ABOVE_HEAD_CLOSE_TAG,
}

/// HTML utils: wrappers, parsers, splitters etc.
class HtmlUtils {
  /// Checks if the source looks like HTML
  static bool isFullHtmlPage(String src) {
    var _src = src.trim().toLowerCase();
    return _src.startsWith(RegExp(r'<!DOCTYPE html>', caseSensitive: false)) &&
        // I didn't forget the closing bracket here.
        // Html opening tag may also have some random attributes.
        _src.contains(RegExp(r'<html', caseSensitive: false)) &&
        _src.contains(RegExp(r'</html>', caseSensitive: false));
  }

  /// Wraps markup in HTML tags
  static String wrapHtml(String src) {
    return '''
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Iframe</title>
    </head>
    <body>
    $src
    </body>
    </html>
    ''';
  }

  /// This is where the magic happens.
  ///
  /// Depending on the params passed to it, this function
  /// embeds ("burns") javascript functions inside the HTML source, wraps it
  /// and/or URI-encodes it.
  static String preprocessSource(
    String src, {
    Set<EmbeddedJsContent> jsContent = const {},
    bool forWeb = false,
    bool encodeHtml = false,
    String? windowDisambiguator,
  }) {
    var _src = src;

    if (!isFullHtmlPage(_src)) {
      _src = wrapHtml(_src);
    }

    if (forWeb) {
      _src = embedWebIframeJsConnector(_src, windowDisambiguator!);
    }

    if (jsContent.isNotEmpty) {
      var jsContentStrings = <String>{};
      for (var jsToEmbed in jsContent) {
        if (jsToEmbed.js != null) {
          jsContentStrings.add(jsToEmbed.js!);
        } else {
          if (forWeb && jsToEmbed.webJs != null) {
            jsContentStrings.add(jsToEmbed.webJs!);
          } else {
            jsContentStrings.add(jsToEmbed.mobileJs!);
          }
        }
      }
      _src = embedJsInHtmlSource(_src, jsContentStrings);
    }

    if (encodeHtml) {
      _src = encodeHtmlToURI(_src);
    }

    return _src;
  }

  /// Encodes HTML to URI
  static String encodeHtmlToURI(String src) {
    return Uri.dataFromString(
      src,
      mimeType: 'text/html',
      encoding: Encoding.getByName('utf-8'),
    ).toString();
  }

  /// Turns URI-encoded HTML "data:" to pure human-readable HTML
  static String dataUriToHtml(String data) {
    return Uri.decodeFull(data).replaceFirst(RegExp(r'^data:.+,'), '');
  }

  /// Retrieves basename from a string path
  static String getPathBaseName(String path) {
    return p.basename(path);
  }

  /// Encodes an image (as a list of bytes) to a base64 embedded HTML image
  ///
  /// Pretty raw, I know, but it works
  static String encodeImageAsEmbeddedBase64(String fileName, Uint8List imageBytes) {
    var imageWidth = '100%';
    var base64Image = '<img width=\"$imageWidth\" src=\"data:image/png;base64, '
        '${base64Encode(imageBytes)}\" data-filename=\"$fileName\">';
    return base64Image;
  }

  /// Wraps an image link with "img" tags
  static String wrapImageLinkWithImgTag(String imageLink) {
    return '<img src=\"$imageLink\">';
  }

  /// Builds a js function using the name and params passed to it.
  ///
  /// Example call: buildJsFunction('say', ["hello", "world"]);
  /// Result: say('hello', 'world')
  static String buildJsFunction(String name, List<dynamic> params) {
    var args = '';
    if (params.isEmpty) {
      return name + '()';
    }
    params.forEach((param) {
      args += addSingleQuotes(param.toString());
      args += ',';
    });
    args = args.substring(0, args.length - 1);
    var function = name + '(' + '$args' + ')';

    return function;
  }

  /// Adds single quotes to the param
  static String addSingleQuotes(String data) {
    return "'$data'";
  }

  /// Embeds js in the HTML source at the specified position
  /// This is just a helper function for the generic [embedInHtmlSource] function
  static String embedJsInHtmlSource(
    String source,
    Set<String> jsContents, {
    EmbedPosition position = EmbedPosition.ABOVE_BODY_CLOSE_TAG,
  }) {
    var newLine = '\n';
    var scriptOpenTag = '<script>';
    var scriptCloseTag = '</script>';
    var jsContent = jsContents.reduce((prev, elem) => prev + newLine * 2 + elem);

    var whatToEmbed = newLine +
        scriptOpenTag +
        newLine +
        jsContent +
        newLine +
        scriptCloseTag +
        newLine;

    return embedInHtmlSource(
      source: source,
      whatToEmbed: whatToEmbed,
      position: position,
    );
  }

  /// Inject `toInject` as a child of the specified `htmlTag`.
  /// The `htmlTag` can be, for example, `head` or `body`.
  ///
  /// The way it works is that it will take the whole `htmlTag`, including
  /// it's attributes (if any), and it will append `toInject` to it, such as the original
  /// `htmlTag` will now have `toInject` as it's first child (by child we mean HTML DOM child)
  static String injectAsChildOf(String htmlTag, String source, String toInject) {
    final replaceSpot = '<$htmlTag([^>]*)>';
    return source.replaceFirstMapped(RegExp(replaceSpot, caseSensitive: false), (match) {
      return '<$htmlTag${match.group(1)!}> \n$toInject';
    });
  }

  /// Generic function to embed anything inside HTML source, at the specified position.
  static String embedInHtmlSource({
    required String source,
    required String whatToEmbed,
    required EmbedPosition position,
  }) {
    switch (position) {
      case EmbedPosition.BELOW_HEAD_OPEN_TAG:
        return injectAsChildOf('head', source, whatToEmbed);
      case EmbedPosition.BELOW_BODY_OPEN_TAG:
        return injectAsChildOf('body', source, whatToEmbed);
      case EmbedPosition.ABOVE_HEAD_CLOSE_TAG:
        final indexToSplit = source.indexOf('</head>');
        final splitSource1 = source.substring(0, indexToSplit);
        final splitSource2 = source.substring(indexToSplit);

        return splitSource1 + whatToEmbed + '\n' + splitSource2;
      case EmbedPosition.ABOVE_BODY_CLOSE_TAG:
        final indexToSplit = source.indexOf('</body>');
        final splitSource1 = source.substring(0, indexToSplit);
        final splitSource2 = source.substring(indexToSplit);

        return splitSource1 + whatToEmbed + '\n' + splitSource2;
    }
  }

  /// (WEB ONLY): Embeds a js-to-dart connector in the HTML source,
  /// allowing us to talk to js on web.
  ///
  /// Will embed an individual connector for each iframe (if more than 1) on
  /// the same screen, using a little trick to disambiguate which connector belongs
  /// to which iframe.
  ///
  /// This (also the [buildIframeViewType] function) was needed because, without it,
  /// you can still show up multiple iframes, but you can only call JS functions on
  /// the last one of them. This is because the last one that renders on the screen
  /// will also call latter iframes' "connect_js_to_flutter" callbacks, thus messing up
  /// others' functions and, well, everything.
  static String embedWebIframeJsConnector(String source, String windowDisambiguator) {
    return embedJsInHtmlSource(
      source,
      {
        'parent.$JS_DART_CONNECTOR_FN$windowDisambiguator && parent.$JS_DART_CONNECTOR_FN$windowDisambiguator(window)'
      },
      position: EmbedPosition.ABOVE_HEAD_CLOSE_TAG,
    );
  }

  /// Builds a unique string to use as windowDisambiguator for
  /// when using multiple iframes in the same window.
  ///
  /// The '-' replace had to be done in order to follow the javascript syntax notation.
  static String buildIframeViewType() {
    var iframeId = '_' + Uuid().v4().replaceAll('-', '_');
    var viewType = '_iframe$iframeId';
    return viewType;
  }

  /// Removes surrounding quotes around a string, if any
  static String unQuoteJsResponseIfNeeded(String rawJsResponse) {
    if ((rawJsResponse.startsWith('\"') && rawJsResponse.endsWith('\"')) ||
        (rawJsResponse.startsWith('\'') && rawJsResponse.endsWith('\''))) {
      return rawJsResponse.substring(1, rawJsResponse.length - 1);
    }
    return rawJsResponse;
  }
}
