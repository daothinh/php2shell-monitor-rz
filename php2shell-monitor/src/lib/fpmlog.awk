# fpmlog.awk - fast PHP-FPM / generic error-log -> stream TSV.
# Pure awk: one process for the whole chunk, no per-line forks.
# The generic error line is the raw line itself; the rule pack decides.
# Usage: awk -f fpmlog.awk -v src=fpm_error [-v realfile=/path -v startline=N] file
BEGIN { OFS = "\t" }

function iso_now() { return strftime("%Y-%m-%dT%H:%M:%SZ", systime()) }

# "[25-Oct-2026 15:30:59 UTC] message" or "[25-Oct-2026 15:30:59] message"
function ts_of(line,   m, mon, MN, i) {
  if (match(line, /^\[[0-9]{2}-[A-Za-z]{3}-[0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
    m = substr(line, 2, 20)
    split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", MN, " ")
    mon = 0
    for (i = 1; i <= 12; i++) if (MN[i] == substr(m, 4, 3)) { mon = i; break }
    if (mon > 0) {
      return sprintf("%s-%02d-%sT%sZ", substr(m, 8, 4), mon, substr(m, 1, 2), substr(m, 13, 8))
    }
  }
  # ISO-ish "2026-10-25 15:30:59" or "2026-10-25T15:30:59"
  if (match(line, /^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
    m = substr(line, 1, 19)
    return substr(m, 1, 10) "T" substr(m, 12, 8) "Z"
  }
  # syslog "Oct 25 15:30:59" (no year)
  if (match(line, /^[A-Z][a-z]{2} [ 0-9][0-9] [0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
    m = substr(line, 1, 15)
    split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", MN, " ")
    mon = 0
    for (i = 1; i <= 12; i++) if (MN[i] == substr(m, 1, 3)) { mon = i; break }
    if (mon > 0) {
      return sprintf("%s-%02d-%02dT%sZ", strftime("%Y", systime()), mon,
                     substr(m, 5, 2) + 0, substr(m, 8, 8))
    }
  }
  return iso_now()
}

function pid_of(line,   s) {
  if (match(line, /child [0-9]+/)) {
    s = substr(line, RSTART + 6, RLENGTH - 6)
    return s
  }
  if (match(line, /\[pid [0-9]+\]/)) {
    s = substr(line, RSTART + 5, RLENGTH - 6)
    return s
  }
  if (match(line, /pid=[0-9]+/)) {
    s = substr(line, RSTART + 4, RLENGTH - 4)
    return s
  }
  return ""
}

{
  raw = $0
  gsub(/[\t\r\n]/, " ", raw)
  if (raw == "") next
  line = (startline > 0) ? startline + NR - 1 : NR
  print ts_of(raw), src, realfile, line, "", "", "", "", "", pid_of(raw), raw, "-"
}
