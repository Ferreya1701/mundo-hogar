// Dev server local que replica el routing de vercel.json
// /images/* -> public/images/*  |  /categorias[/x] -> categoria.html  |  index de carpetas
const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = 8000;
const ROOT = path.resolve(__dirname, '..');
const MIME = {
  '.html':'text/html;charset=utf-8','.js':'application/javascript;charset=utf-8',
  '.css':'text/css;charset=utf-8','.json':'application/json;charset=utf-8',
  '.svg':'image/svg+xml','.xml':'application/xml;charset=utf-8','.txt':'text/plain;charset=utf-8',
  '.jpg':'image/jpeg','.jpeg':'image/jpeg','.png':'image/png','.webp':'image/webp','.ico':'image/x-icon'
};

function resolveFile(url) {
  url = decodeURIComponent(url.split('?')[0]);
  if (url.startsWith('/images/')) return path.join(ROOT, 'public', url);
  if (url === '/categorias' || url.startsWith('/categorias/')) return path.join(ROOT, 'categoria.html');
  if (url.startsWith('/producto/')) return path.join(ROOT, 'producto.html');
  if (url === '/carrito') return path.join(ROOT, 'carrito.html');
  if (url === '/') return path.join(ROOT, 'index.html');
  let p = path.join(ROOT, url.replace(/^\//, ''));
  try { if (fs.statSync(p).isDirectory()) return path.join(p, 'index.html'); } catch (e) {}
  return p;
}

http.createServer((req, res) => {
  const filePath = resolveFile(req.url);
  fs.readFile(filePath, (err, data) => {
    if (err) {
      // fallback 404 page
      fs.readFile(path.join(ROOT, '404.html'), (e2, d2) => {
        res.writeHead(404, { 'Content-Type': 'text/html;charset=utf-8' });
        res.end(e2 ? '404: ' + req.url : d2);
      });
      return;
    }
    res.writeHead(200, { 'Content-Type': MIME[path.extname(filePath).toLowerCase()] || 'application/octet-stream' });
    res.end(data);
  });
}).listen(PORT, () => console.log('Dev server: http://localhost:' + PORT));
