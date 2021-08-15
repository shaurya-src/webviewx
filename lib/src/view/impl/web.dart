import 'dart:convert';
import 'dart:async';
import 'dart:html' as html;
import 'dart:js' as js;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:http/http.dart' as http;

import 'package:webviewx/src/utils/constants.dart';
import 'package:webviewx/src/utils/dart_ui_fix.dart' as ui;
import 'package:webviewx/src/utils/utils.dart';

import 'package:webviewx/src/view/interface.dart' as view_interface;
import 'package:webviewx/src/controller/interface.dart' as ctrl_interface;

import 'package:webviewx/src/controller/impl/web.dart';

//TODO implement navigationDelegate and maybe the rest of controller's features from mobile (scroll, etc)

/// Web implementation
class WebViewXWidget extends StatefulWidget implements view_interface.WebViewXWidget {
  /// Initial content
  @override
  final String initialContent;

  /// Initial source type. Must match [initialContent]'s type.
  ///
  /// Example:
  /// If you set [initialContent] to '<p>hi</p>', then you should
  /// also set the [initialSourceType] accordingly, that is [SourceType.HTML].
  @override
  final SourceType initialSourceType;

  /// User-agent
  /// On web, this is only used when using [SourceType.URL_BYPASS]
  @override
  final String? userAgent;

  /// Widget width
  @override
  final double? width;

  /// Widget height
  @override
  final double? height;

  /// Callback which returns a referrence to the [WebViewXController]
  /// being created.
  @override
  final Function(ctrl_interface.WebViewXController controller)? onWebViewCreated;

  /// A set of [EmbeddedJsContent].
  ///
  /// You can define JS functions, which will be embedded into
  /// the HTML source (won't do anything on URL) and you can later call them
  /// using the controller.
  ///
  /// For more info, see [EmbeddedJsContent].
  @override
  final Set<EmbeddedJsContent> jsContent;

  /// A set of [DartCallback].
  ///
  /// You can define Dart functions, which can be called from the JS side.
  ///
  /// For more info, see [DartCallback].
  @override
  final Set<DartCallback> dartCallBacks;

  /// Boolean value to specify if should ignore all gestures that touch the webview.
  ///
  /// You can change this later from the controller.
  @override
  final bool ignoreAllGestures;

  /// Boolean value to specify if Javascript execution should be allowed inside the webview
  @override
  final JavascriptMode javascriptMode;

  /// This defines if media content(audio - video) should
  /// auto play when entering the page.
  @override
  final AutoMediaPlaybackPolicy initialMediaPlaybackPolicy;

  /// Callback for when the page starts loading.
  @override
  final void Function(String src)? onPageStarted;

  /// Callback for when the page has finished loading (i.e. is shown on screen).
  @override
  final void Function(String src)? onPageFinished;

  /// Callback for when something goes wrong in while page or resources load.
  @override
  final void Function(WebResourceError error)? onWebResourceError;

  /// Parameters specific to the web version.
  /// This may eventually be merged with [mobileSpecificParams],
  /// if all features become cross platform.
  @override
  final WebSpecificParams webSpecificParams;

  /// Parameters specific to the web version.
  /// This may eventually be merged with [webSpecificParams],
  /// if all features become cross platform.
  @override
  final MobileSpecificParams mobileSpecificParams;

  /// Constructor
  WebViewXWidget({
    Key? key,
    this.initialContent = 'about:blank',
    this.initialSourceType = SourceType.URL,
    this.userAgent,
    this.width,
    this.height,
    this.onWebViewCreated,
    this.jsContent = const {},
    this.dartCallBacks = const {},
    this.ignoreAllGestures = false,
    this.javascriptMode = JavascriptMode.unrestricted,
    this.initialMediaPlaybackPolicy =
        AutoMediaPlaybackPolicy.require_user_action_for_all_media_types,
    this.onPageStarted,
    this.onPageFinished,
    this.onWebResourceError,
    this.webSpecificParams = const WebSpecificParams(),
    this.mobileSpecificParams = const MobileSpecificParams(),
  }) : super(key: key);

  @override
  _WebViewXWidgetState createState() => _WebViewXWidgetState();
}

class _WebViewXWidgetState extends State<WebViewXWidget> {
  late html.IFrameElement iframe;
  late String iframeViewType;
  late StreamSubscription iframeOnLoadSubscription;
  late js.JsObject jsWindowObject;

  late WebViewXController webViewXController;

  // Pseudo state used to find out if the initial content has loaded
  late bool _initialContentLoaded;
  late bool _ignoreAllGestures;

  @override
  void initState() {
    super.initState();

    _initialContentLoaded = false;
    _ignoreAllGestures = widget.ignoreAllGestures;

    iframeViewType = _createViewType();
    iframe = _createIFrame();
    _registerView(viewType: iframeViewType);

    webViewXController = _createWebViewXController();

    if (widget.initialSourceType == SourceType.HTML ||
        widget.initialSourceType == SourceType.URL_BYPASS ||
        (widget.initialSourceType == SourceType.URL &&
            widget.initialContent == 'about:blank')) {
      _connectJsToFlutter(then: _callOnWebViewCreatedCallback);
    } else {
      _callOnWebViewCreatedCallback();
    }

    _registerIframeOnLoadCallback();

    // Allow the iframe to initialize.
    // Otherwise it will fail loading the initial content.
    Future.delayed(Duration.zero, () {
      _updateSource(webViewXController.value);
    });
  }

  void _registerView({required String? viewType}) {
    ui.platformViewRegistry.registerViewFactory(viewType!, (int viewId) {
      return iframe;
    });
  }

  WebViewXController _createWebViewXController() {
    return WebViewXController(
      initialContent: widget.initialContent,
      initialSourceType: widget.initialSourceType,
      ignoreAllGestures: _ignoreAllGestures,
      printDebugInfo: widget.webSpecificParams.printDebugInfo,
    )
      ..addListener(_handleChange)
      ..addIgnoreGesturesListener(_handleIgnoreGesturesChange);
  }

  // Keep js "window" object referrence, so we can call functions on it later.
  // This happens only if we use HTML (because you can't alter the source code
  // of some other webpage that you pass in using the URL param)
  //
  // Iframe viewType is used as a disambiguator.
  // Check function [embedWebIframeJsConnector] from [HtmlUtils] for details.
  void _connectJsToFlutter({VoidCallback? then}) {
    js.context['$JS_DART_CONNECTOR_FN$iframeViewType'] = (window) {
      jsWindowObject = window;

      /// Register dart callbacks one by one.
      for (var cb in widget.dartCallBacks) {
        jsWindowObject[cb.name] = cb.callBack;
      }

      // Register history callback
      jsWindowObject[WEB_ON_CLICK_INSIDE_IFRAME_CALLBACK] = (onClickCallbackObject) {
        _handleOnIframeClick(onClickCallbackObject);
      };

      webViewXController.connector = jsWindowObject;

      then?.call();
    };
  }

  void _registerIframeOnLoadCallback() {
    iframeOnLoadSubscription = iframe.onLoad.listen((event) {
      _printIfDebug('IFrame $iframeViewType has been (re)loaded.');

      //TODO
      // webViewXController.value.content is the un-synchronized value
      // replace it with the current value from the current history entry
      // (probably will just give up ValueNotifier or turn it into a ChangeNotifier)
      if (!_initialContentLoaded) {
        _initialContentLoaded = true;
        _callOnPageStartedCallback(webViewXController.value.source);
      } else {
        _callOnPageFinishedCallback(webViewXController.value.source);
      }
    });
  }

  void _callOnWebViewCreatedCallback() {
    widget.onWebViewCreated?.call(webViewXController);
  }

  void _callOnPageStartedCallback(String src) {
    widget.onPageStarted?.call(src);
  }

  void _callOnPageFinishedCallback(String src) {
    widget.onPageFinished?.call(src);
  }

  @override
  Widget build(BuildContext context) {
    Widget htmlElementView = SizedBox(
      width: widget.width,
      height: widget.height,
      child: _htmlElement(iframeViewType),
    );

    return _iframeIgnorePointer(
      child: htmlElementView,
      ignoring: _ignoreAllGestures,
    );
  }

  Widget _iframeIgnorePointer({
    required Widget child,
    bool ignoring = false,
  }) {
    return Stack(
      children: [
        child,
        ignoring
            ? Positioned.fill(
                child: PointerInterceptor(
                  child: Container(),
                ),
              )
            : SizedBox.shrink(),
      ],
    );
  }

  Widget _htmlElement(String iframeViewType) {
    return AbsorbPointer(
      child: RepaintBoundary(
        child: HtmlElementView(
          key: widget.key,
          viewType: iframeViewType,
        ),
      ),
    );
  }

  // This creates a unique String to be used as the view type of the HtmlElementView
  String _createViewType() {
    return HtmlUtils.buildIframeViewType();
  }

  html.IFrameElement _createIFrame() {
    final iframeElement = html.IFrameElement()
      ..id = 'id_$iframeViewType'
      ..name = 'name_$iframeViewType'
      ..style.border = 'none'
      ..width = widget.width!.toInt().toString()
      ..height = widget.height!.toInt().toString()
      ..allowFullscreen = widget.webSpecificParams.webAllowFullscreenContent;

    widget.webSpecificParams.additionalSandboxOptions.forEach(iframeElement.sandbox!.add);

    if (widget.javascriptMode == JavascriptMode.unrestricted) {
      iframeElement.sandbox!.add('allow-scripts');
    }

    final allow = widget.webSpecificParams.additionalAllowOptions;

    if (widget.initialMediaPlaybackPolicy == AutoMediaPlaybackPolicy.always_allow) {
      allow.add('autoplay');
    }

    iframeElement.allow = allow.reduce((curr, next) => '$curr; $next');

    return iframeElement;
  }

  // Called when WebViewXController updates it's value
  //
  // When the content changes from URL to HTML,
  // the connection must be remade in order to
  // add the connector to the controller (connector that
  // allows you to call JS methods)
  void _handleChange() {
    final newModel = webViewXController.value;

    _callOnPageStartedCallback(newModel.source);
    _updateSource(newModel);
  }

  void _handleIgnoreGesturesChange() {
    setState(() {
      _ignoreAllGestures = webViewXController.ignoresAllGestures;
    });
  }

  // Updates the source depending if it is HTML or URL
  void _updateSource(WebViewContent model) {
    final source = model.source;

    if (source.isEmpty) {
      _printIfDebug('Error: Cannot set empty source on webview');
      return;
    }

    switch (model.sourceType) {
      case SourceType.HTML:
        // ignore: unsafe_html
        iframe.srcdoc = HtmlUtils.preprocessSource(
          source,
          jsContent: widget.jsContent,
          windowDisambiguator: iframeViewType,
          forWeb: true,
        );
        break;
      case SourceType.URL:
      case SourceType.URL_BYPASS:
        if (source == 'about:blank') {
          // ignore: unsafe_html
          iframe.srcdoc = HtmlUtils.preprocessSource(
            '<br>',
            jsContent: widget.jsContent,
            windowDisambiguator: iframeViewType,
            forWeb: true,
          );
          break;
        }

        if (!source.startsWith(RegExp('http[s]?://', caseSensitive: false))) {
          _printIfDebug('Error: Invalid URL supplied for webview.');
          return;
        }

        if (model.sourceType == SourceType.URL) {
          iframe.contentWindow!.location.href = source;
        } else {
          _tryFetchRemoteSource(
            method: 'get',
            url: source,
            headers: model.headers,
          );
        }
        break;
    }
  }

  void _handleOnIframeClick(dynamic onClickCallbackObject) {
    if (onClickCallbackObject != null) {
      final dartObj = jsonDecode(onClickCallbackObject) as Map<String, dynamic>;
      final href = dartObj['href'];
      _printIfDebug(dartObj.toString());

      // (ㆆ_ㆆ)
      if (href == 'javascript:history.back()') {
        webViewXController.goBack();
        return;
      } else if (href == 'javascript:history.forward()') {
        webViewXController.goForward();
        return;
      }

      final method = dartObj['method'];
      final body = dartObj['body'];

      final bodyMap = body == null
          ? null
          : (<String, String>{}..addEntries(
              (body as List<dynamic>).map(
                (e) => MapEntry<String, String>(e[0].toString(), e[1].toString()),
              ),
            ));

      _tryFetchRemoteSource(
        method: method,
        url: href,
        headers: webViewXController.value.headers,
        body: bodyMap,
      );
    }
  }

  void _tryFetchRemoteSource({
    required String method,
    required String url,
    Map<String, String>? headers,
    Object? body,
  }) {
    _fetchPageSourceBypass(
      method: 'get',
      url: url,
      headers: headers,
      body: body,
    ).then((source) {
      _setPageSourceAfterBypass(url, source);

      webViewXController.webAddNewHistoryEntry(WebViewContent(
        source: url,
        sourceType: SourceType.URL_BYPASS,
        headers: headers,
        webPostRequestBody: body,
      ));
    }).catchError((e) {
      widget.onWebResourceError?.call(WebResourceError(
        description: 'Failed to fetch the page at $url\nError:\n$e',
        errorCode: WebResourceErrorType.connect.index,
        errorType: WebResourceErrorType.connect,
        domain: Uri.parse(url).authority,
        failingUrl: url,
      ));
    });
  }

  Future<String> _fetchPageSourceBypass({
    required String method,
    required String url,
    Map<String, String>? headers,
    Object? body,
  }) async {
    final proxyList = widget.webSpecificParams.proxyList;

    if (widget.userAgent != null) {
      (headers ??= <String, String>{}).putIfAbsent(
        USER_AGENT_HEADERS_KEY,
        () => widget.userAgent!,
      );
    }

    for (var i = 0; i < proxyList.length; i++) {
      final proxy = proxyList[i];
      final proxiedUri = Uri.parse(proxy.buildProxyUrl(url));

      Future<http.Response> request;

      if (method == 'get') {
        request = http.get(proxiedUri, headers: headers);
      } else {
        request = http.post(proxiedUri, headers: headers, body: body);
      }

      try {
        final response = await request;
        return proxy.extractPageSource(response.body);
      } catch (e) {
        print('Failed to fetch the page at $url from proxy ${proxy.runtimeType}.');

        if (i == proxyList.length - 1) {
          return Future.error(
            'None of the provided proxies were able to fetch the given page.',
          );
        }

        continue;
      }
    }

    return Future.error('Bad state');
  }

  void _setPageSourceAfterBypass(String pageUrl, String pageSource) {
    final replacedPageSource = HtmlUtils.embedInHtmlSource(
      source: pageSource,
      whatToEmbed: '''
      <base href="$pageUrl">
      <script>

      document.addEventListener('click', e => {
        if (frameElement && document.activeElement && document.activeElement.href) {
          e.preventDefault()

          var returnedObject = JSON.stringify({method: 'get', href: document.activeElement.href});
          frameElement.contentWindow.$WEB_ON_CLICK_INSIDE_IFRAME_CALLBACK && frameElement.contentWindow.$WEB_ON_CLICK_INSIDE_IFRAME_CALLBACK(returnedObject)
        }
      })
      document.addEventListener('submit', e => {
        if (frameElement && document.activeElement && document.activeElement.form && document.activeElement.form.action) {
          e.preventDefault()

          if (document.activeElement.form.method === 'post') {
            var formData = new FormData(document.activeElement.form);
            
            var returnedObject = JSON.stringify({method: 'post', href: document.activeElement.form.action, body: [...formData]});
            frameElement.contentWindow.$WEB_ON_CLICK_INSIDE_IFRAME_CALLBACK && frameElement.contentWindow.$WEB_ON_CLICK_INSIDE_IFRAME_CALLBACK(returnedObject)
          } else {
            var urlWithQueryParams = document.activeElement.form.action + '?' + new URLSearchParams(new FormData(document.activeElement.form))

            var returnedObject = JSON.stringify({method: 'get', href: urlWithQueryParams});
            frameElement.contentWindow.$WEB_ON_CLICK_INSIDE_IFRAME_CALLBACK && frameElement.contentWindow.$WEB_ON_CLICK_INSIDE_IFRAME_CALLBACK(returnedObject)
          }
        }
      })
      </script>
      ''',
      position: EmbedPosition.BELOW_HEAD_OPEN_TAG,
    );

    // ignore: unsafe_html
    iframe.srcdoc = HtmlUtils.preprocessSource(
      replacedPageSource,
      jsContent: widget.jsContent,
      windowDisambiguator: iframeViewType,
      forWeb: true,
    );
  }

  void _printIfDebug(String text) {
    if (widget.webSpecificParams.printDebugInfo) {
      print(text);
    }
  }

  @override
  void dispose() {
    iframeOnLoadSubscription.cancel();
    webViewXController.removeListener(_handleChange);
    webViewXController.removeIgnoreGesturesListener(
      _handleIgnoreGesturesChange,
    );
    super.dispose();
  }
}
