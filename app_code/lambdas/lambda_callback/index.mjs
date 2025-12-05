// lambda_callback/index.mjs
function resp(status, headers = {}, body = '') {
  return { statusCode: status, headers, body };
}
function j(body, status = 200) {
  return resp(status, { 'Content-Type': 'application/json' }, JSON.stringify(body));
}

export const handler = async (event) => {
  try {
    const qs = event?.queryStringParameters || {};
    const { code, error, error_description } = qs;

    if (error) return j({ ok:false, source:'cognito', error, error_description }, 400);
    if (!code)  return j({ ok:false, error:'missing_code' }, 400);

    const domain       = process.env.COGNITO_DOMAIN;   
    const clientId     = process.env.CLIENT_ID;        
    const clientSecret = process.env.CLIENT_SECRET;    
    const redirectUri  = process.env.REDIRECT_URI;     
    const front        = process.env.FRONTEND_REDIRECT;

    const missing = ['COGNITO_DOMAIN','CLIENT_ID','CLIENT_SECRET','REDIRECT_URI','FRONTEND_REDIRECT']
      .filter(k => !process.env[k] || !String(process.env[k]).trim());
    if (missing.length) return j({ ok:false, error:'misconfigured_env', missing }, 500);

    const basic = Buffer.from(`${clientId}:${clientSecret}`).toString('base64');
    const tokenUrl = `${domain}/oauth2/token`;
    const form = new URLSearchParams({
      grant_type: 'authorization_code',
      code,
      redirect_uri: redirectUri,
      client_id: clientId,
      client_secret: clientSecret
    }).toString();

    const tokRes = await fetch(tokenUrl, {
      method: 'POST',
      headers: { 'Authorization': `Basic ${basic}`, 'Content-Type': 'application/x-www-form-urlencoded' },
      body: form
    });

    const raw = await tokRes.text();
    if (!tokRes.ok) return j({ ok:false, source:'token', status: tokRes.status, raw }, 502);

    let tokens = {}; try { tokens = JSON.parse(raw); } catch {}
    const frag = new URLSearchParams({
      id_token: tokens.id_token || '',
      access_token: tokens.access_token || '',
      token_type: tokens.token_type || 'Bearer',
      expires_in: String(tokens.expires_in || '')
    }).toString();

    return resp(302, { Location: `${front}#${frag}` }, '');
  } catch (e) {
    return j({ ok:false, error:'callback_exception', message: e.message }, 500);
  }
};
