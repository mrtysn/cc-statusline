#!/bin/zsh
# DESC: Set up the Console API credit in CC Sessions' Usage window: store the key, write the grant, check it
set -euo pipefail

usage() {
  print "usage: ${0:t} --grant <dollars> --granted <YYYY-MM-DD> --expires <YYYY-MM-DD> [--renews-day <1-27>] [--update-key]"
  print ""
  print "Shows 'grant minus API spend since it was granted' as the API CREDIT section of the Usage"
  print "window. Take the three values from Console > Billing > Promotional credits (Date granted,"
  print "Expires on, the dollar total)."
  print ""
  print "--renews-day makes the app roll to the next month's grant by itself: on that day of each month"
  print "(UTC) a new grant of the same size starts and lapses the day after it the month after. The"
  print "Usage window marks such a period 'renewal assumed'. Without it, run this again every month."
  print ""
  print "The key is an Admin API key, or an API key with the read:analytics scope, made in the"
  print "Console. It is read from the prompt (nothing is echoed) and stored in the login Keychain as"
  print "'cc-statusline-analytics-key'. With a key already stored, it is kept unless --update-key."
}

grant="" granted="" expires="" renews_day="" update_key=0
while (( $# )); do
  case $1 in
    --grant) grant=$2; shift 2 ;;
    --granted) granted=$2; shift 2 ;;
    --expires) expires=$2; shift 2 ;;
    --renews-day) renews_day=$2; shift 2 ;;
    --update-key) update_key=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done
if [[ -z $grant || -z $granted || -z $expires ]]; then usage >&2; exit 2; fi
[[ $grant == <->(.<->|) ]] || { print -u2 "--grant must be a number of dollars, got: $grant"; exit 2; }
[[ $granted == [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] ]] || { print -u2 "--granted must be YYYY-MM-DD"; exit 2; }
[[ $expires == [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] ]] || { print -u2 "--expires must be YYYY-MM-DD"; exit 2; }

[[ -z $renews_day || $renews_day == <1-27> ]] || { print -u2 "--renews-day must be 1 to 27, got: $renews_day"; exit 2; }

service=cc-statusline-analytics-key
if (( update_key )) || ! security find-generic-password -s $service >/dev/null 2>&1; then
  print "Paste the key (nothing is shown), then Enter:"
  read -rs key
  [[ -n $key ]] || { print -u2 "no key entered"; exit 1; }
  security add-generic-password -U -s $service -a "$USER" -w "$key"
  unset key
fi

dir=$HOME/Library/Application\ Support/Agent\ Bar\ Hopping
mkdir -p $dir
renew_json=""
[[ -n $renews_day ]] && renew_json=", \"renew_day\": $renews_day"
print -r -- "{\"grant_usd\": $grant, \"granted_at\": \"${granted}T00:00:00Z\", \"expires_at\": \"${expires}T00:00:00Z\"$renew_json}" > $dir/api-credit.json

script=${0:A:h:h}/cc-statusline.js
node $script refresh-api-credit
cache=${XDG_CACHE_HOME:-$HOME/.cache}/cc-statusline/api-credit.json
if [[ -f $cache ]]; then print -r -- "$(<$cache)"; else print -u2 "no reading written; see error.log in ${cache:h}"; exit 1; fi
