// Read only provider metadata. Never emit credentials, tokens, or application data.
import { readFileSync } from 'node:fs';
import { createSign, createDecipheriv } from 'node:crypto';

const env = Object.fromEntries(readFileSync('/etc/personal-apps/finance.env', 'utf8')
  .split('\n').filter(line => line.includes('=')).map(line => {
    const i = line.indexOf('=');
    return [line.slice(0, i), line.slice(i + 1)];
  }));
const b64 = value => Buffer.from(JSON.stringify(value)).toString('base64url');
const now = Math.floor(Date.now() / 1000);
const payload = b64({ alg: 'RS256', typ: 'JWT', kid: env.EB_APP_ID }) + '.' +
  b64({ iss: 'enablebanking.com', aud: 'api.enablebanking.com', iat: now, exp: now + 60 });
const jwt = payload + '.' + createSign('RSA-SHA256').update(payload)
  .sign(readFileSync(env.EB_PRIVATE_KEY_PATH)).toString('base64url');
const response = await fetch('https://api.enablebanking.com/application', {
  headers: { Authorization: 'Bearer ' + jwt }, signal: AbortSignal.timeout(15000),
});
if (!response.ok) throw new Error('Enable Banking metadata HTTP ' + response.status);
const bank = await response.json();
if (!bank.active || !bank.redirect_urls.includes('https://finance.moinax.com/api/callback'))
  throw new Error('Register the new Finance callback in the active Enable Banking application first.');
console.log('Enable Banking: active application accepts the new callback.');

const bytes = readFileSync('/var/lib/daylight/daylight.enc');
const decipher = createDecipheriv('aes-256-gcm', readFileSync('/var/lib/daylight/master.key'), bytes.subarray(0, 12));
decipher.setAuthTag(bytes.subarray(12, 28));
const state = JSON.parse(Buffer.concat([decipher.update(bytes.subarray(28)), decipher.final()]).toString());
const url = new URL('https://accounts.google.com/o/oauth2/v2/auth');
url.search = new URLSearchParams({
  client_id: state.credentials.google.clientId,
  redirect_uri: 'https://daylight.moinax.com/auth/google/callback',
  response_type: 'code', scope: 'openid email', state: 'domain-migration-read-only-check',
}).toString();
const google = await fetch(url, { signal: AbortSignal.timeout(15000) });
if (!google.ok || !new URL(google.url).pathname.includes('/signin/identifier'))
  throw new Error('Google did not accept the new Daylight callback. Inspect the OAuth client configuration.');
console.log('Google: new callback reaches sign-in without redirect_uri_mismatch.');
