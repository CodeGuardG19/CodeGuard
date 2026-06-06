'use strict';

const crypto = require('crypto');

/**
 * Validates a GitHub webhook X-Hub-Signature-256 header against the request body.
 *
 * Uses crypto.timingSafeEqual to prevent timing-based secret extraction.
 * The secret is passed in from the caller (loaded from SSM at cold start) so
 * this module never reads environment variables directly and never logs secrets.
 *
 * @param {string} secret - The raw webhook secret string
 * @param {string} signature - Value of X-Hub-Signature-256 header (e.g. "sha256=abc...")
 * @param {string|Buffer} body - Raw request body bytes
 * @returns {boolean} true if the signature is valid
 */
function verifySignature(secret, signature, body) {
  if (!signature || typeof signature !== 'string') {
    return false;
  }

  if (!signature.startsWith('sha256=')) {
    return false;
  }

  const bodyBuffer = Buffer.isBuffer(body) ? body : Buffer.from(body, 'utf8');
  const expected = crypto
    .createHmac('sha256', secret)
    .update(bodyBuffer)
    .digest('hex');

  const expectedBuffer = Buffer.from(`sha256=${expected}`, 'utf8');
  const signatureBuffer = Buffer.from(signature, 'utf8');

  if (expectedBuffer.length !== signatureBuffer.length) {
    return false;
  }

  return crypto.timingSafeEqual(expectedBuffer, signatureBuffer);
}

module.exports = { verifySignature };
