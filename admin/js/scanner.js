/* ============================================================
   Lector de códigos de barras con la cámara del celular
   ------------------------------------------------------------
   Usa la API BarcodeDetector del navegador (Chrome/Edge en Android,
   Safari 17+ en iPhone). Donde no existe, el botón de escanear no se
   muestra y se puede seguir buscando por nombre o SKU, o con un lector
   USB (que escribe el código y manda Enter en el buscador).
   Uso: MHScanner.disponible() → bool
        MHScanner.abrir(codigo => { ... })  (abre la cámara; cierra solo al leer)
   ============================================================ */
window.MHScanner = (function () {
  const FORMATOS = ['ean_13', 'ean_8', 'upc_a', 'upc_e', 'code_128', 'code_39', 'itf', 'qr_code'];
  let modal = null, stream = null, raf = 0, detector = null;

  function disponible() {
    return 'BarcodeDetector' in window && !!navigator.mediaDevices?.getUserMedia;
  }

  function cerrar() {
    if (raf) cancelAnimationFrame(raf); raf = 0;
    if (stream) { stream.getTracks().forEach(t => t.stop()); stream = null; }
    modal?.remove(); modal = null;
  }

  async function abrir(onCodigo) {
    if (!disponible()) { Utils.toast('Este navegador no puede leer códigos con la cámara. Escribí el código o usá un lector USB.', 'warning', 5000); return; }
    cerrar();
    modal = document.createElement('div');
    modal.className = 'scan-modal';
    modal.innerHTML = `
      <div class="scan-box">
        <video class="scan-video" playsinline muted autoplay></video>
        <div class="scan-marco" aria-hidden="true"></div>
        <div class="scan-hint">Apuntá al código de barras</div>
        <button type="button" class="btn btn-outline scan-cerrar">Cerrar</button>
      </div>`;
    document.body.appendChild(modal);
    modal.querySelector('.scan-cerrar').addEventListener('click', cerrar);
    const video = modal.querySelector('video');
    try {
      detector = detector || new BarcodeDetector({ formats: FORMATOS.filter(f => true) });
      stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: 'environment' }, width: { ideal: 1280 }, height: { ideal: 720 } }, audio: false });
      video.srcObject = stream;
      await video.play();
    } catch (e) {
      console.error('[scanner]', e);
      cerrar();
      Utils.toast(e?.name === 'NotAllowedError'
        ? 'Sin permiso para usar la cámara. Habilitalo en el navegador y probá de nuevo.'
        : 'No se pudo abrir la cámara.', 'error', 5000);
      return;
    }
    let ultimo = 0;
    const tick = async () => {
      if (!modal) return;
      const ahora = performance.now();
      if (ahora - ultimo > 180 && video.readyState >= 2) {
        ultimo = ahora;
        try {
          const codes = await detector.detect(video);
          const c = codes.find(x => x.rawValue && x.rawValue.trim());
          if (c) {
            const val = c.rawValue.trim();
            if (navigator.vibrate) navigator.vibrate(60);
            cerrar();
            onCodigo(val);
            return;
          }
        } catch (_) { /* un frame que no se pudo leer: seguimos */ }
      }
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
  }

  return { disponible, abrir, cerrar };
})();
