// gffs: ffs (github.com/felipecruz/ffs) in Goose. A recursive file
// searcher with ripgrep's command line, as coding agents use it:
//
//     gffs [OPTIONS] PATTERN [PATH...]
//     gffs [OPTIONS] -e PATTERN... [PATH...]
//     gffs --files [OPTIONS] [PATH...]
//
// PATTERN is a regex, run by PCRE2 (native.c). Hidden files and whatever
// .gitignore, .ignore and .rgignore list are left out by default. Output is
// ripgrep's format for a pipe (`path:line:text` with -n).
//
// Files:
//   gffs.goose    the command line (this file)
//   search.goose  the walk, the per-file search and the output
//   glob.goose    globs and ignore-file rules
//   native.c      PCRE2, and the POSIX calls the os module lacks
//
// Build: goose build gffs.goose  (gffs.build links PCRE2)

import std;
import os;
import glob;
import search;

let VERSION = "0.1.0";

// Flags, as codes.
let F_REGEXP = 0;
let F_FIXED = 1;
let F_IGNORE_CASE = 2;
let F_CASE_SENSITIVE = 3;
let F_SMART_CASE = 4;
let F_WORD = 5;
let F_LINE = 6;
let F_INVERT = 7;
let F_LINE_NUMBER = 8;
let F_NO_LINE_NUMBER = 9;
let F_WITH_FILENAME = 10;
let F_NO_FILENAME = 11;
let F_ONLY = 12;
let F_COUNT = 13;
let F_FILES_WITH = 14;
let F_QUIET = 15;
let F_FILES = 16;
let F_MAX_COUNT = 17;
let F_AFTER = 18;
let F_BEFORE = 19;
let F_CONTEXT = 20;
let F_GLOB = 21;
let F_HIDDEN = 22;
let F_NO_HIDDEN = 23;
let F_NO_IGNORE = 24;
let F_NO_IGNORE_VCS = 25;
let F_UNRESTRICTED = 26;
let F_TEXT = 27;
let F_MAX_DEPTH = 28;
let F_THREADS = 29;
let F_HELP = 30;
let F_VERSION = 31;
let F_IGNORED = 32;            // accepted for compatibility, no effect
let F_IGNORED_VALUE = 33;      // the same, with a value (--color)

fn takes_value(f: i64) -> bool {
    f == F_REGEXP || f == F_MAX_COUNT || f == F_AFTER || f == F_BEFORE || f == F_CONTEXT ||
    f == F_GLOB || f == F_MAX_DEPTH || f == F_THREADS || f == F_IGNORED_VALUE
}

fn short_flag(c: u8) -> i64 {
    match c {
        'e' => F_REGEXP, 'F' => F_FIXED, 'i' => F_IGNORE_CASE, 's' => F_CASE_SENSITIVE,
        'S' => F_SMART_CASE, 'w' => F_WORD, 'x' => F_LINE, 'v' => F_INVERT,
        'n' => F_LINE_NUMBER, 'N' => F_NO_LINE_NUMBER, 'H' => F_WITH_FILENAME,
        'I' => F_NO_FILENAME, 'o' => F_ONLY, 'c' => F_COUNT, 'l' => F_FILES_WITH,
        'q' => F_QUIET, 'm' => F_MAX_COUNT, 'A' => F_AFTER, 'B' => F_BEFORE,
        'C' => F_CONTEXT, 'g' => F_GLOB, '.' => F_HIDDEN, 'u' => F_UNRESTRICTED,
        'a' => F_TEXT, 'd' => F_MAX_DEPTH, 'j' => F_THREADS, 'h' => F_HELP,
        'V' => F_VERSION,
        _ => -1,
    }
}

fn long_flag(name: u8[:]) -> i64 {
    if name == "regexp" { return F_REGEXP; }
    if name == "fixed-strings" { return F_FIXED; }
    if name == "ignore-case" { return F_IGNORE_CASE; }
    if name == "case-sensitive" { return F_CASE_SENSITIVE; }
    if name == "smart-case" { return F_SMART_CASE; }
    if name == "word-regexp" { return F_WORD; }
    if name == "line-regexp" { return F_LINE; }
    if name == "invert-match" { return F_INVERT; }
    if name == "line-number" { return F_LINE_NUMBER; }
    if name == "no-line-number" { return F_NO_LINE_NUMBER; }
    if name == "with-filename" { return F_WITH_FILENAME; }
    if name == "no-filename" { return F_NO_FILENAME; }
    if name == "only-matching" { return F_ONLY; }
    if name == "count" { return F_COUNT; }
    if name == "files-with-matches" { return F_FILES_WITH; }
    if name == "quiet" { return F_QUIET; }
    if name == "files" { return F_FILES; }
    if name == "max-count" { return F_MAX_COUNT; }
    if name == "after-context" { return F_AFTER; }
    if name == "before-context" { return F_BEFORE; }
    if name == "context" { return F_CONTEXT; }
    if name == "glob" { return F_GLOB; }
    if name == "hidden" { return F_HIDDEN; }
    if name == "no-hidden" { return F_NO_HIDDEN; }
    if name == "no-ignore" { return F_NO_IGNORE; }
    if name == "no-ignore-vcs" { return F_NO_IGNORE_VCS; }
    if name == "unrestricted" { return F_UNRESTRICTED; }
    if name == "text" { return F_TEXT; }
    if name == "max-depth" || name == "maxdepth" { return F_MAX_DEPTH; }
    if name == "threads" { return F_THREADS; }
    if name == "help" { return F_HELP; }
    if name == "version" { return F_VERSION; }
    if name == "color" || name == "colour" { return F_IGNORED_VALUE; }
    if name == "heading" || name == "no-heading" || name == "no-messages" { return F_IGNORED; }
    return -1;
}

let HELP = """
    usage: gffs [OPTIONS] PATTERN [PATH...]
           gffs [OPTIONS] -e PATTERN... [PATH...]
           gffs --files [OPTIONS] [PATH...]

    A ripgrep-compatible search, in Goose. PATTERN is a regex (PCRE2).
    With no PATH, searches standard input if it is a pipe or file, else
    the current directory. Hidden files and paths listed in .gitignore,
    .ignore and .rgignore are skipped. Exit status: 0 if something
    matched, 1 if nothing did, 2 on an error.

    Patterns:
      -e, --regexp PATTERN    a pattern; repeat to search for any of several
      -F, --fixed-strings     patterns are literal text, not regexes
      -i, --ignore-case       letters match either case
      -S, --smart-case        ignore case unless a pattern has an upper-case letter
      -s, --case-sensitive    the default
      -w, --word-regexp       matches must be whole words
      -x, --line-regexp       matches must be whole lines
      -v, --invert-match      report the lines that do not match

    Output:
      -n, --line-number       print line numbers (default on a terminal)
      -N, --no-line-number
      -H, --with-filename     print the path (default unless one file is searched)
      -I, --no-filename
      -o, --only-matching     print each match, not the whole line
      -c, --count             print the number of matching lines per file
      -l, --files-with-matches  print only the paths of files with a match
      -q, --quiet             print nothing; the exit status says if anything matched
      -m, --max-count N       stop reading a file after N matching lines
      -A, --after-context N   N lines after each match
      -B, --before-context N  N lines before each match
      -C, --context N         N lines before and after each match

    Files:
          --files             list the files that would be searched; no PATTERN
      -g, --glob GLOB         search only files matching GLOB; !GLOB excludes
      -., --hidden            search hidden files and directories too
          --no-hidden         skip hidden files and directories (the default)
          --no-ignore         don't use .gitignore, .ignore or .rgignore files
          --no-ignore-vcs     don't use .gitignore files
      -u, --unrestricted      -u: --no-ignore; -uu: and --hidden; -uuu: and --text
      -a, --text              search binary files as if they were text
      -d, --max-depth N       descend at most N directory levels

      -j, --threads N|auto    threads searching files (default: auto, the
                              performance cores on Apple silicon, else
                              every logical CPU)
      -h, --help
      -V, --version
    """;

fn usage() {
    ffs_write_stderr("usage: gffs [OPTIONS] PATTERN [PATH...]\n       gffs --files [OPTIONS] [PATH...]\nTry 'gffs --help' for more.\n");
    exit(2);
}

fn fail(msg: u8[:]) {
    var m: u8[>..] = [];
    format(m, "gffs: ", msg, "\n");
    ffs_write_stderr(m);
    exit(2);
}

// The command line, as parsed.
let CASE_SENSITIVE = 0;
let CASE_INSENSITIVE = 1;
let CASE_SMART = 2;

var patterns: u8[][>..] = [];
var positional: u8[][>..] = [];
var fixed = false;
var case_mode = CASE_SENSITIVE;
var word = false;
var whole_line = false;
var line_number_flag = -1;      // -1: not given
var filename_flag = -1;
// -o and -q are not modes of their own, as in rg: -q wins over the rest,
// -o modifies the others (-c -o counts matches, -l -o is -l), and of -c,
// -l and --files the last one given wins.
var jobs_flag = 0;              // -j; 0: auto
var only_flag = false;
var quiet_flag = false;
var want_help = false;
var want_version = false;

fn number(v: u8[:]) -> i64 {
    let n, ok = parse_int(v);
    if !ok || n < 0 { usage(); }
    return n;
}

fn apply(f: i64, v: u8[:]) {
    match f {
        F_REGEXP => { patterns.push(v); },
        F_FIXED => { fixed = true; },
        F_IGNORE_CASE => { case_mode = CASE_INSENSITIVE; },
        F_CASE_SENSITIVE => { case_mode = CASE_SENSITIVE; },
        F_SMART_CASE => { case_mode = CASE_SMART; },
        F_WORD => { word = true; },
        F_LINE => { whole_line = true; },
        F_INVERT => { invert = true; },
        F_LINE_NUMBER => { line_number_flag = 1; },
        F_NO_LINE_NUMBER => { line_number_flag = 0; },
        F_WITH_FILENAME => { filename_flag = 1; },
        F_NO_FILENAME => { filename_flag = 0; },
        F_ONLY => { only_flag = true; },
        F_COUNT => { mode = MODE_COUNT; },
        F_FILES_WITH => { mode = MODE_FILES_WITH; },
        F_QUIET => { quiet_flag = true; },
        F_FILES => { mode = MODE_FILES; },
        F_MAX_COUNT => { max_count = number(v); },
        F_AFTER => { after = number(v); },
        F_BEFORE => { before = number(v); },
        F_CONTEXT => {
            after = number(v);
            before = after;
        },
        F_GLOB => {
            if !add_glob(globs, v) {
                var m: u8[>..] = [];
                format(m, "glob too complex: ", v);
                fail(m);
            }
            have_globs = true;
        },
        F_HIDDEN => { hidden = true; },
        F_NO_HIDDEN => { hidden = false; },
        F_NO_IGNORE => { use_ignores = false; },
        F_NO_IGNORE_VCS => { vcs_ignores = false; },
        // -u: no ignore files; -uu: and hidden files; -uuu: and binary files.
        F_UNRESTRICTED => {
            if !use_ignores {
                if hidden { binary = true; } else { hidden = true; }
            } else {
                use_ignores = false;
            }
        },
        F_TEXT => { binary = true; },
        F_MAX_DEPTH => { max_depth = number(v); },
        F_THREADS => { jobs_flag = if v == "auto" { 0 } else { number(v) }; },
        F_HELP => { want_help = true; },
        F_VERSION => { want_version = true; },
        _ => {},
    }
}

// Flags may come anywhere, as in rg; `--` ends them. Short flags combine
// (`-in`), and a value may be attached (`-A5`, `--glob=x`).
// The arguments; argument 0 is the program.
var argv = args();

fn parse() {
    var i = 1;
    var only_positional = false;
    while i < argv.len {
        let a = argv[i];
        if only_positional || a.len < 2 || a[0] != '-' {
            positional.push(a);
        } else if a == "--" {
            only_positional = true;
        } else if a[1] == '-' {
            var eq = -1;
            for c, k in a { if c == '=' && eq < 0 { eq = k; } }
            let flag_name = if eq >= 0 { a[2..eq] } else { a[2..] };
            let f = long_flag(flag_name);
            if f < 0 {
                var m: u8[>..] = [];
                format(m, "unknown option: ", a);
                fail(m);
            }
            if takes_value(f) {
                if eq >= 0 {
                    apply(f, a[eq + 1..]);
                } else {
                    i++;
                    if i == argv.len { usage(); }
                    apply(f, argv[i]);
                }
            } else {
                if eq >= 0 { usage(); }
                apply(f, a[..0]);
            }
        } else {
            var k = 1;
            while k < a.len {
                let f = short_flag(a[k]);
                if f < 0 {
                    var m: u8[>..] = [];
                    format(m, "unknown option: -", a[k..k + 1]);
                    fail(m);
                }
                if takes_value(f) {
                    if k + 1 < a.len {
                        apply(f, a[k + 1..]);
                    } else {
                        i++;
                        if i == argv.len { usage(); }
                        apply(f, argv[i]);
                    }
                    break;
                }
                apply(f, a[..0]);
                k++;
            }
        }
        i++;
    }
}

// An upper-case letter outside an escape: \W, \S, \D are classes.
fn has_upper(p: u8[:]) -> bool {
    var i = 0;
    while i < p.len {
        if p[i] == '\\' {
            i++;
        } else if p[i] >= 'A' && p[i] <= 'Z' {
            return true;
        }
        i++;
    }
    return false;
}

// Smart case: some pattern has an upper-case letter.
fn any_upper() -> bool {
    for p in patterns { if has_upper(p) { return true; } }
    return false;
}

// Text as a regex that matches it literally: every ASCII punctuation byte
// escaped, which PCRE2 allows for any non-alphanumeric.
fn escape(out: u8[>..]&, p: u8[:]) {
    for c in p {
        let alnum = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
        if c < 128 && !alnum && c != ' ' { out.push('\\'); }
        out.push(c);
    }
}

// The patterns as one regex.
fn build_pattern(src: u8[>..]&) {
    if whole_line { src.append("^(?:"); }
    if word { src.append("\\b(?:"); }
    for p, k in patterns {
        if k > 0 { src.push('|'); }
        if patterns.len > 1 { src.append("(?:"); }
        if fixed { escape(src, p); } else { src.append(p); }
        if patterns.len > 1 { src.push(')'); }
    }
    if word { src.append(")\\b"); }
    if whole_line { src.append(")$"); }
}

fn main() {
    parse();
    if quiet_flag {
        mode = MODE_QUIET;
    } else if only_flag {
        if mode == MODE_LINES { mode = MODE_ONLY; }
        if mode == MODE_COUNT { count_matches = true; }
    }

    if want_help {
        ffs_write_stderr(HELP);
        ffs_write_stderr("\n");
        exit(0);
    }
    if want_version {
        var m: u8[>..] = [];
        format(m, "gffs ", VERSION, "\n");
        ffs_write_stderr(m);
        exit(0);
    }

    // The first positional argument is the pattern, unless -e gave one.
    let skip = if mode != MODE_FILES && patterns.len == 0 { 1 } else { 0 };
    if skip == 1 && positional.len == 0 { usage(); }
    var paths: u8[][>..] = [];
    for p, k in positional {
        if k < skip { patterns.push(copy(p)); } else { paths.push(copy(p)); }
    }
    // No path: standard input if something is piped in, as rg does, else
    // the current directory.
    let use_stdin = paths.len == 0 && mode != MODE_FILES && ffs_stdin_readable();

    if mode != MODE_FILES {
        for p in patterns {
            if contains(p, '\n') { fail("the literal '\\n' is not allowed in a regex"); }
        }
        let ignore_case = match case_mode {
            CASE_INSENSITIVE => true,
            CASE_SMART => !any_upper(),
            _ => false,
        };
        var src: u8[>..] = [];
        build_pattern(src);
        var err: u8[>..] = [];
        if !ffs_re_compile(src, ignore_case, err) {
            var m: u8[>..] = [];
            format(m, "regex parse error: ", err, " in ", src);
            fail(m);
        }
    }

    // On a terminal rg numbers lines; in a pipe only with -n.
    line_number = if line_number_flag < 0 { ffs_stdout_is_tty() } else { line_number_flag == 1 };

    // Never more workers than the data stacks allow.
    threads = min(if jobs_flag == 0 { ffs_auto_jobs() } else { jobs_flag }, max(1, hardware_threads()));

    if use_stdin {
        with_filename = filename_flag == 1;
        var stdin_only: u8[][>..] = [];
        stdin_only.push("-");
        run(stdin_only);
    } else {
        with_filename = if filename_flag < 0 { !single_file(paths) } else { filename_flag == 1 };
        run(paths);
    }

    if mode == MODE_QUIET && matched { exit(0); }
    exit(if errors { 2 } else if matched { 0 } else { 1 });
}
