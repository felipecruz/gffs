#!/usr/bin/env bash
# Diffs gffs against rg over a source tree (written for a Redis 8.0.2
# checkout), both outputs sorted. Usage: tests/rg_diff.sh GFFS TREE
G=$(realpath "$1"); cd "$2" || exit 2; pass=0; fail=0
c() {
  want=$(rg "$@" </dev/null 2>/dev/null | LC_ALL=C sort); wr=${PIPESTATUS[0]}
  got=$("$G" "$@" </dev/null 2>/dev/null | LC_ALL=C sort); gr=${PIPESTATUS[0]}
  want_rc=$(rg "$@" </dev/null >/dev/null 2>&1; echo $?); got_rc=$("$G" "$@" </dev/null >/dev/null 2>&1; echo $?)
  if [ "$want" = "$got" ] && [ "$want_rc" = "$got_rc" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $* (rc $want_rc vs $got_rc)"; diff <(echo "$want") <(echo "$got") | head -6 | sed 's/^/    /'; fi
}
c --files -g '*README*' -g Makefile -g '*.sh' -g AGENTS.md
c --files --hidden -g '*instructions*' -g CLAUDE.md -g AGENTS.md
c -n 'dictFind|dictAdd|dictDelete' src
c -n 'struct redisServer \{|struct client \{' src/server.h
c -n -A40 '^dictEntry \*dictFind\(' src/dict.c
c -n 'lazyfree|lazyFree|LazyFree' src
c -n serverAssert
c -c 'serverLog\(LL_WARNING' src
c -l aeCreateFileEvent src
c -w -n dictSize src
c -o -n 'REDIS_VERSION "[0-9.]+"|RDB_VERSION [0-9]+' src
c -n -g '*.tcl' 'lazyfree' tests
c -n '[0-9a-f]{16}' src
c -n 'dictFind|struct [a-z]+ \{' src
c -i -n 'todo|fixme'
c -n -C3 'aeMain' src
c -n -B2 -A1 'return C_ERR;' src/server.c
c -c -v '^#' src
c -x -n '}' src/ae.c
c -F -n 'd->type->' src
c -n -e DICT_OK -e DICT_ERR src/dict.h
c -S -c lazyfree src
c -S -c lazyFree src
c -m2 -n '#include' src
c -o '\w+\(' src/ae.c
c -n '\bint\b' src/ae.c
c -c '' src
c -n 'é|ü|日本' .
c -o -i 'redis[a-z]*' README.md
c --files -d 2
c --files -g '!src/**' -g '*.c'
c --files --no-ignore
c --files -u
c --files -uu -g '!.git'
c -n '\s+$' src/sds.c
c -n -w 'if' src/zmalloc.c
c -n '^\s*/\*' src/zmalloc.c
c -nH 'main' src/redis-cli.c
c -n 'a.*b.*c.*d' src/t_list.c
c -q REDIS_VERSION src/version.h
c -q zz_none src
c -n -A1 -B1 -m3 'if' src/adlist.c
c -n -v 'x' src/version.h
c -o '[0-9]+' src/version.h
c -n '(?i)SERVERASSERT' src/server.h
c -n -F '(' src/version.h
c -c -w 'the' src
echo "rg_diff: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
