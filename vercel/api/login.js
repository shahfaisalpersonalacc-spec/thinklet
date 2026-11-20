// POST /api/login {username, password} -> {token, expiresAt}
import { account, sameText, signToken } from '../lib/auth.js';
import { HttpError, body, route, str } from '../lib/http.js';

const WRONG_DELAY_MS = 800; // slows down password guessing

export default route({
  POST: async (req) => {
    const b = body(req);
    const username = str(b.username, 'Username', 200, { required: true });
    const password = str(b.password, 'Password', 200, { required: true });
    const acct = account();
    // Check both, always, so a wrong username takes as long as a wrong password.
    const userOk = sameText(username, acct.username);
    const passOk = sameText(password, acct.password);
    if (!(userOk && passOk)) {
      await new Promise((r) => setTimeout(r, WRONG_DELAY_MS));
      throw new HttpError(401, 'Wrong username or password.');
    }
    return signToken(acct.username);
  },
});
