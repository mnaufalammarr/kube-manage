const express = require('express');
const router = express.Router();
const { login, logout, getMe, verifyToken } = require('../auth');

router.post('/login', login);
router.post('/logout', logout);
router.get('/me', verifyToken, getMe);

module.exports = router;
