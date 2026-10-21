package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
)

func fixtureApp(t *testing.T) *app {
	t.Helper()
	home := t.TempDir()
	state := filepath.Join(home, "state")
	if err := os.MkdirAll(state, 0700); err != nil {
		t.Fatal(err)
	}
	payload := board{Schema: "fm-crew-board.v1", Home: "test-home", Rows: []worker{
		{ID: "alpha", Project: "widget", Title: "Make the widget spin", Phase: "testing", PhaseSince: time.Now().Unix() - 300},
		{ID: "beta", Project: "gadget", Title: "Fix the gadget", Phase: "fixing", PhaseSince: time.Now().Unix() - 60},
	}}
	raw, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(state, "crew-board.json"), raw, 0600); err != nil {
		t.Fatal(err)
	}
	loaded, err := (paths{State: state}).readBoard()
	if err != nil {
		t.Fatal(err)
	}
	m := newApp(paths{Home: home, State: state}, loaded, nil)
	m.width, m.height = 120, 30
	return m
}

func key(r rune) tea.KeyPressMsg                { return tea.KeyPressMsg(tea.Key{Code: r, Text: string(r)}) }
func special(r rune) tea.KeyPressMsg            { return tea.KeyPressMsg(tea.Key{Code: r}) }
func ctrl(r rune) tea.KeyPressMsg               { return tea.KeyPressMsg(tea.Key{Code: r, Mod: tea.ModCtrl}) }
func alt(r rune) tea.KeyPressMsg                { return tea.KeyPressMsg(tea.Key{Code: r, Mod: tea.ModAlt}) }
func press(m *app, msg tea.KeyPressMsg) tea.Cmd { _, cmd := m.Update(msg); return cmd }

func TestBoardRowsAndCountsRender(t *testing.T) {
	m := fixtureApp(t)
	view := m.View().Content
	for _, text := range []string{"WORKERS", "widget / Make the widget spin", "TESTING 1", "FIXING 1", "FEED", "NOTE [all]"} {
		if !strings.Contains(view, text) {
			t.Errorf("render missing %q", text)
		}
	}
	counts := phaseCounts(m.data.liveWorkers())
	if counts["testing"] != 1 || counts["fixing"] != 1 {
		t.Fatalf("counts = %#v", counts)
	}
}

func TestAllPagesRenderLocalPanels(t *testing.T) {
	m := fixtureApp(t)
	m.data.Panels.Phones = []item{{Title: "S22", Status: "locked", Alert: true}}
	m.data.Panels.Builds = []item{{Title: "Android build", Status: "passed"}}
	m.data.Panels.Bugs = []item{{Title: "Rocketboard login", Status: "in progress"}}
	m.data.Panels.Allowance = []item{{Title: "Codex", Status: "65% remaining"}}
	m.data.Panels.Questions = []item{{Title: "Which release?", Detail: "Blocks Android build"}}
	if view := m.View().Content; !strings.Contains(view, "WAITING ON YOU") || !strings.Contains(view, "Which release?") {
		t.Fatal("NOW page did not show the captain question")
	}
	press(m, key('2'))
	view := m.View().Content
	for _, value := range []string{"TESTING", "PHONES", "S22", "BUILDS", "Android build"} {
		if !strings.Contains(view, value) {
			t.Errorf("TESTING page missing %q", value)
		}
	}
	press(m, key('3'))
	view = m.View().Content
	for _, value := range []string{"PLANNING", "ROCKETBOARD BUGS", "Rocketboard login", "AI ALLOWANCE", "Codex"} {
		if !strings.Contains(view, value) {
			t.Errorf("PLANNING page missing %q", value)
		}
	}
}

func TestQuestionsPageShowsBothFullPanels(t *testing.T) {
	m := fixtureApp(t)
	m.data.Panels.FullQuestions = []item{
		{Title: "FOR TARUN", Status: "section"},
		{Title: "Which device?", Detail: "Use the staging device"},
	}
	m.data.Panels.FullBacklog = []item{
		{Title: "IN FLIGHT", Status: "section"},
		{Title: "Build widget [widget]", Detail: "Finish the animation"},
	}
	press(m, key('4'))
	view := m.View().Content
	for _, value := range []string{"CAPTAIN QUESTIONS", "BACKLOG", "Which device?", "Build widget [widget]"} {
		if !strings.Contains(view, value) {
			t.Fatalf("questions page missing %q", value)
		}
	}
	press(m, key('j'))
	press(m, key('j'))
	press(m, special(tea.KeyEnter))
	if !strings.Contains(m.View().Content, "Use the staging device") {
		t.Fatal("Enter did not expand the full question")
	}
	m.width, m.height = 55, 18
	var explanation []string
	for index := range 20 {
		explanation = append(explanation, fmt.Sprintf("Line %02d explains the question in detail.", index))
	}
	m.data.Panels.FullQuestions[1].Detail = strings.Join(explanation, "\n")
	view = m.View().Content
	for _, line := range strings.Split(view, "\n") {
		if lipgloss.Width(line) > m.width {
			t.Fatal("full question overflowed the narrow panel")
		}
	}
	press(m, ctrl('f'))
	if m.scrollOffset["full_questions"] == 0 {
		t.Fatal("Ctrl-f did not scroll the expanded question")
	}
	if scrolled := m.View().Content; scrolled == view {
		t.Fatal("Ctrl-f did not change the visible question text")
	}
}

func TestCollapseAndNarrowLayout(t *testing.T) {
	m := fixtureApp(t)
	if collapsedHeight(0) != 1 || collapsedHeight(2) != 3 {
		t.Fatal("wrong collapse heights")
	}
	press(m, key(' '))
	if !m.collapsed["workers"] {
		t.Fatal("space did not collapse focused panel")
	}
	press(m, key(' '))
	if m.collapsed["workers"] {
		t.Fatal("space did not reopen panel")
	}
	press(m, key('z'))
	press(m, key('a'))
	if !m.collapsed["workers"] {
		t.Fatal("za did not collapse panel")
	}
	m.width, m.height = 55, 18
	view := m.View().Content
	for _, text := range []string{"WORKERS", "FEED", "NOTE [all]"} {
		if !strings.Contains(view, text) {
			t.Errorf("narrow render missing %q", text)
		}
	}
}

func TestViewFitsTerminal(t *testing.T) {
	m := fixtureApp(t)
	for _, size := range [][2]int{{120, 30}, {55, 18}} {
		m.width, m.height = size[0], size[1]
		for _, mode := range []string{"normal", "motion", "help", "filter"} {
			m.help, m.filterActive = false, false
			m.slide = 0
			switch mode {
			case "motion":
				m.beginMotion()
			case "help":
				m.help = true
			case "filter":
				m.filterActive = true
			}
			lines := strings.Split(m.View().Content, "\n")
			if mode == "help" && !strings.Contains(m.View().Content, "q/:q quit") {
				t.Error("help overlay hid the quit key")
			}
			if len(lines) > m.height {
				t.Errorf("%dx%d %s view has %d lines", m.width, m.height, mode, len(lines))
			}
			for index, line := range lines {
				if width := lipgloss.Width(line); width > m.width {
					t.Errorf("%dx%d %s line %d width %d", m.width, m.height, mode, index, width)
				}
			}
		}
	}
}

func TestVimKeys(t *testing.T) {
	m := fixtureApp(t)
	press(m, key('j'))
	if m.selected["workers"] != 0 {
		t.Fatal("j did not select first row")
	}
	press(m, key('j'))
	if m.selected["workers"] != 1 {
		t.Fatal("j did not move down")
	}
	press(m, key('k'))
	if m.selected["workers"] != 0 {
		t.Fatal("k did not move up")
	}
	press(m, key('G'))
	if m.selected["workers"] != 1 {
		t.Fatal("G did not move to bottom")
	}
	press(m, key('g'))
	press(m, key('g'))
	if m.selected["workers"] != 0 {
		t.Fatal("gg did not move to top")
	}
	press(m, ctrl('d'))
	if m.selected["workers"] != 1 {
		t.Fatal("Ctrl-d did not page down")
	}
	press(m, ctrl('u'))
	if m.selected["workers"] != 0 {
		t.Fatal("Ctrl-u did not page up")
	}
	press(m, alt('2'))
	if m.selected["workers"] != 1 {
		t.Fatal("Alt-2 did not select the second row")
	}
	press(m, alt('1'))
	if m.selected["workers"] != 0 {
		t.Fatal("Alt-1 did not select the first row")
	}
	press(m, special(tea.KeyEnter))
	if m.expanded["workers"] != 1 {
		t.Fatal("Enter did not expand selected row")
	}
	press(m, key('o'))
	if m.expanded["workers"] != 0 {
		t.Fatal("o did not close selected row")
	}
	press(m, key('l'))
	if m.focus != "alerts" {
		t.Fatalf("l focus = %s", m.focus)
	}
	_ = m.View()
	press(m, key('h'))
	if m.focus != "workers" {
		t.Fatalf("h did not return to the panel on the left: %s", m.focus)
	}
	press(m, key('2'))
	if m.page != 1 {
		t.Fatal("2 did not switch page")
	}
	press(m, key('3'))
	if m.page != 2 {
		t.Fatal("3 did not switch page")
	}
	press(m, key('1'))
	if m.page != 0 {
		t.Fatal("1 did not switch page")
	}
	press(m, key('?'))
	if !m.help {
		t.Fatal("? did not show help")
	}
	press(m, special(tea.KeyEsc))
	if m.help {
		t.Fatal("Esc did not close help")
	}
}

func TestWorkerFocusKey(t *testing.T) {
	m := fixtureApp(t)
	if cmd := press(m, key('O')); cmd != nil || !strings.Contains(m.notice, "Select a worker") {
		t.Fatal("O without a selected worker did not give a hint")
	}
	press(m, key('j'))
	if cmd := press(m, key('O')); cmd == nil {
		t.Fatal("O did not request focus for the selected worker")
	}
	press(m, key('?'))
	if !strings.Contains(m.View().Content, "O focus selected worker pane") {
		t.Fatal("help did not document the worker jump")
	}
}

func TestFeedShowsLatestFirstmateAcknowledgement(t *testing.T) {
	m := fixtureApp(t)
	handled := filepath.Join(m.paths.State, "inbox", "handled")
	if err := os.MkdirAll(handled, 0700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"old.note", "new.note"} {
		if err := os.WriteFile(filepath.Join(handled, name), []byte("id="+name+"\n--\nmessage\n"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	old := filepath.Join(handled, "old.note")
	if err := os.Chtimes(old, time.Now().Add(-time.Hour), time.Now().Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	feed, err := readFeed(m.paths.State)
	if err != nil || len(feed) == 0 || feed[0].ID != "new" || !strings.Contains(feed[0].Title, "Firstmate acknowledged") {
		t.Fatalf("latest acknowledgement missing from feed: %v, %v", feed, err)
	}
}

func TestSpatialPanelNavigation(t *testing.T) {
	m := fixtureApp(t)
	press(m, key('j'))
	_ = m.View()
	press(m, key('l'))
	if m.focus != "alerts" {
		t.Fatalf("right chose %s instead of the visible adjacent panel", m.focus)
	}
	_ = m.View()
	press(m, key('h'))
	if m.focus != "workers" {
		t.Fatal("left did not focus the visible panel to the left")
	}
	m.width = 55
	m.focus = "workers"
	m.selected["workers"] = 1
	_ = m.View()
	press(m, key('l'))
	if m.focus != "workers" {
		t.Fatal("right moved in a one-column layout")
	}
	press(m, key('j'))
	if m.focus != "alerts" {
		t.Fatalf("j at row edge moved to %s, want panel below", m.focus)
	}
	press(m, key('k'))
	if m.focus != "workers" {
		t.Fatalf("k in empty panel moved to %s, want panel above", m.focus)
	}
}

func TestFilterAndNoteFocus(t *testing.T) {
	m := fixtureApp(t)
	press(m, key('/'))
	if !m.filterActive {
		t.Fatal("/ did not open filter")
	}
	for _, r := range "widget" {
		press(m, key(r))
	}
	press(m, special(tea.KeyEnter))
	if m.filterActive || len(m.items("workers")) != 1 {
		t.Fatalf("filter did not apply: active=%v query=%q rows=%d", m.filterActive, m.filters["workers"], len(m.items("workers")))
	}
	press(m, key('i'))
	if !m.inputActive {
		t.Fatal("i did not focus note")
	}
	press(m, key('x'))
	press(m, special(tea.KeyEsc))
	if m.inputActive {
		t.Fatal("Esc did not leave note")
	}
	if files, _ := filepath.Glob(filepath.Join(m.paths.State, "inbox", "*.note")); len(files) != 0 {
		t.Fatal("Esc sent a note")
	}
	press(m, key(':'))
	if !m.inputActive || !m.commandMode {
		t.Fatal(": did not focus note")
	}
	press(m, special(tea.KeyEsc))
	if m.inputActive {
		t.Fatal("Esc did not leave command input")
	}
	press(m, key(':'))
	press(m, key('q'))
	command := press(m, special(tea.KeyEnter))
	if command == nil {
		t.Fatal(":q did not quit")
	}
	if _, ok := command().(tea.QuitMsg); !ok {
		t.Fatal(":q did not return QuitMsg")
	}
}

func TestStrayLetterSendsNothing(t *testing.T) {
	m := fixtureApp(t)
	code, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	m.paths.Code = code
	for _, r := range "xwnd" {
		press(m, key(r))
		if m.inputActive {
			t.Fatalf("%q opened note input", r)
		}
		if cmd := press(m, special(tea.KeyEnter)); cmd != nil {
			cmd()
		}
	}
	if files, _ := filepath.Glob(filepath.Join(m.paths.State, "inbox", "*.note")); len(files) != 0 {
		t.Fatalf("stray letter sent notes: %v", files)
	}
	if _, err := os.Stat(filepath.Join(m.paths.State, ".wake-queue")); err == nil {
		t.Fatal("stray letter woke firstmate")
	}
}

func TestInboxNote(t *testing.T) {
	m := fixtureApp(t)
	code, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	m.paths.Code = code
	row := item{ID: "alpha", Title: "widget / Make the widget spin", Status: "testing"}
	if err := m.paths.sendNote("why so slow?", &row); err != nil {
		t.Fatal(err)
	}
	files, err := filepath.Glob(filepath.Join(m.paths.State, "inbox", "*.note"))
	if err != nil || len(files) != 1 {
		t.Fatalf("notes: %v %v", files, err)
	}
	content, err := os.ReadFile(files[0])
	if err != nil {
		t.Fatal(err)
	}
	for _, part := range []string{"Crew board item: alpha", "Note: why so slow?"} {
		if !strings.Contains(string(content), part) {
			t.Errorf("note missing %q", part)
		}
	}
	wake, err := os.ReadFile(filepath.Join(m.paths.State, ".wake-queue"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(wake), "check: captain inbox note") {
		t.Fatal("inbox did not wake firstmate")
	}
}

func TestExpandedWorkerUsesPeek(t *testing.T) {
	m := fixtureApp(t)
	code := t.TempDir()
	bin := filepath.Join(code, "bin")
	if err := os.MkdirAll(bin, 0700); err != nil {
		t.Fatal(err)
	}
	peek := filepath.Join(bin, "fm-peek.sh")
	if err := os.WriteFile(peek, []byte("#!/bin/sh\nprintf 'screen of %s\\n' \"$1\"\n"), 0700); err != nil {
		t.Fatal(err)
	}
	m.paths.Code = code
	press(m, key('j'))
	cmd := press(m, key('o'))
	if cmd == nil {
		t.Fatal("expanding worker did not request a peek")
	}
	message, ok := cmd().(peekMsg)
	if !ok || message.err != nil || !strings.Contains(message.text, "screen of alpha") {
		t.Fatalf("peek result = %#v", message)
	}
}
