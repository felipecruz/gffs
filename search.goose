// The search: walking directories (hidden files, ignore files, `-g` globs,
// a maximum depth), reading each file, finding its matching lines with
// PCRE2 and printing them as ripgrep does in a pipe.
//
// A file is read whole and searched as one buffer: the regex runs over the
// buffer, and each match is widened to its line. A match that runs past
// the end of its line (`\s` can match a newline) is tried again within the
// line alone, so a pattern only ever matches inside one line.
//
// The walk is depth-first with an explicit stack, entries in byte order,
// so output is in a fixed order (ripgrep's is not). Paths are kept relative
// to the root being walked; the printed name is the root as given, a '/'
// if it doesn't end in one, and that relative path.

import std;
import os;
import glob;

// ---- The C side (native.c) ----------------------------------------------

struct Span { start: i64, end: i64 }

extern fn ffs_re_compile(pat: const u8[:], ignore_case: bool, err: u8[>..]&) -> bool;
extern fn ffs_re_find(text: const u8[:], from: i64, out: Span&) -> u8;
extern fn ffs_list_dir(path: const u8[:], out: u8[>..]&) -> bool;
extern fn ffs_stat(path: const u8[:]) -> i64;
extern fn ffs_exists(path: const u8[:]) -> bool;
extern fn ffs_read_file(path: const u8[:], out: u8[>..]&) -> i64;
extern fn ffs_realpath(path: const u8[:], out: u8[>..]&) -> bool;
extern fn ffs_strerror(err: i64, out: u8[>..]&);
extern fn ffs_stdout_is_tty() -> bool;
extern fn ffs_stdin_readable() -> bool;
extern fn ffs_write_stdout(s: const u8[:]) -> bool;
extern fn ffs_write_stderr(s: const u8[:]);
extern fn ffs_find_byte(data: const u8[:], from: i64, c: u8) -> i64;
extern fn ffs_count_byte(data: const u8[:], c: u8) -> i64;
extern fn ffs_auto_jobs() -> i64;

// ---- Options, set by the command line ------------------------------------

// What to print.
let MODE_LINES = 0;
let MODE_ONLY = 1;          // -o: each match on its own line
let MODE_COUNT = 2;         // -c: matching lines per file
let MODE_FILES_WITH = 3;    // -l: the files with a match
let MODE_QUIET = 4;         // -q: nothing; stop at the first match
let MODE_FILES = 5;         // --files: every file that would be searched

var mode = MODE_LINES;
var line_number = false;
var with_filename = false;
var before = 0;             // -B
var after = 0;              // -A
var invert = false;         // -v
var count_matches = false; // -c with -o: count matches, not lines
var max_count = -1;         // -m; -1: no limit
var binary = false;         // -a: search files with NUL bytes too
var hidden = false;         // --hidden
var use_ignores = true;     // .gitignore, .ignore, .rgignore
var vcs_ignores = true;     // the git ones
var max_depth = -1;         // -d; -1: no limit
var globs = RuleSet { lo: 0, hi: 0, any_include: false };   // -g
var have_globs = false;

fn context() -> bool { mode == MODE_LINES && (before > 0 || after > 0) }

// ---- Results ---------------------------------------------------------------

var matched = false;        // a line was reported (a file listed, with --files)
var errors = false;         // a path could not be searched; a message went to stderr
var stopped = false;        // -q matched: nothing more to do

// ---- Output ----------------------------------------------------------------

// Standard output, written in large pieces.
var out: u8[>..] = [];
// The current file as printed.
var name: u8[>..] = [];
// With context lines: something was printed, so the next file's first group
// needs a `--` before it.
var printed_group = false;

fn flush() {
    if out.len == 0 { return; }
    // The reader is gone (`| head`): nothing more to say, and no error.
    if !ffs_write_stdout(out) { exit(0); }
    out.clear();
}

fn flush_if_full() { if out.len >= 1 << 16 { flush(); } }

// "gffs: PATH: No such file or directory (os error 2)", as rg says it.
fn format_error(msg: u8[>..]&, path: u8[:], err: i64) {
    format(msg, "gffs: ", path, ": ");
    ffs_strerror(err, msg);
    format(msg, " (os error ", err, ")\n");
}

fn print_error(msg: u8[:]) {
    errors = true;
    flush();        // keep stdout and stderr in order on a terminal
    ffs_write_stderr(msg);
}

fn report_error(path: u8[:], err: i64) {
    var msg: u8[>..] = [];
    format_error(msg, path, err);
    print_error(msg);
}

// One output line: [name<sep>][number<sep>]text.
fn put_line(sep: u8, number: i64, text: u8[:]) {
    if with_filename {
        out.append(name);
        out.push(sep);
    }
    if line_number {
        format(out, number);
        out.push(sep);
    }
    out.append(text);
    out.push('\n');
}

fn put_name() {
    out.append(name);
    out.push('\n');
}

// ---- Matching lines --------------------------------------------------------

fn find_byte(data: u8[:], from: i64, c: u8) -> i64 { ffs_find_byte(data, from, c) }

fn count_newlines(data: u8[:]) -> i64 { ffs_count_byte(data, '\n') }

var span = Span { 0, 0 };

// The first match in data[..end] at or after `from`, into `span`. A match
// limit hit counts as no match.
fn re_find(data: u8[:], from: i64, end: i64) -> bool {
    return ffs_re_find(data[..end], from, span) == 1;
}

// Calls F(start, end, number) for each line of `data` with a match, in
// order: data[start..end] is the line without its newline. Stops early when
// F returns false.
fn each_matching_line<F>(data: u8[:]) {
    let n = data.len;
    var pos = 0;              // a line start: everything before it is done
    var number = 1;           // the line number at `counted`
    var counted = 0;
    while pos < n {
        guard re_find(data, pos, n) else { return; }
        let ms = span.start;
        // A newline at the end ends the last line; it does not start another.
        if ms == n && data[n - 1] == '\n' { return; }
        // The line holding the match start.
        var ls = ms;
        while ls > pos && data[ls - 1] != '\n' { ls--; }
        let le = find_byte(data, ms, '\n');
        if span.end > le {
            // Past the end of the line: look again within the line alone.
            if !re_find(data, ls, le) {
                pos = le + 1;
                continue;
            }
        }
        number += count_newlines(data[counted..ls]);
        counted = ls;
        if !F(ls, le, number) { return; }
        pos = le + 1;
    }
}

// The same for the lines without a match (-v).
fn each_other_line<F>(data: u8[:]) {
    let n = data.len;
    var next = 0;             // the first line not yet passed on or skipped
    var number = 1;
    each_matching_line(data) { ls, le, k =>
        while next < ls {
            let e = find_byte(data, next, '\n');
            if !F(next, e, number) { return; }
            next = e + 1;
            number++;
        }
        next = le + 1;
        number = k + 1;
        true
    };
    while next < n {
        let e = find_byte(data, next, '\n');
        if !F(next, e, number) { return; }
        next = e + 1;
        number++;
    }
}

// ---- Printing one file's lines ---------------------------------------------

// Per file. With context lines everything before `next_off` has been
// printed or skipped, and `next_line` is its number.
var count = 0;
var matches = 0;            // with count_matches
var next_off = 0;
var next_line = 1;
var after_left = 0;
var printed = false;

fn begin_file() {
    count = 0;
    matches = 0;
    next_off = 0;
    next_line = 1;
    after_left = 0;
    printed = false;
}

fn context_line(data: u8[:]) {
    let nl = find_byte(data, next_off, '\n');
    put_line('-', next_line, data[next_off..nl]);
    next_off = nl + 1;
    next_line++;
}

// The previous match's after-context lines that come before `end`.
fn after_context(data: u8[:], end: i64) {
    while after_left > 0 && next_off < end {
        context_line(data);
        after_left--;
    }
}

fn with_context(data: u8[:], ls: i64, le: i64, number: i64) {
    after_context(data, ls);
    // Up to `before` lines back, but not into what's already printed.
    var b = ls;
    var b_line = number;
    for i in before {
        if b <= next_off { break; }
        var k = b - 1;
        while k > 0 && data[k - 1] != '\n' { k--; }
        b = k;
        b_line--;
    }
    if !printed && printed_group { out.append("--\n"); }
    if printed && b != next_off { out.append("--\n"); }
    next_off = b;
    next_line = b_line;
    while next_off < ls { context_line(data); }
    put_line(':', number, data[ls..le]);
    next_off = le + 1;
    next_line = number + 1;
    after_left = after;
    printed = true;
}

// One reported line. False: stop reading this file.
// Calls F(start, end) for each match in the line data[ls..le]: every
// match, empty ones too, as rg prints them, but not an empty match right
// where the previous one ended. Like rg, the search stops at the end of the
// line with its newline, so an empty match at the very end of a last line
// without one is not found.
fn each_match_in_line<F>(data: u8[:], ls: i64, le: i64) {
    let limit = if le < data.len { le + 1 } else { le };
    var from = ls;
    var last_end = -1;
    while re_find(data, from, le) {
        let s = span.start;
        let e = span.end;
        if e > s || s != last_end { F(s, e); }
        last_end = e;
        from = if e > s { e } else { e + 1 };
        if from >= limit { break; }
    }
}

// One reported line. False: stop reading this file.
fn on_line(data: u8[:], ls: i64, le: i64, number: i64) -> bool {
    count++;
    if mode == MODE_QUIET {
        stopped = true;
        return false;
    }
    if mode == MODE_FILES_WITH {
        put_name();
        return false;
    }
    if mode == MODE_ONLY {
        if !invert {
            each_match_in_line(data, ls, le) { s, e => put_line(':', number, data[s..e]); };
        }
    } else if mode == MODE_LINES {
        if context() { with_context(data, ls, le, number); } else { put_line(':', number, data[ls..le]); }
    } else if mode == MODE_COUNT && count_matches && !invert {
        each_match_in_line(data, ls, le) { s, e => matches++; };
    }
    return max_count < 0 || count < max_count;
}

let BOM = "\xef\xbb\xbf";

fn has_nul(data: u8[:]) -> bool { ffs_find_byte(data, 0, 0) < data.len }

// Searches one file's contents into `out`; `name` is set.
fn search_data(all: u8[:]) {
    // A file with a NUL byte is binary, and skipped.
    if !binary && has_nul(all) { return; }
    // Like ripgrep, a UTF-8 byte-order mark is not part of line 1.
    let data = if starts_with(all, BOM) { all[3..] } else { all };
    begin_file();
    if max_count == 0 { return; }
    if invert {
        each_other_line(data) { ls, le, k => on_line(data, ls, le, k) };
    } else {
        each_matching_line(data) { ls, le, k => on_line(data, ls, le, k) };
    }
    if context() {
        after_context(data, data.len);
        if printed { printed_group = true; }
    }
    // -c -o counts matches rather than lines.
    let reported = if count_matches { matches } else { count };
    if mode == MODE_COUNT && reported > 0 {
        if with_filename {
            out.append(name);
            out.push(':');
        }
        format(out, reported);
        out.push('\n');
    }
    if reported > 0 { matched = true; }
}

// Reads and searches one file into `out`; `name` is set. 0, or the errno
// that kept it from being read.
fn search_file(path: u8[:]) -> i64 {
    var data: u8[>..] = [];
    let err = ffs_read_file(path, data);
    if err == 0 { search_data(data); }
    return err;
}

// A file found by the walk, or named on the command line; `name` is set.
// Files found by the walk that can't be read are skipped silently.
fn visit_file(path: u8[:], report: bool) {
    if mode == MODE_FILES {
        put_name();
        matched = true;
    } else if threads > 1 {
        dispatch(path, report);
    } else {
        let err = search_file(path);
        if err != 0 && report { report_error(path, err); }
    }
    flush_if_full();
}

fn search_stdin() {
    name.clear();
    name.append("<stdin>");
    if mode == MODE_FILES {
        return;
    }
    var data: u8[>..] = [];
    read_stdin(data);
    search_data(data);
    flush_if_full();
}

// ---- Ignore files ----------------------------------------------------------

// The rules from the ignore files in one directory. `parent` is the next
// directory up that has any (an index into `ign_dirs`, -1 for none); rules
// nearer the file win.
struct IgnoreDir {
    parent: i64,
    rel_at: i64,          // the directory, relative to the walk root: ign_text[rel_at..+rel_len]
    rel_len: i64,
    above_at: i64,        // for a directory above the root: the root's path relative to it,
    above_len: i64,       // and -1 otherwise
    set: RuleSet,
}

var ign_dirs: IgnoreDir[>..] = [];
var ign_text: u8[>..] = [];

// What the ignore files say about `path` (relative to the root): the
// innermost directory with a matching rule decides.
fn ignored(chain: i64, path: u8[:], is_dir: bool) -> i64 {
    var node = chain;
    var buf: u8[>..] = [];
    while node >= 0 {
        let n = ign_dirs[node];
        node = n.parent;
        var d = NONE;
        if n.above_len >= 0 {
            buf.clear();
            buf.append(ign_text[n.above_at..n.above_at + n.above_len]);
            buf.push('/');
            buf.append(path);
            d = decide(n.set, buf, is_dir);
        } else if n.rel_len == 0 {
            d = decide(n.set, path, is_dir);
        } else {
            d = decide(n.set, path[n.rel_len + 1..], is_dir);
        }
        if d != NONE { return d; }
    }
    return NONE;
}

// The ignore files a directory may have, in the order they are read: in a
// repository root .git/info/exclude comes first, so it loses to the rest.
let IGNORE_FILES = 4;

fn ignore_file(k: i64) -> const u8[:] {
    match k { 0 => ".git/info/exclude", 1 => ".gitignore", 2 => ".ignore", _ => ".rgignore" }
}

// Appends the contents of the ignore files that count in the directory
// `dir` (a path to open) to `ign`, back to back; lens[k] is the length of
// ignore_file(k), or -1 if it isn't there or doesn't count.
fn read_ignore_files(dir: u8[:], git: bool, repo_root: bool, ign: u8[>..]&, lens: i64[4]&) {
    let vcs = git && vcs_ignores;
    var path: u8[>..] = [];
    for k in IGNORE_FILES {
        lens[k] = -1;
        if k == 0 && !(vcs && repo_root) { continue; }
        if k == 1 && !vcs { continue; }
        path.clear();
        path.append(dir);
        if dir.len > 0 && dir[dir.len - 1] != '/' { path.push('/'); }
        path.append(ignore_file(k));
        let start = ign.len;
        if ffs_read_file(path, ign) == 0 { lens[k] = ign.len - start; }
    }
}

// Parses ignore files read by read_ignore_files and returns the chain to
// use below their directory: a new IgnoreDir on top of `parent`, or
// `parent` if there are none. `rel` is the directory relative to the walk
// root; for a directory above the root (`is_above`), `above` is the root's
// path relative to it.
fn parse_ignores(rel: u8[:], above: u8[:], is_above: bool, ign: u8[:], lens: i64[4], parent: i64) -> i64 {
    var any = false;
    for k in IGNORE_FILES { if lens[k] >= 0 { any = true; } }
    if !any { return parent; }
    var set = new_rule_set();
    var at = 0;
    for k in IGNORE_FILES {
        if lens[k] < 0 { continue; }
        add_ignore_file(set, ign[at..at + lens[k]]);
        at += lens[k];
    }
    let rel_at = ign_text.len;
    ign_text.append(rel);
    let above_at = ign_text.len;
    ign_text.append(above);
    ign_dirs.push(IgnoreDir {
        parent: parent, rel_at: rel_at, rel_len: rel.len,
        above_at: above_at, above_len: if is_above { above.len } else { -1 }, set: set,
    });
    return ign_dirs.len - 1;
}

fn exists_in(dir: u8[:], file: u8[:]) -> bool {
    var p: u8[>..] = [];
    p.append(dir);
    if dir.len > 0 && dir[dir.len - 1] != '/' { p.push('/'); }
    p.append(file);
    return ffs_exists(p);
}

// The directory part of an absolute path: "/a/b" -> "/a", "/a" -> "/";
// -1 for "/" itself.
fn dirname_len(p: u8[:]) -> i64 {
    var end = p.len;
    while end > 1 && p[end - 1] == '/' { end--; }
    if end <= 1 { return -1; }
    var k = end - 1;
    while k > 0 && p[k] != '/' { k--; }
    return if k == 0 { 1 } else { k };
}

// ---- Reading a directory ---------------------------------------------------
//
// The part of the walk that is system calls, done by a worker with -j N
// (N > 1) or on this thread with -j 1: listing a directory, sorting it,
// looking for .git and reading the ignore files.

// What reading a directory found besides its entries.
struct DirInfo {
    ok: bool,             // false: it couldn't be read
    repo_root: bool,      // it holds .git, so its git ignore files count from here down
    lens: i64[4],         // the ignore files' lengths, as read_ignore_files gives them
}

// Reads the directory `dir` (a path to open). Its entries go to `entries`
// as lines, "d name" or "f name", sorted by name; the ignore files that
// count to `ign`. `git`: it is inside a repository already. `root_repo`: it
// is the walk root, and that holds .git.
fn read_dir(dir: u8[:], git: bool, root_repo: bool, entries: u8[>..]&, ign: u8[>..]&) -> DirInfo {
    var info = DirInfo { ok: false, repo_root: false, lens: [-1; 4] };
    var raw: u8[>..] = [];
    if !ffs_list_dir(dir, raw) { return info; }
    info.ok = true;
    var names = split(raw, '\n');
    names.pop();         // after the last newline
    sort(names) { a, b => compare(a[2..], b[2..]) < 0 };
    for n in names {
        entries.append(n);
        entries.push('\n');
    }
    if use_ignores {
        // A repository inside the tree starts using its git ignores here.
        info.repo_root = root_repo || (!git && vcs_ignores && exists_in(dir, ".git"));
        read_ignore_files(dir, git || info.repo_root, info.repo_root, ign, info.lens);
    }
    return info;
}

// ---- The walk ----------------------------------------------------------------
//
// Depth-first, entries in byte order, so the output is in a fixed order.
// With workers, a directory's listing is asked for as soon as the directory
// is found, and the walk takes the listings in its own order as they come
// back: the workers read ahead while this thread filters.

// A directory to read: its number in this walk (the job asking for its
// listing), its path relative to the root, the ignore rules that apply
// inside it, whether it is inside a git repository, and its depth (the root
// is at 0).
struct Dir { id: i64, at: i64, len: i64, ign: i64, git: bool, depth: i64 }

var dir_text: u8[>..] = [];
var dirs: Dir[>..<] = [];
var walk_root: u8[>..] = [];      // the root being walked, as a path to open
var root_is_repo = false;

// Listings that came back from the workers, by directory number:
// listed_at[id] indexes `listed`, -1 while it hasn't come.
struct Listed { info: DirInfo, ent_at: i64, ent_len: i64, ign_at: i64, ign_len: i64 }

var listed: Listed[>..] = [];
var listed_at: i64[>..] = [];
var listed_text: u8[>..] = [];

// The root as `-g` globs see it: "./a/" is "a", and "." is "".
fn glob_prefix(root: u8[:]) -> u8[:] {
    var p = root;
    loop {
        while p.len > 0 && p[p.len - 1] == '/' { p = p[..p.len - 1]; }
        if p == "." { return p[..0]; }
        guard starts_with(p, "./") else { return p; }
        p = p[2..];
        while p.len > 0 && p[0] == '/' { p = p[1..]; }
    }
}

// The path to open for a directory or file at `rel` under the root.
fn fs_path(out: u8[>..]&, rel: u8[:]) {
    out.append(walk_root);
    if rel.len > 0 {
        if walk_root[walk_root.len - 1] != '/' { out.push('/'); }
        out.append(rel);
    }
}

// Puts a directory on the stack, giving it the next number, and with
// workers asks for its listing.
fn new_dir(d: Dir) -> Dir {
    var n = d;
    n.id = listed_at.len;
    listed_at.push(-1);
    if threads > 1 {
        var p: u8[>..] = [];
        fs_path(p, dir_text[n.at..n.at + n.len]);
        qput(Job { kind: JOB_LIST, seq: n.id, report: false, git: n.git,
                   root_repo: n.len == 0 && root_is_repo, name: "", path: p[..] });
    }
    return n;
}

// Waits for the workers' listing of directory `id`.
fn wait_listing(id: i64) -> Listed {
    while listed_at[id] < 0 {
        var d = qget<Done>();
        receive(d);
    }
    return listed[listed_at[id]];
}

// The walk's own work for one directory: deciding which entries to keep,
// visiting the files and putting the subdirectories on the stack.
fn walk_dir(d: Dir, prefix: u8[:], gprefix: u8[:], info: DirInfo, listing: u8[:], ign: u8[:]) {
    let slash = prefix.len > 0 && prefix[prefix.len - 1] != '/';
    // Copied out: pushing children grows dir_text under it.
    var rel: u8[>..] = [];
    rel.append(dir_text[d.at..d.at + d.len]);
    var sub = Dir { id: 0, at: 0, len: 0, ign: d.ign, git: d.git, depth: d.depth + 1 };
    if use_ignores {
        sub.git = sub.git || info.repo_root;
        sub.ign = parse_ignores(rel, "", false, ign, info.lens, sub.ign);
    }
    var path: u8[>..] = [];         // "<rel>/<name>"
    var gpath: u8[>..] = [];        // "<glob prefix>/<rel>/<name>"
    var subdirs: i64[>..] = [];     // children found, as at/len pairs into dir_text
    var start = 0;
    while start < listing.len {
        let end = ffs_find_byte(listing, start, '\n');
        let e = listing[start..end];
        start = end + 1;
        let is_dir = e[0] == 'd';
        let entry = e[2..];
        if max_depth >= 0 && (sub.depth > max_depth || (is_dir && sub.depth == max_depth)) { continue; }
        path.clear();
        if rel.len > 0 {
            path.append(rel);
            path.push('/');
        }
        path.append(entry);
        // As in rg, the first that has a say decides: a glob, then the
        // ignore files, then the hidden check. So a matching glob or a
        // '!' line beats a leading dot.
        let keep = block {
            if have_globs {
                var gd = NONE;
                if gprefix.len > 0 {
                    gpath.clear();
                    gpath.append(gprefix);
                    gpath.push('/');
                    gpath.append(path);
                    gd = decide(globs, gpath, is_dir);
                } else {
                    gd = decide(globs, path, is_dir);
                }
                if gd == IGNORE { break false; }
                if gd == INCLUDE { break true; }
                if !is_dir && globs.any_include { break false; }
            }
            if sub.ign >= 0 {
                let id = ignored(sub.ign, path, is_dir);
                if id == IGNORE { break false; }
                if id == INCLUDE { break true; }
            }
            !(entry[0] == '.' && !hidden)
        };
        if !keep { continue; }
        if is_dir {
            subdirs.push(dir_text.len);
            dir_text.append(path);
            subdirs.push(path.len);
        } else {
            name.clear();
            name.append(prefix);
            if slash { name.push('/'); }
            name.append(path);
            var file: u8[>..] = [];
            fs_path(file, path);
            visit_file(file, false);
            if stopped { return; }
        }
    }
    // Numbered (and asked for) in order, so the workers read them in about
    // the order the walk wants them; pushed last first, so they come off
    // the stack in order.
    var found: Dir[>..] = [];
    var k = 0;
    while k < subdirs.len {
        found.push(new_dir(Dir { id: 0, at: subdirs[k], len: subdirs[k + 1], ign: sub.ign, git: sub.git, depth: sub.depth }));
        k += 2;
    }
    var j = found.len;
    while j > 0 {
        j--;
        dirs.push(found[j]);
    }
}

// Walks the directory `root` (a path to open). `prefix` is how its entries'
// paths begin when printed: the root as given, or "" with no path given.
fn walk(root: u8[:], prefix: u8[:]) {
    let gprefix = glob_prefix(prefix);
    walk_root.clear();
    walk_root.append(root);
    var top = Dir { id: 0, at: 0, len: 0, ign: -1, git: false, depth: 0 };
    root_is_repo = false;
    if use_ignores {
        // The ignore files of the directories above the root: .ignore and
        // .rgignore all the way up, the git ones up to the repository root.
        var real: u8[>..] = [];
        if ffs_realpath(root, real) {
            root_is_repo = exists_in(root, ".git");
            // Ancestors, nearest first, as lengths of `real`.
            var ancestors: i64[>..] = [];
            var p = real.len;
            loop {
                let d = dirname_len(real[..p]);
                if d < 0 { break; }
                ancestors.push(d);
                p = d;
            }
            var repo = -1;
            if !root_is_repo {
                for a, k in ancestors {
                    if exists_in(real[..a], ".git") {
                        repo = k;
                        break;
                    }
                }
            }
            top.git = root_is_repo || repo >= 0;
            // Outermost first, so each node's parent is the one above it.
            var chain = -1;
            var k = ancestors.len;
            while k > 0 {
                k--;
                let a = ancestors[k];
                var above = real[a..];
                while above.len > 0 && above[0] == '/' { above = above[1..]; }
                var ign: u8[>..] = [];
                var lens: i64[4] = [-1; 4];
                read_ignore_files(real[..a], repo >= 0 && k <= repo, repo == k, ign, lens);
                chain = parse_ignores("", above, true, ign, lens, chain);
            }
            top.ign = chain;
        }
    }
    dir_text.clear();
    listed.clear();
    listed_at.clear();
    listed_text.clear();
    dirs.push(new_dir(top));

    while dirs.len > 0 && !stopped {
        let d = dirs.pop();
        if threads > 1 {
            let l = wait_listing(d.id);
            if l.info.ok {
                walk_dir(d, prefix, gprefix, l.info, listed_text[l.ent_at..l.ent_at + l.ent_len],
                         listed_text[l.ign_at..l.ign_at + l.ign_len]);
            }
        } else {
            var dir: u8[>..] = [];
            fs_path(dir, dir_text[d.at..d.at + d.len]);
            var entries: u8[>..] = [];
            var ign: u8[>..] = [];
            let info = read_dir(dir, d.git, d.len == 0 && root_is_repo, entries, ign);
            if info.ok { walk_dir(d, prefix, gprefix, info, entries, ign); }
        }
    }
    // After -q matched: listings still on their way are for nothing.
    while dirs.len > 0 {
        let d = dirs.pop();
        if threads > 1 { wait_listing(d.id); }
    }
}

// ---- Threads ----------------------------------------------------------------
//
// With -j N (N > 1), N workers read the directories and search the files,
// and this thread decides what the walk keeps and prints. A worker is a
// separate program with its own copies of the globals, taken when it is
// spawned, so it starts out with the options as parsed; the compiled regex
// is PCRE2's, shared in C. Files go out as numbered jobs and come back as
// their output, which is printed in job order: the output is the same as
// with -j 1.
//
// Both kinds of job share one queue each way, since a worker or this
// thread can wait on only one queue.

let JOB_STOP = 0;
let JOB_SEARCH = 1;           // search the file `path`, printed as `name`
let JOB_LIST = 2;             // read the directory `path`: read_dir

struct Job { kind: i64, seq: i64, report: bool, git: bool, root_repo: bool, name: u8[], path: u8[] }

// A job's result. For a search: whether it matched, whether it printed
// context lines, an error message and the output. For a listing (`seq` is
// the directory's number): `info`, `err` holding the ignore files and `out`
// the entries.
struct Done { kind: i64, seq: i64, matched: bool, group: bool, info: DirInfo, err: u8[], out: u8[] }

// A Done that came back before its turn, its text in `stash_text`.
struct Stashed { seq: i64, matched: bool, group: bool, err_at: i64, err_len: i64, out_at: i64, out_len: i64 }

var threads = 1;              // -j; 1: everything on this thread
var workers: i64[>..] = [];
var next_seq = 0;             // the next job's number
var next_print = 0;           // the next job to print
var in_flight = 0;            // jobs sent, not yet back
var stash: Stashed[>..] = [];
var stash_text: u8[>..] = [];

thread_fn worker() {
    loop {
        let job = qget<Job>();
        guard job.kind != JOB_STOP else { break; }
        if job.kind == JOB_LIST {
            var entries: u8[>..] = [];
            var ign: u8[>..] = [];
            let info = read_dir(job.path, job.git, job.root_repo, entries, ign);
            qput(Done { kind: JOB_LIST, seq: job.seq, matched: false, group: false, info: info,
                        err: ign[..], out: entries[..] });
            continue;
        }
        name.clear();
        name.append(job.name);
        out.clear();
        matched = false;
        printed_group = false;
        var err: u8[>..] = [];
        let code = search_file(job.path);
        if code != 0 && job.report { format_error(err, job.path, code); }
        qput(Done { kind: JOB_SEARCH, seq: job.seq, matched: matched, group: printed_group,
                    info: DirInfo { ok: true, repo_root: false, lens: [-1; 4] }, err: err[..], out: out[..] });
    }
}

fn start_workers() {
    for i in threads { workers.push(thread_spawn(worker)); }
}

// Prints one file's results, in turn.
fn print_done(m: bool, group: bool, err: u8[:], text: u8[:]) {
    if err.len > 0 { print_error(err); }
    if m {
        matched = true;
        if mode == MODE_QUIET { exit(0); }
    }
    // Context groups of different files are separated by `--`.
    if group {
        if printed_group { out.append("--\n"); }
        printed_group = true;
    }
    out.append(text);
    flush_if_full();
}

// Prints the stashed results that are now in turn.
fn print_stashed() {
    loop {
        var k = -1;
        for st, i in stash { if st.seq == next_print { k = i; } }
        if k < 0 { break; }
        let st = stash[k];
        print_done(st.matched, st.group, stash_text[st.err_at..st.err_at + st.err_len],
                   stash_text[st.out_at..st.out_at + st.out_len]);
        next_print++;
        swap_remove(stash, k);
    }
    if stash.len == 0 { stash_text.clear(); }
}

// A result from a worker: a listing is kept for the walk, a search printed
// in turn.
fn receive(d: Done&) {
    if d.kind == JOB_LIST {
        let ent_at = listed_text.len;
        listed_text.append(d.out);
        let ign_at = listed_text.len;
        listed_text.append(d.err);
        listed_at[d.seq] = listed.len;
        listed.push(Listed { info: d.info, ent_at: ent_at, ent_len: d.out.len, ign_at: ign_at, ign_len: d.err.len });
    } else {
        take(d);
    }
}

fn take(d: Done&) {
    in_flight--;
    if d.seq == next_print {
        print_done(d.matched, d.group, d.err, d.out);
        next_print++;
        print_stashed();
        return;
    }
    let err_at = stash_text.len;
    stash_text.append(d.err);
    let out_at = stash_text.len;
    stash_text.append(d.out);
    stash.push(Stashed { seq: d.seq, matched: d.matched, group: d.group, err_at: err_at,
                         err_len: d.err.len, out_at: out_at, out_len: d.out.len });
}

// Sends a file to the workers, and prints whatever has come back. At most
// a few jobs per worker are out at once, which keeps the walk from running
// far ahead of the search and bounds what waits to be printed.
fn dispatch(path: u8[:], report: bool) {
    qput(Job { kind: JOB_SEARCH, seq: next_seq, report: report, git: false, root_repo: false,
               name: name[..], path: path });
    next_seq++;
    in_flight++;
    loop {
        var d, ok = qpoll<Done>();
        if !ok { break; }
        receive(d);
    }
    while in_flight > 8 * threads {
        var d = qget<Done>();
        receive(d);
    }
}

// Waits for every job sent so far to be printed.
fn wait_workers() {
    while in_flight > 0 {
        var d = qget<Done>();
        receive(d);
    }
}

// Waits for every job, then stops the workers.
fn finish_workers() {
    wait_workers();
    for i in workers.len { qput(Job { kind: JOB_STOP, seq: 0, report: false, git: false, root_repo: false, name: "", path: "" }); }
    for id in workers { thread_wait(id); }
}

// Searches every path: directories walked, files searched, "-" standard
// input. No paths: the current directory, printed without a "./" prefix.
fn run(paths) {
    // Workers only for a directory walk or several files.
    if threads > 1 && !single_file(paths) { start_workers(); } else { threads = 1; }
    if paths.len == 0 {
        walk(".", "");
    }
    for path in paths {
        if stopped { break; }
        if path == "-" {
            wait_workers();
            search_stdin();
            continue;
        }
        let kind = ffs_stat(path);
        if kind < 0 {
            wait_workers();
            report_error(path, -kind);
        } else if kind == 2 {
            walk(path, path);
        } else {
            name.clear();
            name.append(path);
            visit_file(path, true);
        }
    }
    if threads > 1 { finish_workers(); }
    flush();
}

// rg prints no file names when the only path is a file or standard input.
fn single_file(paths) -> bool {
    if paths.len != 1 { return false; }
    for p in paths { return p == "-" || ffs_stat(p) == 1; }
    return false;
}
