# Google OAuth Setup

This guide walks through creating Google OAuth credentials for oauth2-proxy.

## Steps

1. Go to [Google Cloud Console](https://console.cloud.google.com/)

2. Create a new project (or select an existing one):
   - Click the project dropdown → "New Project"
   - Name: `TeslaMate Auth` (or any name)

3. Enable the OAuth consent screen:
   - Navigate to **APIs & Services → OAuth consent screen**
   - User Type: **External**
   - App name: `TeslaMate`
   - Support email: your email
   - Authorized domains: your root domain (e.g., `yourdomain.com`)
   - Add your email as a test user (required while app is in "Testing" status)

4. Create OAuth credentials:
   - Navigate to **APIs & Services → Credentials**
   - Click **Create Credentials → OAuth 2.0 Client ID**
   - Application type: **Web application**
   - Name: `TeslaMate oauth2-proxy`
   - Authorized redirect URIs: `https://<your-hostname>/oauth2/callback`

5. Note the **Client ID** and **Client Secret** — you'll need these when running `make configure`

## Notes

- While the app is in "Testing" status, only test users you explicitly add can authenticate
- To allow any Google account with your email domain, change the app to "In production" status
- The OAuth consent screen can take a few minutes to propagate after changes
