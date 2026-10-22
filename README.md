# gffs

[ffs](https://github.com/felipecruz/ffs), a recursive file searcher with
ripgrep's command line, ported to [Goose](https://github.com/aardappel/goose).
Regexes are run by PCRE2.

```console
$ gffs -n -w 'dictFind|dictAdd|dictDelete' src/dict.h
125: * dictAdd, dictFind, and other functions against the dictionary even while
208:int dictAdd(dict *d, void *key, void *val);
215:int dictDelete(dict *d, const void *key);
221:dictEntry * dictFind(dict *d, const void *key);
```

## Build

You need git, CMake 3.27 or later, a C++20 compiler (to build Goose) and
PCRE2 (`brew install pcre2`, or `libpcre2-dev` on Linux).

```bash
scripts/setup-goose.sh                  # clones and builds Goose into ./goose
goose/build/goose build gffs.goose      # writes ./gffs
tests/run.sh                            # glob unit tests + ffs's rg compatibility suite
```

`scripts/setup-goose.sh` pins Goose to the commit gffs was written against.
Set `GOOSE_REF=main` to try a newer one.

`gffs.build` links PCRE2. On macOS it looks for PCRE2 under `/opt/homebrew`,
so edit that path if your Homebrew lives in `/usr/local`. The program uses
threads, so build it with `goose build`: `goose run` can't run it because
the in-process TinyCC backend has no thread-local storage.

## What it does

It has everything in ffs's command line:

- **Patterns:** `-e` `-F` `-i` `-S` `-s` `-w` `-x` `-v`
- **Output:** `-n` `-N` `-H` `-I` `-o` `-c` `-l` `-q` `-m` `-A` `-B` `-C`
- **Files:** `--files` `-g` `--hidden` `--no-hidden` `--no-ignore`
  `--no-ignore-vcs` `-u`/`-uu`/`-uuu` `-a` `-d`
- **Other:** `-j` `-h` `-V`
- **Accepted and ignored:** `--color`, `--heading`, `--no-heading` and
  `--no-messages`

As in ffs and ripgrep, a directory search skips hidden files and binary files
(anything with a NUL byte). It also skips whatever `.gitignore` (inside a git
repository), `.git/info/exclude`, `.ignore` and `.rgignore` list, in each
directory and in the directories above the search root. Ignore files and `-g`
use git's glob syntax, plus `{a,b}`. With no path, gffs searches piped stdin,
or the current directory if nothing is piped in. Exit status is 0 when
something matched, 1 when nothing did and 2 on an error.

Run against real `rg`, gffs passes all 97 of ffs's `tests/compat.sh` command
lines. It also passes `tests/rg_diff.sh`, 47 more searches over the Redis
source tree.

## How it is put together

| File | What |
|:--|:--|
| `gffs.goose` | the command line: flags, smart case, building one regex from `-e`/`-F`/`-w`/`-x` |
| `search.goose` | the directory walk, ignore-file chains, the per-file search, ripgrep's output format, worker threads |
| `glob.goose` | gitignore globs: `*`, `?`, classes, `**` as a linear-time automaton, budgeted `{a,b}` expansion |
| `native.c` | PCRE2, plus the POSIX calls Goose's `os` module lacks (typed `readdir`, `isatty`, `fstat`, `realpath`, `errno`), and `memchr` scans |

- **Search:** each file is read whole and the regex runs over the whole
  buffer. A match is widened to its line. If a match runs past its line
  (`\s` can match a newline), gffs tries again within that line alone, so
  matches never cross lines.
- **Threads:** `-j N` workers (Goose `thread_fn`s, which share no memory)
  do the system-call work, from one job queue:
  - **Listing directories:** `readdir`, sorting, the `.git` check and
    reading the ignore files.
  - **Searching files:** reading each file and running the regex.

  The main thread asks for a directory's listing as soon as it finds the
  directory, so the workers read ahead. It keeps the parsed ignore rules,
  decides which entries to keep, and takes listings in depth-first order as
  they come back. Search output returns as numbered results and is printed
  in job order. So the output is the same at any `-j`, and in a fixed order,
  which ripgrep's and ffs's isn't.

## Differences from ffs

- **The regex engine is PCRE2** in UTF mode, with Unicode properties and
  invalid UTF-8 allowed, instead of ffs's own engine. `-i`, `\w`, `\d` and
  `\b` are Unicode-aware, as they are in ripgrep; in ffs they are ASCII-only.
  Syntax errors come with PCRE2's messages.
- **`-o`** prints empty matches and counts matches with `-c`, as ripgrep
  does. ffs skips empty matches.
- **Output is in a fixed order**: entries are sorted bytewise and walked
  depth-first.
- **Files are read whole** instead of streamed through a fixed buffer.
- **Error messages start with `gffs:`.**

## Speed

These were measured on an Apple M-series machine with 4 performance cores,
while other processes loaded it (a load average of 6 to 9 on 8 cores). The
tools ran interleaved, so the comparison between them is fair, but the
absolute times are higher than on an idle machine. Each time is the mean of
the faster half of the runs.

The 15 searches from ffs's `bench/agent.sh`, in a Redis 8.0.2 checkout:

| | gffs | ffs | ripgrep |
|:--|--:|--:|--:|
| all 15 searches | 502 ms | 460 ms | 526 ms |
| `-n '[0-9a-f]{16}' src`, a regex with no literal | 41 ms | 73 ms | 37 ms |
| `--files` | 22 ms | 15 ms | 24 ms |

An LLVM checkout, 187,000 files in 17,000 directories:

| | gffs `-j1` | gffs | ffs | ripgrep |
|:--|--:|--:|--:|--:|
| `--files` | 1,106 ms | 786 ms | 769 ms | 539 ms |
| `-c -g '*.td' 'def [A-Z]+[0-9]+'` | 1,986 ms | 1,108 ms | 1,076 ms | 798 ms |

Where gffs is slower than ffs or ripgrep:

- **`-i`:** PCRE2's caseless matching is slower than ffs's literal
  prefilter.
- **Large trees:** the main thread decides which entries to keep
  (globs and ignore rules) on its own, and that is what limits the walk
  there.
