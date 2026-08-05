const bcrypt = require('bcrypt');

const password = process.argv[2];

if (!password) {
  console.log('Usage: node server/hash-password.js <password>');
  process.exit(1);
}

const hash = bcrypt.hashSync(password, 10);
console.log(`Password: ${password}`);
console.log(`Bcrypt Hash: ${hash}`);
