# Tesla API Connection

TeslaMate connects to your Tesla vehicle using the Tesla Owner API. You must generate API tokens and paste them into the TeslaMate UI.

## Generating Tokens

```bash
make tesla-token
```

This downloads [tesla_auth](https://github.com/adriankumpf/tesla_auth) and opens a browser login. Sign in with your Tesla account to generate an **Access Token** and **Refresh Token**.

## Connecting to TeslaMate

1. Open the TeslaMate web UI
2. Paste the **Access Token** and **Refresh Token** from the step above
3. TeslaMate begins polling your vehicle automatically

Tokens are encrypted at rest using the `ENCRYPTION_KEY` secret. TeslaMate automatically refreshes tokens, so you should not need to re-generate them.

## Troubleshooting

- If authentication fails, re-run `make tesla-token` to generate new tokens
- If the car shows as "unavailable", it may be asleep — TeslaMate will reconnect when it wakes
- Check logs: `kubectl logs -n teslamate deploy/teslamate`
