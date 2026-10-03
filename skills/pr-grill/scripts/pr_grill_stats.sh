#!/usr/bin/env bash
# Battle record for pr-grill: one line per PR, readable with git + bash only.
#
# Usage:
#   pr_grill_stats.sh record --branch B [--pr N] --nodes N --code N --author N --approved N --open N
#                     [--drill PERFECT/PARTIAL/WRONG] [--difficulty easy|normal|brutal]
#                     [--stumbled lens1,lens2] [--rounds N] [--level newcomer|working|owner]
#                                                               append a record, print the meter line
#   pr_grill_stats.sh meter --nodes N --code N --author N --approved N [--open N]
#                                                               print only the meter line
#   pr_grill_stats.sh list [--last N]                             table of past PRs + weak-lens trend
#   pr_grill_stats.sh weak                                        just the weak-lens trend (for the collector)
#   pr_grill_stats.sh banner --branch B [--profile "wrote=ai · knows=some"]
#                                                               start card: branch, profile, last readiness, weak lenses
#                                                               (one line instead of a box when the terminal is < 60 columns)
#
# Storage: $PR_GRILL_STATS_DIR/stats.log, default <repo>/.pr-grill (git-ignored by the collector).
# Readiness = (code + author + approved/2) / nodes. [approved] counts half: agreed with, not said in own words.
set -uo pipefail

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }

STATS_DIR="${PR_GRILL_STATS_DIR:-${PR_GRILL_DIR:-}}"
if [ -z "$STATS_DIR" ]; then
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: not in a git repository; set PR_GRILL_DIR" >&2; exit 1; }
  STATS_DIR="$ROOT/.pr-grill"
fi
LOG="$STATS_DIR/stats.log"

CMD="${1:-}"; [ $# -gt 0 ] && shift
BRANCH=""; PRNUM=""; NODES=""; CODE=0; AUTHOR=0; APPROVED=0; OPEN=0; DRILL=""; DIFF=""; STUMBLED=""; ROUNDS=1; LAST=10; LEVEL=""; PROFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --branch) BRANCH="$2"; shift 2 ;;     --pr) PRNUM="$2"; shift 2 ;;
    --nodes) NODES="$2"; shift 2 ;;       --code) CODE="$2"; shift 2 ;;
    --author) AUTHOR="$2"; shift 2 ;;     --approved) APPROVED="$2"; shift 2 ;;
    --open) OPEN="$2"; shift 2 ;;         --drill) DRILL="$2"; shift 2 ;;
    --difficulty) DIFF="$2"; shift 2 ;;   --stumbled) STUMBLED="$2"; shift 2 ;;
    --rounds) ROUNDS="$2"; shift 2 ;;     --last) LAST="$2"; shift 2 ;;
    --level) LEVEL="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

is_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# readiness percent from counts; prints "" when nodes is 0
readiness() {
  local n="$1" c="$2" a="$3" p="$4"
  [ "$n" -eq 0 ] && { echo ""; return; }
  echo $(( (c * 100 + a * 100 + p * 50) / n ))
}

# 10-cell bar
bar() {
  local pct="$1" filled i s=""
  filled=$(( pct / 10 )); [ "$filled" -gt 10 ] && filled=10   # floor: never show more than you have
  for i in 1 2 3 4 5 6 7 8 9 10; do if [ "$i" -le "$filled" ]; then s="${s}█"; else s="${s}░"; fi; done
  printf '%s' "$s"
}

meter_line() {
  local n="$1" c="$2" a="$3" p="$4" o="$5" d="$6" st="$7" pct
  pct=$(readiness "$n" "$c" "$a" "$p")
  if [ -z "$pct" ]; then printf 'Readiness: (no decision-tree nodes recorded)'
  else printf 'Readiness %s %d%%  (code %d · author %d · approved %d · open %d of %d)' "$(bar "$pct")" "$pct" "$c" "$a" "$p" "$o" "$n"; fi
  [ -n "$d" ] && printf '  Drill %s' "$(printf '%s' "$d" | awk -F/ '{printf "%d/%d", $1, $1+$2+$3}')"
  [ -n "$st" ] && printf '  Stumbled: %s' "$st"
  printf '\n'
}

need_counts() {
  for v in "$NODES" "$CODE" "$AUTHOR" "$APPROVED" "$OPEN"; do
    is_int "$v" || { echo "ERROR: --nodes/--code/--author/--approved/--open must be non-negative integers" >&2; exit 2; }
  done
  if [ $((CODE + AUTHOR + APPROVED + OPEN)) -gt "$NODES" ]; then
    echo "ERROR: code+author+approved+open ($((CODE + AUTHOR + APPROVED + OPEN))) exceeds --nodes ($NODES)" >&2; exit 2
  fi
  if [ -n "$DRILL" ] && ! printf '%s' "$DRILL" | grep -Eq '^[0-9]+/[0-9]+/[0-9]+$'; then
    echo "ERROR: --drill must be PERFECT/PARTIAL/WRONG, e.g. 5/2/1" >&2; exit 2
  fi
  # the log is one key=value line per record; a space in a value would break every reader
  case "$BRANCH$STUMBLED$DIFF$LEVEL$PRNUM" in *[[:space:]]*) echo "ERROR: --branch/--stumbled/--difficulty/--level/--pr must not contain spaces" >&2; exit 2 ;; esac
}

# Weak-lens trend over the last 3 records: a lens that appears in 2 or more of them
weak_trend() {
  [ -f "$LOG" ] || return 0
  tail -3 "$LOG" | sed -n 's/.*stumbled=\([^ ]*\).*/\1/p' | tr ',' '\n' | grep -Ev '^(-)?$' | sort | uniq -c | sort -rn \
    | awk '$1 >= 2 { printf "%s (%d of last 3)\n", $2, $1 }'
}

# Rank from how many PRs are on record; a ★ when the last five average 85% readiness or better.
# Counting battles, not scores, is deliberate: showing up is what builds the habit.
rank_of() {
  local n="$1" r avg
  if   [ "$n" -ge 25 ]; then r="Master"
  elif [ "$n" -ge 12 ]; then r="Senior"
  elif [ "$n" -ge 6 ];  then r="Veteran"
  elif [ "$n" -ge 3 ];  then r="Regular"
  else r="Rookie"; fi
  if [ -f "$LOG" ] && [ "$n" -ge 3 ]; then
    avg=$(tail -5 "$LOG" | sed -n 's/.*readiness=\([0-9]*\).*/\1/p' | awk '{ s += $1; c++ } END { if (c) printf "%d", s / c; else print 0 }')
    [ "${avg:-0}" -ge 85 ] && r="$r ★"
  fi
  printf '%s' "$r"
}

case "$CMD" in
  record)
    [ -n "$BRANCH" ] || { echo "ERROR: --branch is required" >&2; exit 2; }
    need_counts
    mkdir -p "$STATS_DIR" || exit 1
    PCT=$(readiness "$NODES" "$CODE" "$AUTHOR" "$APPROVED")
    case "$LEVEL" in ''|newcomer|working|owner) ;; *) echo "ERROR: --level must be newcomer, working or owner" >&2; exit 2 ;; esac
    printf 'date=%s branch=%s pr=%s nodes=%s code=%s author=%s approved=%s open=%s readiness=%s drill=%s difficulty=%s stumbled=%s rounds=%s level=%s\n' \
      "$(date '+%Y-%m-%d')" "$BRANCH" "${PRNUM:--}" "$NODES" "$CODE" "$AUTHOR" "$APPROVED" "$OPEN" "${PCT:--}" "${DRILL:--}" "${DIFF:--}" "${STUMBLED:--}" "$ROUNDS" "${LEVEL:-working}" >> "$LOG"
    meter_line "$NODES" "$CODE" "$AUTHOR" "$APPROVED" "$OPEN" "$DRILL" "$STUMBLED"
    echo "Recorded in $LOG ($(grep -c . "$LOG") PR(s) so far)"
    ;;
  meter)
    need_counts
    meter_line "$NODES" "$CODE" "$AUTHOR" "$APPROVED" "$OPEN" "$DRILL" "$STUMBLED"
    ;;
  list)
    [ -f "$LOG" ] || { echo "No record yet ($LOG). Finish a Grill or Drill and it will be written."; exit 0; }
    is_int "$LAST" || { echo "ERROR: --last must be an integer" >&2; exit 2; }
    printf '%-10s  %-28s  %-6s  %-5s  %-6s  %-7s  %-8s  %s\n' date branch pr ready drill rounds level stumbled
    tail -"$LAST" "$LOG" | awk '{
      for (i = 1; i <= NF; i++) { split($i, kv, "="); r[kv[1]] = kv[2] }
      d = r["drill"]; if (d != "-") { split(d, p, "/"); d = p[1] "/" (p[1] + p[2] + p[3]) }
      ready = (r["readiness"] == "-") ? "-" : r["readiness"] "%"
      lv = ("level" in r) ? r["level"] : "working"
      printf "%-10s  %-28s  %-6s  %-5s  %-6s  %-7s  %-8s  %s\n", r["date"], substr(r["branch"], 1, 28), r["pr"], ready, d, r["rounds"], lv, r["stumbled"]
    }'
    W=$(weak_trend)
    if [ -n "$W" ]; then
      echo; echo "Weak lenses (stumbled in 2+ of the last 3 PRs): $(printf '%s' "$W" | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
      echo "Next Brief should lead with questions from these lenses."
    fi
    echo; echo "Rank: $(rank_of "$(grep -c . "$LOG")")  (Rookie < 3 PRs · Regular 3+ · Veteran 6+ · Senior 12+ · Master 25+; ★ = last five average 85%+)"
    echo "Past Q&A files: $STATS_DIR/<branch>/PR_QA.md (kept until you delete the directory)"
    ;;
  weak)
    weak_trend
    ;;
  banner)
    [ -n "$BRANCH" ] || { echo "ERROR: --branch is required" >&2; exit 2; }
    # pad to N display columns: the box-drawing, bar and arrow glyphs are multibyte but one column wide,
    # so count them as one byte each before measuring (bash substitution is bytewise, which is what we want)
    pad() { local s="$1" n="$2" t; t=${s//█/x}; t=${t//░/x}; t=${t//←/x}; t=${t//·/x}; t=${t//═/x}; t=${t//★/x}
            printf '%s' "$s"; local i=${#t}; while [ "$i" -lt "$n" ]; do printf ' '; i=$((i + 1)); done; }
    rep() { local i=0; while [ "$i" -lt "$2" ]; do printf '%s' "$1"; i=$((i + 1)); done; }
    LASTPCT=""; COUNT=0
    if [ -f "$LOG" ]; then
      COUNT=$(grep -c . "$LOG")
      LASTPCT=$(tail -1 "$LOG" | sed -n 's/.*readiness=\([^ ]*\).*/\1/p'); [ "$LASTPCT" = "-" ] && LASTPCT=""
    fi
    W=$(weak_trend | sed 's/ (.*//' | tr '\n' ',' | sed 's/,$//; s/,/, /g')
    RANK=$(rank_of "$COUNT")
    COLS="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"
    B=$(printf '%.26s' "$BRANCH")
    if [ "$COLS" -lt 60 ]; then
      # narrow terminal or CI log: one line
      printf '🔥 pr-grill · %s%s · %s · Readiness %s 0%%%s%s\n' "$B" "${PROFILE:+ · $PROFILE}" "$RANK" "$(bar 0)" "${LASTPCT:+ · last $LASTPCT%}" "${W:+ · weak: $W}"
    else
      # start card, 50 columns inside the frame
      line() { printf '║  '; pad "$1" 50; printf '  ║\n'; }
      printf '╔═══ pr-grill ═══%s╗\n' "$(rep '═' 38)"
      line "$(pad "$B" 26)  ${PROFILE:-}"
      line "Readiness $(bar 0)  0%${LASTPCT:+    last PR: $LASTPCT%}"
      line "$RANK · $COUNT PR(s) on record${W:+ · weak lately: $W}"
      printf '╚%s╝\n' "$(rep '═' 54)"
    fi
    ;;
  ''|-h|--help) usage ;;
  *) echo "ERROR: unknown command: $CMD" >&2; usage >&2; exit 2 ;;
esac
