#!/usr/bin/env bash
# Adapted from Chara-Freedom/vps-psiphon (MIT), upstream commit of 2026-11-10: see CREDITS.md.
# Asks Gemini itself whether it serves this exit, and prints one line:
#   exit 0  ok            Gemini replied; the line names the place it puts us in
#   exit 1  REFUSED       error 1060: Gemini declines this address
#   exit 2  inconclusive  anything else — never grounds for a rotation
#   exit 3  CAPTCHA       with IMPERSONATE=1 only: Google sends a browser on this exit to
#                         its captcha on www.google.com/sorry
# Logged out: the page is fetched for its session fields and cookies, then one message
# is sent and held open until Gemini answers (two minutes at most).
#
# With IMPERSONATE=1 the page is fetched by curl-impersonate as the newest Chrome it
# knows. Google can flag an exit for browsers alone: on one such exit, measured within
# a few minutes, every browser handshake (Chrome, Firefox, Safari) was redirected to the
# captcha, with or without a browser's headers, while plain curl got the page, with or
# without them — the handshake decides. The message itself still goes by plain curl.
#
#   --direct  probe from this host's own address instead of through the tunnel, to
#             tell a burned exit apart from a refusal that follows the whole host.
set -uo pipefail
[ -r /etc/default/vps-psiphon ] && . /etc/default/vps-psiphon
P=(--socks5-hostname "${BIND:-127.0.0.1}:${SOCKS_PORT:-1080}")
[ "${1:-}" = --direct ] && P=(-4)
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36'
d="$(mktemp -d)" || { echo "inconclusive (no temp dir)"; exit 2; }
trap 'rm -rf "$d"' EXIT
C=(-s "${P[@]}" -A "$UA" -H 'Accept-Language: en-US,en;q=0.9' -b "$d/jar" -c "$d/jar")

# The browser build sends its own coherent headers, so it gets no -A or -H of ours.
G=(curl "${C[@]}"); imp=0; note=""
if [ "${IMPERSONATE:-0}" = 1 ]; then
  ci=/opt/vps-psiphon/curl-impersonate
  n="$(ls "$ci" 2>/dev/null | sed -n 's/^curl_chrome\([0-9][0-9]*\)$/\1/p' | sort -n | tail -1)"
  if [ -n "$n" ] && [ -x "$ci/curl-impersonate" ]; then
    G=("$ci/curl_chrome$n" -s "${P[@]}" -b "$d/jar" -c "$d/jar"); imp=1
  else
    note=" (impersonate is on, but no curl-impersonate build is installed: the page went by plain curl)"
  fi
fi

code="$("${G[@]}" --max-time 30 -o "$d/app" -D "$d/head" -w '%{http_code}' https://gemini.google.com/app 2>/dev/null || true)"
if [ "$imp" = 1 ] && [ "$code" = 302 ] &&
   grep -qiE '^location: *https://[^/]*google\.[a-z.]+/sorry/' "$d/head" 2>/dev/null; then
  echo "CAPTCHA — Google sends a browser on this exit to /sorry, Gemini not asked"; exit 3
fi
bl="$(grep -oE '"cfb2h":"[^"]+"' "$d/app" 2>/dev/null | head -1 | cut -d'"' -f4)"
sid="$(grep -oE '"FdrFJe":"[^"]+"' "$d/app" 2>/dev/null | head -1 | cut -d'"' -f4)"
if [ -z "$bl" ] || [ -z "$sid" ]; then
  echo "inconclusive (page answered ${code:-nothing}, without the session fields)$note"; exit 2
fi

U='https://gemini.google.com/_/BardChatUi/data/assistant.lamda.BardFrontendService/StreamGenerate'
H=(-H 'Content-Type: application/x-www-form-urlencoded;charset=utf-8'
   -H 'Origin: https://gemini.google.com' -H 'Referer: https://gemini.google.com/' -H 'X-Same-Domain: 1')

# Gemini can take a minute or more to answer, while Psiphon's servers close a connection
# on which no byte has moved for 30 s. So a second request rides the same HTTP/2
# connection and keeps it busy: its body trickles one byte every 2 s until the message's
# transfer is over (its -w line goes to stderr, unbuffered, into $d/w). Google answers
# that request 400 once its body ends, and the answer is discarded.
i=0
while ! grep -q message-done "$d/w" 2>/dev/null && [ "$i" -lt 60 ]; do sleep 2; printf x; i=$((i + 1)); done |
  curl --parallel "${C[@]}" "${H[@]}" --max-time 130 -o "$d/out" -w '%{stderr}message-done' \
    --data-urlencode 'f.req=[null,"[[\"hi\"],null,null]"]' \
    "$U?bl=${bl}&f.sid=${sid}&hl=en&_reqid=$(( RANDOM * 10 + 100000 ))&rt=c" \
    --next "${C[@]}" "${H[@]}" -X POST -T - --max-time 130 -o /dev/null "$U?rt=c" \
    >/dev/null 2>"$d/w"

# 1060 decides first: a held answer can open with a frame that is not a reply. Served
# means a reply that names the place; 1096 trails every logged-out reply and says
# nothing. The code opens the error's array: once a bare [1060], now [1060,null,"…"].
errs="$(grep -oE 'BardErrorInfo",\[[0-9]+' "$d/out" 2>/dev/null | grep -oE '[0-9]+' | sort -u | tr '\n' ' ')"
case " $errs " in
  *" 1060 "*) echo "REFUSED — Gemini declines this exit (error 1060, no reply)$note"; exit 1 ;;
esac
where="$(grep -oE '\\"[^"\\]+\\",\\"SWML_DESCRIPTION' "$d/out" 2>/dev/null | head -1 | cut -d'"' -f2 | tr -d '\\')"
[ -n "$where" ] && { echo "ok — Gemini replies, and places this exit in $where$note"; exit 0; }
if grep -q '"wrb.fr",null,"\[' "$d/out" 2>/dev/null; then
  echo "inconclusive (an answer without a place${errs:+, error ${errs% }})$note"; exit 2
fi
# A message Google sends to its captcha gets a 302 page in place of an answer. Told apart
# from silence in the journal, but never a rotation: the message goes by plain curl, and
# a captcha for curl's handshake says nothing about what a browser gets on this exit.
if grep -qiE 'https://[^/"]*google\.[a-z.]+/sorry/' "$d/out" 2>/dev/null; then
  echo "inconclusive (StreamGenerate sent to /sorry)$note"; exit 2
fi
echo "inconclusive (no reply${errs:+, error ${errs% }})$note"; exit 2
