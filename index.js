const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const isPost = process.env['STATE_isPost'] === 'true';

if (isPost) {
  // Post phase — runs automatically at job end via `post: index.js`
  execFileSync('bash', [path.join(__dirname, 'save.sh')], { stdio: 'inherit' });
} else {
  // Main phase — mark that post should run, then restore
  fs.appendFileSync(process.env['GITHUB_STATE'], 'isPost=true\n');
  execFileSync('bash', [path.join(__dirname, 'restore.sh')], { stdio: 'inherit' });
}
