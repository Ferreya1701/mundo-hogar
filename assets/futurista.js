// Menú de las páginas internas: hamburguesa en celular y buscador que lleva al catálogo.
// El término viaja en ?q= y /productos lo levanta al cargar.
(function () {
  const burger = document.getElementById('burger');
  const mnav = document.getElementById('mnav');
  if (burger && mnav) {
    const cerrar = () => { mnav.classList.remove('open'); burger.setAttribute('aria-expanded', 'false'); burger.setAttribute('aria-label', 'Abrir menú'); };
    burger.addEventListener('click', () => {
      const abierto = mnav.classList.toggle('open');
      burger.setAttribute('aria-expanded', String(abierto));
      burger.setAttribute('aria-label', abierto ? 'Cerrar menú' : 'Abrir menú');
    });
    mnav.querySelectorAll('a').forEach(a => a.addEventListener('click', cerrar));
  }
  ['q-top', 'q-side', 'q-mov'].forEach(id => {
    const input = document.getElementById(id);
    if (!input) return;
    input.addEventListener('keydown', e => {
      if (e.key !== 'Enter') return;
      e.preventDefault();
      const t = input.value.trim();
      location.href = '/productos' + (t ? '?q=' + encodeURIComponent(t.slice(0, 80)) : '');
    });
  });
})();
