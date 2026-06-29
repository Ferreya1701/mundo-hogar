// Dev server: maps /images/* → public/images/* (same as vercel.json rewrite)
const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = 8000;
const ROOT = path.resolve(__dirname, '..');
const MIME = {
  '.html':'text/html;charset=utf-8',
  '.js':'application/javascript',
  '.css':'text/css',
  '.json':'application/json',
  '.jpg':'image/jpeg','.jpeg':'image/jpeg',
  '.png':'image/png','.webp':'image/webp',
  '.ico':'image/x-icon','.svg':'image/svg+xml'
};

http.createServer((req, res) => {
  let url = req.url.split('?')[0];
  let filePath = url.startsWith('/images/')
    ? path.join(ROOT, 'public', url)
    : path.join(ROOT, url === '/' ? 'index.html' : url.slice(1));
  fs.readFile(filePath, (err, data) => {
    if (err) { res.writeHead(404); res.end('404: ' + url); return; }
    const ext = path.extname(filePath).toLowerCase();
    res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream' });
    res.end(data);
  });
}).listen(PORT, () => console.log('Dev server: http://localhost:' + PORT));
