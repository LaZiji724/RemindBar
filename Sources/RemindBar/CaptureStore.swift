import Foundation
import RemindCore

/// Calibration samples (never the user's secrets) written next to the app's data, readable only by the user.
enum CaptureStore {
    static var directory: URL {
        AppModel.supportDirectory().appendingPathComponent("capture", isDirectory: true)
    }

    private static func prepare() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    /// Removes every calibration sample (they contain course and assignment names).
    @discardableResult
    static func clear() -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path) else { return true }
        return (try? FileManager.default.removeItem(at: directory)) != nil
    }

    static var hasSamples: Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).isEmpty == false
    }

    static func append(line: String, to file: String) {
        prepare()
        let url = directory.appendingPathComponent(file)
        let data = Data((Redactor.scrub(line) + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    static func write(_ text: String, to file: String) {
        prepare()
        let url = directory.appendingPathComponent(file)
        try? Redactor.scrub(text).write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Injected into the 课堂派 web app while calibrating: logs the read-only API calls the page itself makes
/// (URL, request body, response) so the adapter can be written against real traffic. Headers are never recorded.
enum KetangpaiCapture {
    static let script = #"""
    (function () {
      if (window.__rbCapture) { return; }
      window.__rbCapture = true;
      var wanted = /openapiv5\.ketangpai\.com\/*(Futurev2|FutureV2|HomeworkApi|CourseApi|todoApi|StudentApi|Todo)/i;
      function post(entry) {
        try { window.webkit.messageHandlers.rbcapture.postMessage(JSON.stringify(entry)); } catch (e) {}
      }
      var open = XMLHttpRequest.prototype.open;
      var send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.__rb = { method: method, url: String(url) };
        return open.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function (body) {
        var meta = this.__rb;
        var xhr = this;
        if (meta && wanted.test(meta.url)) {
          xhr.addEventListener('load', function () {
            var text = '';
            try { text = String(xhr.responseText || ''); } catch (e) {}
            post({ via: 'xhr', method: meta.method, url: meta.url,
                   request: typeof body === 'string' ? body.slice(0, 2000) : null,
                   status: xhr.status, response: text.slice(0, 30000) });
          });
        }
        return send.apply(this, arguments);
      };
      var nativeFetch = window.fetch;
      if (nativeFetch) {
        window.fetch = function (input, init) {
          var url = typeof input === 'string' ? input : (input && input.url) || '';
          var promise = nativeFetch.apply(this, arguments);
          if (wanted.test(url)) {
            promise.then(function (response) {
              response.clone().text().then(function (text) {
                post({ via: 'fetch', method: (init && init.method) || 'GET', url: url,
                       request: init && typeof init.body === 'string' ? init.body.slice(0, 2000) : null,
                       status: response.status, response: text.slice(0, 30000) });
              });
            });
          }
          return promise;
        };
      }
    })();
    """#
}
