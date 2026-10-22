// Globs, for `-g` and for ignore files (.gitignore, .ignore, .rgignore).
//
// Both use gitignore rules, as ripgrep does:
//
//     *  ?  [a-z] [!a]   any run of bytes but '/', one byte, a class
//     **                 any run of bytes, '/' included: `**/x`, `a/**`, `a/**/b`
//     {a,b}              alternatives
//     \x                 x literally
//
// A pattern with no '/' (other than a trailing one) matches the file name
// at any depth; with a '/', it matches the whole path, relative to the
// directory of the ignore file (or the search root, for `-g`). A trailing
// '/' matches directories only.
//
// Ignore files come with the tree being searched, so a hostile one must not
// make the search hang or run out of memory: `**` is matched in time linear
// in the pattern times the path, and `{a,b}` expansion has a budget. A rule
// that would need more is left out.
//
// Every rule lives in the global `rules`, its pattern in `rule_text`. A
// rule set is a range of `rules`: the `-g` globs are one, and each
// directory with ignore files gets one of its own.

import std;

// What a matching rule says about a path.
let NONE = 0;
let IGNORE = 1;
let INCLUDE = 2;

// How a rule matches: most ignore-file lines are a name, `*.ext` or
// `name*`, which need no glob matcher.
let SHAPE_GLOB = 0;
let SHAPE_LITERAL = 1;
let SHAPE_SUFFIX = 2;     // the pattern is what follows the `*`
let SHAPE_PREFIX = 3;     // the pattern is what comes before the `*`

// The longest pattern with `**` or `{` that is accepted: matching `**`
// keeps a state per pattern byte. Paths are shorter than this anyway.
let MAX_LEN = 4096;

struct Rule {
    at: i64,              // the pattern: rule_text[at..at + len]
    len: i64,
    shape: i64,
    basename: bool,       // matches the file name only (the pattern has no '/')
    dir_only: bool,
    kind: i64,            // IGNORE or INCLUDE
}

// Rules in order, `rules[lo..hi]`; the last one that matches a path decides.
struct RuleSet { lo: i64, hi: i64, any_include: bool }

var rule_text: u8[>..] = [];
var rules: Rule[>..] = [];

fn lower(c: u8) -> u8 { if c >= 'A' && c <= 'Z' { c + 32 } else { c } }
fn upper(c: u8) -> u8 { if c >= 'a' && c <= 'z' { c - 32 } else { c } }

fn eql(a: u8, b: u8, fold: bool) -> bool { a == b || (fold && lower(a) == lower(b)) }

// Index of the ']' closing the class at pattern[start] == '[', or -1 if
// unclosed (the '[' is then literal). A ']' first in the class is a member.
fn class_end(pattern: u8[:], start: i64) -> i64 {
    var i = start + 1;
    if i < pattern.len && (pattern[i] == '!' || pattern[i] == '^') { i++; }
    if i < pattern.len && pattern[i] == ']' { i++; }
    while i < pattern.len {
        if pattern[i] == ']' { return i; }
        i++;
    }
    return -1;
}

fn in_range_folded(lo: u8, hi: u8, c: u8) -> bool {
    let l = lower(c);
    let u = upper(c);
    (l >= lo && l <= hi) || (u >= lo && u <= hi)
}

fn in_class(body: u8[:], c: u8, fold: bool) -> bool {
    var b = body;
    let negate = b.len > 0 && (b[0] == '!' || b[0] == '^');
    if negate { b = b[1..]; }
    var found = false;
    var i = 0;
    while i < b.len {
        if i + 2 < b.len && b[i + 1] == '-' {
            let lo = b[i];
            let hi = b[i + 2];
            if (c >= lo && c <= hi) || (fold && in_range_folded(lo, hi, c)) { found = true; }
            i += 3;
        } else {
            if eql(b[i], c, fold) { found = true; }
            i++;
        }
    }
    return found != negate;
}

// One byte of the pattern (or one class) at pattern[p] against `c`: the
// position after it on a match, else -1.
fn match_one(pattern: u8[:], p: i64, c: u8, fold: bool) -> i64 {
    let pc = pattern[p];
    if pc == '?' {
        return if c == '/' { -1 } else { p + 1 };
    }
    if pc == '[' {
        let end = class_end(pattern, p);
        if end >= 0 {
            if c == '/' || !in_class(pattern[p + 1..end], c, fold) { return -1; }
            return end + 1;
        }
    }
    if pc == '\\' && p + 1 < pattern.len {
        return if eql(pattern[p + 1], c, fold) { p + 2 } else { -1 };
    }
    return if eql(pc, c, fold) { p + 1 } else { -1 };
}

fn has_double_star(pattern: u8[:]) -> bool {
    for i in 1..pattern.len { if pattern[i] == '*' && pattern[i - 1] == '*' { return true; } }
    return false;
}

// Does `text` match `pattern`? `*`, `?` and classes never match '/'. With
// `fold`, ASCII letters match either case. A pattern with `**` must be at
// most MAX_LEN bytes; a longer one matches nothing.
fn glob_match(pattern: u8[:], text: u8[:], fold: bool) -> bool {
    if has_double_star(pattern) { return match_states(pattern, text, fold); }
    // Only single `*`s: backtracking to the last one is enough, since a
    // later `*` can take whatever an earlier one would have.
    var p = 0;
    var t = 0;
    // Backtracking point for the last `*`: where it started in the pattern,
    // and how much of the text it has eaten so far.
    var star_p = -1;
    var star_t = 0;
    loop {
        if p < pattern.len {
            if pattern[p] == '*' {
                star_p = p;
                star_t = t;
                p++;
                continue;
            }
            if t < text.len {
                let q = match_one(pattern, p, text[t], fold);
                if q >= 0 {
                    p = q;
                    t++;
                    continue;
                }
            }
        } else if t == text.len {
            return true;
        }
        // Mismatch: let the last `*` eat one more byte, but never a '/'.
        if star_p < 0 { return false; }
        if star_t >= text.len || text[star_t] == '/' { return false; }
        star_t++;
        p = star_p + 1;
        t = star_t;
    }
}

// State flags of a pattern position: `AT` it, or (for `**/` only) inside
// the directories it matches. From `AT`, `**/` can match no directory at
// all, but once a byte is read it must end with a '/'.
let AT: u8 = 1;
let IN_DIRS: u8 = 2;

// The token at pattern[p]: 0 one byte or class, 1 a single `*`, 2 a `**`.
// For `**`, also where it ends (after the '/' of `**/`) and whether it had
// that slash.
fn token(pattern: u8[:], p: i64) -> i64, i64, bool {
    if pattern[p] != '*' { return 0, 0, false; }
    if p + 1 == pattern.len || pattern[p + 1] != '*' { return 1, 0, false; }
    var rest = p + 2;
    while rest < pattern.len && pattern[rest] == '*' { rest++; }
    if rest < pattern.len && pattern[rest] == '/' { return 2, rest + 1, true; }
    return 2, rest, false;
}

// Adds the states reachable without reading a byte: past a `*` or `**`
// that matches nothing, and into `**/`'s directories. They are all at or
// after the position they come from, so one pass does it.
fn skip_empty(pattern: u8[:], set: u8[:]) {
    for p in pattern.len {
        if set[p] & AT == 0 { continue; }
        let kind, to, slash = token(pattern, p);
        if kind == 2 {
            set[to] |= AT;
            if slash { set[p] |= IN_DIRS; }
        } else if kind == 1 {
            set[p + 1] |= AT;
        }
    }
}

// A pattern with `**`, run as an automaton whose states are positions in
// the pattern: every position the text read so far can have reached is
// tracked at once, so no choice is ever retried. `**/` matches zero or more
// whole directories, any other `**` any run of bytes, '/' included.
fn match_states(pattern: u8[:], text: u8[:], fold: bool) -> bool {
    if pattern.len > MAX_LEN { return false; }
    var a: u8[>..] = [];
    a.resize(pattern.len + 1, 0);
    var b: u8[>..] = [];
    b.resize(pattern.len + 1, 0);
    var cur_is_a = true;
    a[0] = AT;
    skip_empty(pattern, a);
    for c in text {
        let cur: u8[:] = if cur_is_a { a } else { b };
        let next: u8[:] = if cur_is_a { b } else { a };
        fill(next, 0);
        var alive = false;
        for p in pattern.len {
            let flags = cur[p];
            if flags == 0 { continue; }
            alive = true;
            let kind, to, slash = token(pattern, p);
            if flags & IN_DIRS != 0 {
                // Inside `**/`'s directories: any byte, and after a '/'
                // possibly the end of them.
                next[p] |= IN_DIRS;
                if c == '/' { next[to] |= AT; }
            }
            if flags & AT == 0 { continue; }
            if kind == 2 {
                if !slash { next[p] |= AT; }
            } else if kind == 1 {
                if c != '/' { next[p] |= AT; }
            } else {
                let q = match_one(pattern, p, c, fold);
                if q >= 0 { next[q] |= AT; }
            }
        }
        if !alive { return false; }
        skip_empty(pattern, next);
        cur_is_a = !cur_is_a;
    }
    let last: u8[:] = if cur_is_a { a } else { b };
    return last[pattern.len] & AT != 0;
}

// The first '{' that has a matching '}', and that '}', in one pass:
// checking each '{' with a scan of its own is quadratic on `{{{{…`.
// -1, -1 if there is none.
fn first_group(pattern: u8[:]) -> i64, i64 {
    var open: i64[>..<] = [];
    var best_open = -1;
    var best_close = -1;
    var i = 0;
    while i < pattern.len {
        let c = pattern[i];
        if c == '\\' {
            i++;
        } else if c == '{' {
            open.push(i);
        } else if c == '}' && open.len > 0 {
            let o = open.pop();
            if best_open < 0 || o < best_open {
                best_open = o;
                best_close = i;
            }
        }
        i++;
    }
    return best_open, best_close;
}

// A '/' anywhere but at the end.
fn has_inner_slash(p: u8[:]) -> bool {
    for c in p { if c == '/' { return true; } }
    return false;
}

fn shape_of(pattern: u8[:], basename: bool) -> i64 {
    let meta = "*?[\\";
    var first_meta = -1;
    var metas = 0;
    for c, i in pattern {
        if contains(meta, c) {
            if first_meta < 0 { first_meta = i; }
            metas++;
        }
    }
    if metas == 0 { return SHAPE_LITERAL; }
    // '*' can't cross '/', which only holds without checking for file names.
    if !basename || pattern.len < 2 || metas > 1 { return SHAPE_GLOB; }
    if pattern[0] == '*' { return SHAPE_SUFFIX; }
    if pattern[pattern.len - 1] == '*' { return SHAPE_PREFIX; }
    return SHAPE_GLOB;
}

// Adds one rule per expansion of `pat` (its `{a,b}` groups expanded), all
// with the same `kind`, `basename` and `dir_only`. False: too complex, and
// nothing was added. `budget_bytes` is what expansion may still produce.
fn add_expanded(pat: u8[:], basename: bool, dir_only: bool, kind: i64, budget_bytes: i64&) -> bool {
    // Expansion as a work list instead of recursion: each item is a pattern
    // in `work`, and an item with a group is replaced by one item per
    // alternative. `work` only grows, so the slices into it stay valid.
    var work: u8[>..] = [];
    var items: i64[>..<] = [];     // start, end pairs into `work`
    var done: i64[>..] = [];       // finished patterns: start, end pairs
    var steps = 1024;
    work.append(pat);
    items.push(0);
    items.push(work.len);
    while items.len > 0 {
        let end = items.pop();
        let start = items.pop();
        if steps == 0 { return false; }
        steps--;
        let p = work[start..end];
        let open, close = first_group(p);
        if open < 0 {
            if p.len > MAX_LEN && has_double_star(p) { return false; }
            done.push(start);
            done.push(end);
            continue;
        }
        if p.len > MAX_LEN { return false; }
        // Each alternative between the braces, at depth 0, joined with what
        // comes before and after the group. Pushed last first, so they come
        // out in order.
        var alts: i64[>..<] = [];
        var from = open + 1;
        var depth = 0;
        var j = from;
        while j <= close {
            let c = if j == close { ',' } else { p[j] };
            if c == '\\' {
                j++;
            } else if c == '{' {
                depth++;
            } else if c == '}' {
                depth--;
            } else if c == ',' && depth == 0 {
                alts.push(from);
                alts.push(j);
                from = j + 1;
            }
            j++;
        }
        var k = alts.len;
        while k > 0 {
            k -= 2;
            let a = alts[k];
            let b = alts[k + 1];
            let len = open + (b - a) + (p.len - close - 1);
            if len > budget_bytes { return false; }
            budget_bytes -= len;
            let s = work.len;
            work.append(p[..open]);
            work.append(p[a..b]);
            work.append(p[close + 1..]);
            items.push(s);
            items.push(work.len);
        }
    }
    var k = 0;
    while k < done.len {
        let p = work[done[k]..done[k + 1]];
        k += 2;
        let shape = shape_of(p, basename);
        let lit = if shape == SHAPE_SUFFIX { p[1..] } else if shape == SHAPE_PREFIX { p[..p.len - 1] } else { p };
        let at = rule_text.len;
        rule_text.append(lit);
        rules.push(Rule { at: at, len: lit.len, shape: shape, basename: basename, dir_only: dir_only, kind: kind });
    }
    return true;
}

// Adds one gitignore-style pattern to the set, which must be the last one
// made. A leading '!' means the opposite of `kind_plain`. False: the
// pattern was too complex, and was left out.
fn add_rule(set: RuleSet&, line: u8[:], kind_plain: i64, budget_bytes: i64&) -> bool {
    var pat = line;
    var kind = kind_plain;
    if pat.len > 0 && pat[0] == '!' {
        kind = if kind == IGNORE { INCLUDE } else { IGNORE };
        pat = pat[1..];
    } else if pat.len > 1 && pat[0] == '\\' && (pat[1] == '!' || pat[1] == '#') {
        pat = pat[1..];
    }
    var dir_only = false;
    if pat.len > 1 && pat[pat.len - 1] == '/' {
        dir_only = true;
        pat = pat[..pat.len - 1];
    }
    if pat.len == 0 { return true; }
    let basename = !has_inner_slash(pat);
    if pat[0] == '/' { pat = pat[1..]; }
    guard add_expanded(pat, basename, dir_only, kind, budget_bytes) else { return false; }
    set.hi = rules.len;
    if kind == INCLUDE { set.any_include = true; }
    return true;
}

// A new, empty set at the end of `rules`.
fn new_rule_set() -> RuleSet { RuleSet { lo: rules.len, hi: rules.len, any_include: false } }

// Adds a `-g` glob. False: it was too complex.
fn add_glob(set: RuleSet&, glob: u8[:]) -> bool {
    var budget = 1 << 20;
    return add_rule(set, glob, INCLUDE, budget);
}

// Adds every line of an ignore file: comments and blank lines skipped,
// trailing spaces trimmed (unless escaped), lines too complex to use
// skipped too. The bytes expansion may produce are budgeted for the whole
// file, in proportion to its size.
fn add_ignore_file(set: RuleSet&, contents: u8[:]) {
    var budget = 2 * contents.len + (1 << 20);
    each_split(contents, '\n') {
        var line = it;
        if line.len > 0 && line[line.len - 1] == '\r' { line = line[..line.len - 1]; }
        if line.len > 0 && line[0] != '#' {
            while line.len > 0 && line[line.len - 1] == ' ' && !(line.len > 1 && line[line.len - 2] == '\\') {
                line = line[..line.len - 1];
            }
            add_rule(set, line, IGNORE, budget);
        }
    };
}

// The last rule of the set matching `path` (relative, '/'-separated):
// IGNORE, INCLUDE or NONE.
fn decide(set: RuleSet, path: u8[:], is_dir: bool) -> i64 {
    var slash = -1;
    for c, i in path { if c == '/' { slash = i; } }
    let base = path[slash + 1..];
    var i = set.hi;
    while i > set.lo {
        i--;
        let r = rules[i];
        if r.dir_only && !is_dir { continue; }
        let text = if r.basename { base } else { path };
        let pat = rule_text[r.at..r.at + r.len];
        let hit = match r.shape {
            SHAPE_LITERAL => pat == text,
            SHAPE_SUFFIX => ends_with(text, pat),
            SHAPE_PREFIX => starts_with(text, pat),
            _ => glob_match(pat, text, false),
        };
        if hit { return r.kind; }
    }
    return NONE;
}
