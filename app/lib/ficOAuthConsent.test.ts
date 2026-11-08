import test from 'node:test';
import assert from 'node:assert/strict';
import { authorizationIdValido, scopeConsensoValido } from './ficOAuthConsent.ts';

test('consent accepts opaque Supabase authorization IDs without requiring a UUID', () => {
  for (const id of ['opaqueAuthorization_G7k9-Example42', '11111111-1111-4111-8111-111111111111']) {
    assert.equal(authorizationIdValido(id), true);
  }
});

test('consent accepts email with the standard identity and refresh scopes requested by ChatGPT', () => {
  for (const scope of ['email', 'openid email offline_access', 'email openid', 'offline_access email', ' email  openid ']) {
    assert.equal(scopeConsensoValido(scope), true);
  }
});

test('consent still requires email and rejects unrelated permissions', () => {
  for (const scope of [undefined, '', 'openid offline_access', 'profile email', 'email documents.write', ['email']]) {
    assert.equal(scopeConsensoValido(scope), false);
  }
});

test('consent rejects missing, duplicated, oversized or path-changing authorization IDs', () => {
  for (const id of [undefined, null, '', ['first', 'second'], 'x'.repeat(1025),
    '../other', 'id/consent', 'id?approve=true', 'id#fragment', '%2F', 'id\n', ' id', 'id ']) {
    assert.equal(authorizationIdValido(id), false);
  }
});
