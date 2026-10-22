// Unit tests for glob.goose: goose run glob_test.goose
import std;
import glob;

var failures = 0;

fn check(name: u8[:], got: bool, want: bool) {
    if got != want {
        print("FAIL ", name, " got ", got);
        failures++;
    }
}

fn main() {
    check("a", glob_match("*.c", "x.c", false), true);
    check("b", glob_match("*.c", "d/x.c", false), false);
    check("c", glob_match("a/**", "a/b/c", false), true);
    check("d", glob_match("**/gen/*.c", "x/y/gen/z.c", false), true);
    check("e", glob_match("**/gen/*.c", "gen/z.c", false), true);
    check("f", glob_match("a/**/b", "a/b", false), true);
    check("g", glob_match("a/**/b", "a/x/y/b", false), true);
    check("h", glob_match("[a-c]?d", "bxd", false), true);
    check("i", glob_match("[!a-c]?d", "bxd", false), false);
    check("j", glob_match("*Test*", "JobTests.swift", false), true);
    var s = new_rule_set();
    add_glob(s, "*.{h,tcl}");
    add_glob(s, "!tests/unit/**");
    check("k", decide(s, "src/a.h", false) == INCLUDE, true);
    check("l", decide(s, "tests/unit/a.tcl", false) == IGNORE, true);
    check("m", decide(s, "src/a.c", false) == NONE, true);
    var t = new_rule_set();
    add_ignore_file(t, "build\n/top-ignored.txt\n*.log\n!keep.log\n# c\n\n");
    check("n", decide(t, "build", true) == IGNORE, true);
    check("o", decide(t, "a/build", true) == IGNORE, true);
    check("p", decide(t, "x.log", false) == IGNORE, true);
    check("q", decide(t, "keep.log", false) == INCLUDE, true);
    check("r", decide(t, "top-ignored.txt", false) == IGNORE, true);
    check("s", decide(t, "a/top-ignored.txt", false) == NONE, true);
    var u = new_rule_set();
    add_glob(u, "{a,{b,c}d}x");
    check("t", decide(u, "cdx", false) == INCLUDE, true);
    check("u", decide(u, "ax", false) == INCLUDE, true);
    check("v", decide(u, "bx", false) == NONE, true);
    print("glob tests: ", failures, " failed");
    if failures > 0 { exit(1); }
}
