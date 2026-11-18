//
//  WebView.swift — Cyclette
//  Mostra la web app pubblicata su GitHub Pages dentro l'app (WKWebView, il motore di Safari)
//  e le aggiunge il Bluetooth (ble-polyfill.js + BLEBridge).
//

import SwiftUI
import WebKit
import UIKit

struct WebView: UIViewRepresentable {
    let url: URL
    let ble: BLEBridge

    func makeCoordinator() -> Coordinator { Coordinator(url: url, ble: ble) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true               // video dentro la pagina, non a tutto schermo di sistema
        config.mediaTypesRequiringUserActionForPlayback = []  // i percorsi possono partire da soli, anche con l'audio
        config.websiteDataStore = .default()                  // profili e storico restano salvati

        let content = WKUserContentController()
        if let path = Bundle.main.path(forResource: "ble-polyfill", ofType: "js"),
           let source = try? String(contentsOfFile: path, encoding: .utf8) {
            content.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        } else {
            assertionFailure("ble-polyfill.js non è nel progetto: aggiungilo al target Cyclette")
        }
        content.add(WeakScriptHandler(ble), name: "ble")
        content.add(WeakScriptHandler(ble), name: "share")
        config.userContentController = content

        let web = WKWebView(frame: .zero, configuration: config)
        let bg = UIColor(red: 0.043, green: 0.059, blue: 0.078, alpha: 1)
        web.isOpaque = false
        web.backgroundColor = bg
        web.scrollView.backgroundColor = bg
        web.scrollView.contentInsetAdjustmentBehavior = .never  // la pagina gestisce da sé notch e bordi (safe area)
        web.scrollView.bounces = false
        web.allowsBackForwardNavigationGestures = false
        web.allowsLinkPreview = false
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        if #available(iOS 16.4, *) { web.isInspectable = true }  // debug da Safari sul Mac (Sviluppo → iPhone)

        ble.webView = web
        context.coordinator.webView = web
        UIApplication.shared.isIdleTimerDisabled = true        // lo schermo non si spegne durante l'allenamento
        web.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 20))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, @preconcurrency WKNavigationDelegate, @preconcurrency WKUIDelegate {
        let url: URL
        let ble: BLEBridge
        weak var webView: WKWebView?
        private var triedCache = false

        init(url: URL, ble: BLEBridge) {
            self.url = url
            self.ble = ble
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(becameActive),
                                                   name: UIApplication.didBecomeActiveNotification, object: nil)
        }

        @objc private func becameActive() { UIApplication.shared.isIdleTimerDisabled = true }

        // nuova pagina (avvio, ricarica, aggiornamento): il Bluetooth riparte pulito
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            ble.resetForNewPage()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            triedCache = false
        }

        // Senza internet: si usa l'ultima copia salvata della pagina (stesso indirizzo = stessi dati)
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            if triedCache { showOffline(webView); return }
            triedCache = true
            webView.load(URLRequest(url: url, cachePolicy: .returnCacheDataDontLoad, timeoutInterval: 10))
        }

        private func showOffline(_ webView: WKWebView) {
            let html = """
            <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
            <style>body{background:#0b0f14;color:#e8edf2;font:17px -apple-system;display:grid;place-items:center;height:100vh;margin:0;text-align:center}
            a{display:inline-block;margin-top:18px;padding:12px 22px;border-radius:14px;background:#0a84ff;color:#fff;text-decoration:none;font-weight:700}</style></head>
            <body><div>🚴<br><br><b>Serve internet per il primo avvio</b><br>Collegati al Wi-Fi e riprova.<br>
            <a href="\(url.absoluteString)">Riprova</a></div></body></html>
            """
            webView.loadHTMLString(html, baseURL: nil)
        }

        // Il contenuto della pagina si è chiuso (memoria): si ricarica
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.load(URLRequest(url: url))
        }

        // Link verso altri siti: si aprono in Safari
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               navigationAction.targetFrame?.isMainFrame == true,
               let u = navigationAction.request.url, let host = u.host, host != url.host,
               u.scheme == "http" || u.scheme == "https" {
                UIApplication.shared.open(u)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // target="_blank" / window.open: in Safari
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let u = navigationAction.request.url { UIApplication.shared.open(u) }
            return nil
        }

        // alert() e confirm() della pagina (di solito l'app usa le sue finestre, questi sono di riserva)
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
            if !present(a, from: webView) { completionHandler() }
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "Annulla", style: .cancel) { _ in completionHandler(false) })
            a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
            if !present(a, from: webView) { completionHandler(false) }
        }

        private func present(_ vc: UIViewController, from webView: WKWebView) -> Bool {
            guard var top = webView.window?.rootViewController else { return false }
            while let next = top.presentedViewController { top = next }
            top.present(vc, animated: true)
            return true
        }
    }
}

/// Evita che WKUserContentController tenga in vita il ponte Bluetooth per sempre
@MainActor
final class WeakScriptHandler: NSObject, @preconcurrency WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
