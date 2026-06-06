'use strict';

const crypto = require('crypto');
const { verifySignature } = require('../src/verify');

const SECRET = 'test-secret-abc123';

function makeSignature(secret, body) {
  const hmac = crypto.createHmac('sha256', secret).update(body).digest('hex');
  return `sha256=${hmac}`;
}

describe('verifySignature', () => {
  test('returns true for a valid signature', () => {
    const body = '{"ref":"refs/heads/main"}';
    const sig = makeSignature(SECRET, body);
    expect(verifySignature(SECRET, sig, body)).toBe(true);
  });

  test('returns false when signature is tampered', () => {
    const body = '{"ref":"refs/heads/main"}';
    const sig = makeSignature(SECRET, body);
    const tampered = sig.slice(0, -4) + 'ffff';
    expect(verifySignature(SECRET, tampered, body)).toBe(false);
  });

  test('returns false when body is different from signed body', () => {
    const body = '{"ref":"refs/heads/main"}';
    const sig = makeSignature(SECRET, body);
    expect(verifySignature(SECRET, sig, '{"ref":"refs/heads/other"}')).toBe(false);
  });

  test('returns false when secret is wrong', () => {
    const body = '{"ref":"refs/heads/main"}';
    const sig = makeSignature(SECRET, body);
    expect(verifySignature('wrong-secret', sig, body)).toBe(false);
  });

  test('returns false for missing signature', () => {
    expect(verifySignature(SECRET, undefined, 'body')).toBe(false);
    expect(verifySignature(SECRET, null, 'body')).toBe(false);
    expect(verifySignature(SECRET, '', 'body')).toBe(false);
  });

  test('returns false when signature has no sha256= prefix', () => {
    const body = 'body';
    const hmac = crypto.createHmac('sha256', SECRET).update(body).digest('hex');
    expect(verifySignature(SECRET, hmac, body)).toBe(false);
  });

  test('accepts a Buffer body', () => {
    const body = Buffer.from('{"action":"push"}', 'utf8');
    const sig = makeSignature(SECRET, body);
    expect(verifySignature(SECRET, sig, body)).toBe(true);
  });

  test('returns false when signature lengths differ (timing-safe path)', () => {
    expect(verifySignature(SECRET, 'sha256=short', 'body')).toBe(false);
  });
});
