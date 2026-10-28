const fs = require('node:fs');
const path = require('node:path');
const cssPath = path.resolve('dsh/mobile-fix.css').split(path.sep).join('/');
let src = fs.readFileSync('bootstrap.js', 'utf8');
src = src.replace("'/opt/dsh/mobile-fix.css'", JSON.stringify(cssPath));
fs.writeFileSync('.tmp/bs-selftest.js', src);
console.log('css:', cssPath);
