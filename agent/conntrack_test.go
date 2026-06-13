package agent

import (
	"strings"
	"testing"

	"github.com/henrygd/beszel/internal/entities/system"
)

func TestParseConntrackStat(t *testing.T) {
	// Two CPU rows; hex values. Columns deliberately ordered like a real kernel
	// (header drives the index mapping, so order independence is what we verify).
	const sample = `entries  searched found new invalid ignore delete delete_list insert insert_failed drop early_drop icmp_error  expect_new expect_create expect_delete search_restart
00000064  00000000 0000000a 00000000 00000002 00000000 00000000 00000000 00000000 00000001 00000003 00000000 00000000  00000000 00000000 00000000 00000005
00000064  00000000 00000014 00000000 00000004 00000000 00000000 00000000 00000000 00000002 00000005 00000001 00000000  00000000 00000000 00000000 0000000a`

	var st system.ConntrackStats
	if err := parseConntrackStat(strings.NewReader(sample), &st); err != nil {
		t.Fatalf("parseConntrackStat: %v", err)
	}

	// found 0xa+0x14=30, invalid 0x2+0x4=6, insert_failed 0x1+0x2=3,
	// drop 0x3+0x5=8, early_drop 0x0+0x1=1, search_restart 0x5+0xa=15
	for _, c := range []struct {
		name string
		got  uint64
		want uint64
	}{
		{"found", st.Found, 30},
		{"invalid", st.Invalid, 6},
		{"insert_failed", st.InsertFailed, 3},
		{"drop", st.Drop, 8},
		{"early_drop", st.EarlyDrop, 1},
		{"search_restart", st.SearchRestart, 15},
	} {
		if c.got != c.want {
			t.Errorf("%s = %d, want %d", c.name, c.got, c.want)
		}
	}
}

// A kernel that omits some columns (e.g. no search_restart) must not error;
// the absent counters simply stay zero.
func TestParseConntrackStatMissingColumns(t *testing.T) {
	const sample = `entries found invalid drop
00000064 00000007 00000001 00000002`

	var st system.ConntrackStats
	if err := parseConntrackStat(strings.NewReader(sample), &st); err != nil {
		t.Fatalf("parseConntrackStat: %v", err)
	}
	if st.Found != 7 || st.Drop != 2 || st.Invalid != 1 {
		t.Errorf("found=%d drop=%d invalid=%d", st.Found, st.Drop, st.Invalid)
	}
	if st.SearchRestart != 0 || st.EarlyDrop != 0 || st.InsertFailed != 0 {
		t.Errorf("absent columns should be zero: sr=%d ed=%d if=%d", st.SearchRestart, st.EarlyDrop, st.InsertFailed)
	}
}
