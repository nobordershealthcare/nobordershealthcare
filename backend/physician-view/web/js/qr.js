// qr.js — QR scanner for desktop browsers using the BarcodeDetector Web API.
//
// Used when the clinician is at a desktop workstation and needs to scan
// the patient's phone screen via a webcam or built-in camera.
//
// The primary flow (phone camera scans QR → OS opens URL) does NOT use this.
// This is a secondary path for desktop clinicians only.
//
// API: window.QRScanner.open(callback)
//      callback(result: string | null)
//      result is the decoded QR URL string, or null if cancelled.
//
// Browser support:
//   BarcodeDetector — Chrome 83+, Edge 83+, Samsung Internet 14+
//   Falls back to a "not supported" message on Firefox / Safari.

'use strict';

(function (global) {

  // Check once at load time.
  const SUPPORTED = typeof BarcodeDetector !== 'undefined';

  let _stream      = null;  // active MediaStream
  let _animFrame   = null;  // requestAnimationFrame handle
  let _callback    = null;  // caller's callback
  let _detector    = null;  // BarcodeDetector instance

  /**
   * Open the QR scanner modal.
   * @param {function(string|null): void} callback
   */
  function open(callback) {
    _callback = callback;

    if (!SUPPORTED) {
      callback(null);
      return;
    }

    const modal = document.getElementById('qr-modal');
    if (!modal) {
      callback(null);
      return;
    }

    modal.classList.add('active');
    _startCamera();
  }

  /** Close the scanner and release the camera. */
  function close() {
    _stopCamera();
    const modal = document.getElementById('qr-modal');
    if (modal) modal.classList.remove('active');
  }

  // ── Camera + decode loop ────────────────────────────────────

  async function _startCamera() {
    try {
      _stream = await navigator.mediaDevices.getUserMedia({
        video: {
          facingMode: { ideal: 'environment' },  // back camera on phones
          width:  { ideal: 1280 },
          height: { ideal: 720 },
        },
        audio: false,
      });
    } catch (err) {
      // Permission denied or no camera available
      close();
      if (_callback) {
        _callback(null);
        _callback = null;
      }
      return;
    }

    const video = document.getElementById('qr-video');
    if (!video) { _stopCamera(); return; }

    video.srcObject = _stream;
    video.setAttribute('playsinline', ''); // required for iOS
    video.setAttribute('muted', '');

    try { await video.play(); } catch (_) {}

    if (!_detector) {
      try {
        _detector = new BarcodeDetector({ formats: ['qr_code'] });
      } catch (e) {
        close();
        if (_callback) { _callback(null); _callback = null; }
        return;
      }
    }

    _scheduleDetect(video);
  }

  function _scheduleDetect(video) {
    _animFrame = requestAnimationFrame(function () {
      _detect(video);
    });
  }

  async function _detect(video) {
    if (!_stream || video.readyState < 2) {
      // Video not ready yet — try again next frame
      _scheduleDetect(video);
      return;
    }

    try {
      const barcodes = await _detector.detect(video);
      if (barcodes && barcodes.length > 0) {
        const result = barcodes[0].rawValue;
        close();
        if (_callback) {
          // Extract just the JWT if the QR encodes a full URL with hash
          let token = result;
          const hashMatch = result.match(/[#&]token=([^&]+)/);
          if (hashMatch) token = decodeURIComponent(hashMatch[1]);
          // Or query string (legacy)
          const queryMatch = result.match(/[?&]token=([^&]+)/);
          if (!hashMatch && queryMatch) token = decodeURIComponent(queryMatch[1]);

          _callback(token !== result ? token : result);
          _callback = null;
        }
        return;
      }
    } catch (_) {
      // BarcodeDetector.detect() can throw on certain frames — continue loop
    }

    // No QR found this frame — keep scanning
    _scheduleDetect(video);
  }

  function _stopCamera() {
    if (_animFrame) { cancelAnimationFrame(_animFrame); _animFrame = null; }
    if (_stream) {
      _stream.getTracks().forEach(function (t) { t.stop(); });
      _stream = null;
    }
    const video = document.getElementById('qr-video');
    if (video) { video.srcObject = null; }
  }

  // ── Close button wiring (called once DOM is ready) ──────────
  document.addEventListener('DOMContentLoaded', function () {
    const closeBtn = document.getElementById('qr-close-btn');
    if (closeBtn) {
      closeBtn.addEventListener('click', function () {
        close();
        if (_callback) { _callback(null); _callback = null; }
      });
    }
  });

  global.QRScanner = { open, close, supported: SUPPORTED };

})(window);
