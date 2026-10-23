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
	"github.com/charmbracelet/x/ansi"
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

func TestHeaderShowsHomeAndTabState(t *testing.T) {
	m := fixtureApp(t)
	m.data.Home = "firstmate"
	m.data.Panels.Alerts = []item{{Title: "Needs attention", Alert: true}}
	header := m.header()
	if strings.Contains(header, "//  firstmate") || !strings.Contains(header, "WORKERS 2") {
		t.Fatalf("primary header has duplicate home or no worker count: %q", header)
	}
	active := lipgloss.NewStyle().Foreground(background).Background(yellow).Bold(true).Render(" 1 NOW ")
	badge := lipgloss.NewStyle().Foreground(background).Background(red).Bold(true).Render(" 1 ")
	if !strings.Contains(header, active) || strings.Contains(header, badge) || !strings.Contains(header, "1 NEW: Needs attention") {
		t.Fatal("active tab missing, or a rail notification badged the NOW tab instead of the header")
	}
	m.data.Home = "secondmate"
	m.page = 1
	header = m.header()
	if !strings.Contains(header, "FIRSTMATE  //  secondmate") || strings.Contains(header, active) {
		t.Fatal("secondmate home or changed active tab missing")
	}
}

func TestAllPagesRenderLocalPanels(t *testing.T) {
	m := fixtureApp(t)
	m.data.Panels.Phones = []item{{Title: "S22", Status: "locked", Alert: true}}
	m.data.Panels.TestQueue = []item{{Title: "Galaxy S22", Status: "section"}, {Title: "Locked", Status: "locked"}}
	m.data.Panels.Builds = []item{{Title: "Android build", Status: "passed"}}
	m.data.Panels.Bugs = []item{{Title: "Rocketboard login", Status: "in progress"}}
	m.data.Panels.Allowance = []item{{Title: "Codex", Status: "65% remaining"}}
	m.data.Panels.FullQuestions = []item{{Title: "Which release?", Detail: "Blocks Android build"}}
	if view := m.View().Content; strings.Contains(view, "WAITING ON YOU") || strings.Contains(view, "Which release?") {
		t.Fatal("NOW page still duplicates the captain questions")
	}
	press(m, key('4'))
	view := m.View().Content
	for _, value := range []string{"TESTING", "TEST QUEUE", "Galaxy S22", "LATEST BUILDS", "Android build"} {
		if !strings.Contains(view, value) {
			t.Errorf("TESTING page missing %q", value)
		}
	}
	press(m, key('2'))
	view = m.View().Content
	for _, value := range []string{"PLANNING", "ROCKETBOARD BUGS", "Rocketboard login", "AI ALLOWANCE", "Codex"} {
		if !strings.Contains(view, value) {
			t.Errorf("PLANNING page missing %q", value)
		}
	}
}

func TestQuestionsPageShowsOnlyCaptainQuestions(t *testing.T) {
	m := fixtureApp(t)
	m.data.Panels.FullQuestions = []item{
		{Title: "For Tarun", Status: "section"},
		{Title: "Which device?", Detail: "Use the staging device"},
	}
	m.data.Panels.FullBacklog = []item{
		{Title: "In flight", Status: "section"},
		{Title: "Build widget [widget]", Detail: "Finish the animation"},
	}
	press(m, key('3'))
	if len(pages[2]) != 1 || pages[2][0].id != "full_questions" {
		t.Fatalf("QUESTIONS sub-tabs = %#v, want only CAPTAIN QUESTIONS", pages[2])
	}
	view := m.View().Content
	if !strings.Contains(view, "CAPTAIN QUESTIONS") || !strings.Contains(view, "Use the staging device") {
		t.Fatal("questions page did not show the highlighted question in full")
	}
	if strings.Contains(view, "BACKLOG") || strings.Contains(view, "Build widget [widget]") {
		t.Fatal("QUESTIONS still shows a backlog")
	}
	m.slide = 0
	for _, step := range []rune{'l', 'h'} {
		press(m, key(step))
		if m.focus != "full_questions" || m.slide != 0 {
			t.Fatalf("%c on a one-sub-tab page moved focus to %s or animated", step, m.focus)
		}
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
		t.Fatal("Ctrl-f did not scroll the highlighted question")
	}
	if scrolled := m.View().Content; scrolled == view {
		t.Fatal("Ctrl-f did not change the visible question text")
	}
}

func TestPlanningBacklogCarriesTheFullBacklog(t *testing.T) {
	m := fixtureApp(t)
	queued, inFlight := 1, 2
	m.data.Panels.Backlog = backlog{Queued: &queued, InFlight: &inFlight, Next: []item{{Title: "Short next row"}}}
	m.data.Panels.FullBacklog = []item{
		{Title: "In flight", Status: "section"},
		{Title: "Build widget [widget]", Detail: "Finish the **widget** animation"},
		{Title: "Queued", Status: "section"},
		{Title: "Write tests [gadget]", Detail: "Cover the startup path"},
	}
	press(m, key('2'))
	press(m, key('l'))
	if m.focus != "backlog" {
		t.Fatalf("PLANNING second sub-tab = %s, want backlog", m.focus)
	}
	view := m.View().Content
	for _, value := range []string{"In flight 2  /  Queued 1", "Build widget [widget]", "Write tests [gadget]"} {
		if !strings.Contains(view, value) {
			t.Fatalf("PLANNING backlog missing %q", value)
		}
	}
	if strings.Contains(view, "Short next row") {
		t.Fatal("PLANNING backlog showed the short next-up list instead of the full backlog")
	}
	press(m, key('j'))
	if m.selected["backlog"] != 2 {
		t.Fatalf("j selected backlog row %d, want the first task after the headings", m.selected["backlog"])
	}
	press(m, special(tea.KeyEnter))
	if view := m.View().Content; !strings.Contains(view, "Finish the widget animation") {
		t.Fatal("Enter did not show the backlog item's full note")
	}
	if count := len(withoutSections(m.items("backlog"))); count != 2 {
		t.Fatalf("backlog rows counted headings: %d", count)
	}
	m.data.Panels.FullBacklog = nil
	if !strings.Contains(m.View().Content, "Short next row") {
		t.Fatal("backlog lost its next-up fallback when the full list is unavailable")
	}
	m.data.Panels.FullBacklog = []item{{Title: "In flight", Status: "section"}, {Title: "Queued", Status: "section"}}
	rows := m.items("backlog")
	if len(rows) != 2 || rows[1].Title != "Short next row" {
		t.Fatalf("headings-only backlog = %#v, want the next-up list", rows)
	}
	m.data.Panels.FullBacklog = []item{{Title: "Backlog unavailable", Detail: "Could not read bin/fm-tasks-axi.sh", Status: "error"}}
	rows = m.items("backlog")
	if len(rows) != 3 || !strings.HasPrefix(rows[1].Title, "Backlog unavailable") || rows[2].Title != "Short next row" {
		t.Fatalf("failed full-list read = %#v, want its reason above the next-up list", rows)
	}
	view = m.View().Content
	if !strings.Contains(view, "Could not read bin/fm-tasks-axi.sh") {
		t.Fatal("backlog hid the failed full-list read")
	}
}

func TestPlanningFocusCueFollowsPanel(t *testing.T) {
	m := fixtureApp(t)
	m.data.Panels.Bugs = []item{{Title: "Login bug"}}
	m.data.Panels.FullBacklog = []item{{Title: "Build widget"}}
	m.selected["bugs"] = 0
	m.selected["backlog"] = 1
	press(m, key('2'))
	bugs, plan := pages[1][0], pages[1][1]
	before := m.View().Content
	press(m, special(tea.KeyTab))
	after := m.View().Content
	if m.focus != "backlog" || before == after || !strings.Contains(after, "Build widget") {
		t.Fatal("moving focus did not change the large panel")
	}
	active := func(title string) string {
		return lipgloss.NewStyle().Foreground(background).Background(yellow).Bold(true).Render(" " + title + " ")
	}
	if strip := m.subTabs(200); !strings.Contains(strip, active(plan.title)) || strings.Contains(strip, active(bugs.title)) {
		t.Fatalf("sub-tab strip did not move its focus cue: %q", strip)
	}
	for id, index := range map[string]int{"bugs": 0, "backlog": 1} {
		selected := m.rowLine(id, m.items(id)[index], index, 40)
		delete(m.selected, id)
		unselected := m.rowLine(id, m.items(id)[index], index, 40)
		m.selected[id] = index
		if selected == unselected {
			t.Errorf("%s selected row has no cursor cue", id)
		}
	}
}

func TestCollapseAndNarrowLayout(t *testing.T) {
	m := fixtureApp(t)
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
	for _, text := range []string{"WORKERS", "NOTE [all]"} {
		if !strings.Contains(view, text) {
			t.Errorf("narrow render missing %q", text)
		}
	}
}

func TestViewFitsTerminal(t *testing.T) {
	m := fixtureApp(t)
	for _, size := range [][2]int{{120, 30}, {55, 18}} {
		m.width, m.height = size[0], size[1]
		for _, mode := range []string{"normal", "motion", "help", "filter", "rail-detail"} {
			m.help, m.filterActive = false, false
			m.railDetail = nil
			m.slide = 0
			switch mode {
			case "motion":
				m.beginTransition(1)
			case "help":
				m.help = true
			case "filter":
				m.filterActive = true
			case "rail-detail":
				m.railDetail = &item{Title: "Waiting test", Detail: strings.Repeat("Unlock the phone.\n", 20)}
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
	if m.focus != "ready" {
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

func TestFeedSkipsInternalFilesAndDatesOnlyNewestLine(t *testing.T) {
	m := fixtureApp(t)
	for name, body := range map[string]string{
		"alpha.status":            "working: started\nphase: testing - suite\n",
		".startup-network.status": "state=done\npid=123\n",
	} {
		if err := os.WriteFile(filepath.Join(m.paths.State, name), []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	feed, err := readFeed(m.paths.State)
	if err != nil || len(feed) != 2 {
		t.Fatalf("feed should contain only two task events: %v, %v", feed, err)
	}
	if feed[0].Status != "" || feed[1].Status == "" ||
		!strings.Contains(feed[0].Title, "started") || !strings.Contains(feed[1].Title, "testing") {
		t.Fatalf("feed assigned an inaccurate time or order: %v", feed)
	}
}

func TestArrowsStepSubTabsAndJKStayInPanel(t *testing.T) {
	m := fixtureApp(t)
	press(m, key('j'))
	_ = m.View()
	press(m, key('l'))
	if m.focus != "ready" {
		t.Fatalf("right chose %s instead of the next sub-tab", m.focus)
	}
	_ = m.View()
	press(m, key('h'))
	if m.focus != "workers" {
		t.Fatal("left did not focus the previous sub-tab")
	}
	m.width = 55
	m.selected["workers"] = 1
	_ = m.View()
	press(m, key('l'))
	if m.focus != "ready" {
		t.Fatal("right did not step through the sub-tabs in a one-column layout")
	}
	m.focus = "workers"
	for _, step := range []rune{'j', 'j', 'G'} {
		press(m, key(step))
		if m.focus != "workers" || m.selected["workers"] != 1 {
			t.Fatalf("%c at the bottom row left the panel: focus %s row %d", step, m.focus, m.selected["workers"])
		}
	}
	press(m, ctrl('d'))
	if m.focus != "workers" {
		t.Fatal("Ctrl-d at the bottom row left the panel")
	}
	m.selected["workers"] = 0
	press(m, key('k'))
	press(m, ctrl('u'))
	if m.focus != "workers" || m.selected["workers"] != 0 {
		t.Fatalf("k at the top row left the panel: focus %s", m.focus)
	}
	m.focus, m.slide = "ready", 0
	press(m, key('j'))
	press(m, key('k'))
	if m.focus != "ready" || m.slide != 0 {
		t.Fatalf("j/k in an empty panel changed sub-tab to %s", m.focus)
	}
}

func TestSectionHeadingsAreStyledAndSkipped(t *testing.T) {
	m := fixtureApp(t)
	m.data.Panels.FullQuestions = []item{
		{Title: "Your decisions, something is blocked behind each", Status: "section"},
		{Title: "UIX. Pick the UI.", Detail: "UIX. Pick the UI. Prototype or design."},
		{Title: "For Tarun", Status: "section"},
		{Title: "Can we use the staging phone?", Detail: "Production stays locked."},
	}
	press(m, key('3'))
	lines, owners := m.panelLines(panelSpec{id: "full_questions"}, 60)
	if owners[0] != -1 || owners[1] != -1 || !strings.Contains(lines[1], "────") {
		t.Fatalf("first heading lacks its divider: %q", lines[:2])
	}
	if !strings.Contains(lines[0], "Your decisions, something is blocked behind each") ||
		strings.Contains(strings.Join(lines, "\n"), "YOUR DECISIONS") || strings.Contains(lines[0], "section") {
		t.Fatalf("heading rendered as tagged row text: %q", lines[0])
	}
	heading := lipgloss.NewStyle().Foreground(cyan).Bold(true).Render("For Tarun")
	if !strings.Contains(strings.Join(lines, "\n"), heading) {
		t.Fatal("second heading is not styled as a heading")
	}
	if m.selected["full_questions"] != 1 {
		t.Fatalf("opening the page selected row %d, want the first question", m.selected["full_questions"])
	}
	press(m, key('j'))
	if m.selected["full_questions"] != 3 {
		t.Fatalf("j landed on row %d instead of skipping the heading", m.selected["full_questions"])
	}
	press(m, key('k'))
	press(m, key('k'))
	if m.selected["full_questions"] != 1 {
		t.Fatalf("k selected heading row %d", m.selected["full_questions"])
	}
	press(m, key('G'))
	press(m, key('g'))
	press(m, key('g'))
	if m.selected["full_questions"] != 1 {
		t.Fatal("gg selected a heading")
	}
	_ = m.View()
	rect := m.lastRects[0]
	m.Update(tea.MouseClickMsg{X: rect.x + 2, Y: rect.y + 3})
	if m.selected["full_questions"] != 1 {
		t.Fatal("a click on a heading changed the selection")
	}
}

func TestHighlightedQuestionShowsFullTextWithoutEnter(t *testing.T) {
	m := fixtureApp(t)
	long := "UIX. Pick the UI. " + strings.Repeat("Consider the detailed constraint. ", 20) + "Final decision needed."
	m.data.Panels.FullQuestions = []item{
		{Title: "UIX. Pick the UI.", Detail: long},
		{Title: "OPS. Release timing.", Detail: "OPS. Release timing. Choose the window."},
	}
	press(m, key('3'))
	view := m.View().Content
	if !strings.Contains(view, "Consider the detailed constraint.") || strings.Contains(view, "Choose the window.") {
		t.Fatal("the highlighted question did not show its own full text")
	}
	for range 10 {
		press(m, ctrl('f'))
	}
	if !strings.Contains(m.View().Content, "Final decision needed.") {
		t.Fatal("the highlighted question could not scroll to its end")
	}
	press(m, key('j'))
	view = m.View().Content
	if !strings.Contains(view, "Choose the window.") || strings.Contains(view, "Consider the detailed constraint.") {
		t.Fatal("moving the cursor did not move the shown question text")
	}
	m.width, m.height = 55, 18
	for _, line := range strings.Split(m.View().Content, "\n") {
		if lipgloss.Width(line) > m.width {
			t.Fatal("highlighted question overflowed the narrow panel")
		}
	}
}

func TestQuestionsLiveOnlyOnTheirPageWithACountBadge(t *testing.T) {
	m := fixtureApp(t)
	m.data.Panels.FullQuestions = []item{
		{Title: "Decisions", Status: "section"},
		{Title: "UIX. Pick the UI."},
		{Title: "OPS. Release timing."},
	}
	for _, spec := range pages[0] {
		if spec.id == "questions" || spec.title == "WAITING ON YOU" {
			t.Fatal("NOW still carries a questions sub-tab")
		}
	}
	badge := lipgloss.NewStyle().Foreground(background).Background(cyan).Bold(true).Render(" 2 ")
	if header := m.header(); !strings.Contains(header, " 3 QUESTIONS ") || !strings.Contains(header, badge) {
		t.Fatalf("questions tab has no open-question badge: %q", header)
	}
	m.data.Panels.FullQuestions = nil
	if strings.Contains(m.header(), badge) {
		t.Fatal("questions badge stayed with no open questions")
	}
}

func TestEmptyNotificationsAndReadyExplainThemselves(t *testing.T) {
	m := fixtureApp(t)
	if view := m.View().Content; !strings.Contains(view, "NOTIFICATIONS") || !strings.Contains(view, "none") {
		t.Fatal("empty notifications missing from the rail")
	}
	m.focus = "ready"
	if view := m.View().Content; !strings.Contains(view, "Nothing is waiting on you") {
		t.Fatal("empty READY FOR YOU did not explain what it shows")
	}
}

func TestSubTabsStayAboveFixedLargePanel(t *testing.T) {
	m := fixtureApp(t)
	for page := 0; page < 4; page++ {
		if len(pages[page]) < 2 {
			continue
		}
		m.page = page
		m.focus = pages[page][0].id
		strip := m.subTabs(200)
		last := -1
		for _, spec := range pages[page] {
			index := strings.Index(strip, spec.title)
			if index <= last {
				t.Fatalf("page %d sub-tabs out of order: %q", page, strip)
			}
			last = index
		}
		active := lipgloss.NewStyle().Foreground(background).Background(yellow).Bold(true).
			Render(" " + pages[page][0].title + " ")
		if !strings.Contains(strip, active) {
			t.Fatalf("page %d has no active sub-tab", page)
		}
		_ = m.View()
		first := m.lastRects[0]
		positions := map[string]int{}
		for _, rect := range m.lastRects[1:] {
			positions[rect.id] = rect.y
		}
		press(m, key('l'))
		_ = m.View()
		second := m.lastRects[0]
		if m.focus != pages[page][1].id || first.x != second.x || first.width != second.width {
			t.Fatalf("page %d large panel moved or skipped sub-tab", page)
		}
		for _, rect := range m.lastRects[1:] {
			if before, ok := positions[rect.id]; ok && before != rect.y {
				t.Fatalf("page %d summary %s moved from %d to %d", page, rect.id, before, rect.y)
			}
		}
		if !strings.Contains(m.subTabs(200), lipgloss.NewStyle().Foreground(background).
			Background(yellow).Bold(true).Render(" "+pages[page][1].title+" ")) {
			t.Fatalf("page %d active cue did not move", page)
		}
	}
}

func TestEverySubTabReachableByArrows(t *testing.T) {
	m := fixtureApp(t)
	for page, specs := range pages {
		m.page, m.focus = page, specs[0].id
		for index := 1; index < len(specs); index++ {
			press(m, key('l'))
			if m.focus != specs[index].id {
				t.Fatalf("page %d right skipped %s", page, specs[index].id)
			}
		}
		for index := len(specs) - 2; index >= 0; index-- {
			press(m, key('h'))
			if m.focus != specs[index].id {
				t.Fatalf("page %d left skipped %s", page, specs[index].id)
			}
		}
	}
}

func TestNarrowTabStripKeepsFocusedTabVisible(t *testing.T) {
	m := fixtureApp(t)
	m.width, m.height = 55, 18
	active := func(title string) string {
		return lipgloss.NewStyle().Foreground(background).Background(yellow).Bold(true).Render(" " + title + " ")
	}
	m.focus = "feed"
	strip := m.subTabs(m.width - 4)
	if !strings.Contains(strip, active("FEED")) {
		t.Fatalf("focused FEED sub-tab was clipped from the narrow strip: %q", strip)
	}
	if !strings.Contains(m.View().Content, active("FEED")) {
		t.Fatal("focused FEED sub-tab was clipped at narrow width")
	}
	m.page, m.focus = 1, "backlog"
	strip = m.subTabs(m.width - 4)
	if !strings.Contains(strip, active("BACKLOG")) {
		t.Fatalf("PLANNING sub-tab strip lost its focused tab: %q", strip)
	}
	view := m.View().Content
	if !strings.Contains(view, "2 PLANNING") || !strings.Contains(view, active("BACKLOG")) {
		t.Fatal("focused PLANNING page or BACKLOG sub-tab was clipped")
	}
}

func TestShortWideLayoutKeepsCardsInsideTheBody(t *testing.T) {
	m := fixtureApp(t)
	m.width, m.height = 120, 24
	body := max(5, m.height-8)
	_ = m.View()
	focus := m.focus
	for _, rect := range m.lastRects {
		if rect.y+rect.height > 4+body {
			t.Fatalf("%s hit rect %d..%d reaches past the body ending at %d", rect.id, rect.y, rect.y+rect.height, 4+body)
		}
	}
	for _, y := range []int{4 + body, 4 + body + 2, 4 + body + 3} {
		m.Update(tea.MouseClickMsg{X: m.width - 2, Y: y})
		if m.focus != focus {
			t.Fatalf("click at y=%d below the cards focused %s", y, m.focus)
		}
	}
}

func TestInformationRailShowsRowsAndScrolls(t *testing.T) {
	m := fixtureApp(t)
	m.data.Panels.Alerts = []item{{Title: "S22 locked", Status: "locked", Alert: true}}
	m.data.Panels.TestQueue = []item{
		{Title: "EDITOR", Status: "section"},
		{Title: "RUNNING: suite", Status: "running 5m"},
		{Title: "Galaxy S22", Status: "section"},
		{Title: "Locked", Status: "locked"},
	}
	m.data.Panels.Builds = []item{{Title: "Android build", Status: "passed"}}
	m.data.Panels.Routines = []item{{Title: "Daily check", Status: "done"}}
	m.data.Panels.Allowance = []item{{Title: "Claude", Status: "70% left"}}
	for _, page := range pages {
		for _, spec := range page {
			for _, rail := range railPanels {
				if spec.id == rail.id {
					t.Fatalf("rail panel %s remains a main sub-tab", spec.id)
				}
			}
		}
	}
	seen := map[string]bool{}
	for offset := 0; offset < 50; offset += 3 {
		m.railOffset = offset
		view := m.View().Content
		for _, value := range []string{"NOTIFICATIONS", "TEST QUEUE", "LATEST BUILDS", "DAILY ROUTINES", "AI ALLOWANCE", "S22 locked", "RUNNING: suite", "Android build", "Daily check", "Claude"} {
			seen[value] = seen[value] || strings.Contains(view, value)
		}
	}
	for value, found := range seen {
		if !found {
			t.Errorf("rail never displayed %s while scrolling", value)
		}
	}
}

func TestWorkersGroupedByProjectWithoutSelectingHeadings(t *testing.T) {
	m := fixtureApp(t)
	m.data.Rows = append(m.data.Rows, worker{ID: "gamma", Kind: "playbot", Project: "widget",
		Title: "[Playbot] UI review", Phase: "working"})
	rows := m.items("workers")
	lines, owners := m.panelLines(panelSpec{id: "workers"}, 80)
	joined := strings.Join(lines, "\n")
	for _, value := range []string{"WIDGET  2 workers", "GADGET  1 worker", "[Playbot] UI review"} {
		if !strings.Contains(joined, value) {
			t.Fatalf("project grouping missing %q", value)
		}
	}
	if len(rows) != 3 || owners[0] != -1 {
		t.Fatal("headings became selectable or worker group lost rows")
	}
	for index := range rows {
		press(m, key('j'))
		if m.selected["workers"] != index {
			t.Fatalf("j selected %d, want worker %d", m.selected["workers"], index)
		}
	}
}

func TestParkedPlaybotLaneWaitsOnTheCaptain(t *testing.T) {
	m := fixtureApp(t)
	chat := "playbot://workspace/space-live/thread/thread-parked"
	m.data.Rows = append(m.data.Rows, worker{ID: "lane-parked", Kind: "playbot", Project: "widget",
		Title: "[Playbot] Choosing a launch window", Phase: "parked", PhaseSince: time.Now().Unix() - 30,
		Note: "Waiting on you: answer the card in this Playbot chat", PRURL: chat})
	rows := m.items("workers")
	index := -1
	for position := range rows {
		if rows[position].ID == "lane-parked" {
			index = position
		}
	}
	if index < 0 {
		t.Fatal("a parked Playbot lane is missing from WORKERS")
	}
	parked := rows[index]
	if parked.Status != "parked" || parked.Link != chat {
		t.Fatalf("parked lane row reads status %q link %q", parked.Status, parked.Link)
	}
	detail := m.detail("workers", parked, 80)
	if !strings.Contains(detail, "Waiting on you") || !strings.Contains(detail, "Chat: "+chat) {
		t.Fatalf("parked lane detail reads: %q", detail)
	}
	if line := m.rowLine("workers", parked, index, 100); !strings.Contains(line, "PARKED") {
		t.Fatalf("parked lane row reads: %q", line)
	}
	if phaseColor("parked").GetForeground() == muted || activePhase("parked") {
		t.Fatal("a parked lane is drawn as an idle or running worker")
	}
}

func TestQuestionReplyAndFullDetail(t *testing.T) {
	m := fixtureApp(t)
	m.page, m.focus = 2, "full_questions"
	m.data.Panels.FullQuestions = []item{{ID: "question-1", Title: "UIX. Prototype or design UI.",
		Detail: "UIX. Prototype or design UI. " + strings.Repeat("Consider the detailed constraint. ", 25) + "Final decision needed."}}
	m.selected["full_questions"] = 0
	if !strings.Contains(m.detail("full_questions", m.data.Panels.FullQuestions[0], 40), "Final") ||
		!strings.Contains(m.detail("full_questions", m.data.Panels.FullQuestions[0], 40), "needed.") {
		t.Fatal("question detail was truncated")
	}
	if !strings.Contains(m.View().Content, "REPLY [UIX]") {
		t.Fatal("question reply label missing")
	}
	for range 10 {
		press(m, ctrl('f'))
	}
	if !strings.Contains(m.View().Content, "Final decision") {
		t.Fatal("highlighted question could not scroll to its end")
	}
	code := t.TempDir()
	if err := os.MkdirAll(filepath.Join(code, "bin"), 0700); err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\ncat > \"$FM_HOME/reply.txt\"\n"
	if err := os.WriteFile(filepath.Join(code, "bin", "fm-inbox.sh"), []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	m.paths.Code = code
	press(m, key('r'))
	if !m.inputActive {
		t.Fatal("r did not open the reply input")
	}
	m.input.SetValue("Use the prototype")
	command := press(m, special(tea.KeyEnter))
	if command == nil {
		t.Fatal("reply did not submit")
	}
	command()
	message, err := os.ReadFile(filepath.Join(m.paths.Home, "reply.txt"))
	if err != nil || !strings.Contains(string(message), "Reply [UIX]: UIX. Prototype or design UI.") ||
		!strings.Contains(string(message), "Answer: Use the prototype") {
		t.Fatalf("reply lost its question context: %q, %v", message, err)
	}
}

func TestMouseIgnoresRowsPastThePanelWindow(t *testing.T) {
	m := fixtureApp(t)
	m.width, m.height = 120, 24
	for index := range 20 {
		m.data.Rows = append(m.data.Rows, worker{ID: fmt.Sprintf("w%d", index), Title: fmt.Sprintf("Worker %d", index)})
	}
	m.selected["workers"] = 0
	_ = m.View()
	rect := m.lastRects[0]
	for _, y := range []int{rect.y + rect.height - 2, rect.y + rect.height - 1} {
		m.Update(tea.MouseClickMsg{X: rect.x + 2, Y: y})
		if m.selected["workers"] != 0 {
			t.Fatalf("click at y=%d selected row %d past the drawn window", y, m.selected["workers"])
		}
	}
}

func TestReplyKeepsItsQuestionWhenTheCursorMoves(t *testing.T) {
	m := fixtureApp(t)
	m.page, m.focus = 2, "full_questions"
	m.data.Panels.FullQuestions = []item{
		{ID: "question-1", Title: "UIX. Prototype or design UI.", Detail: "first"},
		{ID: "question-2", Title: "OPS. Release timing.", Detail: "second"},
	}
	m.selected["full_questions"] = 0
	code := t.TempDir()
	if err := os.MkdirAll(filepath.Join(code, "bin"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(code, "bin", "fm-inbox.sh"), []byte("#!/bin/sh\ncat > \"$FM_HOME/reply.txt\"\n"), 0700); err != nil {
		t.Fatal(err)
	}
	m.paths.Code = code
	press(m, key('r'))
	m.input.SetValue("use the prototype")
	_ = m.View()
	rect := m.lastRects[0]
	_, owners := m.panelLines(panelSpec{id: "full_questions"}, rect.width-4)
	line := 0
	for line < len(owners) && owners[line] != 1 {
		line++
	}
	m.Update(tea.MouseClickMsg{X: rect.x + 2, Y: rect.y + 3 + line - m.panelOffset(panelSpec{id: "full_questions"}, rect.width-4, rect.height, owners)})
	if m.selected["full_questions"] != 1 {
		t.Fatalf("click left the selection on question %d", m.selected["full_questions"])
	}
	if !strings.Contains(m.View().Content, "REPLY [UIX]") {
		t.Fatal("reply label followed the click instead of the question the reply started on")
	}
	command := press(m, special(tea.KeyEnter))
	if command == nil {
		t.Fatal("reply did not submit")
	}
	command()
	message, err := os.ReadFile(filepath.Join(m.paths.Home, "reply.txt"))
	if err != nil || !strings.Contains(string(message), "Reply [UIX]: UIX. Prototype or design UI.") ||
		!strings.Contains(string(message), "Answer: use the prototype") ||
		strings.Contains(string(message), "Reply [OPS]") {
		t.Fatalf("reply left its question after the cursor moved: %q, %v", message, err)
	}
}

func TestMouseSelectsDisplayedRowsAndTabs(t *testing.T) {
	m := fixtureApp(t)
	m.data.Rows[0].Note = "first detail\nsecond detail\nthird detail"
	m.selected["workers"] = 0
	m.expanded["workers"] = 1
	_ = m.View()
	rect := m.lastRects[0]
	m.slide = 0
	activeX := rect.x + 2
	m.Update(tea.MouseClickMsg{X: activeX, Y: rect.y + 1})
	if m.slide != 0 || m.focus != "workers" {
		t.Fatal("clicking the active sub-tab started motion")
	}
	m.Update(tea.MouseClickMsg{X: rect.x + 2, Y: rect.y + 3 + 8})
	if m.selected["workers"] != 1 || m.slide != 0 {
		_, owners := m.panelLines(panelSpec{id: "workers"}, rect.width-4)
		t.Fatalf("click after expanded detail chose row %d or slide %d; owners=%v", m.selected["workers"], m.slide, owners)
	}
	m.Update(tea.MouseClickMsg{X: rect.x + 1 + lipgloss.Width(m.subTab(pages[0][0])) + 2, Y: rect.y + 1})
	if m.focus != "ready" || m.slide == 0 {
		t.Fatal("clicking another sub-tab did not focus and animate it")
	}
	m.focus, m.slide = "workers", 0
	m.expanded["workers"] = 0
	m.data.Rows = nil
	for index := range 20 {
		m.data.Rows = append(m.data.Rows, worker{ID: fmt.Sprintf("w%d", index), Title: fmt.Sprintf("Worker %d", index)})
	}
	m.selected["workers"] = 0
	m.scrollOffset["workers"] = 15
	_ = m.View()
	rect = m.lastRects[0]
	m.Update(tea.MouseClickMsg{X: rect.x + 2, Y: rect.y + 3})
	if m.selected["workers"] != 3 || m.slide != 0 {
		t.Fatalf("click in scrolled panel selected row %d", m.selected["workers"])
	}
}

func TestRailRowsStayOnEveryPageAndClicksShowDetail(t *testing.T) {
	m := fixtureApp(t)
	m.data.Panels.Alerts = []item{{Title: "Device locked", Detail: "Unlock S22", Alert: true, Nid: "locked:s22", Sig: "waiter"}}
	m.data.Panels.TestQueue = []item{{Title: "EDITOR", Status: "section"}, {Title: "NEXT: Build widget", Status: "waiting 4m"}}
	for page := range pages {
		m.page, m.focus = page, pages[page][0].id
		view := m.View().Content
		if !strings.Contains(view, "NOTIFICATIONS") || !strings.Contains(view, "NEW Device locked") ||
			!strings.Contains(view, "TEST QUEUE") || !strings.Contains(view, "NEXT: Build widget") {
			t.Fatalf("page %d lost actual rail rows: %q", page, view)
		}
		if _, ok := m.railHit[7]; !ok {
			t.Fatalf("page %d has no clickable alert row", page)
		}
	}
	m.Update(tea.MouseClickMsg{X: m.width - 4, Y: 7})
	if len(m.newAlerts()) != 0 || m.railDetail == nil || !strings.Contains(m.View().Content, "Unlock S22") {
		t.Fatal("clicking a rail notification did not acknowledge it or show detail")
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

func TestWorkerRowsShowTheirTagInThePhaseColour(t *testing.T) {
	m := fixtureApp(t)
	m.data.Panels.WorkerTags = map[string]string{"alpha": "S22 TEST 5m"}
	rows := m.items("workers")
	var alpha, beta int
	for index, row := range rows {
		if row.ID == "alpha" {
			alpha = index
		} else {
			beta = index
		}
	}
	tagged := m.rowLine("workers", rows[alpha], alpha, 100)
	if !strings.Contains(tagged, phaseColor("testing").Render("5m  S22 TEST 5m")) || strings.Contains(tagged, "TESTING") {
		t.Fatalf("tagged worker row lost its tag or phase colour: %q", tagged)
	}
	if plain := m.rowLine("workers", rows[beta], beta, 100); !strings.Contains(plain, "FIXING") {
		t.Fatalf("untagged worker did not fall back to its phase word: %q", plain)
	}
	if line := m.rowLine("workers", rows[alpha], alpha, 40); strings.Contains(line, "\n") || lipgloss.Width(line) > 40 {
		t.Fatalf("tagged row is not one line within the panel: %q", line)
	}
	m.data.Rows[0].Note = "holding S22 for the merge benchmark; then the full suite"
	m.selected["workers"] = alpha
	m.expanded["workers"] = alpha + 1
	if !strings.Contains(m.View().Content, "then the full suite") {
		t.Fatal("expanding a tagged worker did not show its full note")
	}
}

func TestSelectedRowTagStaysReadableOnTheHighlight(t *testing.T) {
	m := fixtureApp(t)
	m.data.Panels.TestQueue = []item{{Title: "RUNNING: Build widget", Status: "running 8m"}}
	for _, id := range []string{"workers", "test_queue"} {
		row := m.items(id)[0]
		delete(m.selected, id)
		unselected := m.rowLine(id, row, 0, 80)
		m.selected[id] = 0
		selected := m.rowLine(id, row, 0, 80)
		status := row.Status
		if id == "workers" {
			status = "5m  TESTING"
			if row.ID != "alpha" {
				status = "1m  FIXING"
			}
		}
		chip := phaseChip(row.Status).Render(status)
		if !strings.Contains(selected, chip) || strings.Contains(selected, phaseColor(row.Status).Render(status)) {
			t.Fatalf("%s selected tag is not a dark-text chip: %q", id, selected)
		}
		if unselected == selected || !strings.Contains(unselected, phaseColor(row.Status).Render(status)) {
			t.Fatalf("%s unselected tag lost its phase colour: %q", id, unselected)
		}
	}
}

func TestRefreshMovesASelectionOffAHeading(t *testing.T) {
	m := fixtureApp(t)
	m.data.Panels.FullQuestions = []item{
		{Title: "Your decisions", Status: "section"},
		{ID: "question-0", Title: "Pick the UI", Detail: "Prototype or design"},
		{Title: "For Tarun", Status: "section"},
		{ID: "question-1", Title: "Which device?", Detail: "Use the staging device"},
	}
	press(m, key('3'))
	m.selected["full_questions"] = 1
	m.data.Panels.TestQueue = []item{{Title: "Full suite", Status: "section"}, {Title: "RUNNING: Build widget", Status: "running 8m"}}
	data := m.data
	data.Panels.FullQuestions = []item{
		{Title: "Your decisions", Status: "section"},
		{Title: "For Tarun", Status: "section"},
		{ID: "question-1", Title: "Which device?", Detail: "Use the staging device"},
	}
	m.Update(refreshedMsg{data: data, feed: m.feed})
	if m.selected["full_questions"] != 2 || m.selectedQuestion() == nil || m.selectedQuestion().ID != "question-1" {
		t.Fatalf("answered question left the cursor on a heading: %#v", m.selected)
	}
	if !strings.Contains(m.View().Content, "Use the staging device") {
		t.Fatal("the next question's full text did not show after a refresh")
	}
	data.Panels.FullQuestions = []item{
		{ID: "question-0", Title: "Pick the UI"},
		{Title: "Your decisions", Status: "section"},
		{Title: "For Tarun", Status: "section"},
	}
	m.Update(refreshedMsg{data: data, feed: m.feed})
	if m.selected["full_questions"] != 0 {
		t.Fatalf("cursor did not fall back to the question above the headings: %#v", m.selected)
	}
}

func TestSelectedYellowPhaseTagIsADarkChip(t *testing.T) {
	m := fixtureApp(t)
	for _, phase := range []string{"testing", "validating"} {
		m.data.Panels.TestQueue = []item{{Title: "Phone run", Status: phase}}
		m.selected["test_queue"] = 0
		selected := m.rowLine("test_queue", m.items("test_queue")[0], 0, 80)
		inverted := lipgloss.NewStyle().Foreground(yellow).Background(background).Bold(true).Render(phase)
		if !strings.Contains(selected, inverted) {
			t.Fatalf("%s tag on the yellow bar is not a dark chip in its colour: %q", phase, selected)
		}
	}
	m.data.Panels.TestQueue = []item{{Title: "Build", Status: "running 8m"}}
	selected := m.rowLine("test_queue", m.items("test_queue")[0], 0, 80)
	if !strings.Contains(selected, lipgloss.NewStyle().Foreground(background).Background(cyan).Bold(true).Render("running 8m")) {
		t.Fatalf("non-yellow selected tag lost its coloured chip: %q", selected)
	}
}

func TestPageOrderAndNumberKeys(t *testing.T) {
	want := []string{"NOW", "PLANNING", "QUESTIONS", "TESTING"}
	first := []string{"workers", "bugs", "full_questions", "landings"}
	if strings.Join(pageNames, ",") != strings.Join(want, ",") {
		t.Fatalf("page names = %v, want %v", pageNames, want)
	}
	m := fixtureApp(t)
	for index, name := range want {
		press(m, key(rune('1'+index)))
		if m.page != index || m.focus != first[index] {
			t.Fatalf("%d opened page %d focus %s, want %s", index+1, m.page, m.focus, name)
		}
		if header := m.header(); !strings.Contains(header, fmt.Sprintf(" %d %s ", index+1, name)) {
			t.Fatalf("header tab %d is not %s: %q", index+1, name, header)
		}
	}
}

// pageTabX returns the screen column of the first cell of a page tab, derived
// from the same layout code the header renders with.
func pageTabX(m *app, page int) int {
	tabs, start := m.pageTabs()
	x := 1
	for index := start; index < page; index++ {
		x += lipgloss.Width(tabs[index]) + 2
	}
	return x
}

func TestMouseClickSwitchesPageTabs(t *testing.T) {
	for _, width := range []int{120, 60} {
		m := fixtureApp(t)
		m.width, m.height = width, 30
		for _, page := range []int{2, 1, 3, 0} {
			_ = m.View()
			command := func() tea.Cmd {
				_, c := m.Update(tea.MouseClickMsg{Button: tea.MouseLeft, X: pageTabX(m, page) + 1, Y: 2})
				return c
			}()
			if m.page != page {
				t.Fatalf("width %d: click on page tab %d left page %d", width, page, m.page)
			}
			if command == nil {
				t.Fatalf("width %d: page click did not animate", width)
			}
			if m.focus != pages[page][0].id && !(page == 0 && m.focus == "workers") {
				t.Fatalf("width %d: page %d focus %s", width, page, m.focus)
			}
		}
		before := m.page
		m.Update(tea.MouseClickMsg{Button: tea.MouseLeft, X: m.width - 3, Y: 2})
		if m.page != before {
			t.Fatalf("width %d: click past the tabs changed the page", width)
		}
	}
}

func TestMouseClickSwitchesSubTabs(t *testing.T) {
	for _, size := range [][2]int{{120, 30}, {70, 30}, {50, 30}} {
		m := fixtureApp(t)
		m.width, m.height = size[0], size[1]
		for page := range pages {
			m.page, m.focus = page, pages[page][0].id
			for _, target := range pages[page] {
				for _, from := range pages[page] {
					m.focus = from.id
					_ = m.View()
					rect := m.lastRects[0]
					innerWidth := max(1, rect.width-4)
					x := 0
					start := m.subTabStart(innerWidth)
					found := false
					for _, spec := range pages[page][start:] {
						width := lipgloss.Width(m.subTab(spec))
						if spec.id == target.id && x < innerWidth {
							m.Update(tea.MouseClickMsg{Button: tea.MouseLeft, X: rect.x + 1 + x, Y: rect.y + 1})
							found = true
							break
						}
						x += width + 1
					}
					if found && m.focus != target.id {
						t.Fatalf("%v page %d: click on sub-tab %s from %s focused %s (start %d)", size, page, target.id, from.id, m.focus, start)
					}
				}
			}
		}
	}
}

func TestNarrowInformationFallback(t *testing.T) {
	m := fixtureApp(t)
	m.width, m.height = 55, 18
	if view := m.View().Content; strings.Contains(view, "INFORMATION") {
		t.Fatal("narrow terminal did not prioritize the main panel")
	}
	press(m, key('s'))
	if view := m.View().Content; !strings.Contains(view, "INFORMATION") || !strings.Contains(view, "NOTIFICATIONS") {
		t.Fatal("narrow terminal cannot open the information rail")
	}
	press(m, key('s'))
	if view := m.View().Content; !strings.Contains(view, "WORKERS") {
		t.Fatal("narrow terminal cannot return to the main panel")
	}
}

func TestMouseClickPageTabIgnoredWhileModal(t *testing.T) {
	for _, mode := range []rune{'?', '/', 'i'} {
		m := fixtureApp(t)
		m.width, m.height = 120, 30
		_ = m.View()
		press(m, key(mode))
		if !m.help && !m.filterActive && !m.inputActive {
			t.Fatalf("%c did not open a modal", mode)
		}
		if mode == '/' {
			press(m, key('x'))
		}
		_ = m.View()
		focus := m.focus
		m.Update(tea.MouseClickMsg{Button: tea.MouseLeft, X: pageTabX(m, 1) + 1, Y: 2})
		if m.page != 0 || m.focus != focus {
			t.Fatalf("%c: page tab click switched to page %d focus %s", mode, m.page, m.focus)
		}
		if mode == '/' {
			press(m, special(tea.KeyEnter))
			if m.filters[focus] != "x" {
				t.Fatalf("filter landed on the wrong panel: %v", m.filters)
			}
		}
	}
}

func TestMergeWaitingWorkerIsTaggedColouredAndSortedFirst(t *testing.T) {
	m := fixtureApp(t)
	url := "https://github.com/example/repo/pull/78"
	m.data.Panels.WorkerTags = map[string]string{"beta": "PR #78 READY TO MERGE"}
	m.data.Panels.MergeWaiting = map[string]string{"beta": url}
	rows := m.items("workers")
	if rows[0].ID != "beta" || rows[0].Status != mergeWaitingPhase || rows[0].Link != url {
		t.Fatalf("merge-waiting worker is not the first row with its PR link: %#v", rows[0])
	}
	line := m.rowLine("workers", rows[0], 0, 100)
	style := phaseColor(mergeWaitingPhase)
	if sel, ok := m.selected["workers"]; ok && sel == 0 {
		style = phaseChip(mergeWaitingPhase)
	}
	open, _, _ := strings.Cut(style.Render("\x00"), "\x00")
	if open == "" {
		t.Fatal("pr-ready style rendered no colour sequence")
	}
	_, tagged, ok := strings.Cut(line, open)
	if !ok || !strings.Contains(tagged, "PR #78 READY TO MERGE") {
		t.Fatalf("row tag is not drawn in the pr-ready colour: %q", line)
	}
	if phaseColor(mergeWaitingPhase).GetForeground() == phaseColor("done").GetForeground() ||
		phaseColor(mergeWaitingPhase).GetForeground() == phaseColor("ready-to-merge").GetForeground() {
		t.Fatal("merge-waiting colour is not distinct from done and ready")
	}
	m.selected["workers"] = 0
	m.expanded["workers"] = 1
	if !strings.Contains(m.View().Content, url) {
		t.Fatal("selected merge-waiting worker did not show the full PR URL")
	}
	m.data.Panels.MergeWaiting = nil
	for _, row := range m.items("workers") {
		if row.Status == mergeWaitingPhase {
			t.Fatalf("worker without a waiting PR got the merge look: %#v", row)
		}
	}
}

func twoAlerts() []item {
	return []item{
		{Title: "alpha: failed", Detail: "Build crashed. Since 2 minutes ago.", Status: "failed", Alert: true, Nid: "failed:alpha", Sig: "build crashed"},
		{Title: "3 decisions waiting on you", Status: "decisions", Alert: true, Nid: "decisions:summary", Sig: "a\nb\nc"},
	}
}

func TestNewAlertsAppearAsCountedNotificationOnEveryPage(t *testing.T) {
	m := fixtureApp(t)
	m.data.Panels.Alerts = twoAlerts()
	for page := 0; page < len(pages); page++ {
		m.setPage(page)
		header := m.header()
		if !strings.Contains(header, "2 NEW: alpha: failed") {
			t.Fatalf("page %d header lacks the counted notification: %q", page, header)
		}
	}
	m.setPage(0)
	if !strings.Contains(m.View().Content, "NEW alpha: failed") {
		t.Fatal("unseen alert row is not marked NEW")
	}
}

func TestViewingAnAlertMarksItSeenAndItRecedes(t *testing.T) {
	m := fixtureApp(t)
	m.data.Panels.Alerts = twoAlerts()
	_ = m.View()
	m.Update(tea.MouseClickMsg{X: m.width - 4, Y: 7})
	if got := len(m.newAlerts()); got != 1 {
		t.Fatalf("selecting the first alert left %d new, want 1", got)
	}
	header := m.header()
	if !strings.Contains(header, "1 NEW: 3 decisions waiting on you") {
		t.Fatalf("header should count only the unseen alert: %q", header)
	}
	if m.alertCount(0) != 0 {
		t.Fatalf("NOW tab badge counts %d rail notifications, want 0", m.alertCount(0))
	}
	if !strings.Contains(m.View().Content, "alpha: failed") {
		t.Fatal("a seen alert must stay listed until its cause clears")
	}
	press(m, special(tea.KeyEsc))
	_ = m.View()
	m.Update(tea.MouseClickMsg{X: m.width - 4, Y: 9})
	if len(m.newAlerts()) != 0 || strings.Contains(m.header(), "NEW") {
		t.Fatal("viewing every alert should clear the notification")
	}
}

func TestNextNotificationKeyOpensAndAcknowledgesEachNewAlert(t *testing.T) {
	m := fixtureApp(t)
	m.data.Panels.Alerts = twoAlerts()
	press(m, key('n'))
	if m.railDetail == nil || m.railDetail.Nid != "failed:alpha" || len(m.newAlerts()) != 1 {
		t.Fatalf("n should open and acknowledge the first new alert, detail %#v", m.railDetail)
	}
	press(m, key('n'))
	if m.railDetail == nil || m.railDetail.Nid != "decisions:summary" || len(m.newAlerts()) != 0 {
		t.Fatalf("n should step to the next new alert, detail %#v", m.railDetail)
	}
	if strings.Contains(m.header(), "NEW") {
		t.Fatal("acknowledging every alert by keyboard should clear the header count")
	}
	press(m, key('n'))
	if m.notice != "No new notifications" {
		t.Fatalf("n with nothing new should say so, got %q", m.notice)
	}
}

func TestSeenAlertSurvivesRestartAndReturnsWhenItChanges(t *testing.T) {
	m := fixtureApp(t)
	m.data.Panels.Alerts = twoAlerts()
	_ = m.View()
	m.Update(tea.MouseClickMsg{X: m.width - 4, Y: 7})
	press(m, special(tea.KeyEsc))
	_ = m.View()
	m.Update(tea.MouseClickMsg{X: m.width - 4, Y: 9})
	again := newApp(m.paths, m.data, nil)
	if len(again.newAlerts()) != 0 {
		t.Fatal("seen state did not survive a board restart")
	}
	changed := twoAlerts()
	changed[1].Sig = "a\nb\nc\nd"
	again.data.Panels.Alerts = changed
	fresh := again.newAlerts()
	if len(fresh) != 1 || fresh[0].Nid != "decisions:summary" {
		t.Fatalf("a changed issue should be new again, got %#v", fresh)
	}
}

func TestClearedAlertIsForgottenSoARecurrenceIsNewAgain(t *testing.T) {
	m := fixtureApp(t)
	m.data.Panels.Alerts = twoAlerts()
	_ = m.View()
	m.Update(tea.MouseClickMsg{X: m.width - 4, Y: 7})
	press(m, special(tea.KeyEsc))
	_ = m.View()
	m.Update(tea.MouseClickMsg{X: m.width - 4, Y: 9})
	cleared := m.data
	cleared.Panels.Alerts = twoAlerts()[1:]
	m.Update(refreshedMsg{data: cleared})
	if _, kept := m.seen["failed:alpha"]; kept {
		t.Fatal("a cleared alert's seen record should be dropped")
	}
	if len(loadSeen(m.paths.State)) != 1 {
		t.Fatal("the pruned seen state was not persisted")
	}
	back := m.data
	back.Panels.Alerts = twoAlerts()
	m.Update(refreshedMsg{data: back})
	fresh := m.newAlerts()
	if len(fresh) != 1 || fresh[0].Nid != "failed:alpha" {
		t.Fatalf("a recurrence should be new, got %#v", fresh)
	}
}

func TestNewAlertRowKeepsItsFullStatusWithinTheRowWidth(t *testing.T) {
	m := fixtureApp(t)
	m.data.Panels.Alerts = twoAlerts()
	delete(m.selected, "alerts")
	for index, row := range m.items("alerts") {
		if !m.isNew(row) {
			t.Fatalf("row %d should be unseen", index)
		}
		line := m.rowLine("alerts", row, index, 60)
		plain := ansi.Strip(line)
		if !strings.Contains(plain, "NEW ") || !strings.HasSuffix(plain, row.Status) {
			t.Fatalf("NEW row lost its status: %q", plain)
		}
		if got := lipgloss.Width(line); got > 60 {
			t.Fatalf("NEW row is %d wide, wider than the 60-column panel: %q", got, plain)
		}
	}
}

func TestWorkerRowShowsRuntimeAndModel(t *testing.T) {
	m := fixtureApp(t)
	m.data.Panels.WorkerRuntimes = map[string]runtime{
		"alpha": {Runtime: "Claude", Model: "Opus 5.5", Effort: "high"},
		"beta":  {Runtime: "Codex"},
	}
	rows := m.items("workers")
	for index, row := range rows {
		line := m.rowLine("workers", row, index, 100)
		switch row.ID {
		case "alpha":
			if !strings.Contains(line, "Claude (Opus 5.5)") || strings.Contains(line, "effort") {
				t.Fatalf("row should carry the runtime and model but not the effort: %q", line)
			}
			if !strings.Contains(row.Detail, "Runtime: Claude (Opus 5.5), effort high") {
				t.Fatalf("detail lost the full runtime: %q", row.Detail)
			}
		case "beta":
			if !strings.Contains(line, "Codex  ") || strings.Contains(line, "Codex (") || !strings.HasPrefix(row.Detail, "Runtime: Codex") || strings.Contains(row.Detail, "Codex (") {
				t.Fatalf("runtime without a model should read alone: %q / %q", line, row.Detail)
			}
		}
		if lipgloss.Width(line) > 100 {
			t.Fatalf("row overflows: %q", line)
		}
	}
	m.data.Panels.WorkerRuntimes = nil
	for _, row := range m.items("workers") {
		if strings.Contains(row.Detail, "Runtime:") {
			t.Fatalf("a worker with no runtime record must show none: %q", row.Detail)
		}
	}
}
